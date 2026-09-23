// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice 行为规范的标准 ERC20，供整个测试套件使用。
contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    /// @notice 不受限制地增发，方便测试随意分发余额。
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
