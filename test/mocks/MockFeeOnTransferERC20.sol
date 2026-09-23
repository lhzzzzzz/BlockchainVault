// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice 在每一次转账途中烧掉一定比例的 ERC20。
/// @dev 用于证明 {BlockchainVault-depositERC20} 记入的是余额增量而非请求金额，
///      因此抽成代币无法让金库虚报自己的持仓。
contract MockFeeOnTransferERC20 is ERC20 {
    /// @notice 每次非增发、非销毁的转账所收取的手续费，单位为基点。
    uint256 public feeBps;

    constructor(uint256 feeBps_) ERC20("FeeOnTransfer", "FOT") {
        feeBps = feeBps_;
    }

    /// @notice 不受限制地增发，方便测试随意分发余额。
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @inheritdoc ERC20
    /// @dev 两段转账都通过 `super` 调用，以免本重写递归调用自己。
    ///      增发（`from == 0`）与销毁（`to == 0`）从不收取手续费。
    function _update(address from, address to, uint256 value) internal override {
        if (feeBps > 0 && from != address(0) && to != address(0) && value > 0) {
            uint256 fee = (value * feeBps) / 10_000;
            if (fee > 0) {
                super._update(from, address(0), fee);
                super._update(from, to, value - fee);
                return;
            }
        }
        super._update(from, to, value);
    }
}
