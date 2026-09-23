// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
// OpenZeppelin 5.x 中的 `ReentrancyGuard` 是无状态的（其状态存放在 ERC-7201 槽位），
// 这正是 `contracts-upgradeable` 包不再提供可升级变体的原因，因此这里可以直接在代理后复用。
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IBlockchainVault} from "./interfaces/IBlockchainVault.sol";
import {VaultStorage} from "./libraries/VaultStorage.sol";

/// @title BlockchainVault
/// @notice 可升级（UUPS）的 ETH 与 ERC20 托管金库。
///
/// @dev 资金流出由两套相互独立的机制把关：
///      1. 角色授权 —— Owner 与任意 Admin 可直接调用 {withdrawETH} / {withdrawERC20}；
///      2. EIP-712 链下授权 —— Owner/Admin 离线签署一个 {WithdrawRequest}，
///         任何人（通常是中继者）都可以把签名提交给 {withdrawWithSig}。
///
///      机制 2 的重放防护有三重：每个签名者各自的顺序 `nonce`、`deadline`，
///      以及把授权绑定到本合约地址与 `block.chainid` 的 EIP-712 域分隔符。
///      因此跨链重放与跨合约重放会恢复出不同的地址，被判为 {UnauthorizedSigner} 而拒绝。
///
///      所有会改变状态的提款都遵循 Checks-Effects-Interactions：
///      nonce 的消耗与风控额度的记账都发生在任何外部调用之前。
contract BlockchainVault is
    IBlockchainVault,
    Initializable,
    OwnableUpgradeable,
    PausableUpgradeable,
    EIP712Upgradeable,
    UUPSUpgradeable,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;

    /// @notice {WithdrawRequest} 的 EIP-712 类型哈希。
    /// @dev 链下签名者必须使用完全一致的类型字符串：
    ///      `WithdrawRequest(address to,address token,uint256 amount,uint256 nonce,uint256 deadline)`。
    bytes32 public constant WITHDRAW_REQUEST_TYPEHASH =
        keccak256("WithdrawRequest(address to,address token,uint256 amount,uint256 nonce,uint256 deadline)");

    /// @dev EIP-712 域名称。属于被签名的内容，部署后不可更改。
    string private constant _EIP712_DOMAIN_NAME = "BlockchainVault";

    /// @dev EIP-712 域版本。属于被签名的内容，部署后不可更改。
    string private constant _EIP712_DOMAIN_VERSION = "1";

    /// @notice 限制函数只能由 Owner 或持有 Admin 角色的账户调用。
    modifier onlyOwnerOrAdmin() {
        _checkOwnerOrAdmin();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        // 逻辑合约自身永不初始化，只有代理才会初始化。若放任逻辑合约处于未初始化状态，
        // 攻击者就能直接对它调用 `initialize` 从而劫持合约。
        _disableInitializers();
    }

    // ---------------------------------------------------------------------
    // 初始化
    // ---------------------------------------------------------------------

    /// @notice 在代理后面初始化金库。
    /// @dev 只能调用一次。负责建立所有权、暂停开关与 EIP-712 域。
    ///      {ReentrancyGuard} 与 {UUPSUpgradeable} 不持有状态，无需初始化。
    /// @param initialOwner 被授予 Owner 角色（最高权限）的地址，不可为零地址。
    function initialize(address initialOwner) external initializer {
        if (initialOwner == address(0)) revert ZeroAddress();

        __Ownable_init(initialOwner);
        __Pausable_init();
        __EIP712_init(_EIP712_DOMAIN_NAME, _EIP712_DOMAIN_VERSION);
    }

    // ---------------------------------------------------------------------
    // 存款
    // ---------------------------------------------------------------------

    /// @notice 接收一笔普通的原生 ETH 转账并记入金库。
    /// @dev 暂停期间同样允许。零金额转账会被静默接受。
    receive() external payable {
        if (msg.value > 0) {
            emit Deposited(msg.sender, address(0), msg.value);
        }
    }

    /// @notice 接收携带未知 calldata 的原生 ETH 转账。
    /// @dev 暂停期间同样允许。不携带金额的调用会被拒绝，
    ///      因为这类调用比起有意存款，更像是误操作。
    fallback() external payable {
        if (msg.value == 0) {
            bytes4 selector;
            assembly {
                selector := calldataload(0)
            }
            revert UnknownFunction(selector);
        }
        emit Deposited(msg.sender, address(0), msg.value);
    }

    /// @inheritdoc IBlockchainVault
    /// @dev 暂停期间同样允许。记入的金额取金库的余额增量，
    ///      因此对转账途中抽成的代币也能正确记账。
    function depositERC20(address token, uint256 amount) external nonReentrant {
        if (token == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (token.code.length == 0) revert NotAContract(token);

        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - balanceBefore;

        if (received == 0) revert ZeroAmount();
        emit Deposited(msg.sender, token, received);
    }

    // ---------------------------------------------------------------------
    // 基于角色的提款
    // ---------------------------------------------------------------------

    /// @inheritdoc IBlockchainVault
    function withdrawETH(address to, uint256 amount)
        external
        nonReentrant
        whenNotPaused
        onlyOwnerOrAdmin
    {
        _withdraw(address(0), to, amount);
    }

    /// @inheritdoc IBlockchainVault
    function withdrawERC20(address token, address to, uint256 amount)
        external
        nonReentrant
        whenNotPaused
        onlyOwnerOrAdmin
    {
        if (token == address(0)) revert ZeroAddress();
        _withdraw(token, to, amount);
    }

    // ---------------------------------------------------------------------
    // 基于签名的提款
    // ---------------------------------------------------------------------

    /// @inheritdoc IBlockchainVault
    /// @dev 先发出 {WithdrawnWithSig}，再发出底层的 {Withdrawn} 事件。
    ///      当签名格式非法或 `s` 值具备可延展性时，
    ///      会以 OpenZeppelin 的 `ECDSAInvalidSignature*` 系列错误回滚。
    function withdrawWithSig(WithdrawRequest calldata request, bytes calldata signature)
        external
        nonReentrant
        whenNotPaused
    {
        VaultStorage.Layout storage $ = VaultStorage.layout();

        if (block.timestamp > request.deadline) {
            revert SignatureExpired(request.deadline, block.timestamp);
        }

        // EIP-712 域分隔符内嵌了 `block.chainid` 与 `address(this)`，
        // 因此该摘要只对「本链上的本金库」有效。
        bytes32 digest = _hashTypedDataV4(_hashWithdrawRequest(request));
        address signer = ECDSA.recoverCalldata(digest, signature);

        if (!_isAuthorized(signer)) revert UnauthorizedSigner(signer);

        uint256 expectedNonce = $.nonces[signer];
        if (request.nonce != expectedNonce) revert InvalidNonce(signer, request.nonce, expectedNonce);

        // --- 状态变更：在任何交互之前先烧掉 nonce，使该签名无法被重放。 ---
        $.nonces[signer] = expectedNonce + 1;
        emit WithdrawnWithSig(signer, request.to, request.amount, request.nonce);

        // --- 外部交互 ---
        _withdraw(request.token, request.to, request.amount);
    }

    // ---------------------------------------------------------------------
    // 角色管理
    // ---------------------------------------------------------------------

    /// @inheritdoc IBlockchainVault
    function addAdmin(address admin) external onlyOwner {
        if (admin == address(0)) revert ZeroAddress();

        VaultStorage.Layout storage $ = VaultStorage.layout();
        if ($.admins[admin]) revert AlreadyAdmin(admin);

        $.admins[admin] = true;
        emit AdminAdded(admin);
    }

    /// @inheritdoc IBlockchainVault
    function removeAdmin(address admin) external onlyOwner {
        VaultStorage.Layout storage $ = VaultStorage.layout();
        if (!$.admins[admin]) revert NotAdmin(admin);

        $.admins[admin] = false;
        emit AdminRemoved(admin);
    }

    // ---------------------------------------------------------------------
    // 熔断开关
    // ---------------------------------------------------------------------

    /// @inheritdoc IBlockchainVault
    function pause() external onlyOwner {
        _pause();
    }

    /// @inheritdoc IBlockchainVault
    function unpause() external onlyOwner {
        _unpause();
    }

    // ---------------------------------------------------------------------
    // 风控配置
    // ---------------------------------------------------------------------

    /// @inheritdoc IBlockchainVault
    function setWhitelistEnabled(bool enabled) external onlyOwner {
        VaultStorage.layout().whitelistEnabled = enabled;
        emit WhitelistEnabledUpdated(enabled);
    }

    /// @inheritdoc IBlockchainVault
    function setWhitelisted(address account, bool allowed) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();

        VaultStorage.layout().whitelist[account] = allowed;
        emit WhitelistUpdated(account, allowed);
    }

    /// @inheritdoc IBlockchainVault
    function setSingleWithdrawLimit(address token, uint256 limit) external onlyOwner {
        VaultStorage.layout().singleWithdrawLimit[token] = limit;
        emit SingleWithdrawLimitUpdated(token, limit);
    }

    /// @inheritdoc IBlockchainVault
    function setDailyWithdrawLimit(address token, uint256 limit) external onlyOwner {
        VaultStorage.layout().dailyWithdrawLimit[token] = limit;
        emit DailyWithdrawLimitUpdated(token, limit);
    }

    /// @inheritdoc IBlockchainVault
    function resetDailySpent(address token) external onlyOwner {
        VaultStorage.Layout storage $ = VaultStorage.layout();
        $.spentToday[token] = 0;
        $.lastSpendDay[token] = _currentDay();
        emit DailySpentReset(token);
    }

    // ---------------------------------------------------------------------
    // 只读查询
    // ---------------------------------------------------------------------

    /// @inheritdoc IBlockchainVault
    function getETHBalance() external view returns (uint256) {
        return address(this).balance;
    }

    /// @inheritdoc IBlockchainVault
    function getTokenBalance(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    /// @inheritdoc IBlockchainVault
    function getNonce(address signer) external view returns (uint256) {
        return VaultStorage.layout().nonces[signer];
    }

    /// @inheritdoc IBlockchainVault
    function isAdmin(address account) external view returns (bool) {
        return VaultStorage.layout().admins[account];
    }

    /// @inheritdoc IBlockchainVault
    function isWhitelisted(address account) external view returns (bool) {
        return VaultStorage.layout().whitelist[account];
    }

    /// @inheritdoc IBlockchainVault
    function whitelistEnabled() external view returns (bool) {
        return VaultStorage.layout().whitelistEnabled;
    }

    /// @inheritdoc IBlockchainVault
    function getSingleWithdrawLimit(address token) external view returns (uint256) {
        return VaultStorage.layout().singleWithdrawLimit[token];
    }

    /// @inheritdoc IBlockchainVault
    function getDailyWithdrawLimit(address token) external view returns (uint256) {
        return VaultStorage.layout().dailyWithdrawLimit[token];
    }

    /// @inheritdoc IBlockchainVault
    function getSpentToday(address token) external view returns (uint256) {
        return VaultStorage.layout().spentToday[token];
    }

    /// @inheritdoc IBlockchainVault
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @inheritdoc IBlockchainVault
    function hashWithdrawRequest(WithdrawRequest calldata request) external view returns (bytes32) {
        return _hashTypedDataV4(_hashWithdrawRequest(request));
    }

    // ---------------------------------------------------------------------
    // 内部实现
    // ---------------------------------------------------------------------

    /// @dev 把 `amount` 数量的 `token`（`address(0)` 表示原生 ETH）转给 `to`。
    ///
    ///      顺序是刻意安排的：所有校验与所有状态写入都发生在外部调用之前。
    ///      因此收款方回滚会连带回滚整笔提款，
    ///      一次失败的付款绝不可能让金库停留在「状态改了一半」的中间态。
    function _withdraw(address token, address to, uint256 amount) private {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        VaultStorage.Layout storage $ = VaultStorage.layout();

        if ($.whitelistEnabled && !$.whitelist[to]) revert NotWhitelisted(to);

        _consumeLimits(token, amount);

        uint256 available;
        if (token == address(0)) {
            available = address(this).balance;
        } else {
            if (token.code.length == 0) revert NotAContract(token);
            available = IERC20(token).balanceOf(address(this));
        }
        if (amount > available) revert InsufficientBalance(token, amount, available);

        // 在转账之前发出事件，使日志顺序与状态变更的顺序保持一致。
        emit Withdrawn(to, token, amount);

        if (token == address(0)) {
            // 使用 `call` 而非 `transfer`/`send`：它会转发全部可用 gas，
            // 因此合约收款方与多签钱包不会因为 2300 gas 的额度上限而被卡死。
            (bool success,) = to.call{value: amount}("");
            if (!success) revert ETHTransferFailed(to, amount);
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    /// @dev 校验并记录 `token` 的单笔限额与滚动单日限额。
    ///      限额为 `0` 表示「不限制」，从而让校验默认不出现在热路径上。
    function _consumeLimits(address token, uint256 amount) private {
        VaultStorage.Layout storage $ = VaultStorage.layout();

        uint256 singleLimit = $.singleWithdrawLimit[token];
        if (singleLimit != 0 && amount > singleLimit) {
            revert SingleWithdrawLimitExceeded(token, amount, singleLimit);
        }

        uint256 dailyLimit = $.dailyWithdrawLimit[token];
        if (dailyLimit != 0) {
            uint256 today = _currentDay();
            uint256 spent = $.lastSpendDay[token] == today ? $.spentToday[token] : 0;

            // 饱和减法：限额有可能被调低到低于当日已经花掉的金额。
            uint256 remaining = spent >= dailyLimit ? 0 : dailyLimit - spent;
            if (amount > remaining) revert DailyWithdrawLimitExceeded(token, amount, remaining);

            $.spentToday[token] = spent + amount;
            $.lastSpendDay[token] = today;
        }
    }

    /// @dev 判断 `account` 是否可以发起提款，即是否持有 Owner 或 Admin 角色。
    function _isAuthorized(address account) private view returns (bool) {
        return account == owner() || VaultStorage.layout().admins[account];
    }

    /// @dev 当 `msg.sender` 不持有 Owner 或 Admin 角色时回滚。
    function _checkOwnerOrAdmin() private view {
        if (!_isAuthorized(msg.sender)) revert UnauthorizedCaller(msg.sender);
    }

    /// @dev 一次提款授权的 EIP-712 结构体哈希。
    function _hashWithdrawRequest(WithdrawRequest calldata request) private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                WITHDRAW_REQUEST_TYPEHASH,
                request.to,
                request.token,
                request.amount,
                request.nonce,
                request.deadline
            )
        );
    }

    /// @dev 当前 UTC 日序号，作为滚动单日限额的分桶键。
    function _currentDay() private view returns (uint256) {
        return block.timestamp / 1 days;
    }

    /// @dev 只有 Owner 能把代理指向新的实现合约。
    ///      新实现还会被 {UUPSUpgradeable} 通过 `proxiableUUID` 校验，
    ///      从而拒绝 EOA 与非 UUPS 合约。
    function _authorizeUpgrade(address) internal override onlyOwner {}
}
