// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title VaultStorage
/// @notice {BlockchainVault} 所使用的 ERC-7201 命名空间存储布局。
/// @dev 状态不存放在 slot 0，而是位于由命名空间字符串推导出的槽位，
///      因此金库的未来版本可以直接追加字段，既不会与所继承的 OpenZeppelin 模块
///      （它们同样是命名空间化的）的状态冲突，也不会与日后新引入的基类冲突。
///      在 {Layout} 末尾追加字段是升级安全的；重排或删除字段则不是。
library VaultStorage {
    /// @notice 金库状态。字段顺序属于存储 ABI 的一部分 —— 只允许追加。
    /// @param admins Owner 之外、被允许发起提款的账户。
    /// @param nonces 每个签名者下一次应当使用的 nonce（防重放）。
    /// @param whitelist 当 `whitelistEnabled` 为真时，允许接收提款的收款方。
    /// @param whitelistEnabled 提款白名单是否生效。
    /// @param singleWithdrawLimit 每个代币的单笔限额；`0` 表示关闭该校验。
    /// @param dailyWithdrawLimit 每个代币按 UTC 日累计的限额；`0` 表示关闭该校验。
    /// @param spentToday 在 `lastSpendDay[token]` 这一天内已经提出的金额。
    /// @param lastSpendDay `spentToday` 所属的 UTC 日序号（`block.timestamp / 1 days`）。
    struct Layout {
        mapping(address account => bool isAdmin) admins;
        mapping(address signer => uint256 nonce) nonces;
        mapping(address account => bool allowed) whitelist;
        bool whitelistEnabled;
        mapping(address token => uint256 limit) singleWithdrawLimit;
        mapping(address token => uint256 limit) dailyWithdrawLimit;
        mapping(address token => uint256 spent) spentToday;
        mapping(address token => uint256 day) lastSpendDay;
    }

    /// @dev `keccak256(abi.encode(uint256(keccak256("vault.storage.BlockchainVault")) - 1)) & ~bytes32(uint256(0xff))`。
    ///      由 `test/VaultStorageSlot.t.sol` 校验。
    bytes32 internal constant SLOT = 0x3db71306f2ca18d7ee18ab1454c13a0cf765f604472057f73023c55cec037800;

    /// @notice 返回存放在 {SLOT} 处的 {Layout} 结构体。
    function layout() internal pure returns (Layout storage $) {
        assembly {
            $.slot := SLOT
        }
    }
}
