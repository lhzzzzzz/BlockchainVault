// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IBlockchainVault
/// @notice {BlockchainVault} 的对外接口：一个托管 ETH 与 ERC20 的金库，
///         既可以通过角色授权（Owner/Admin）放款，也可以通过 Owner/Admin 产出的
///         EIP-712 链下签名放款。
/// @dev 完整的 ABI 还包含所继承的 OpenZeppelin 接口：
///      `owner()`、`transferOwnership(address)`、`renounceOwnership()`（Ownable），
///      `paused()`、`Paused`/`Unpaused` 事件（Pausable），
///      `proxiableUUID()`、`upgradeToAndCall(address,bytes)`（UUPS），
///      以及 `eip712Domain()`（ERC-5267）。
interface IBlockchainVault {
    // ---------------------------------------------------------------------
    // 数据模型
    // ---------------------------------------------------------------------

    /// @notice Owner/Admin 在链下签署的 EIP-712 授权载荷。
    /// @param to       资金接收方，不可为零地址。
    /// @param token    要提出的 ERC20 地址；`address(0)` 表示提出原生 ETH。
    /// @param amount   以该代币最小单位计的金额。
    /// @param nonce    每个签名者各自的顺序 nonce；成功后即被消耗（防重放）。
    /// @param deadline 该授权失效的 Unix 时间戳。
    struct WithdrawRequest {
        address to;
        address token;
        uint256 amount;
        uint256 nonce;
        uint256 deadline;
    }

    // ---------------------------------------------------------------------
    // 事件
    // ---------------------------------------------------------------------

    /// @notice 只要有价值流入金库（原生 ETH 或 ERC20）就会发出。
    /// @param from   存款人，即存款调用的 `msg.sender`。
    /// @param token  ERC20 地址；原生 ETH 时为 `address(0)`。
    /// @param amount 金库实际收到的金额。
    event Deposited(address indexed from, address indexed token, uint256 amount);

    /// @notice 规范的「资金离开金库」事件，所有提款通道都会发出。
    /// @dev 由签名授权的提款还会额外发出信息更丰富的 {WithdrawnWithSig}；
    ///      链下核算只应累加 {Withdrawn}，绝不能两者相加。
    /// @param to     接收方。
    /// @param token  ERC20 地址；原生 ETH 时为 `address(0)`。
    /// @param amount 转出的金额。
    event Withdrawn(address indexed to, address indexed token, uint256 amount);

    /// @notice 当一笔提款由链下签名授权时发出。
    /// @param signer 从签名中恢复出的、持有 Owner/Admin 角色的地址。
    /// @param to     接收方。
    /// @param amount 转出的金额。
    /// @param nonce  本次请求所消耗的 nonce。
    event WithdrawnWithSig(address indexed signer, address indexed to, uint256 amount, uint256 nonce);

    /// @notice 当 `admin` 被授予提款权限时发出。
    event AdminAdded(address indexed admin);

    /// @notice 当 `admin` 被撤销提款权限时发出。
    event AdminRemoved(address indexed admin);

    /// @notice 当提款白名单被开启或关闭时发出。
    event WhitelistEnabledUpdated(bool enabled);

    /// @notice 当某账户被加入或移出提款白名单时发出。
    event WhitelistUpdated(address indexed account, bool allowed);

    /// @notice 当 `token` 的单笔限额发生变化时发出。`limit == 0` 表示关闭该校验。
    event SingleWithdrawLimitUpdated(address indexed token, uint256 limit);

    /// @notice 当 `token` 的滚动单日限额发生变化时发出。`limit == 0` 表示关闭该校验。
    event DailyWithdrawLimitUpdated(address indexed token, uint256 limit);

    /// @notice 当 `token` 的当日已用额度被手动清零时发出。
    event DailySpentReset(address indexed token);

    // ---------------------------------------------------------------------
    // 错误
    // ---------------------------------------------------------------------

    /// @notice `to`/`token`/`account` 为零地址。
    error ZeroAddress();

    /// @notice 传入了零金额，或者该次转账实际上没有移动任何价值。
    error ZeroAmount();

    /// @notice 金库持有的 `token` 不足以支付本次提款。
    error InsufficientBalance(address token, uint256 requested, uint256 available);

    /// @notice 向 `to` 发送原生 ETH 失败。
    error ETHTransferFailed(address to, uint256 amount);

    /// @notice `token` 地址上没有任何代码，因此它不可能是代币合约。
    error NotAContract(address token);

    /// @notice 调用者既不是 Owner 也不是 Admin。
    error UnauthorizedCaller(address caller);

    /// @notice 该账户已经持有 Admin 角色。
    error AlreadyAdmin(address account);

    /// @notice 该账户并未持有 Admin 角色。
    error NotAdmin(address account);

    /// @notice 白名单已启用，但收款方不在白名单内。
    error NotWhitelisted(address account);

    /// @notice 本次提款超过了为 `token` 配置的单笔限额。
    error SingleWithdrawLimitExceeded(address token, uint256 amount, uint256 limit);

    /// @notice 本次提款超过了 `token` 当日剩余的额度。
    error DailyWithdrawLimitExceeded(address token, uint256 amount, uint256 remaining);

    /// @notice 所签名的请求已过期。
    error SignatureExpired(uint256 deadline, uint256 blockTimestamp);

    /// @notice 传入的 nonce 与该签名者当前的 nonce 不一致。
    error InvalidNonce(address signer, uint256 provided, uint256 expected);

