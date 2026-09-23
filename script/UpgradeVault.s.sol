// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {BlockchainVault} from "../src/BlockchainVault.sol";

/// @title UpgradeVault
/// @notice 把一个已有的金库代理指向新的 UUPS 实现。
///
/// @dev 新实现是刻意以地址形式传入、而不是 import 进来的：
///      通用升级脚本的意义就在于，下一个版本出现时它不需要重新编译。先部署好新实现，例如：
///
///        forge create src/BlockchainVaultV3.sol:BlockchainVaultV3 \
///          --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast
///
///      然后执行升级：
///
///        VAULT_PROXY=0xProxy NEW_IMPLEMENTATION=0xImpl \
///        forge script script/UpgradeVault.s.sol \
///          --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast
///
///      该调用必须来自金库的 Owner，否则会以 `OwnableUnauthorizedAccount` 回滚。
///      {BlockchainVault} 中的 `_authorizeUpgrade` 负责强制这一点。
contract UpgradeVault is Script {
    /// @notice 把 `VAULT_PROXY` 指定的代理升级到 `NEW_IMPLEMENTATION`。
    /// @return proxy 被升级的代理地址。
    /// @return newImplementation 代理现在指向的实现地址。
    function run() external returns (address proxy, address newImplementation) {
        proxy = vm.envOr("VAULT_PROXY", readDeployedProxy());
        newImplementation = vm.envOr("NEW_IMPLEMENTATION", address(0));

        require(proxy != address(0), "UpgradeVault: set VAULT_PROXY (or deploy first)");
        require(newImplementation != address(0), "UpgradeVault: set NEW_IMPLEMENTATION");
        require(newImplementation.code.length > 0, "UpgradeVault: NEW_IMPLEMENTATION has no code");

        bytes memory payload = _payload();

        console2.log("Upgrading proxy   :", proxy);
        console2.log("New implementation:", newImplementation);
        console2.log("Caller (must be owner):", msg.sender);

        vm.startBroadcast();
        BlockchainVault(payable(proxy)).upgradeToAndCall(newImplementation, payload);
        vm.stopBroadcast();

        console2.log("Upgrade complete. Verify the new version with:");
        console2.log("  cast call <proxy> 'version()(string)' --rpc-url <rpc>");
    }

    /// @dev 可选的升级后调用，会在同一笔交易里经代理执行。
    ///      把 `UPGRADE_CALLDATA` 设为十六进制编码的载荷即可启用（例如一个初始化调用）。
    function _payload() private view returns (bytes memory) {
        if (!vm.envExists("UPGRADE_CALLDATA")) {
            return "";
        }
        return vm.envBytes("UPGRADE_CALLDATA");
    }

    /// @dev 回退到 {DeployVault} 为当前链记录下来的代理地址（如果存在）。
    function readDeployedProxy() private view returns (address) {
        string memory path = string.concat("./deployments/", vm.toString(block.chainid), ".json");
        if (!vm.exists(path)) {
            return address(0);
        }
        return vm.parseJsonAddress(vm.readFile(path), ".proxy");
    }
}
