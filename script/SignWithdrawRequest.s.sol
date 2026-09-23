// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {BlockchainVault} from "../src/BlockchainVault.sol";
import {IBlockchainVault} from "../src/interfaces/IBlockchainVault.sol";

/// @title SignWithdrawRequest
/// @notice 为一次离线提款授权生成 EIP-712 签名 —— 也就是 Owner 或 Admin
///         在一台从不发送交易的机器上所走的流程。
///
/// @dev 只读：它调用金库的 view 函数获取域分隔符与签名者当前的 nonce，然后在本地完成签名。
///      不会广播任何交易。
///
///        VAULT_PROXY=0xProxy SIGNER_PRIVATE_KEY=0xKey TO=0xRecipient AMOUNT=1000000000000000000 \
///        forge script script/SignWithdrawRequest.s.sol --rpc-url $RPC_URL
///
///      环境变量：
///        VAULT_PROXY         必填，金库代理地址。
///        SIGNER_PRIVATE_KEY  必填，用于授权本次提款的 Owner/Admin 私钥。
///        TO                  必填，收款地址。
///        AMOUNT              必填，金额，以该代币最小单位计。
///        TOKEN               可选，ERC20 地址。提取原生 ETH 时省略。
///        NONCE               可选，默认为签名者当前链上 nonce。
///        DEADLINE            可选，Unix 时间戳。默认为当前时间后一小时。
contract SignWithdrawRequest is Script {
    /// @notice 构造、哈希并签署一次提款授权，然后打印出来。
    /// @dev `view`：该脚本只从链上读取数据并在本地签名，从不广播。
    function run() external view {
        address proxy = vm.envOr("VAULT_PROXY", address(0));
        require(proxy != address(0), "SignWithdrawRequest: set VAULT_PROXY");

        uint256 signerKey = vm.envUint("SIGNER_PRIVATE_KEY");
        address signer = vm.addr(signerKey);

        BlockchainVault vault = BlockchainVault(payable(proxy));

        IBlockchainVault.WithdrawRequest memory request = IBlockchainVault.WithdrawRequest({
            to: vm.envOr("TO", address(0)),
            token: vm.envOr("TOKEN", address(0)),
            amount: vm.envUint("AMOUNT"),
            nonce: vm.envOr("NONCE", vault.getNonce(signer)),
            deadline: vm.envOr("DEADLINE", block.timestamp + 1 hours)
        });

        require(request.to != address(0), "SignWithdrawRequest: set TO");

        // 摘要是从合约里取的，这样被签名的内容就不可能与链上的类型哈希、
        // 域名称/版本、chain id 或验证合约地址产生偏差。
        bytes32 digest = vault.hashWithdrawRequest(request);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        console2.log("=== Offline withdrawal authorisation ===");
        console2.log("verifyingContract:", proxy);
        console2.log("chainId          :", block.chainid);
        console2.log("domainSeparator  :", vm.toString(vault.domainSeparator()));
        console2.log("signer           :", signer);
        console2.log("to               :", request.to);
        console2.log("token            :", request.token);
        console2.log("amount           :", request.amount);
        console2.log("nonce            :", request.nonce);
        console2.log("deadline         :", request.deadline);
        console2.log("");
        console2.log("digest:");
        console2.logBytes32(digest);
        console2.log("signature (r || s || v):");
        console2.logBytes(signature);
        console2.log("");
        console2.log("Any account can relay it with:");
        console2.log("  cast send <proxy> 'withdrawWithSig((address,address,uint256,uint256,uint256),bytes)' \\");
        console2.log("    (<to>,<token>,<amount>,<nonce>,<deadline>) <signature> \\");
        console2.log("    --rpc-url <rpc> --private-key <relayer-key>");
    }
}