    /// @notice 恢复出的签名者既不持有 Owner 角色也不持有 Admin 角色。
    error UnauthorizedSigner(address signer);

    /// @notice 一次针对本合约未实现函数的调用落到了 {fallback} 上。
    error UnknownFunction(bytes4 selector);

    // ---------------------------------------------------------------------
    // 存款
    // ---------------------------------------------------------------------

    /// @notice 把一笔 ERC20 存入金库并记账。
    /// @dev 调用者必须事先向本合约授权 `amount` 额度。记入的金额以金库的余额增量衡量，
    ///      因此对转账途中抽成的代币也能正确记账。暂停期间同样允许存款。
    /// @param token  要从调用者账户拉取的 ERC20 合约。
    /// @param amount 要拉取的金额，以该代币最小单位计。
    function depositERC20(address token, uint256 amount) external;

    // ---------------------------------------------------------------------
    // 提款
    // ---------------------------------------------------------------------

    /// @notice 从金库向 `to` 转出 `amount` 数量的原生 ETH。
    /// @dev 可由 Owner 或 Admin 调用。暂停期间被禁止。
    function withdrawETH(address to, uint256 amount) external;

    /// @notice 从金库向 `to` 转出 `amount` 数量的 `token`。
    /// @dev 可由 Owner 或 Admin 调用。暂停期间被禁止。
    function withdrawERC20(address token, address to, uint256 amount) external;

    /// @notice 凭 EIP-712 签名，代表 Owner/Admin 提取资金。
    /// @dev 任何人都可以调用（中继者可以代为支付 gas）。签名必须针对
    ///      {hashWithdrawRequest} 的结果、并使用 `eip712Domain()` 返回的域，
    ///      该域把这份授权绑定到本合约地址与 `block.chainid` 上。
    /// @param request   被授权的提款请求。
    /// @param signature 65 字节的 `r || s || v` ECDSA 签名。`s` 值具备可延展性时会回滚。
    function withdrawWithSig(WithdrawRequest calldata request, bytes calldata signature) external;

    // ---------------------------------------------------------------------
    // 角色管理
    // ---------------------------------------------------------------------

    /// @notice 把 Admin 角色授予 `admin`，使其可以发起提款。
    /// @dev 仅限 Owner。
    function addAdmin(address admin) external;

    /// @notice 撤销 `admin` 的 Admin 角色，立即生效。
    /// @dev 仅限 Owner。
    function removeAdmin(address admin) external;

    // ---------------------------------------------------------------------
    // 熔断开关
    // ---------------------------------------------------------------------

    /// @notice 冻结所有提款通道。存款仍然可用。
    /// @dev 仅限 Owner。会发出继承自 Pausable 的 `Paused(address)` 事件。
    function pause() external;

    /// @notice 重新开放提款。
    /// @dev 仅限 Owner。会发出继承自 Pausable 的 `Unpaused(address)` 事件。
    function unpause() external;

    // ---------------------------------------------------------------------
    // 风控配置
    // ---------------------------------------------------------------------

    /// @notice 开启或关闭提款白名单。
    /// @dev 仅限 Owner。白名单生效期间，资金只能提给名单内的收款方。
    function setWhitelistEnabled(bool enabled) external;

    /// @notice 把某账户加入（`allowed == true`）或移出提款白名单。
    /// @dev 仅限 Owner。
    function setWhitelisted(address account, bool allowed) external;

    /// @notice 设置 `token` 的单笔提款限额；`0` 表示关闭该校验。
    /// @dev 仅限 Owner。
    function setSingleWithdrawLimit(address token, uint256 limit) external;

    /// @notice 设置 `token` 的滚动单日提款限额；`0` 表示关闭该校验。
    /// @dev 仅限 Owner。窗口为 UTC 日，即 `block.timestamp / 1 days`。
    function setDailyWithdrawLimit(address token, uint256 limit) external;

    /// @notice 把 `token` 的当日已用额度清零，恢复完整的单日额度。
    /// @dev 仅限 Owner。
    function resetDailySpent(address token) external;

    // ---------------------------------------------------------------------
    // 只读查询
    // ---------------------------------------------------------------------

    /// @notice 金库持有的原生 ETH。
    function getETHBalance() external view returns (uint256);

    /// @notice 金库持有的 `token` 余额。
    function getTokenBalance(address token) external view returns (uint256);

    /// @notice `signer` 下一次应当使用的 nonce，即重放计数器。
    function getNonce(address signer) external view returns (uint256);

    /// @notice `account` 当前是否持有 Admin 角色。
    function isAdmin(address account) external view returns (bool);

    /// @notice `account` 是否在提款白名单内。
    function isWhitelisted(address account) external view returns (bool);

    /// @notice 提款白名单是否正在强制执行。
    function whitelistEnabled() external view returns (bool);

    /// @notice 为 `token` 配置的单笔提款限额（`0` 表示未启用）。
    function getSingleWithdrawLimit(address token) external view returns (uint256);

    /// @notice 为 `token` 配置的单日提款限额（`0` 表示未启用）。
    function getDailyWithdrawLimit(address token) external view returns (uint256);

    /// @notice `token` 在当前 UTC 日内已经提出的金额。
    function getSpentToday(address token) external view returns (uint256);

    /// @notice 当前生效的 EIP-712 域分隔符（`block.chainid` 变化时会随之改变）。
    function domainSeparator() external view returns (bytes32);

    /// @notice Owner/Admin 为授权 `request` 所必须签署的 EIP-712 摘要。
    function hashWithdrawRequest(WithdrawRequest calldata request) external view returns (bytes32);
}
