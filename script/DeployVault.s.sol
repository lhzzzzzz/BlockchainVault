// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {BlockchainVault} from "../src/BlockchainVault.sol";

/// @title DeployVault
/// @notice 一条命令完成金库部署：逻辑合约、ERC-1967 代理、初始化，以及可选的初始 Admin。
///         同时把部署结果记录到 `deployments/<chainId>.json`。
///
/// @dev 签名者由命令行参数决定，因此任何 Foundry 签名后端都可以使用
///      （`--private-key`、`--account`、`--ledger`、`--unlocked`）。
///
///      本地空跑（不发送任何交易）：
///        forge script script/DeployVault.s.sol
///
///      测试网部署：
///        VAULT_OWNER=0xOwner VAULT_ADMINS=0xAdmin1,0xAdmin2 \
///        forge script script/DeployVault.s.sol \
///          --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --broadcast --verify
///
///      环境变量：
///        VAULT_OWNER   可选，地址。默认为广播账户本身。
///        VAULT_ADMINS  可选，逗号分隔的地址列表，用于授予 Admin 角色。
contract DeployVault is Script {
    /// @notice 部署并初始化金库。
    /// @return vault 部署好的 {BlockchainVault}，通过其代理访问。
    /// @return implementation 代理所委托的逻辑合约。
    function run() external returns (BlockchainVault vault, address implementation) {
        address vaultOwner = vm.envExists("VAULT_OWNER") ? vm.envAddress("VAULT_OWNER", ",")[0] : msg.sender;
        address[] memory initialAdmins =
            vm.envExists("VAULT_ADMINS") ? vm.envAddress("VAULT_ADMINS", ",") : new address[](0);

        console2.log("Deployer          :", msg.sender);
        console2.log("Owner             :", vaultOwner);
        console2.log("Initial admins    :", initialAdmins.length);

        vm.startBroadcast();
        (vault, implementation) = _deploy(vaultOwner, initialAdmins);
        vm.stopBroadcast();

        _writeDeployment(address(vault), implementation, vaultOwner);
        _report(address(vault), implementation, vaultOwner, initialAdmins);
    }

    /// @dev 部署逻辑合约、代理以及所有初始 Admin。
    function _deploy(address vaultOwner, address[] memory initialAdmins)
        internal
        returns (BlockchainVault vault, address implementation)
    {
        implementation = address(new BlockchainVault());

        // 初始化与代理创建在同一个调用里原子完成（放在代理的构造函数调用中），
        // 因此金库绝不会出现「已部署但无 Owner」的中间状态。
        vault = BlockchainVault(
            payable(
                address(
                    new ERC1967Proxy(implementation, abi.encodeCall(BlockchainVault.initialize, (vaultOwner)))
                )
            )
        );

        for (uint256 i = 0; i < initialAdmins.length; ++i) {
            // 这是对部署期固定列表的有界循环，不存在无界输入。
            // forge-lint: disable-next-line(calls-loop)
            vault.addAdmin(initialAdmins[i]);
        }
    }

    /// @dev 持久化部署结果，方便后续脚本（例如升级脚本）找到代理地址。
    function _writeDeployment(address vault, address implementation, address vaultOwner) internal {
        vm.createDir("./deployments", true);

        string memory objectKey = "deployment";
        // 这些 serialize 辅助函数会返回累积起来的 JSON；只有最后一次调用的返回值是有用的，
        // 因此中间几次的返回值是刻意丢弃的。
        // forge-lint: disable-start(unused-return)
        vm.serializeUint(objectKey, "chainId", block.chainid);
        vm.serializeAddress(objectKey, "implementation", implementation);
        vm.serializeAddress(objectKey, "owner", vaultOwner);
        string memory json = vm.serializeAddress(objectKey, "proxy", vault);
        // forge-lint: disable-end(unused-return)

        string memory path = string.concat("./deployments/", vm.toString(block.chainid), ".json");
        vm.writeJson(json, path);
        console2.log("Deployment written:", path);
    }

    /// @dev 便于人阅读的部署结果摘要。
    function _report(address vault, address implementation, address vaultOwner, address[] memory admins)
        internal
        pure
    {
        console2.log("");
        console2.log("=== BlockchainVault deployed ===");
        console2.log("proxy (use this):", vault);
        console2.log("implementation   :", implementation);
        console2.log("owner            :", vaultOwner);
        for (uint256 i = 0; i < admins.length; ++i) {
            console2.log("admin            :", admins[i]);
        }
        console2.log("");
        console2.log("Verify with:");
        console2.log("  cast call <proxy> 'getETHBalance()(uint256)' --rpc-url <rpc>");
    }
}
