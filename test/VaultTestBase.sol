// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {BlockchainVault} from "../src/BlockchainVault.sol";
import {IBlockchainVault} from "../src/interfaces/IBlockchainVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockNonStandardERC20} from "./mocks/MockNonStandardERC20.sol";

/// @notice 金库测试套件共用的夹具与 EIP-712 辅助函数。
/// @dev 摘要辅助函数是从零重新实现 EIP-712，而不是调用金库自己的
///      `hashWithdrawRequest`。这样签名相关的测试就是在拿金库与「标准的独立实现」对比，
///      而不是拿金库与它自己对比。
abstract contract VaultTestBase is Test {
    /// @dev EIP-712 域类型哈希，独立于被测合约写出。
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    /// @dev `WithdrawRequest` 的 EIP-712 结构体类型哈希，独立写出。
    bytes32 internal constant WITHDRAW_REQUEST_TYPEHASH =
        keccak256("WithdrawRequest(address to,address token,uint256 amount,uint256 nonce,uint256 deadline)");

    bytes32 internal constant DOMAIN_NAME_HASH = keccak256(bytes("BlockchainVault"));
    bytes32 internal constant DOMAIN_VERSION_HASH = keccak256(bytes("1"));

    uint256 internal constant OWNER_PK = 0xA11CE;
    uint256 internal constant ADMIN_PK = 0xB0B;
    uint256 internal constant STRANGER_PK = 0xCAFE;

    uint256 internal constant ETH_FUNDING = 1_000 ether;
    uint256 internal constant TOKEN_FUNDING = 1_000_000e18;
    uint256 internal constant DEFAULT_DEADLINE_OFFSET = 1 hours;

    /// @dev 被测金库，通过它的 ERC1967 代理访问。
    BlockchainVault internal vault;

    /// @dev 代理背后的逻辑合约。
    BlockchainVault internal implementation;

    MockERC20 internal token;
    MockNonStandardERC20 internal nonStandardToken;

    address internal owner;
    address internal admin;
    address internal stranger;

    /// @dev 普通收款方，不持有任何角色。
    address internal alice;
    address internal bob;

    function setUp() public virtual {
        // 使用一个贴近真实的时间戳，使测试里的 deadline 运算不受默认值
        // `block.timestamp == 1`（2023-11-14T22:13:20Z）的影响。
        vm.warp(1_700_000_000);

        owner = vm.addr(OWNER_PK);
        admin = vm.addr(ADMIN_PK);
        stranger = vm.addr(STRANGER_PK);
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        vm.deal(owner, ETH_FUNDING);
        vm.deal(admin, ETH_FUNDING);
        vm.deal(stranger, ETH_FUNDING);
        vm.deal(alice, ETH_FUNDING);
        vm.deal(bob, ETH_FUNDING);

        implementation = new BlockchainVault();
        // 被测金库是指向被追踪的 `implementation` 的代理，
        // 这样升级测试就能针对代理创建时所用的确切地址做断言。
        vault = _deployVaultWithLogic(address(implementation), owner);

        token = new MockERC20("MockToken", "MCK");
        nonStandardToken = new MockNonStandardERC20();

        token.mint(alice, TOKEN_FUNDING);
        token.mint(owner, TOKEN_FUNDING);

        // 先给金库备好 ETH 与代币，好让提款有东西可转。
        vm.deal(address(vault), 100 ether);
        vm.prank(alice);
        token.approve(address(vault), type(uint256).max);
        vm.prank(alice);
        vault.depositERC20(address(token), 100_000e18);
    }

    // ---------------------------------------------------------------------
    // 部署辅助函数
    // ---------------------------------------------------------------------

    /// @dev 部署一个全新的金库（带自己的新逻辑合约与代理）。
    function _deployVault(address initialOwner) internal returns (BlockchainVault) {
        return _deployVaultWithLogic(address(new BlockchainVault()), initialOwner);
    }

    /// @dev 部署一个指向 `logic` 的代理并完成初始化。
    function _deployVaultWithLogic(address logic, address initialOwner) internal returns (BlockchainVault) {
        return BlockchainVault(
            payable(address(new ERC1967Proxy(logic, abi.encodeCall(BlockchainVault.initialize, (initialOwner)))))
        );
    }

    // ---------------------------------------------------------------------
    // 存款辅助函数
    // ---------------------------------------------------------------------

    /// @dev 由 `depositor` 存入 `amount` 数量的 `token`，会先完成授权。
    function _depositToken(address depositor, uint256 amount) internal {
        vm.startPrank(depositor);
        token.approve(address(vault), amount);
        vault.depositERC20(address(token), amount);
        vm.stopPrank();
    }

    /// @dev 通过 `receive()` 向金库发送原生 ETH。
    function _donateETH(address from, uint256 amount) internal {
        vm.prank(from);
        (bool ok,) = address(vault).call{value: amount}("");
        require(ok, "ETH donation failed");
    }

    // ---------------------------------------------------------------------
    // EIP-712 辅助函数（独立实现）
    // ---------------------------------------------------------------------

    /// @dev 为任意 chain id 与合约地址重新计算 EIP-712 域分隔符。
    function _domainSeparator(uint256 chainId, address verifyingContract) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH, DOMAIN_NAME_HASH, DOMAIN_VERSION_HASH, chainId, verifyingContract
            )
        );
    }

    /// @dev 独立于金库，重新计算一次提款请求的完整 EIP-712 摘要。
    function _digest(uint256 chainId, address verifyingContract, IBlockchainVault.WithdrawRequest memory request)
        internal
        pure
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                WITHDRAW_REQUEST_TYPEHASH,
                request.to,
                request.token,
                request.amount,
                request.nonce,
                request.deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(chainId, verifyingContract), structHash));
    }

    /// @dev 被测金库在当前链上的摘要。
    function _digestForVault(IBlockchainVault.WithdrawRequest memory request) internal view returns (bytes32) {
        return _digest(block.chainid, address(vault), request);
    }

    /// @dev 用 `privateKey` 对 `digest` 签名，返回 65 字节的 `r || s || v` 签名。
    function _sign(uint256 privateKey, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev 针对被测金库签署一个请求。
    function _signRequest(uint256 privateKey, IBlockchainVault.WithdrawRequest memory request)
        internal
        view
        returns (bytes memory)
    {
        return _sign(privateKey, _digestForVault(request));
    }

    // ---------------------------------------------------------------------
    // 请求构造辅助函数
    // ---------------------------------------------------------------------

    /// @dev 用 `nonce` 与「一小时后到期」的 deadline 构造一个发往 `to`/`token`/`amount` 的请求。
    function _request(address to, address token_, uint256 amount, uint256 nonce)
        internal
        view
        returns (IBlockchainVault.WithdrawRequest memory)
    {
        return _requestWithDeadline(to, token_, amount, nonce, block.timestamp + DEFAULT_DEADLINE_OFFSET);
    }

    /// @dev 用显式指定的 deadline 构造一个请求。
    function _requestWithDeadline(address to, address token_, uint256 amount, uint256 nonce, uint256 deadline)
        internal
        pure
        returns (IBlockchainVault.WithdrawRequest memory)
    {
        return IBlockchainVault.WithdrawRequest({
            to: to, token: token_, amount: amount, nonce: nonce, deadline: deadline
        });
    }

    /// @dev 构造一个提取金库 ETH、由 Owner 以当前 nonce 签署的请求。
    function _ownerRequest(address to, uint256 amount) internal view returns (IBlockchainVault.WithdrawRequest memory) {
        return _request(to, address(0), amount, vault.getNonce(owner));
    }

    /// @dev 构造一个提取金库 ETH、由 Admin 以当前 nonce 签署的请求。
    function _adminRequest(address to, uint256 amount) internal view returns (IBlockchainVault.WithdrawRequest memory) {
        return _request(to, address(0), amount, vault.getNonce(admin));
    }
}
