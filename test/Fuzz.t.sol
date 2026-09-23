// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {VaultTestBase} from "./VaultTestBase.sol";
import {IBlockchainVault} from "../src/interfaces/IBlockchainVault.sol";

/// @notice 基于性质的测试。它们断言的是对**任意**输入都应当成立的不变量，
///         而这恰恰是手写样例测试最薄弱的地方。
contract FuzzTest is VaultTestBase {
    // ---------------------------------------------------------------------
    // 资产
    // ---------------------------------------------------------------------

    /// @dev 存进去多少就必须能取出来多少，且金库余额恰好是净额。
    function testFuzz_DepositThenWithdrawERC20(uint96 depositAmount, uint96 withdrawAmount) public {
        uint256 deposit = bound(depositAmount, 1, TOKEN_FUNDING);
        uint256 withdraw = bound(withdrawAmount, 1, deposit);

        vm.startPrank(owner);
        token.approve(address(vault), deposit);
        vault.depositERC20(address(token), deposit);

        assertEq(vault.getTokenBalance(address(token)), 100_000e18 + deposit);

        vault.withdrawERC20(address(token), bob, withdraw);
        vm.stopPrank();

        assertEq(token.balanceOf(bob), withdraw);
        assertEq(vault.getTokenBalance(address(token)), 100_000e18 + deposit - withdraw);
    }

    /// @dev 任何超过金库余额的提款都必须回滚，并且不得动到余额。
    function testFuzz_OverBalanceWithdrawalAlwaysReverts(uint96 rawAmount) public {
        uint256 available = vault.getETHBalance();
        uint256 amount = bound(rawAmount, available + 1, type(uint96).max);

        vm.expectRevert(
            abi.encodeWithSelector(IBlockchainVault.InsufficientBalance.selector, address(0), amount, available)
        );
        vm.prank(owner);
        vault.withdrawETH(alice, amount);

        assertEq(vault.getETHBalance(), available);
    }

    /// @dev 任何在余额范围内的提款都必须成功，并恰好减去该金额。
    function testFuzz_WithdrawalWithinBalanceAlwaysSucceeds(uint96 rawAmount) public {
        uint256 available = vault.getETHBalance();
        uint256 amount = bound(rawAmount, 1, available);

        vm.prank(owner);
        vault.withdrawETH(alice, amount);

        assertEq(vault.getETHBalance(), available - amount);
        assertEq(alice.balance, ETH_FUNDING + amount);
    }

    // ---------------------------------------------------------------------
    // 签名 nonce
    // ---------------------------------------------------------------------

    /// @dev 每接受一个签名，nonce 就恰好前进 1，无论使用多少次。
    function testFuzz_NonceAdvancesByExactlyOnePerSignature(uint8 rawUses) public {
        uint256 uses = bound(rawUses, 1, 25);

        for (uint256 i = 0; i < uses; ++i) {
            IBlockchainVault.WithdrawRequest memory request = _ownerRequest(alice, 1);
            vault.withdrawWithSig(request, _signRequest(OWNER_PK, request));
            assertEq(vault.getNonce(owner), i + 1);
        }

        assertEq(vault.getNonce(owner), uses);
    }

    /// @dev 只要 nonce 不是当前应当使用的那个，签名就会被拒绝，且不会移动任何资金。
    function testFuzz_OnlyTheCurrentNonceIsAccepted(uint96 rawNonce) public {
        uint256 wrongNonce = bound(rawNonce, 1, type(uint96).max);

        IBlockchainVault.WithdrawRequest memory request = _request(alice, address(0), 1 ether, wrongNonce);
        bytes memory signature = _signRequest(OWNER_PK, request);

        vm.expectRevert(
            abi.encodeWithSelector(IBlockchainVault.InvalidNonce.selector, owner, wrongNonce, 0)
        );
        vault.withdrawWithSig(request, signature);

        assertEq(vault.getNonce(owner), 0);
        assertEq(vault.getETHBalance(), 100 ether);
    }

    // ---------------------------------------------------------------------
    // 风控限额
    // ---------------------------------------------------------------------

    /// @dev 相对单笔上限而言，任意金额都要被正确放行或拦截。
    function testFuzz_SingleLimitIsEnforced(uint96 rawLimit, uint96 rawAmount) public {
        uint256 limit = bound(rawLimit, 1, 100 ether);
        uint256 amount = bound(rawAmount, 1, 200 ether);

        vm.prank(owner);
        vault.setSingleWithdrawLimit(address(0), limit);

        if (amount > limit) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IBlockchainVault.SingleWithdrawLimitExceeded.selector, address(0), amount, limit
                )
            );
            vm.prank(owner);
            vault.withdrawETH(alice, amount);
        } else {
            vm.prank(owner);
            vault.withdrawETH(alice, amount);
            assertEq(alice.balance, ETH_FUNDING + amount);
        }
    }

    /// @dev 同一 UTC 日内的两笔提款永远不可能超过单日上限，
    ///      并且计数器始终等于实际提出去的金额之和。
    function testFuzz_DailyLimitIsNeverExceeded(uint96 rawFirst, uint96 rawSecond) public {
        uint256 cap = 10 ether;

        vm.prank(owner);
        vault.setDailyWithdrawLimit(address(0), cap);

        uint256 first = bound(rawFirst, 1, cap);
        vm.prank(owner);
        vault.withdrawETH(alice, first);
        assertEq(vault.getSpentToday(address(0)), first);

        uint256 second = bound(rawSecond, 1, cap);
        uint256 remaining = cap - first;

        if (second > remaining) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IBlockchainVault.DailyWithdrawLimitExceeded.selector, address(0), second, remaining
                )
            );
            vm.prank(owner);
            vault.withdrawETH(alice, second);
        } else {
            vm.prank(owner);
            vault.withdrawETH(alice, second);
            assertEq(vault.getSpentToday(address(0)), first + second);
        }

        assertLe(vault.getSpentToday(address(0)), cap, "daily spend can never exceed the cap");
    }

    // ---------------------------------------------------------------------
    // 权限控制
    // ---------------------------------------------------------------------

    /// @dev 除 Owner 与 Admin 之外的任何地址都永远无法把资金转出去。
    function testFuzz_OnlyOwnerOrAdminCanWithdraw(address caller) public {
        vm.assume(caller != owner && caller != admin);

        vm.expectRevert(abi.encodeWithSelector(IBlockchainVault.UnauthorizedCaller.selector, caller));
        vm.prank(caller);
        vault.withdrawETH(caller, 1 ether);
    }

    /// @dev 把任意地址设为 Admin，都恰好只会授予提款权。
    function testFuzz_AnyAddressCanBeGrantedAdminRights(address newAdmin, uint96 rawAmount) public {
        vm.assume(newAdmin != address(0) && newAdmin != owner);

        vm.prank(owner);
        vault.addAdmin(newAdmin);
        assertTrue(vault.isAdmin(newAdmin));

        uint256 amount = bound(rawAmount, 1, 50 ether);
        vm.prank(newAdmin);
        vault.withdrawETH(bob, amount);

        assertEq(bob.balance, ETH_FUNDING + amount);
    }

    /// @dev 被撤销之后，无论该 Admin 是谁，都再也无法提款。
    function testFuzz_RemovedAdminLosesAllRights(address removedAdmin) public {
        vm.assume(removedAdmin != address(0) && removedAdmin != owner);

        vm.startPrank(owner);
        vault.addAdmin(removedAdmin);
        vault.removeAdmin(removedAdmin);
        vm.stopPrank();

        assertFalse(vault.isAdmin(removedAdmin));

        vm.expectRevert(abi.encodeWithSelector(IBlockchainVault.UnauthorizedCaller.selector, removedAdmin));
        vm.prank(removedAdmin);
        vault.withdrawETH(bob, 1 ether);
    }
}
