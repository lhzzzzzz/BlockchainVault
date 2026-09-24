// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {VaultTestBase} from "./VaultTestBase.sol";
import {IBlockchainVault} from "../src/interfaces/IBlockchainVault.sol";
import {MockFeeOnTransferERC20} from "./mocks/MockFeeOnTransferERC20.sol";

/// @notice 只要调用一个金库并未实现的选择器，就会落到 `fallback()` 上。
interface IBogusFunction {
    function bogus() external payable;
}

/// @notice FR-1：金库能够托管 ETH 与 ERC20 代币。
contract DepositTest is VaultTestBase {
    event Deposited(address indexed from, address indexed token, uint256 amount);

    // ---------------------------------------------------------------------
    // FR-1.1 / AC-1 —— 原生 ETH
    // ---------------------------------------------------------------------

    /// @dev 直接向合约发送 ETH 会触发 `receive()`：转账成功、余额增加，并发出 `Deposited` 事件。
    function test_ReceiveCreditsETHAndEmitsDeposited() public {
        uint256 balanceBefore = vault.getETHBalance();

        vm.expectEmit(true, true, false, true, address(vault));
        emit Deposited(alice, address(0), 5 ether);

        vm.prank(alice);
        (bool ok,) = address(vault).call{value: 5 ether}("");

        assertTrue(ok, "plain ETH send must succeed");
        assertEq(vault.getETHBalance(), balanceBefore + 5 ether);
        assertEq(address(vault).balance, balanceBefore + 5 ether);
    }

    /// @dev 零金额转账不会回滚，但也不会发出事件——`receive()` 里的 `if (msg.value > 0)` 只影响日志。
    function test_ReceiveAcceptsZeroValueWithoutEmitting() public {
        uint256 balanceBefore = vault.getETHBalance();

        // 这里预期不会发出任何事件：刻意不调用 `expectEmit`，且余额保持不变。
        vm.prank(alice);
        (bool ok,) = address(vault).call{value: 0}("");

        assertTrue(ok, "zero-value send must not revert");
        assertEq(vault.getETHBalance(), balanceBefore);
    }

    /// @dev 携带金额的未知选择器调用会落到 `fallback()`，同样计为存款并发出事件。
    function test_FallbackWithValueCreditsETH() public {
        uint256 balanceBefore = vault.getETHBalance();

        vm.expectEmit(true, true, false, true, address(vault));
        emit Deposited(alice, address(0), 3 ether);

        vm.prank(alice);
        (bool ok,) = address(vault).call{value: 3 ether}(abi.encodeCall(IBogusFunction.bogus, ()));

        assertTrue(ok, "fallback with value must succeed");
        assertEq(vault.getETHBalance(), balanceBefore + 3 ether);
    }

    /// @dev 不带金额的未知选择器调用被 `fallback()` 以 `UnknownFunction(selector)` 拒绝
    ///      （这类调用更像是误操作，而非有意存款）。
    function test_FallbackWithoutValueReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(IBlockchainVault.UnknownFunction.selector, IBogusFunction.bogus.selector)
        );
        IBogusFunction(address(vault)).bogus();
    }

    // ---------------------------------------------------------------------
    // FR-1.2 / AC-2 —— ERC20
    // ---------------------------------------------------------------------

    /// @dev 先 approve 再 `depositERC20`：金库余额增加、存款人余额减少，并发出 `Deposited`。
    function test_DepositERC20CreditsVault() public {
        uint256 vaultBefore = vault.getTokenBalance(address(token));
        uint256 aliceBefore = token.balanceOf(alice);

        // 先授权：`expectEmit` 匹配的是「紧接着的下一个事件」，而 `approve` 会发出 `Approval`。
        vm.prank(alice);
        token.approve(address(vault), 1_000e18);

        vm.expectEmit(true, true, false, true, address(vault));
        emit Deposited(alice, address(token), 1_000e18);

        vm.prank(alice);
        vault.depositERC20(address(token), 1_000e18);

        assertEq(vault.getTokenBalance(address(token)), vaultBefore + 1_000e18);
        assertEq(token.balanceOf(alice), aliceBefore - 1_000e18);
    }

    /// @dev FR-1.5 / SC-5：仿 USDT 的代币不返回 `bool`，SafeERC20 仍必须能处理它。
    function test_DepositERC20SupportsNonStandardToken() public {
        nonStandardToken.mint(alice, 500e6);

        vm.startPrank(alice);
        nonStandardToken.approve(address(vault), 500e6);
        vault.depositERC20(address(nonStandardToken), 500e6);
        vm.stopPrank();

        assertEq(vault.getTokenBalance(address(nonStandardToken)), 500e6);
        assertEq(nonStandardToken.balanceOf(address(vault)), 500e6);
    }

    /// @dev 存入 0 金额被 `ZeroAmount` 拒绝。
    function test_DepositERC20RevertsOnZeroAmount() public {
        vm.expectRevert(IBlockchainVault.ZeroAmount.selector);
        vm.prank(alice);
        vault.depositERC20(address(token), 0);
    }

    /// @dev 代币地址传 `address(0)` 被 `ZeroAddress` 拒绝。
    function test_DepositERC20RevertsOnZeroAddress() public {
        vm.expectRevert(IBlockchainVault.ZeroAddress.selector);
        vm.prank(alice);
        vault.depositERC20(address(0), 1e18);
    }

    /// @dev 代币地址是 EOA（无代码）时被 `NotAContract` 拒绝——
    ///      否则 SafeERC20 会对空地址「假成功」，金库误以为收到了钱。
    function test_DepositERC20RevertsForAddressWithoutCode() public {
        vm.expectRevert(abi.encodeWithSelector(IBlockchainVault.NotAContract.selector, alice));
        vm.prank(alice);
        vault.depositERC20(alice, 1e18);
    }

    /// @dev 记入的金额必须是实际观测到的余额增量，而不是请求金额，
    ///      这样抽成代币就无法让金库误以为自己持有得更多。
    function test_DepositERC20CreditsBalanceDeltaForFeeOnTransferToken() public {
        MockFeeOnTransferERC20 feeToken = new MockFeeOnTransferERC20(100); // 1%
        feeToken.mint(alice, 1_000e18);

        vm.prank(alice);
        feeToken.approve(address(vault), 1_000e18);

        vm.expectEmit(true, true, false, true, address(vault));
        emit Deposited(alice, address(feeToken), 990e18);

        vm.prank(alice);
        vault.depositERC20(address(feeToken), 1_000e18);

        assertEq(vault.getTokenBalance(address(feeToken)), 990e18);
        assertEq(feeToken.balanceOf(address(vault)), 990e18);
    }

    /// @dev 100% 抽成的代币会让金库实际收到 0，此时以 `ZeroAmount` 回滚而不是记一笔空账。
    function test_DepositERC20RevertsWhenNothingArrives() public {
        MockFeeOnTransferERC20 feeToken = new MockFeeOnTransferERC20(10_000); // 100%
        feeToken.mint(alice, 1_000e18);

        vm.startPrank(alice);
        feeToken.approve(address(vault), 1_000e18);
        vm.expectRevert(IBlockchainVault.ZeroAmount.selector);
        vault.depositERC20(address(feeToken), 1_000e18);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    // FR-1.3 / FR-1.4 —— 余额查询
    // ---------------------------------------------------------------------

    /// @dev `getETHBalance()` 返回的正是链上真实余额 `address(this).balance`。
    function test_GetETHBalanceReportsOnChainBalance() public view {
        assertEq(vault.getETHBalance(), address(vault).balance);
        assertEq(vault.getETHBalance(), 100 ether);
    }

    /// @dev `getTokenBalance()` 返回的正是代币合约里的真实 `balanceOf(金库)`。
    function test_GetTokenBalanceReportsOnChainBalance() public view {
        assertEq(vault.getTokenBalance(address(token)), token.balanceOf(address(vault)));
        assertEq(vault.getTokenBalance(address(token)), 100_000e18);
    }

    // ---------------------------------------------------------------------
    // FR-5.3 / AC-10 —— 暂停不影响存款
    // ---------------------------------------------------------------------

    /// @dev 暂停后提款被禁，但 ETH 与 ERC20 存款都必须照常成功（`whenNotPaused` 只加在提款入口）。
    function test_DepositsAreAllowedWhilePaused() public {
        vm.prank(owner);
        vault.pause();
        assertTrue(vault.paused());

        vm.prank(alice);
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertTrue(ok, "ETH deposits must work while paused");

        _depositToken(alice, 5e18);
        assertEq(token.balanceOf(address(vault)), 100_000e18 + 5e18);
    }
}
