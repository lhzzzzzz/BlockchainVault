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

    /// @dev FR-4.1：initialize 传入的地址成为 Owner（部署者即 Owner）。
    function test_InitializerBecomesOwner() public view {
        assertEq(vault.owner(), owner);
        assertEq(vault.owner(), vm.addr(OWNER_PK));
    }

    /// @dev 初始化时传零地址作为 Owner 会以 `ZeroAddress` 回滚，
    ///      避免部署出一个无人能管理的金库。
    function test_InitializeRevertsForZeroOwner() public {
        BlockchainVault logic = new BlockchainVault();

        vm.expectRevert(IBlockchainVault.ZeroAddress.selector);
        new ERC1967Proxy(address(logic), abi.encodeCall(BlockchainVault.initialize, (address(0))));
    }

    /// @dev `initializer` 修饰符保证 initialize 只能调用一次，第二次被 `InvalidInitialization` 拒绝。
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

    /// @dev FR-4.2 + FR-4.4：`addAdmin` 发出 `AdminAdded`，并且被授权者立刻获得提款能力。
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

    /// @dev 把零地址设为 Admin 会以 `ZeroAddress` 回滚（零地址无意义且无法操作）。
    function test_AddAdminRevertsForZeroAddress() public {
        vm.expectRevert(IBlockchainVault.ZeroAddress.selector);
        vm.prank(owner);
        vault.addAdmin(address(0));
    }

    /// @dev 重复添加同一个 Admin 会以 `AlreadyAdmin` 回滚，避免冗余状态写入。
    function test_AddAdminRevertsForExistingAdmin() public {
        vm.startPrank(owner);
        vault.addAdmin(admin);

        vm.expectRevert(abi.encodeWithSelector(IBlockchainVault.AlreadyAdmin.selector, admin));
        vault.addAdmin(admin);
        vm.stopPrank();
    }

    /// @dev FR-4 验收：撤销 Admin 立即生效——同一次调用后就再也无法提款（`UnauthorizedCaller`）。
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

    /// @dev 移除一个本来就不是 Admin 的地址会以 `NotAdmin` 回滚。
    function test_RemoveAdminRevertsForNonAdmin() public {
        vm.expectRevert(abi.encodeWithSelector(IBlockchainVault.NotAdmin.selector, admin));
        vm.prank(owner);
        vault.removeAdmin(admin);
    }

    /// @dev 撤销后可以再次添加同一地址为 Admin，角色是可逆的普通状态位。
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

    /// @dev FR-4.5：无关地址调用 `addAdmin` 被 `OwnableUnauthorizedAccount` 拒绝。
    function test_NonOwnerCannotAddAdmin() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        vault.addAdmin(stranger);
    }

    /// @dev FR-4.5：Admin 自己也不能管理角色（`removeAdmin` 是 onlyOwner），无法自我保权。
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

    /// @dev FR-4.3：`transferOwnership` 发出 `OwnershipTransferred` 并真正改写 owner。
    function test_TransferOwnershipEmitsAndTakesEffect() public {
        vm.expectEmit(true, true, false, false, address(vault));
        emit OwnershipTransferred(owner, bob);

        vm.prank(owner);
        vault.transferOwnership(bob);

        assertEq(vault.owner(), bob);
    }

    /// @dev 无关地址无法转移所有权。
    function test_NonOwnerCannotTransferOwnership() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        vault.transferOwnership(stranger);
    }

    /// @dev 转移后原 Owner 立即失去提款权（`_isAuthorized` 只承认当前的 owner）。
    function test_PreviousOwnerLosesPrivilegesAfterTransfer() public {
        vm.prank(owner);
        vault.transferOwnership(bob);

        vm.expectRevert(abi.encodeWithSelector(IBlockchainVault.UnauthorizedCaller.selector, owner));
        vm.prank(owner);
        vault.withdrawETH(alice, 1 ether);
    }

    /// @dev 新 Owner 获得完整权限，可以管理 Admin。
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

    /// @dev FR-5.1 + FR-6.5：`pause` 发出 `Paused(调用者)`，且 `paused()` 变为 true。
    function test_PauseEmitsPausedEvent() public {
        assertFalse(vault.paused());

        vm.expectEmit(false, false, false, true, address(vault));
        emit Paused(owner);

        vm.prank(owner);
        vault.pause();

        assertTrue(vault.paused());
    }

    /// @dev FR-5.2 + FR-6.5：`unpause` 发出 `Unpaused(调用者)`，`paused()` 回到 false。
    function test_UnpauseEmitsUnpausedEvent() public {
        vm.prank(owner);
        vault.pause();

        vm.expectEmit(false, false, false, true, address(vault));
        emit Unpaused(owner);

        vm.prank(owner);
        vault.unpause();

        assertFalse(vault.paused());
    }

    /// @dev FR-5.1：无关地址无法暂停金库。
    function test_NonOwnerCannotPause() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        vault.pause();
    }

    /// @dev FR-5.2：无关地址无法恢复一个已暂停的金库（防止攻击者「解冻」）。
    function test_NonOwnerCannotUnpause() public {
        vm.prank(owner);
        vault.pause();

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        vault.unpause();
    }

    /// @dev 重复暂停被 OZ `whenNotPaused` 以 `EnforcedPause` 拒绝。
    function test_PauseRevertsWhenAlreadyPaused() public {
        vm.startPrank(owner);
        vault.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vault.pause();
        vm.stopPrank();
    }

    /// @dev 在未暂停状态下 unpause 被 OZ `whenPaused` 以 `ExpectedPause` 拒绝。
    function test_UnpauseRevertsWhenNotPaused() public {
        vm.expectRevert(PausableUpgradeable.ExpectedPause.selector);
        vm.prank(owner);
        vault.unpause();
    }
}
