// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {VaultTestBase} from "./VaultTestBase.sol";
import {BlockchainVault} from "../src/BlockchainVault.sol";
import {IBlockchainVault} from "../src/interfaces/IBlockchainVault.sol";
import {ReentrancyAttacker} from "./mocks/ReentrancyAttacker.sol";
import {ReentrantERC20} from "./mocks/ReentrantERC20.sol";
import {MockReturnFalseERC20} from "./mocks/MockReturnFalseERC20.sol";

/// @notice 在付款**进行中**读取金库状态，用以证明状态变更发生在外部调用之前
///         （Checks-Effects-Interactions）。
contract PayoutObserver {
    BlockchainVault public immutable VAULT;
    address public immutable SIGNER;

    uint256 public nonceSeenDuringPayout;
    uint256 public spentTodaySeenDuringPayout;
    uint256 public payoutCount;

    constructor(BlockchainVault vault_, address signer_) {
        VAULT = vault_;
        SIGNER = signer_;
    }

    receive() external payable {
        payoutCount += 1;
        nonceSeenDuringPayout = VAULT.getNonce(SIGNER);
        spentTodaySeenDuringPayout = VAULT.getSpentToday(address(0));
    }
}

/// @notice 需求文档 4.1 节的威胁模型，逐条写成可执行的攻击（SC-1 … SC-6）。
contract AttackTest is VaultTestBase {
    // ---------------------------------------------------------------------
    // SC-1 —— 重入
    // ---------------------------------------------------------------------

    /// @dev 这个恶意收款方**同时也是 Admin**，因此能拦住重入调用的不可能是权限控制，
    ///      只可能是重入锁。
    function test_ReentrancyGuardBlocksEthReentrancy() public {
        ReentrancyAttacker attacker = new ReentrancyAttacker(vault);

        vm.prank(owner);
        vault.addAdmin(address(attacker));

        attacker.attack(1 ether);

        assertTrue(attacker.attempted(), "the receive hook must have tried to re-enter");
        assertTrue(attacker.reentryReverted(), "the re-entrant call must revert");
        assertEq(
            attacker.reentryErrorSelector(),
            ReentrancyGuard.ReentrancyGuardReentrantCall.selector,
            "the guard, not access control, must be the blocker"
        );

        // 有且只有一笔提款成功。
        assertEq(address(attacker).balance, 1 ether);
        assertEq(vault.getETHBalance(), 99 ether);
    }

    /// @dev 代币发起的重入（在 ERC20 的 `_update` 里回调金库）同样被重入锁拦住。
    ///      该代币也被设为 Admin，确保拦截者不是权限修饰符。
    function test_ReentrancyGuardBlocksErc20Reentrancy() public {
        ReentrantERC20 hostileToken = new ReentrantERC20();
        hostileToken.setVault(vault);
        hostileToken.mint(alice, 1_000e18);

        vm.startPrank(alice);
        hostileToken.approve(address(vault), 1_000e18);
        vault.depositERC20(address(hostileToken), 1_000e18);
        vm.stopPrank();

        // 同样把这个代币设为 Admin，这样拦截者只可能是重入锁。
        vm.prank(owner);
        vault.addAdmin(address(hostileToken));

        vm.prank(owner);
        vault.withdrawERC20(address(hostileToken), bob, 100e18);

        assertTrue(hostileToken.attempted(), "the token must have tried to re-enter");
        assertTrue(hostileToken.reentryReverted());
        assertEq(
            hostileToken.reentryErrorSelector(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector
        );
        assertEq(hostileToken.balanceOf(bob), 100e18, "only the legitimate payout happened");
    }

    /// @dev 付款执行时，nonce 与单日额度计数器必须已经被写入，
    ///      这样重入尝试就绝不可能把它们再复用一次。
    function test_StateIsUpdatedBeforeTheExternalCall() public {
        PayoutObserver observer = new PayoutObserver(vault, owner);

        vm.prank(owner);
        vault.setDailyWithdrawLimit(address(0), 10 ether);

        IBlockchainVault.WithdrawRequest memory request = _ownerRequest(address(observer), 3 ether);
        bytes memory signature = _signRequest(OWNER_PK, request);

        vault.withdrawWithSig(request, signature);

        assertEq(observer.payoutCount(), 1);
        assertEq(observer.nonceSeenDuringPayout(), 1, "nonce must be burnt before the transfer");
        assertEq(
            observer.spentTodaySeenDuringPayout(),
            3 ether,
            "daily spend must be recorded before the transfer"
        );
    }

    // ---------------------------------------------------------------------
    // SC-2 —— 重放
    // ---------------------------------------------------------------------

    /// @dev 同一份签名第一次有效，之后连续 3 次重放都被 `InvalidNonce` 拒绝，且资金不再移动。
    ///      （nonce 进摘要 + 状态检查，两道防线共同作用。）
    function test_ReplayAttackIsRejected() public {
        IBlockchainVault.WithdrawRequest memory request = _ownerRequest(alice, 2 ether);
        bytes memory signature = _signRequest(OWNER_PK, request);

        // 这次攻击第一次是成功的。
        vault.withdrawWithSig(request, signature);
        assertEq(alice.balance, ETH_FUNDING + 2 ether);

        // 之后每一次用同一份授权重放都会失败。
        for (uint256 i = 0; i < 3; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(IBlockchainVault.InvalidNonce.selector, owner, 0, 1)
            );
            vault.withdrawWithSig(request, signature);
        }

        assertEq(alice.balance, ETH_FUNDING + 2 ether, "no funds moved on the replays");
    }

    // ---------------------------------------------------------------------
    // SC-3 —— 跨链重放
    // ---------------------------------------------------------------------

    /// @dev 用「另一条链的 chainId」算出的摘要签名后拿到本链使用，
    ///      会恢复出不同地址而被判为 `UnauthorizedSigner`，资金不动。
    function test_CrossChainReplayIsRejected() public {
        IBlockchainVault.WithdrawRequest memory request = _request(alice, address(0), 2 ether, 0);
        bytes memory signatureOnAnotherChain = _sign(OWNER_PK, _digest(block.chainid + 1, address(vault), request));

        vm.expectPartialRevert(IBlockchainVault.UnauthorizedSigner.selector);
        vault.withdrawWithSig(request, signatureOnAnotherChain);

        assertEq(alice.balance, ETH_FUNDING);
    }

    // ---------------------------------------------------------------------
    // SC-4 —— 签名可延展性
    // ---------------------------------------------------------------------

    /// @dev 用 (v', r, n−s) 构造同一份授权的可延展对偶形式，必须被 ECDSA 的 s 值上限拒绝，
    ///      且 nonce 不被消耗。
    function test_MalleableCounterpartIsRejected() public {
        IBlockchainVault.WithdrawRequest memory request = _ownerRequest(alice, 1 ether);
        bytes32 digest = _digestForVault(request);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_PK, digest);

        uint256 order = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 flippedS = bytes32(order - uint256(s));
        uint8 flippedV = v == 27 ? 28 : 27;

        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureS.selector, flippedS));
        vault.withdrawWithSig(request, abi.encodePacked(r, flippedS, flippedV));

        assertEq(vault.getNonce(owner), 0);
    }

    // ---------------------------------------------------------------------
    // SC-5 —— 恶意 / 非标准代币
    // ---------------------------------------------------------------------

    /// @dev 仿 USDT 的代币完全不返回值；SafeERC20 必须能接受它。
    function test_NonStandardTokenCannotBrickTheVault() public {
        nonStandardToken.mint(alice, 100e6);
        vm.startPrank(alice);
        nonStandardToken.approve(address(vault), 100e6);
        vault.depositERC20(address(nonStandardToken), 100e6);
        vm.stopPrank();

        vm.prank(owner);
        vault.withdrawERC20(address(nonStandardToken), bob, 100e6);

        assertEq(nonStandardToken.balanceOf(bob), 100e6);
        assertEq(vault.getTokenBalance(address(nonStandardToken)), 0);
    }

    /// @dev 一个不抛异常、而是回答 `false` 的代币必须让提款中止，
    ///      而不能被当成成功。
    function test_TokenReturningFalseAbortsWithdrawal() public {
        MockReturnFalseERC20 brokenToken = new MockReturnFalseERC20();

        vm.expectRevert(
            abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(brokenToken))
        );
        vm.prank(owner);
        vault.withdrawERC20(address(brokenToken), alice, 1e18);
    }

    /// @dev 把 EOA（无代码地址）当代币传入时，被 `code.length` 检查挡下，
    ///      避免 SafeERC20 对空地址「假成功」。
    function test_DepositFromAddressWithoutCodeIsRejected() public {
        vm.expectRevert(abi.encodeWithSelector(IBlockchainVault.NotAContract.selector, bob));
        vm.prank(owner);
        vault.depositERC20(bob, 1e18);
    }

    // ---------------------------------------------------------------------
    // SC-6 —— 越权
    // ---------------------------------------------------------------------

    /// @dev 无关地址调用 `withdrawETH` 被 `onlyOwnerOrAdmin` 拒绝。
    function test_StrangerCannotWithdrawEth() public {
        vm.expectRevert(abi.encodeWithSelector(IBlockchainVault.UnauthorizedCaller.selector, stranger));
        vm.prank(stranger);
        vault.withdrawETH(stranger, 1 ether);
    }

    /// @dev 无关地址调用 `withdrawERC20` 同样被拒绝。
    function test_StrangerCannotWithdrawTokens() public {
        vm.expectRevert(abi.encodeWithSelector(IBlockchainVault.UnauthorizedCaller.selector, stranger));
        vm.prank(stranger);
        vault.withdrawERC20(address(token), stranger, 1e18);
    }

    /// @dev 无关地址无法自我提权为 Admin（`addAdmin` 是 onlyOwner），且状态确实未变。
    function test_StrangerCannotGrantThemselvesAdmin() public {
        vm.expectRevert();
        vm.prank(stranger);
        vault.addAdmin(stranger);

        assertFalse(vault.isAdmin(stranger));
    }

    /// @dev 无关地址既不能暂停也不能恢复（两者都是 onlyOwner）。
    function test_StrangerCannotPauseOrUnpause() public {
        vm.expectRevert();
        vm.prank(stranger);
        vault.pause();

        vm.prank(owner);
        vault.pause();

        vm.expectRevert();
        vm.prank(stranger);
        vault.unpause();
    }

    /// @dev 无关地址无法调用 `upgradeToAndCall` 更换实现（`_authorizeUpgrade` 是 onlyOwner）。
    function test_StrangerCannotUpgrade() public {
        vm.expectRevert();
        vm.prank(stranger);
        vault.upgradeToAndCall(address(0xBEEF), "");
    }

    /// @dev 即便是一份有效的 Owner 签名也无法被改道：收款方被摘要覆盖，
    ///      因此抢跑者换不掉它。
    function test_ValidSignatureCannotBeFrontRunToAnotherRecipient() public {
        IBlockchainVault.WithdrawRequest memory request = _ownerRequest(alice, 1 ether);
        bytes memory signature = _signRequest(OWNER_PK, request);

        IBlockchainVault.WithdrawRequest memory hijacked = request;
        hijacked.to = stranger;

        vm.expectPartialRevert(IBlockchainVault.UnauthorizedSigner.selector);
        vault.withdrawWithSig(hijacked, signature);

        assertEq(stranger.balance, ETH_FUNDING);
    }
}
