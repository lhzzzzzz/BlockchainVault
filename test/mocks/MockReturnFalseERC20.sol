// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice 每次调用都回报成功，却一枚代币都不移动，并且 `transfer`/`transferFrom`
///         返回 `false` 的 ERC20，用来模拟一个损坏或带有恶意的代币。
/// @dev SafeERC20 必须把 `false` 返回值视为失败，而不能悄悄当作成功（SC-5）。
///      `balanceOf` 刻意虚报余额，好让金库的余额校验通过，
///      从而迫使这个错误必须由 SafeERC20 自己捕获。
contract MockReturnFalseERC20 {
    uint256 private constant FAKE_BALANCE = 1_000_000e18;

    function totalSupply() external pure returns (uint256) {
        return FAKE_BALANCE;
    }

    function balanceOf(address) external pure returns (uint256) {
        return FAKE_BALANCE;
    }

    function allowance(address, address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return false;
    }

    function approve(address, uint256) external pure returns (bool) {
        return true;
    }
}
