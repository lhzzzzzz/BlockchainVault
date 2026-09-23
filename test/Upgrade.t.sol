// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {VaultTestBase} from "./VaultTestBase.sol";
import {BlockchainVault} from "../src/BlockchainVault.sol";
import {VaultV2} from "./mocks/VaultV2.sol";
import {IBlockchainVault} from "../src/interfaces/IBlockchainVault.sol";

/// @notice FR/UUPS：只有 Owner 可以升级，且升级过程中不得丢失任何状态。
contract UpgradeTest is VaultTestBase {
    event Upgraded(address indexed implementation);

    /// @dev 部署 V2，并以 Owner 身份把代理指向它。
    function _upgradeToV2() internal returns (VaultV2 v2) {
        v2 = new VaultV2();
        vm.prank(owner);
        vault.upgradeToAndCall(address(v2), "");
    }

    /// @dev 以 V2 的 ABI 来看待这个代理。
    function _v2() private view returns (VaultV2) {
        return VaultV2(payable(address(vault)));
    }

    /// @dev 读取 `proxy` 的 ERC-1967 实现槽位。
    ///      这里不能用 `ERC1967Utils.getImplementation()`：它读的是调用者自身的存储，
    ///      那将会是本测试合约而不是代理。
    function _implementationOf(address proxy) private view returns (address) {
        return address(uint160(uint256(vm.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT))));
    }

    // ---------------------------------------------------------------------
    // 升级授权
    // ---------------------------------------------------------------------

    function test_OwnerCanUpgrade() public {
        VaultV2 v2 = _upgradeToV2();

        assertEq(_implementationOf(address(vault)), address(v2));
        assertEq(_v2().version(), "2.0.0");
    }

    function test_UpgradeEmitsUpgradedEvent() public {
        VaultV2 v2 = new VaultV2();

        vm.expectEmit(true, false, false, false, address(vault));
        emit Upgraded(address(v2));

        vm.prank(owner);
        vault.upgradeToAndCall(address(v2), "");
    }

    function test_NonOwnerCannotUpgrade() public {
        VaultV2 v2 = new VaultV2();

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        vault.upgradeToAndCall(address(v2), "");

        assertEq(_implementationOf(address(vault)), address(implementation));
    }

    /// @dev Admin 是运营人员而不是治理者：他们不能更换实现合约。
    function test_AdminCannotUpgrade() public {
        vm.prank(owner);
        vault.addAdmin(admin);

        VaultV2 v2 = new VaultV2();

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, admin));
        vm.prank(admin);
        vault.upgradeToAndCall(address(v2), "");
    }

    function test_CannotUpgradeToContractThatIsNotUUPS() public {
        vm.expectRevert(
            abi.encodeWithSelector(ERC1967Utils.ERC1967InvalidImplementation.selector, address(token))
        );
        vm.prank(owner);
        vault.upgradeToAndCall(address(token), "");
    }

    /// @dev 完全没有代码的目标无法通过校验：`proxiableUUID()` 返回空 returndata，
    ///      于是解码那个 `bytes32` 失败，调用以「无数据」的方式回滚，
    ///      而不是像面对「有代码的合约」时那样抛出 ERC-1967 错误。
    function test_CannotUpgradeToZeroAddress() public {
        vm.expectRevert();
        vm.prank(owner);
        vault.upgradeToAndCall(address(0), "");
    }

    /// @dev 逻辑合约必须拒绝那些只能经代理调用的入口，
    ///      但在被直接调用时仍要能回答 `proxiableUUID()` —— 这正是校验一个实现的方式。
    function test_ImplementationRejectsProxyOnlyEntryPoints() public {
        VaultV2 v2 = new VaultV2();

        vm.expectRevert(UUPSUpgradeable.UUPSUnauthorizedCallContext.selector);
        implementation.upgradeToAndCall(address(v2), "");

        // 直接在逻辑合约上调用是成功的……
        assertEq(implementation.proxiableUUID(), ERC1967Utils.IMPLEMENTATION_SLOT);

        // ……但经代理调用必须回滚，这样代理就永远不可能被升级成它自己。
        vm.expectRevert(UUPSUpgradeable.UUPSUnauthorizedCallContext.selector);
        vault.proxiableUUID();
    }

    function test_ProxyReportsTheErc1967ImplementationSlot() public view {
        assertEq(_implementationOf(address(vault)), address(implementation));
        assertEq(ERC1967Utils.IMPLEMENTATION_SLOT, bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1));
    }

    // ---------------------------------------------------------------------
    // 状态保持
    // ---------------------------------------------------------------------

    function test_UpgradePreservesAssetBalances() public {
        _upgradeToV2();

        assertEq(vault.getETHBalance(), 100 ether);
        assertEq(vault.getTokenBalance(address(token)), 100_000e18);
    }

    function test_UpgradePreservesAdminsAndNonces() public {
        vm.prank(owner);
        vault.addAdmin(admin);

        // 先消耗掉一个 nonce，这样才有东西可以被「保持」。
        IBlockchainVault.WithdrawRequest memory request = _ownerRequest(alice, 1 ether);
        vault.withdrawWithSig(request, _signRequest(OWNER_PK, request));

        _upgradeToV2();

        assertTrue(vault.isAdmin(admin));
        assertEq(vault.getNonce(owner), 1);
        assertEq(vault.getNonce(admin), 0);
        assertEq(vault.owner(), owner);
    }

    function test_UpgradePreservesRiskConfiguration() public {
        vm.startPrank(owner);
        vault.setWhitelistEnabled(true);
        vault.setWhitelisted(alice, true);
        vault.setSingleWithdrawLimit(address(0), 3 ether);
        vault.setDailyWithdrawLimit(address(token), 5_000e18);
        vm.stopPrank();

        _upgradeToV2();

        assertTrue(vault.whitelistEnabled());
        assertTrue(vault.isWhitelisted(alice));
        assertEq(vault.getSingleWithdrawLimit(address(0)), 3 ether);
        assertEq(vault.getDailyWithdrawLimit(address(token)), 5_000e18);
    }

    function test_WithdrawalsStillWorkAfterUpgrade() public {
        _upgradeToV2();

        // 基于角色的通道。
        vm.prank(owner);
        vault.withdrawETH(alice, 1 ether);

        // 签名通道，nonce 从 V1 停下的位置继续。
        IBlockchainVault.WithdrawRequest memory request = _ownerRequest(alice, 2 ether);
        vault.withdrawWithSig(request, _signRequest(OWNER_PK, request));

        assertEq(alice.balance, ETH_FUNDING + 3 ether);
        assertEq(vault.getNonce(owner), 1);
    }

    // ---------------------------------------------------------------------
    // V2 新增内容
    // ---------------------------------------------------------------------

    /// @dev 新增的存储使用它自己的 ERC-7201 命名空间，因此不可能与 V1 的状态发生别名重叠。
    function test_V2AddsStorageWithoutCollidingWithV1() public {
        VaultV2 upgraded = _v2();
        _upgradeToV2();

        // 从零开始，递增 V2 专属的计数器。
        assertEq(upgraded.withdrawalCount(), 0);
        upgraded.bumpWithdrawalCount();
        upgraded.bumpWithdrawalCount();
        assertEq(upgraded.withdrawalCount(), 2);

        // V2 的写入完全不影响 V1 的状态。
        assertEq(vault.getNonce(owner), 0);
        assertEq(vault.getETHBalance(), 100 ether);
        assertEq(vault.getTokenBalance(address(token)), 100_000e18);
    }

    /// @dev `upgradeToAndCall` 必须把传入的 calldata 经代理、针对新实现执行。
    function test_UpgradeToAndCallExecutesTheInitializerPayload() public {
        VaultV2 v2 = new VaultV2();

        vm.prank(owner);
        vault.upgradeToAndCall(address(v2), abi.encodeCall(VaultV2.bumpWithdrawalCount, ()));

        assertEq(_v2().withdrawalCount(), 1);
        assertEq(_v2().version(), "2.0.0");
    }

    /// @dev 升级后的代理上，各守卫依然无法被重新初始化。
    function test_InitializerStillLockedAfterUpgrade() public {
        _upgradeToV2();

        vm.expectRevert();
        vault.initialize(stranger);
    }
}
