// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {VaultTestBase} from "./VaultTestBase.sol";
import {BlockchainVault} from "../src/BlockchainVault.sol";
import {IBlockchainVault} from "../src/interfaces/IBlockchainVault.sol";

/// @notice FR-4（角色与所有权）以及 FR-5.1–FR-5.3（熔断开关）。
contract AccessControlTest is VaultTestBase {
    event AdminAdded(address indexed admin);
    event AdminRemoved(address indexed admin);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    // 与 OpenZeppelin 的 `Pausable` 保持一致：它声明的这两个事件都没有 `indexed`。
    event Paused(address account);
    event Unpaused(address account);

    // ---------------------------------------------------------------------
    // FR-4.1 —— 部署
    // ---------------------------------------------------------------------

    function test_InitializerBecomesOwner() public view {
        assertEq(vault.owner(), owner);
        assertEq(vault.owner(), vm.addr(OWNER_PK));
    }

    function test_InitializeRevertsForZeroOwner() public {
        BlockchainVault logic = new BlockchainVault();

        vm.expectRevert(IBlockchainVault.ZeroAddress.selector);
        new ERC1967Proxy(address(logic), abi.encodeCall(BlockchainVault.initialize, (address(0))));
    }

    function test_InitializeCannotBeCalledTwice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vault.initialize(stranger);
    }

    /// @dev 逻辑合约会关闭自身的初始化器，因此无法被直接劫持。
    function test_ImplementationCannotBeInitialized() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(stranger);
    }

    // ---------------------------------------------------------------------
    // FR-4.2 / FR-4.4 —— 管理员生命周期
    // ---------------------------------------------------------------------

    function test_AddAdminGrantsWithdrawRights() public {
        assertFalse(vault.isAdmin(admin));

        vm.expectEmit(true, false, false, false, address(vault));
        emit AdminAdded(admin);

        vm.prank(owner);
        vault.addAdmin(admin);

        assertTrue(vault.isAdmin(admin));

        vm.prank(admin);
        vault.withdrawETH(alice, 1 ether);
        assertEq(alice.balance, ETH_FUNDING + 1 ether);
    }

    function test_AddAdminRevertsForZeroAddress() public {
        vm.expectRevert(IBlockchainVault.ZeroAddress.selector);
        vm.prank(owner);
        vault.addAdmin(address(0));
    }

    function test_AddAdminRevertsForExistingAdmin() public {
        vm.startPrank(owner);
        vault.addAdmin(admin);

        vm.expectRevert(abi.encodeWithSelector(IBlockchainVault.AlreadyAdmin.selector, admin));
        vault.addAdmin(admin);
        vm.stopPrank();
    }

    function test_RemoveAdminRevokesWithdrawRightsImmediately() public {
        vm.startPrank(owner);
        vault.addAdmin(admin);

        vm.expectEmit(true, false, false, false, address(vault));
        emit AdminRemoved(admin);

        vault.removeAdmin(admin);
        vm.stopPrank();

        assertFalse(vault.isAdmin(admin));

        vm.expectRevert(abi.encodeWithSelector(IBlockchainVault.UnauthorizedCaller.selector, admin));
        vm.prank(admin);
        vault.withdrawETH(alice, 1 ether);
    }

    function test_RemoveAdminRevertsForNonAdmin() public {
        vm.expectRevert(abi.encodeWithSelector(IBlockchainVault.NotAdmin.selector, admin));
        vm.prank(owner);
        vault.removeAdmin(admin);
    }

    function test_AdminCanBeReAddedAfterRemoval() public {
        vm.startPrank(owner);
        vault.addAdmin(admin);
        vault.removeAdmin(admin);
        vault.addAdmin(admin);
        vm.stopPrank();

        assertTrue(vault.isAdmin(admin));
    }

    // ---------------------------------------------------------------------
    // FR-4.5 —— 只有 Owner 能管理角色
    // ---------------------------------------------------------------------

    function test_NonOwnerCannotAddAdmin() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        vault.addAdmin(stranger);
    }

    function test_NonOwnerCannotRemoveAdmin() public {
        vm.prank(owner);
        vault.addAdmin(admin);

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, admin));
        vm.prank(admin);
        vault.removeAdmin(admin);
    }

    /// @dev Admin 是运营人员而不是治理者：他们不能给自己或他人升权。
    function test_AdminCannotPromoteThemselvesToOwner() public {
        vm.prank(owner);
        vault.addAdmin(admin);

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, admin));
        vm.prank(admin);
        vault.transferOwnership(admin);
    }

    // ---------------------------------------------------------------------
    // FR-4.3 —— 所有权转移
    // ---------------------------------------------------------------------

    function test_TransferOwnershipEmitsAndTakesEffect() public {
        vm.expectEmit(true, true, false, false, address(vault));
        emit OwnershipTransferred(owner, bob);

        vm.prank(owner);
        vault.transferOwnership(bob);

        assertEq(vault.owner(), bob);
    }

    function test_NonOwnerCannotTransferOwnership() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        vault.transferOwnership(stranger);
    }

    function test_PreviousOwnerLosesPrivilegesAfterTransfer() public {
        vm.prank(owner);
        vault.transferOwnership(bob);

        vm.expectRevert(abi.encodeWithSelector(IBlockchainVault.UnauthorizedCaller.selector, owner));
        vm.prank(owner);
        vault.withdrawETH(alice, 1 ether);
    }

    function test_NewOwnerCanManageAdmins() public {
        vm.prank(owner);
        vault.transferOwnership(bob);

        vm.prank(bob);
        vault.addAdmin(admin);

        assertTrue(vault.isAdmin(admin));
    }

    // ---------------------------------------------------------------------
    // FR-5.1 / FR-5.2 / FR-6.5 —— 熔断开关
    // ---------------------------------------------------------------------

    function test_PauseEmitsPausedEvent() public {
        assertFalse(vault.paused());

        vm.expectEmit(false, false, false, true, address(vault));
        emit Paused(owner);

        vm.prank(owner);
        vault.pause();

        assertTrue(vault.paused());
    }

    function test_UnpauseEmitsUnpausedEvent() public {
        vm.prank(owner);
        vault.pause();

        vm.expectEmit(false, false, false, true, address(vault));
        emit Unpaused(owner);

        vm.prank(owner);
        vault.unpause();

        assertFalse(vault.paused());
    }

    function test_NonOwnerCannotPause() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        vault.pause();
    }

    function test_NonOwnerCannotUnpause() public {
        vm.prank(owner);
        vault.pause();

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        vault.unpause();
    }

    function test_PauseRevertsWhenAlreadyPaused() public {
        vm.startPrank(owner);
        vault.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vault.pause();
        vm.stopPrank();
    }

    function test_UnpauseRevertsWhenNotPaused() public {
        vm.expectRevert(PausableUpgradeable.ExpectedPause.selector);
        vm.prank(owner);
        vault.unpause();
    }
}
