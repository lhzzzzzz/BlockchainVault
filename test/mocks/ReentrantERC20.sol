// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {BlockchainVault} from "../../src/BlockchainVault.sol";

/// @notice 会在 `_update` 内部重入金库的 ERC20，也就是在金库执行 `safeTransfer`
///         执行到一半的时候（SC-1 的代币发起重入路径）。
/// @dev 这个恶意回调只在**从金库转出**时触发，而且只触发一次，
///      因此该测试替身自身不会无限递归下去。
contract ReentrantERC20 is ERC20 {
    /// @notice 被攻击的金库，由测试设置一次。
    BlockchainVault public vault;

    /// @notice 是否已经发起过一次重入尝试。
    bool public attempted;

    /// @notice 重入调用是否回滚了。
    bool public reentryReverted;

    /// @notice 重入调用回滚时携带的错误选择器（如果有）。
    bytes4 public reentryErrorSelector;

    /// @dev 重入闩锁，保证恶意路径在单次转账中最多执行一次。
    bool private _inCallback;

    constructor() ERC20("ReentrantToken", "REENT") {}

    /// @notice 不受限制地增发，方便测试随意分发余额。
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice 让该测试替身指向它应当攻击的金库。
    function setVault(BlockchainVault vault_) external {
        vault = vault_;
    }

    /// @inheritdoc ERC20
    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);

        if (address(vault) != address(0) && !_inCallback && from == address(vault)) {
            _inCallback = true;
            attempted = true;
            try vault.withdrawERC20(address(this), address(this), value) {
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
            _inCallback = false;
        }
    }
}
