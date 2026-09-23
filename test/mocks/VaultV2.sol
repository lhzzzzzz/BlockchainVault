// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BlockchainVault} from "../../src/BlockchainVault.sol";

/// @notice {VaultV2} 新增的存储，位于它自己的命名空间里。
/// @dev 这正是 {BlockchainVault} 采用 ERC-7201 布局所带来的具体收益：
///      新版本在一个全新推导出的槽位上扩展状态，而不是往旧布局后面追加，
///      因此既不会与 V1 的金库字段冲突，也不会与所继承的 OpenZeppelin 模块冲突。
library VaultV2Storage {
    /// @dev `keccak256(abi.encode(uint256(keccak256("vault.storage.BlockchainVaultV2")) - 1)) & ~bytes32(uint256(0xff))`。
    bytes32 internal constant SLOT = 0xf3f2427fbe6a50c90783b9c9fa31dbcbbfc7fbdf9c3821d38644fc4a07c67200;

    struct Layout {
        uint256 withdrawalCount;
    }

    function layout() internal pure returns (Layout storage $) {
        assembly {
            $.slot := SLOT
        }
    }
}

/// @notice 升级测试所使用的 V2 实现。
/// @dev 它新增了一个函数与一个存储命名空间，同时继承了 V1 的全部逻辑与布局。
///      这里没有声明构造函数：继承来的那个已经关闭了初始化器。
contract VaultV2 is BlockchainVault {
    /// @notice 当 V2 专属计数器被递增时发出。
    event WithdrawalCountIncremented(uint256 newCount);

    /// @notice 版本标记，V1 中并不存在，因此测试可以用它来证明代理确实切换了实现。
    function version() external pure returns (string memory) {
        return "2.0.0";
    }

    /// @notice 递增 V2 专属计数器，用以检验新增的存储命名空间。
    function bumpWithdrawalCount() external {
        VaultV2Storage.Layout storage $ = VaultV2Storage.layout();
        $.withdrawalCount += 1;
        emit WithdrawalCountIncremented($.withdrawalCount);
    }

    /// @notice 读取 V2 专属计数器。
    function withdrawalCount() external view returns (uint256) {
        return VaultV2Storage.layout().withdrawalCount;
    }
}
