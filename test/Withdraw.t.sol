// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {VaultTestBase} from "./VaultTestBase.sol";
import {BlockchainVault} from "../src/BlockchainVault.sol";
import {IBlockchainVault} from "../src/interfaces/IBlockchainVault.sol";

/// @notice 拒收 ETH 的收款方，用来证明失败的付款会原子性回滚（FR-2.5）。
contract EthRejector {
    receive() external payable {
        revert("EthRejector: refusing ETH");
    }
}

/// @notice 完全无法接收 ETH 的收款方。
contract NoReceiveFunction {
    uint256 public value;
}

/// @notice 所需 gas 远超 `transfer`/`send` 所能提供的 2300 gas 额度的收款方。
/// @dev 写一个冷存储槽要花掉 2 万以上 gas，因此只有金库用 `call` 付款时才能触达本合约。
///      它是「用 `call` 而不是 `transfer`」这一决定的回归测试。
contract GasHungryReceiver {
    uint256 public callCount;

    receive() external payable {
        callCount += 1;
    }
}

/// @notice FR-2：受角色限制的 ETH 与 ERC20 提款。
contract WithdrawTest is VaultTestBase {
    event Withdrawn(address indexed to, address indexed token, uint256 amount);

    // ---------------------------------------------------------------------
    // FR-2.1 / AC-3 —— 有授权的 ETH 提款
    // ---------------------------------------------------------------------

    /// @dev Owner 提 ETH：收款方到账、金库余额等额减少。
    function test_OwnerWithdrawsETH() public {
        uint256 vaultBefore = vault.getETHBalance();
        uint256 aliceBefore = alice.balance;

        vm.prank(owner);
        vault.withdrawETH(alice, 10 ether);

        assertEq(alice.balance, aliceBefore + 10 ether);
        assertEq(vault.getETHBalance(), vaultBefore - 10 ether);
    }

    /// @dev Admin 同样可以提 ETH（`onlyOwnerOrAdmin` 承认两种角色）。
    function test_AdminWithdrawsETH() public {
        vm.prank(owner);
        vault.addAdmin(admin);

        uint256 aliceBefore = alice.balance;
        vm.prank(admin);
        vault.withdrawETH(alice, 7 ether);

        assertEq(alice.balance, aliceBefore + 7 ether);
    }

    /// @dev 提款发出规范的 `Withdrawn(to, token, amount)` 事件；
    ///      ETH 的 `token` 字段是 `address(0)`。
    function test_WithdrawETHEmitsWithdrawn() public {
        vm.expectEmit(true, true, false, true, address(vault));
        emit Withdrawn(alice, address(0), 1 ether);

        vm.prank(owner);
        vault.withdrawETH(alice, 1 ether);
    }

    // ---------------------------------------------------------------------
    // FR-2.2 —— 有授权的 ERC20 提款
    // ---------------------------------------------------------------------

    /// @dev Owner 提 ERC20：事件里带真实代币地址，收款方到账、金库余额减少。
    function test_OwnerWithdrawsERC20() public {
        uint256 vaultBefore = vault.getTokenBalance(address(token));

        vm.expectEmit(true, true, false, true, address(vault));
        emit Withdrawn(bob, address(token), 2_500e18);

        vm.prank(owner);
        vault.withdrawERC20(address(token), bob, 2_500e18);

        assertEq(token.balanceOf(bob), 2_500e18);
        assertEq(vault.getTokenBalance(address(token)), vaultBefore - 2_500e18);
    }

    /// @dev Admin 同样可以提 ERC20。
    function test_AdminWithdrawsERC20() public {
        vm.prank(owner);
        vault.addAdmin(admin);

        vm.prank(admin);
        vault.withdrawERC20(address(token), bob, 1_000e18);

        assertEq(token.balanceOf(bob), 1_000e18);
    }

    /// @dev FR-1.5 / SC-5 在「出金」方向同样成立：仿 USDT 的代币也必须能正常支付。
    function test_WithdrawERC20SupportsNonStandardToken() public {
        nonStandardToken.mint(alice, 1_000e6);
        vm.startPrank(alice);
        nonStandardToken.approve(address(vault), 1_000e6);
        vault.depositERC20(address(nonStandardToken), 1_000e6);
        vm.stopPrank();

        vm.prank(owner);
        vault.withdrawERC20(address(nonStandardToken), bob, 400e6);

        assertEq(nonStandardToken.balanceOf(bob), 400e6);
        assertEq(vault.getTokenBalance(address(nonStandardToken)), 600e6);
    }

    // ---------------------------------------------------------------------
    // FR-2.3 / AC-12 —— 零地址
    // ---------------------------------------------------------------------

    /// @dev 提 ETH 到零地址被 `ZeroAddress` 拒绝，避免资金被销毁。
    function test_WithdrawETHRevertsToZeroAddress() public {
        vm.expectRevert(IBlockchainVault.ZeroAddress.selector);
        vm.prank(owner);
        vault.withdrawETH(address(0), 1 ether);
    }

    /// @dev 提代币到零地址同样被拒绝。
    function test_WithdrawERC20RevertsToZeroAddress() public {
        vm.expectRevert(IBlockchainVault.ZeroAddress.selector);
        vm.prank(owner);
        vault.withdrawERC20(address(token), address(0), 1e18);
    }

    /// @dev 提 0 金额被 `ZeroAmount` 拒绝（避免无意义的状态与日志）。
    function test_WithdrawRevertsOnZeroAmount() public {
        vm.expectRevert(IBlockchainVault.ZeroAmount.selector);
        vm.prank(owner);
        vault.withdrawETH(alice, 0);
    }

    // ---------------------------------------------------------------------
    // FR-2.4 / AC-11 —— 余额不足
    // ---------------------------------------------------------------------

    /// @dev 提款超过金库 ETH 余额时被 `InsufficientBalance` 拒绝，
    ///      错误里带上了请求额与实际可用额，便于链下定位。
    function test_WithdrawETHRevertsWhenBalanceInsufficient() public {
        uint256 available = vault.getETHBalance();

        vm.expectRevert(
            abi.encodeWithSelector(
                IBlockchainVault.InsufficientBalance.selector, address(0), available + 1, available
            )
        );
        vm.prank(owner);
        vault.withdrawETH(alice, available + 1);
    }

    /// @dev 提款超过金库 ERC20 余额时同样被拒绝。
    function test_WithdrawERC20RevertsWhenBalanceInsufficient() public {
        uint256 available = vault.getTokenBalance(address(token));

        vm.expectRevert(
            abi.encodeWithSelector(
                IBlockchainVault.InsufficientBalance.selector, address(token), available + 1, available
            )
        );
        vm.prank(owner);
        vault.withdrawERC20(address(token), alice, available + 1);
    }

    /// @dev 全新部署的空金库（余额 0）提 1 wei 也会回滚，`available` 为 0。
    function test_WithdrawETHRevertsWhenVaultIsEmpty() public {
        BlockchainVault emptyVault = _deployVault(owner);

        vm.expectRevert(
            abi.encodeWithSelector(IBlockchainVault.InsufficientBalance.selector, address(0), 1, 0)
        );
        vm.prank(owner);
        emptyVault.withdrawETH(alice, 1);
    }

    // ---------------------------------------------------------------------
    // 代币版本重载的参数校验
    // ---------------------------------------------------------------------

    /// @dev `withdrawERC20` 的代币参数传 `address(0)` 被拒绝
    ///      （注意：这里零地址是「代币地址」非法，而非收款地址）。
    function test_WithdrawERC20RevertsForZeroTokenAddress() public {
        vm.expectRevert(IBlockchainVault.ZeroAddress.selector);
        vm.prank(owner);
        vault.withdrawERC20(address(0), alice, 1e18);
    }

    /// @dev 代币参数是 EOA（无代码）时被 `NotAContract` 拒绝，
    ///      避免 SafeERC20 对空地址「假成功」而不报错。
    function test_WithdrawERC20RevertsForAddressWithoutCode() public {
        vm.expectRevert(abi.encodeWithSelector(IBlockchainVault.NotAContract.selector, bob));
        vm.prank(owner);
        vault.withdrawERC20(bob, alice, 1);
    }

    // ---------------------------------------------------------------------
    // FR-2.5 —— 失败的付款绝不能丢币
    // ---------------------------------------------------------------------

    /// @dev 收款方拒收 ETH 时整笔交易回滚：金库余额分毫未动、收款方余额仍为 0。
    function test_FailedETHPayoutRevertsAndKeepsFunds() public {
        EthRejector rejector = new EthRejector();
        uint256 vaultBefore = vault.getETHBalance();

        vm.expectRevert(
            abi.encodeWithSelector(IBlockchainVault.ETHTransferFailed.selector, address(rejector), 1 ether)
        );
        vm.prank(owner);
        vault.withdrawETH(address(rejector), 1 ether);

        assertEq(vault.getETHBalance(), vaultBefore, "vault balance must be untouched");
        assertEq(address(rejector).balance, 0);
    }

    /// @dev 收款方连 `receive`/`fallback` 都没有时，转账失败并以 `ETHTransferFailed` 回滚。
    function test_ETHPayoutToContractWithoutReceiveReverts() public {
        NoReceiveFunction receiver = new NoReceiveFunction();

        vm.expectRevert(
            abi.encodeWithSelector(IBlockchainVault.ETHTransferFailed.selector, address(receiver), 1 ether)
        );
        vm.prank(owner);
        vault.withdrawETH(address(receiver), 1 ether);
    }

    /// @dev 针对 `call` 与 `transfer` 之争的回归测试：receive 钩子里的一次 SSTORE
    ///      就会超过 `transfer` 所能提供的 2300 gas 额度。
    function test_ETHPayoutToGasHungryReceiverSucceeds() public {
        GasHungryReceiver receiver = new GasHungryReceiver();

        vm.prank(owner);
        vault.withdrawETH(address(receiver), 1 ether);

        assertEq(receiver.callCount(), 1);
        assertEq(address(receiver).balance, 1 ether);
    }

    // ---------------------------------------------------------------------
    // FR-5.1 / FR-5.2 / AC-9 —— 暂停会挡住提款
    // ---------------------------------------------------------------------

    /// @dev 暂停后 Owner 提 ETH 也被 `EnforcedPause` 拦下（暂停对所有人一视同仁）。
    function test_WithdrawETHRevertsWhilePaused() public {
        vm.prank(owner);
        vault.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(owner);
        vault.withdrawETH(alice, 1 ether);
    }

    /// @dev 暂停后 `withdrawERC20` 同样被拦下。
    function test_WithdrawERC20RevertsWhilePaused() public {
        vm.prank(owner);
        vault.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(owner);
        vault.withdrawERC20(address(token), alice, 1e18);
    }

    /// @dev 恢复（unpause）之后提款立刻重新可用——暂停是开关而不是终止。
    function test_WithdrawWorksAgainAfterUnpause() public {
        vm.startPrank(owner);
        vault.pause();
        vault.unpause();
        vault.withdrawETH(alice, 1 ether);
        vm.stopPrank();

        assertEq(vault.getETHBalance(), 99 ether);
    }
}
