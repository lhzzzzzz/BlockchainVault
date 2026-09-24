// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {VaultTestBase} from "./VaultTestBase.sol";
import {BlockchainVault} from "../src/BlockchainVault.sol";
import {IBlockchainVault} from "../src/interfaces/IBlockchainVault.sol";

/// @notice FR-3：由离线 EIP-712 签名授权的提款。
/// @dev 这里用到的每一个摘要都由 {VaultTestBase} 依据 EIP-712 规范重新计算，
///      而不是从金库读回来，因此这些测试是在拿实现与「标准」对比，
///      而不是拿实现与它自己对比。
contract SignatureWithdrawTest is VaultTestBase {
    event Withdrawn(address indexed to, address indexed token, uint256 amount);
    event WithdrawnWithSig(address indexed signer, address indexed to, uint256 amount, uint256 nonce);

    /// @dev secp256k1 群的阶，用于构造某个签名的可延展对偶形式。
    uint256 private constant SECP256K1N =
        0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    /// @dev OpenZeppelin 所能接受的最大 `s` 值（secp256k1n / 2）。
    uint256 private constant MAX_VALID_S =
        0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    // ---------------------------------------------------------------------
    // FR-3.1 / FR-3.2 / FR-3.3 / FR-3.4 —— 正常路径
    // ---------------------------------------------------------------------

    /// @dev Owner 签名提 ETH：收款方到账、金库余额减少，并发出一笔 `WithdrawnWithSig`。
    function test_OwnerSignatureWithdrawsETH() public {
        IBlockchainVault.WithdrawRequest memory request = _ownerRequest(alice, 5 ether);
        bytes memory signature = _signRequest(OWNER_PK, request);

        uint256 aliceBefore = alice.balance;

        // 签名事件先于转账发出。
        vm.expectEmit(true, true, false, true, address(vault));
        emit WithdrawnWithSig(owner, alice, 5 ether, 0);

        vault.withdrawWithSig(request, signature);

        assertEq(alice.balance, aliceBefore + 5 ether);
        assertEq(vault.getETHBalance(), 95 ether);
    }

    /// @dev Admin 签名提 ERC20：事件里的 signer 是 Admin，且消耗的是 Admin 自己的 nonce。
    function test_AdminSignatureWithdrawsERC20() public {
        vm.prank(owner);
        vault.addAdmin(admin);

        IBlockchainVault.WithdrawRequest memory request = _request(bob, address(token), 3_000e18, 0);
        bytes memory signature = _signRequest(ADMIN_PK, request);

        vm.expectEmit(true, true, false, true, address(vault));
        emit WithdrawnWithSig(admin, bob, 3_000e18, 0);

        vault.withdrawWithSig(request, signature);

        assertEq(token.balanceOf(bob), 3_000e18);
        assertEq(vault.getNonce(admin), 1);
    }

    /// @dev FR-3：签名者负责授权，但任何人都可以付 gas 并提交。
    function test_AnyoneCanRelayAValidSignature() public {
        IBlockchainVault.WithdrawRequest memory request = _ownerRequest(alice, 1 ether);
        bytes memory signature = _signRequest(OWNER_PK, request);

        vm.prank(stranger);
        vault.withdrawWithSig(request, signature);

        assertEq(alice.balance, ETH_FUNDING + 1 ether);
    }

    /// @dev AC-5：一次成功的提款恰好消耗一个 nonce。
    function test_NonceIncrementsAfterEachUse() public {
        assertEq(vault.getNonce(owner), 0);

        for (uint256 i = 0; i < 3; ++i) {
            IBlockchainVault.WithdrawRequest memory request = _ownerRequest(alice, 1 ether);
            vault.withdrawWithSig(request, _signRequest(OWNER_PK, request));
            assertEq(vault.getNonce(owner), i + 1);
        }
    }

    /// @dev nonce 是「每个签名者各自独立」的：Owner 的提款不会推进 Admin 的计数。
    function test_NoncesAreTrackedPerSigner() public {
        vm.prank(owner);
        vault.addAdmin(admin);

        IBlockchainVault.WithdrawRequest memory ownerRequest = _ownerRequest(alice, 1 ether);
        vault.withdrawWithSig(ownerRequest, _signRequest(OWNER_PK, ownerRequest));

        // Owner 的提款不会动到 Admin 的 nonce。
        assertEq(vault.getNonce(owner), 1);
        assertEq(vault.getNonce(admin), 0);

        IBlockchainVault.WithdrawRequest memory adminRequest = _adminRequest(alice, 1 ether);
        vault.withdrawWithSig(adminRequest, _signRequest(ADMIN_PK, adminRequest));

        assertEq(vault.getNonce(owner), 1);
        assertEq(vault.getNonce(admin), 1);
    }

    /// @dev FR-3.6 的边界：`deadline` 正好等于当前时间戳时仍然有效
    ///      （判断是 `block.timestamp > deadline` 才拒绝）。
    function test_DeadlineAtExactlyNowIsStillValid() public {
        IBlockchainVault.WithdrawRequest memory request =
            _requestWithDeadline(alice, address(0), 1 ether, 0, block.timestamp);
        bytes memory signature = _signRequest(OWNER_PK, request);

        vault.withdrawWithSig(request, signature);

        assertEq(alice.balance, ETH_FUNDING + 1 ether);
    }

    // ---------------------------------------------------------------------
    // FR-3.5 / SC-2 / AC-6 —— 防重放
    // ---------------------------------------------------------------------

    /// @dev FR-3.5 / AC-6：同一份签名第二次提交被 `InvalidNonce(owner, 0, 1)` 拒绝。
    function test_ReplayingTheSameSignatureReverts() public {
        IBlockchainVault.WithdrawRequest memory request = _ownerRequest(alice, 1 ether);
        bytes memory signature = _signRequest(OWNER_PK, request);

        vault.withdrawWithSig(request, signature);

        vm.expectRevert(abi.encodeWithSelector(IBlockchainVault.InvalidNonce.selector, owner, 0, 1));
        vault.withdrawWithSig(request, signature);
    }

    /// @dev nonce 必须严格顺序：跳过中间的号（用 5 而当前是 0）会被拒绝。
    function test_SkippingANonceReverts() public {
        IBlockchainVault.WithdrawRequest memory request = _request(alice, address(0), 1 ether, 5);
        bytes memory signature = _signRequest(OWNER_PK, request);

        vm.expectRevert(abi.encodeWithSelector(IBlockchainVault.InvalidNonce.selector, owner, 5, 0));
        vault.withdrawWithSig(request, signature);
    }

    /// @dev 用一个已经被消耗掉的 nonce 签署的请求同样不能生效。
    function test_StaleNonceReverts() public {
        IBlockchainVault.WithdrawRequest memory first = _ownerRequest(alice, 1 ether);
        vault.withdrawWithSig(first, _signRequest(OWNER_PK, first));

        IBlockchainVault.WithdrawRequest memory stale = _request(alice, address(0), 1 ether, 0);
        bytes memory staleSignature = _signRequest(OWNER_PK, stale);

        vm.expectRevert(abi.encodeWithSelector(IBlockchainVault.InvalidNonce.selector, owner, 0, 1));
        vault.withdrawWithSig(stale, staleSignature);
    }

    // ---------------------------------------------------------------------
    // FR-3.6 / AC-7 —— 过期
    // ---------------------------------------------------------------------

    /// @dev FR-3.6 / AC-7：deadline 已过（当前时间 − 1 秒）的签名被 `SignatureExpired` 拒绝，
    ///      错误里带上 deadline 与当前时间戳。
    function test_ExpiredSignatureReverts() public {
        uint256 deadline = block.timestamp - 1;
        IBlockchainVault.WithdrawRequest memory request =
            _requestWithDeadline(alice, address(0), 1 ether, 0, deadline);
        bytes memory signature = _signRequest(OWNER_PK, request);

        vm.expectRevert(
            abi.encodeWithSelector(IBlockchainVault.SignatureExpired.selector, deadline, block.timestamp)
        );
        vault.withdrawWithSig(request, signature);
    }

    /// @dev 时间前进越过 deadline 之后，原本有效的签名自然失效（无需任何链上操作）。
    function test_SignatureBecomesInvalidAfterDeadlinePasses() public {
        IBlockchainVault.WithdrawRequest memory request =
            _requestWithDeadline(alice, address(0), 1 ether, 0, block.timestamp + 10 minutes);
        bytes memory signature = _signRequest(OWNER_PK, request);

        vm.warp(block.timestamp + 10 minutes + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                IBlockchainVault.SignatureExpired.selector, request.deadline, block.timestamp
            )
        );
        vault.withdrawWithSig(request, signature);
    }

    // ---------------------------------------------------------------------
    // FR-3.7 / SC-3 —— 跨链重放
    // ---------------------------------------------------------------------

    /// @dev FR-3.7 / SC-3：按「另一条链的 chainId」算出的摘要签名后在本链提交，
    ///      会恢复出不同地址而被判为 `UnauthorizedSigner`。
    function test_SignatureSignedForAnotherChainIdReverts() public {
        IBlockchainVault.WithdrawRequest memory request = _request(alice, address(0), 1 ether, 0);
        bytes memory signature = _sign(OWNER_PK, _digest(block.chainid + 1, address(vault), request));

        vm.expectPartialRevert(IBlockchainVault.UnauthorizedSigner.selector);
        vault.withdrawWithSig(request, signature);
    }

    /// @dev 上一个测试的反面：一旦 chain id 真的变化，同一个签名**确实**是有效的，
    ///      这证明先前被拒是源于域绑定，而不是这个签名本身根本用不了。
    function test_SignatureIsValidOnTheChainItWasSignedFor() public {
        uint256 otherChainId = block.chainid + 1;
        IBlockchainVault.WithdrawRequest memory request = _request(alice, address(0), 1 ether, 0);
        bytes memory signature = _sign(OWNER_PK, _digest(otherChainId, address(vault), request));

        vm.chainId(otherChainId);
        vault.withdrawWithSig(request, signature);

        assertEq(alice.balance, ETH_FUNDING + 1 ether);
    }

    /// @dev 域分隔符随 chainId 变化：链切换后 `domainSeparator()` 与按新链重算的结果一致。
    function test_DomainSeparatorTracksChainId() public {
        bytes32 original = vault.domainSeparator();
        assertEq(original, _domainSeparator(block.chainid, address(vault)));

        vm.chainId(block.chainid + 1);

        assertNotEq(vault.domainSeparator(), original);
        assertEq(vault.domainSeparator(), _domainSeparator(block.chainid, address(vault)));
    }

    // ---------------------------------------------------------------------
    // FR-3.8 —— 跨合约重放
    // ---------------------------------------------------------------------

    /// @dev FR-3.8：同一份签名在本金库有效，但拿到另一个金库（地址不同）会恢复出别的地址而被拒。
    function test_SignatureSignedForAnotherVaultReverts() public {
        BlockchainVault otherVault = _deployVault(owner);
        vm.deal(address(otherVault), 10 ether);

        IBlockchainVault.WithdrawRequest memory request = _request(alice, address(0), 1 ether, 0);
        bytes memory signature = _signRequest(OWNER_PK, request); // 绑定到 `vault`

        // 对 `vault` 来说，它是一个完全有效的签名……
        vault.withdrawWithSig(request, signature);

        // ……但对 `otherVault` 会恢复出另一个地址，因此在那边被拒绝。
        vm.expectPartialRevert(IBlockchainVault.UnauthorizedSigner.selector);
        otherVault.withdrawWithSig(request, signature);
    }

    // ---------------------------------------------------------------------
    // FR-3.4 —— 签名者必须持有 Owner 或 Admin 角色
    // ---------------------------------------------------------------------

    /// @dev FR-3.4：无关地址（stranger）自己签名也会被 `UnauthorizedSigner(stranger)` 拒绝。
    function test_SignatureFromUnauthorisedAccountReverts() public {
        IBlockchainVault.WithdrawRequest memory request = _request(alice, address(0), 1 ether, 0);
        bytes memory signature = _signRequest(STRANGER_PK, request);

        vm.expectRevert(abi.encodeWithSelector(IBlockchainVault.UnauthorizedSigner.selector, stranger));
        vault.withdrawWithSig(request, signature);
    }

    /// @dev FR-4 验收：撤销某 Admin 会使其此前已经产出的签名一并失效。
    function test_RemovedAdminSignatureIsRejected() public {
        vm.startPrank(owner);
        vault.addAdmin(admin);
        vm.stopPrank();

        IBlockchainVault.WithdrawRequest memory request = _adminRequest(alice, 1 ether);
        bytes memory signature = _signRequest(ADMIN_PK, request);

        vm.prank(owner);
        vault.removeAdmin(admin);

        vm.expectPartialRevert(IBlockchainVault.UnauthorizedSigner.selector);
        vault.withdrawWithSig(request, signature);
    }

    /// @dev FR-4.3 验收：所有权转移之后，金库不再承认前任 Owner 的签名。
    function test_PreviousOwnerSignatureIsRejectedAfterTransfer() public {
        IBlockchainVault.WithdrawRequest memory request = _ownerRequest(alice, 1 ether);
        bytes memory signature = _signRequest(OWNER_PK, request);

        vm.prank(owner);
        vault.transferOwnership(bob);

        vm.expectPartialRevert(IBlockchainVault.UnauthorizedSigner.selector);
        vault.withdrawWithSig(request, signature);
    }

    // ---------------------------------------------------------------------
    // AC-8 / SC-4 —— 篡改与可延展性
    // ---------------------------------------------------------------------

    /// @dev AC-8：把已签名的金额从 5 改成 6 后，摘要变化导致恢复出别的地址而被拒。
    function test_TamperedAmountReverts() public {
        IBlockchainVault.WithdrawRequest memory request = _ownerRequest(alice, 5 ether);
        bytes memory signature = _signRequest(OWNER_PK, request);

        request.amount = 6 ether; // 攻击者抬高付款金额

        vm.expectPartialRevert(IBlockchainVault.UnauthorizedSigner.selector);
        vault.withdrawWithSig(request, signature);
    }

    /// @dev 篡改收款方（把资金改道给攻击者）同样失效。
    function test_TamperedRecipientReverts() public {
        IBlockchainVault.WithdrawRequest memory request = _ownerRequest(alice, 1 ether);
        bytes memory signature = _signRequest(OWNER_PK, request);

        request.to = stranger; // 攻击者改写收款方

        vm.expectPartialRevert(IBlockchainVault.UnauthorizedSigner.selector);
        vault.withdrawWithSig(request, signature);
    }

    /// @dev 篡改代币（把「提 ETH」改成「提某个代币」）同样失效。
    function test_TamperedTokenReverts() public {
        IBlockchainVault.WithdrawRequest memory request = _ownerRequest(alice, 1 ether);
        bytes memory signature = _signRequest(OWNER_PK, request);

        request.token = address(token); // 攻击者把 ETH 换成某个代币

        vm.expectPartialRevert(IBlockchainVault.UnauthorizedSigner.selector);
        vault.withdrawWithSig(request, signature);
    }

    /// @dev nonce 也在摘要里：改 nonce 就等于改签名，因此无法把一份授权挪到别的 nonce 槽位复用。
    function test_TamperedNonceReverts() public {
        IBlockchainVault.WithdrawRequest memory request = _ownerRequest(alice, 1 ether);
        bytes memory signature = _signRequest(OWNER_PK, request);

        request.nonce = 1;

        vm.expectPartialRevert(IBlockchainVault.UnauthorizedSigner.selector);
        vault.withdrawWithSig(request, signature);
    }

    /// @dev 篡改 deadline（把有效期延长一天）同样失效。
    function test_TamperedDeadlineReverts() public {
        IBlockchainVault.WithdrawRequest memory request = _ownerRequest(alice, 1 ether);
        bytes memory signature = _signRequest(OWNER_PK, request);

        request.deadline = request.deadline + 1 days; // 攻击者延长有效期

        vm.expectPartialRevert(IBlockchainVault.UnauthorizedSigner.selector);
        vault.withdrawWithSig(request, signature);
    }

    /// @dev SC-4：可延展的对偶形式 `(v', r, n - s)` 必须被拒绝，
    ///      否则同一份授权就会存在两种不同的有效编码。
    function test_MalleableSignatureReverts() public {
        IBlockchainVault.WithdrawRequest memory request = _ownerRequest(alice, 1 ether);
        bytes32 digest = _digestForVault(request);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_PK, digest);
        assertLe(uint256(s), MAX_VALID_S, "foundry must produce a canonical low-s signature");

        bytes32 flippedS = bytes32(SECP256K1N - uint256(s));
        uint8 flippedV = v == 27 ? 28 : 27;

        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureS.selector, flippedS));
        vault.withdrawWithSig(request, abi.encodePacked(r, flippedS, flippedV));
    }

    /// @dev 空签名（长度 0）被 `ECDSAInvalidSignatureLength(0)` 拒绝。
    function test_EmptySignatureReverts() public {
        IBlockchainVault.WithdrawRequest memory request = _ownerRequest(alice, 1 ether);

        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureLength.selector, 0));
        vault.withdrawWithSig(request, "");
    }

    /// @dev 长度不足 65 字节的签名（64 字节）被 `ECDSAInvalidSignatureLength(64)` 拒绝。
    function test_ShortSignatureReverts() public {
        IBlockchainVault.WithdrawRequest memory request = _ownerRequest(alice, 1 ether);

        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureLength.selector, 64));
        vault.withdrawWithSig(request, new bytes(64));
    }

    /// @dev `v` 不是 27/28 时被 `ECDSAInvalidSignature` 拒绝（防止随意构造恢复值）。
    function test_InvalidVValueReverts() public {
        IBlockchainVault.WithdrawRequest memory request = _ownerRequest(alice, 1 ether);
        bytes32 digest = _digestForVault(request);

        (, bytes32 r, bytes32 s) = vm.sign(OWNER_PK, digest);

        vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
        vault.withdrawWithSig(request, abi.encodePacked(r, s, uint8(17)));
    }

    // ---------------------------------------------------------------------
    // FR-3.1 —— EIP-712 域本身
    // ---------------------------------------------------------------------

    /// @dev 金库的 `hashWithdrawRequest` 必须与夹具里独立实现的 EIP-712 摘要逐字节相同。
    function test_HashWithdrawRequestMatchesIndependentDigest() public view {
        IBlockchainVault.WithdrawRequest memory request = _request(alice, address(token), 42e18, 7);
        assertEq(vault.hashWithdrawRequest(request), _digest(block.chainid, address(vault), request));
    }

    /// @dev ERC-5267：`eip712Domain()` 暴露的四个域字段与链上实际值一致（钱包据此自动构造域）。
    function test_Eip712DomainIsExposed() public view {
        (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        ) = vault.eip712Domain();

        assertEq(fields, hex"0f", "all four domain fields are present");
        assertEq(name, "BlockchainVault");
        assertEq(version, "1");
        assertEq(chainId, block.chainid);
        assertEq(verifyingContract, address(vault));
        assertEq(salt, bytes32(0));
        assertEq(extensions.length, 0);
    }

    /// @dev 链上暴露的 `WITHDRAW_REQUEST_TYPEHASH` 必须与需求约定的类型字符串完全一致
    ///      （多一个空格、少一个字段都会让链下签名全部失效）。
    function test_WithdrawRequestTypehashMatchesSpec() public view {
        assertEq(
            vault.WITHDRAW_REQUEST_TYPEHASH(),
            keccak256("WithdrawRequest(address to,address token,uint256 amount,uint256 nonce,uint256 deadline)")
        );
    }

    // ---------------------------------------------------------------------
    // 签名通道周边的守卫
    // ---------------------------------------------------------------------

    /// @dev 暂停期间签名提款同样被 `EnforcedPause` 拦下。
    function test_SignatureWithdrawalRevertsWhilePaused() public {
        IBlockchainVault.WithdrawRequest memory request = _ownerRequest(alice, 1 ether);
        bytes memory signature = _signRequest(OWNER_PK, request);

        vm.prank(owner);
        vault.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vault.withdrawWithSig(request, signature);
    }

    /// @dev 签名里的收款方是零地址时被 `ZeroAddress` 拒绝（签名有效也照样拦）。
    function test_SignatureWithdrawalRevertsToZeroAddress() public {
        IBlockchainVault.WithdrawRequest memory request = _ownerRequest(address(0), 1 ether);
        bytes memory signature = _signRequest(OWNER_PK, request);

        vm.expectRevert(IBlockchainVault.ZeroAddress.selector);
        vault.withdrawWithSig(request, signature);
    }

    /// @dev 签名里的金额是 0 时被 `ZeroAmount` 拒绝。
    function test_SignatureWithdrawalRevertsOnZeroAmount() public {
        IBlockchainVault.WithdrawRequest memory request = _ownerRequest(alice, 0);
        bytes memory signature = _signRequest(OWNER_PK, request);

        vm.expectRevert(IBlockchainVault.ZeroAmount.selector);
        vault.withdrawWithSig(request, signature);
    }

    /// @dev 失败的付款必须把它消耗掉的 nonce 一并回滚，
    ///      否则这份授权就会在没有任何资金移动的情况下被烧掉。
    function test_FailedSignatureWithdrawalRollsBackTheNonce() public {
        IBlockchainVault.WithdrawRequest memory request = _ownerRequest(alice, 200 ether); // 超过余额
        bytes memory signature = _signRequest(OWNER_PK, request);

        vm.expectRevert(
            abi.encodeWithSelector(
                IBlockchainVault.InsufficientBalance.selector, address(0), 200 ether, 100 ether
            )
        );
        vault.withdrawWithSig(request, signature);

        assertEq(vault.getNonce(owner), 0, "nonce must not be consumed by a reverted withdrawal");
    }

    /// @dev 收款方拒收 ETH 时整笔回滚：nonce 仍为 0、金库余额分毫未动。
    function test_SignatureWithdrawalToRejectingContractReverts() public {
        RejectingRecipientForSig rejecting = new RejectingRecipientForSig();

        IBlockchainVault.WithdrawRequest memory request = _ownerRequest(address(rejecting), 1 ether);
        bytes memory signature = _signRequest(OWNER_PK, request);

        vm.expectRevert(
            abi.encodeWithSelector(IBlockchainVault.ETHTransferFailed.selector, address(rejecting), 1 ether)
        );
        vault.withdrawWithSig(request, signature);

        assertEq(vault.getNonce(owner), 0);
        assertEq(vault.getETHBalance(), 100 ether);
    }
}

/// @notice 拒收 ETH 的收款方，用于签名提款的失败路径。
contract RejectingRecipientForSig {
    receive() external payable {
        revert("RejectingRecipientForSig");
    }
}
