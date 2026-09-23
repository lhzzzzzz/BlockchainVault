// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BlockchainVault} from "../../src/BlockchainVault.sol";

/// @notice 恶意的 ETH 收款方，会在外层提款尚未结束时，从它的 `receive` 回调里尝试重入金库（SC-1）。
/// @dev 重入调用通过 `try/catch` 发出，这样测试就能观察到它**为什么**被拒绝：
///      重入锁的回滚被捕获并记录下来，而外层提款依然可以正常完成。
///      这一点把「被 ReentrancyGuard 拦住」与「被权限控制拦住」区分开来，
///      而对外层调用简单地 `vm.expectRevert` 是无法区分的。
contract ReentrancyAttacker {
    /// @notice 被攻击的金库。
    BlockchainVault public immutable VAULT;

    /// @notice 重入调用所使用的金额。
    uint256 public reentryAmount;

    /// @notice 是否已经发起过一次重入尝试。
    bool public attempted;

    /// @notice 重入调用是否回滚了。
    bool public reentryReverted;

    /// @notice 重入调用回滚时携带的错误选择器（如果有）。
    bytes4 public reentryErrorSelector;

    /// @notice receive 钩子被触发的次数。
    uint256 public received;

    constructor(BlockchainVault vault_) {
        VAULT = vault_;
    }

    /// @notice 从外部发起攻击：先提款到本合约，本合约随即重入。
    /// @param amount 要提取的金额。
    function attack(uint256 amount) external {
        reentryAmount = amount;
        VAULT.withdrawETH(address(this), amount);
    }

    /// @notice 执行重入提款，并把结果记录下来而不是向上抛出。
    function reenter() public {
        attempted = true;
        try VAULT.withdrawETH(address(this), reentryAmount) {
            reentryReverted = false;
        } catch (bytes memory reason) {
            reentryReverted = true;
            if (reason.length >= 4) {
                bytes4 selector;
                assembly {
                    selector := mload(add(reason, 0x20))
                }
                reentryErrorSelector = selector;
            }
        }
    }

    /// @dev 在金库付款时触发，也就是提款尚未结束的那一刻。
    receive() external payable {
        received += 1;
        reenter();
    }
}
