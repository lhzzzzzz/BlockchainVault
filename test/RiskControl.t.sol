// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {VaultTestBase} from "./VaultTestBase.sol";
import {IBlockchainVault} from "../src/interfaces/IBlockchainVault.sol";

/// @notice FR-5.4（白名单）与 FR-5.5（单笔限额 / 滚动单日限额）。
contract RiskControlTest is VaultTestBase {
    event WhitelistEnabledUpdated(bool enabled);
    event WhitelistUpdated(address indexed account, bool allowed);
    event SingleWithdrawLimitUpdated(address indexed token, uint256 limit);
    event DailyWithdrawLimitUpdated(address indexed token, uint256 limit);
    event DailySpentReset(address indexed token);

    // ---------------------------------------------------------------------
    // FR-5.4 —— 白名单
    // ---------------------------------------------------------------------

    function test_WhitelistIsDisabledByDefault() public view {
        assertFalse(vault.whitelistEnabled());
        assertFalse(vault.isWhitelisted(alice));
    }

    function test_SetWhitelistEnabledEmitsAndTakesEffect() public {
        vm.expectEmit(false, false, false, true, address(vault));
        emit WhitelistEnabledUpdated(true);

        vm.prank(owner);
        vault.setWhitelistEnabled(true);

        assertTrue(vault.whitelistEnabled());
    }

    function test_SetWhitelistedEmitsAndTakesEffect() public {
        vm.expectEmit(true, false, false, true, address(vault));
        emit WhitelistUpdated(alice, true);

        vm.prank(owner);
        vault.setWhitelisted(alice, true);

        assertTrue(vault.isWhitelisted(alice));
    }

    function test_SetWhitelistedCanRemoveAnAccount() public {
        vm.startPrank(owner);
        vault.setWhitelisted(alice, true);

        vm.expectEmit(true, false, false, true, address(vault));
        emit WhitelistUpdated(alice, false);

        vault.setWhitelisted(alice, false);
        vm.stopPrank();

        assertFalse(vault.isWhitelisted(alice));
    }

    function test_SetWhitelistedRevertsForZeroAddress() public {
        vm.expectRevert(IBlockchainVault.ZeroAddress.selector);
        vm.prank(owner);
        vault.setWhitelisted(address(0), true);
    }

    function test_WhitelistBlocksNonWhitelistedRecipient() public {
        vm.startPrank(owner);
        vault.setWhitelistEnabled(true);
        vault.setWhitelisted(alice, true);
        vm.stopPrank();

        // 名单内的收款方：放行。
        vm.prank(owner);
        vault.withdrawETH(alice, 1 ether);

        // 名单外的收款方：拒绝。
        vm.expectRevert(abi.encodeWithSelector(IBlockchainVault.NotWhitelisted.selector, bob));
        vm.prank(owner);
        vault.withdrawETH(bob, 1 ether);
    }

    function test_WhitelistBlocksUnlistedERC20Recipient() public {
        vm.startPrank(owner);
        vault.setWhitelistEnabled(true);
        vault.setWhitelisted(alice, true);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(IBlockchainVault.NotWhitelisted.selector, bob));
        vm.prank(owner);
        vault.withdrawERC20(address(token), bob, 1e18);
    }

    function test_WhitelistAppliesToSignatureWithdrawals() public {
        vm.startPrank(owner);
        vault.setWhitelistEnabled(true);
        vault.setWhitelisted(alice, true);
        vm.stopPrank();

        // 签名完全有效，只是指向了一个不在名单里的收款方。
        IBlockchainVault.WithdrawRequest memory request = _ownerRequest(bob, 1 ether);
        bytes memory signature = _signRequest(OWNER_PK, request);

        vm.expectRevert(abi.encodeWithSelector(IBlockchainVault.NotWhitelisted.selector, bob));
        vault.withdrawWithSig(request, signature);

        // 这次尝试并不会把该授权烧掉。
        assertEq(vault.getNonce(owner), 0);
    }

    function test_WhitelistIsIgnoredWhileDisabled() public {
        vm.prank(owner);
        vault.setWhitelisted(alice, true); // 已加入名单，但白名单总开关是关的

        vm.prank(owner);
        vault.withdrawETH(bob, 1 ether);

        assertEq(bob.balance, ETH_FUNDING + 1 ether);
    }

    function test_DisablingWhitelistReopensAllRecipients() public {
        vm.startPrank(owner);
        vault.setWhitelistEnabled(true);

        vm.expectRevert(abi.encodeWithSelector(IBlockchainVault.NotWhitelisted.selector, bob));
        vault.withdrawETH(bob, 1 ether);

        vault.setWhitelistEnabled(false);
        vault.withdrawETH(bob, 1 ether);
        vm.stopPrank();

        assertEq(bob.balance, ETH_FUNDING + 1 ether);
    }

    function test_WhitelistDoesNotRestrictDeposits() public {
        vm.prank(owner);
        vault.setWhitelistEnabled(true);

        _depositToken(alice, 10e18);
        assertEq(token.balanceOf(address(vault)), 100_010e18);
    }

    function test_OnlyOwnerCanConfigureWhitelist() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        vault.setWhitelistEnabled(true);

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        vault.setWhitelisted(stranger, true);
    }

    // ---------------------------------------------------------------------
    // FR-5.5 —— 单笔限额
    // ---------------------------------------------------------------------

    function test_SetSingleWithdrawLimitEmitsAndTakesEffect() public {
        vm.expectEmit(true, false, false, true, address(vault));
        emit SingleWithdrawLimitUpdated(address(0), 5 ether);

        vm.prank(owner);
        vault.setSingleWithdrawLimit(address(0), 5 ether);

        assertEq(vault.getSingleWithdrawLimit(address(0)), 5 ether);
    }

    function test_SingleLimitAllowsExactlyTheLimit() public {
        vm.startPrank(owner);
        vault.setSingleWithdrawLimit(address(0), 5 ether);
        vault.withdrawETH(alice, 5 ether);
        vm.stopPrank();

        assertEq(alice.balance, ETH_FUNDING + 5 ether);
    }

    function test_SingleLimitBlocksOversizedWithdrawal() public {
        vm.prank(owner);
        vault.setSingleWithdrawLimit(address(0), 5 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                IBlockchainVault.SingleWithdrawLimitExceeded.selector, address(0), 5 ether + 1, 5 ether
            )
        );
        vm.prank(owner);
        vault.withdrawETH(alice, 5 ether + 1);
    }

    function test_SingleLimitAppliesToSignatureWithdrawals() public {
        vm.prank(owner);
        vault.setSingleWithdrawLimit(address(0), 1 ether);

        IBlockchainVault.WithdrawRequest memory request = _ownerRequest(alice, 2 ether);
        bytes memory signature = _signRequest(OWNER_PK, request);

        vm.expectRevert(
            abi.encodeWithSelector(
                IBlockchainVault.SingleWithdrawLimitExceeded.selector, address(0), 2 ether, 1 ether
            )
        );
        vault.withdrawWithSig(request, signature);
    }

    function test_ZeroSingleLimitDisablesTheCheck() public {
        vm.startPrank(owner);
        vault.setSingleWithdrawLimit(address(0), 1 ether);
        vault.setSingleWithdrawLimit(address(0), 0); // 重新关闭
        vault.withdrawETH(alice, 50 ether);
        vm.stopPrank();

        assertEq(alice.balance, ETH_FUNDING + 50 ether);
    }

    function test_SingleLimitIsTrackedPerToken() public {
        uint256 aliceTokensBefore = token.balanceOf(alice);

        vm.startPrank(owner);
        vault.setSingleWithdrawLimit(address(0), 1 ether); // 只给 ETH 设了上限

        vm.expectRevert(
            abi.encodeWithSelector(
                IBlockchainVault.SingleWithdrawLimitExceeded.selector, address(0), 2 ether, 1 ether
            )
        );
        vault.withdrawETH(alice, 2 ether);

        // ERC20 没有配置限额，因此同样大小的提款是允许的。
        vault.withdrawERC20(address(token), alice, 1_000e18);
        vm.stopPrank();

        assertEq(token.balanceOf(alice), aliceTokensBefore + 1_000e18);
    }

    function test_OnlyOwnerCanSetSingleLimit() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        vault.setSingleWithdrawLimit(address(0), 1 ether);
    }

    // ---------------------------------------------------------------------
    // FR-5.5 —— 滚动单日限额
    // ---------------------------------------------------------------------

    function test_SetDailyWithdrawLimitEmitsAndTakesEffect() public {
        vm.expectEmit(true, false, false, true, address(vault));
        emit DailyWithdrawLimitUpdated(address(0), 10 ether);

        vm.prank(owner);
        vault.setDailyWithdrawLimit(address(0), 10 ether);

        assertEq(vault.getDailyWithdrawLimit(address(0)), 10 ether);
    }

    function test_DailyLimitAccumulatesAcrossWithdrawals() public {
        vm.startPrank(owner);
        vault.setDailyWithdrawLimit(address(0), 10 ether);

        vault.withdrawETH(alice, 4 ether);
        assertEq(vault.getSpentToday(address(0)), 4 ether);

        vault.withdrawETH(alice, 6 ether);
        assertEq(vault.getSpentToday(address(0)), 10 ether);
        vm.stopPrank();

        assertEq(alice.balance, ETH_FUNDING + 10 ether);
    }

    function test_DailyLimitBlocksOnceExhausted() public {
        vm.startPrank(owner);
        vault.setDailyWithdrawLimit(address(0), 10 ether);
        vault.withdrawETH(alice, 8 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                IBlockchainVault.DailyWithdrawLimitExceeded.selector, address(0), 3 ether, 2 ether
            )
        );
        vault.withdrawETH(alice, 3 ether);
        vm.stopPrank();

        assertEq(vault.getSpentToday(address(0)), 8 ether, "a rejected withdrawal records nothing");
    }

    function test_DailyLimitResetsOnTheNextUtcDay() public {
        vm.startPrank(owner);
        vault.setDailyWithdrawLimit(address(0), 5 ether);
        vault.withdrawETH(alice, 5 ether);

        vm.expectRevert(
            abi.encodeWithSelector(IBlockchainVault.DailyWithdrawLimitExceeded.selector, address(0), 1, 0)
        );
        vault.withdrawETH(alice, 1);
        vm.stopPrank();

        // 跳到下一个 UTC 日的第一秒。
        vm.warp((block.timestamp / 1 days + 1) * 1 days);

        vm.prank(owner);
        vault.withdrawETH(alice, 5 ether);

        assertEq(vault.getSpentToday(address(0)), 5 ether, "counter is rebased to the new day");
        assertEq(alice.balance, ETH_FUNDING + 10 ether);
    }

    function test_DailyLimitUsesUtcDayBoundary() public {
        vm.startPrank(owner);
        vault.setDailyWithdrawLimit(address(0), 5 ether);

        // 跳到当前 UTC 日的最后一秒。
        vm.warp((block.timestamp / 1 days + 1) * 1 days - 1);
        vault.withdrawETH(alice, 5 ether);

        // 一秒之后就是新的一天：额度又可以用了。
        vm.warp(block.timestamp + 1);
        vault.withdrawETH(alice, 5 ether);
        vm.stopPrank();

        assertEq(vault.getSpentToday(address(0)), 5 ether);
    }

    function test_ResetDailySpentRestoresTheAllowance() public {
        vm.startPrank(owner);
        vault.setDailyWithdrawLimit(address(0), 5 ether);
        vault.withdrawETH(alice, 5 ether);

        assertEq(vault.getSpentToday(address(0)), 5 ether);

        vm.expectEmit(true, false, false, false, address(vault));
        emit DailySpentReset(address(0));

        vault.resetDailySpent(address(0));
        assertEq(vault.getSpentToday(address(0)), 0);

        vault.withdrawETH(alice, 5 ether);
        vm.stopPrank();

        assertEq(alice.balance, ETH_FUNDING + 10 ether);
    }

    /// @dev 覆盖饱和减法的分支：限额有可能被调低到低于当日已经花掉的金额。
    function test_LoweringTheDailyLimitBelowSpendBlocksFurtherWithdrawals() public {
        vm.startPrank(owner);
        vault.setDailyWithdrawLimit(address(0), 10 ether);
        vault.withdrawETH(alice, 10 ether);

        vault.setDailyWithdrawLimit(address(0), 5 ether);

        vm.expectRevert(
            abi.encodeWithSelector(IBlockchainVault.DailyWithdrawLimitExceeded.selector, address(0), 1, 0)
        );
        vault.withdrawETH(alice, 1);
        vm.stopPrank();
    }

    function test_DailyLimitIsTrackedPerToken() public {
        vm.startPrank(owner);
        vault.setDailyWithdrawLimit(address(0), 5 ether);
        vault.setDailyWithdrawLimit(address(token), 1_000e18);

        vault.withdrawETH(alice, 5 ether);
        vault.withdrawERC20(address(token), alice, 1_000e18);
        vm.stopPrank();

        assertEq(vault.getSpentToday(address(0)), 5 ether);
        assertEq(vault.getSpentToday(address(token)), 1_000e18);
    }

    function test_DailyLimitAppliesToSignatureWithdrawals() public {
        vm.prank(owner);
        vault.setDailyWithdrawLimit(address(0), 3 ether);

        IBlockchainVault.WithdrawRequest memory request = _ownerRequest(alice, 4 ether);
        bytes memory signature = _signRequest(OWNER_PK, request);

        vm.expectRevert(
            abi.encodeWithSelector(
                IBlockchainVault.DailyWithdrawLimitExceeded.selector, address(0), 4 ether, 3 ether
            )
        );
        vault.withdrawWithSig(request, signature);
    }

    function test_ZeroDailyLimitDisablesTheCheck() public {
        vm.startPrank(owner);
        vault.setDailyWithdrawLimit(address(0), 1 ether);
        vault.setDailyWithdrawLimit(address(0), 0);
        vault.withdrawETH(alice, 40 ether);
        vm.stopPrank();

        assertEq(alice.balance, ETH_FUNDING + 40 ether);
        assertEq(vault.getSpentToday(address(0)), 0, "no accounting while the check is off");
    }

    function test_OnlyOwnerCanSetDailyLimit() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        vault.setDailyWithdrawLimit(address(0), 1 ether);
    }

    function test_OnlyOwnerCanResetDailySpent() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        vault.resetDailySpent(address(0));
    }
}
