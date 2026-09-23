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

    function test_OwnerWithdrawsETH() public {
        uint256 vaultBefore = vault.getETHBalance();
        uint256 aliceBefore = alice.balance;

        vm.prank(owner);
        vault.withdrawETH(alice, 10 ether);

        assertEq(alice.balance, aliceBefore + 10 ether);
        assertEq(vault.getETHBalance(), vaultBefore - 10 ether);
    }

    function test_AdminWithdrawsETH() public {
        vm.prank(owner);
        vault.addAdmin(admin);

        uint256 aliceBefore = alice.balance;
        vm.prank(admin);
        vault.withdrawETH(alice, 7 ether);

        assertEq(alice.balance, aliceBefore + 7 ether);
    }

    function test_WithdrawETHEmitsWithdrawn() public {
        vm.expectEmit(true, true, false, true, address(vault));
        emit Withdrawn(alice, address(0), 1 ether);

        vm.prank(owner);
        vault.withdrawETH(alice, 1 ether);
    }

    // ---------------------------------------------------------------------
    // FR-2.2 —— 有授权的 ERC20 提款
    // ---------------------------------------------------------------------

    function test_OwnerWithdrawsERC20() public {
        uint256 vaultBefore = vault.getTokenBalance(address(token));

        vm.expectEmit(true, true, false, true, address(vault));
        emit Withdrawn(bob, address(token), 2_500e18);

        vm.prank(owner);
        vault.withdrawERC20(address(token), bob, 2_500e18);

        assertEq(token.balanceOf(bob), 2_500e18);
        assertEq(vault.getTokenBalance(address(token)), vaultBefore - 2_500e18);
    }

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

    function test_WithdrawETHRevertsToZeroAddress() public {
        vm.expectRevert(IBlockchainVault.ZeroAddress.selector);
        vm.prank(owner);
        vault.withdrawETH(address(0), 1 ether);
    }

    function test_WithdrawERC20RevertsToZeroAddress() public {
        vm.expectRevert(IBlockchainVault.ZeroAddress.selector);
        vm.prank(owner);
        vault.withdrawERC20(address(token), address(0), 1e18);
    }

    function test_WithdrawRevertsOnZeroAmount() public {
        vm.expectRevert(IBlockchainVault.ZeroAmount.selector);
        vm.prank(owner);
        vault.withdrawETH(alice, 0);
    }

    // ---------------------------------------------------------------------
    // FR-2.4 / AC-11 —— 余额不足
    // ---------------------------------------------------------------------

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

    function test_WithdrawERC20RevertsForZeroTokenAddress() public {
        vm.expectRevert(IBlockchainVault.ZeroAddress.selector);
        vm.prank(owner);
        vault.withdrawERC20(address(0), alice, 1e18);
    }

    function test_WithdrawERC20RevertsForAddressWithoutCode() public {
        vm.expectRevert(abi.encodeWithSelector(IBlockchainVault.NotAContract.selector, bob));
        vm.prank(owner);
        vault.withdrawERC20(bob, alice, 1);
    }

    // ---------------------------------------------------------------------
    // FR-2.5 —— 失败的付款绝不能丢币
    // ---------------------------------------------------------------------

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

    function test_WithdrawETHRevertsWhilePaused() public {
        vm.prank(owner);
        vault.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(owner);
        vault.withdrawETH(alice, 1 ether);
    }

    function test_WithdrawERC20RevertsWhilePaused() public {
        vm.prank(owner);
        vault.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(owner);
        vault.withdrawERC20(address(token), alice, 1e18);
    }

    function test_WithdrawWorksAgainAfterUnpause() public {
        vm.startPrank(owner);
        vault.pause();
        vault.unpause();
        vault.withdrawETH(alice, 1 ether);
        vm.stopPrank();

        assertEq(vault.getETHBalance(), 99 ether);
    }
}
