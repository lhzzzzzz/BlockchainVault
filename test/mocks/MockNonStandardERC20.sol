// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice 一个 `transfer`、`transferFrom`、`approve` 都**不返回任何值**的 ERC20，
///         行为与以太坊主网上的 USDT 完全一致。用于证明金库的每一次代币交互都走 SafeERC20，
///         而不是想当然地假设存在 `bool` 返回值（SC-5）。
/// @dev 整个文件都关闭了 `incorrect-erc20-interface` 静态检查规则：
///      缺少返回值正是这个测试替身存在的意义。
// forge-lint: disable-start(incorrect-erc20-interface)
contract MockNonStandardERC20 {
    string public name = "NonStandardToken";
    string public symbol = "NSTD";
    uint8 public constant decimals = 6;

    uint256 public totalSupply;
    mapping(address account => uint256 balance) public balanceOf;
    mapping(address account => mapping(address spender => uint256 amount)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    // --- 刻意不返回任何值。 ---

    function transfer(address to, uint256 amount) external {
        _transfer(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
    }

    function _transfer(address from, address to, uint256 amount) private {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}
// forge-lint: disable-end(incorrect-erc20-interface)
