# 设计文档 — BlockchainVault（M2 交付物）

> 本文档对应里程碑 **M2：接口设计 + 数据模型**，是需求文档的实现落地说明。
> 内容：数据模型、签名结构、事件与错误、接口契约、关键流程、风控语义、可升级性设计，
> 以及**与需求文档的偏差与取舍**（第 9 节）。

---

## 1. 设计目标与约束

| 目标 | 设计选择 |
| --- | --- |
| 资金安全 | 只有 Owner / Admin 能提款；签名提款需 Owner/Admin 的 EIP-712 签名 |
| 防重放 | 每个签名者顺序 nonce + deadline + 域绑定（chainId + 合约地址） |
| 防重入 | `ReentrancyGuard` + 严格 Checks-Effects-Interactions |
| 可升级 | UUPS（ERC-1967）+ ERC-7201 命名空间存储 |
| 标准化 | OpenZeppelin 5.6.1；SafeERC20 / ECDSA / EIP712 / Ownable / Pausable |
| Gas 效率 | 无循环；未配置风控时走零开销分支；`calldata` 签名不拷贝到内存 |
| 可测试 | 逻辑集中在单个内部 `_withdraw`，两条提款通道共享同一套校验 |

**编译约束**：Solidity `0.8.24`，EVM 目标 `cancun`。
OpenZeppelin 5.6 的 `utils/Bytes.sol` 使用 `mcopy` 指令，`paris` 目标无法编译。

---

## 2. 数据模型

### 2.1 状态分布

合约状态由三部分组成，互不冲突：

| 来源 | 内容 | 存储位置 |
| --- | --- | --- |
| `OwnableUpgradeable` | `owner` | ERC-7201：`openzeppelin.storage.Ownable` |
| `PausableUpgradeable` | `paused` | ERC-7201：`openzeppelin.storage.Pausable` |
| `EIP712Upgradeable` | 域名称 / 版本（分隔符不缓存，每次调用时重算） | ERC-7201：`openzeppelin.storage.EIP712` |
| `ReentrancyGuard` | 重入锁 `_status` | ERC-7201：`openzeppelin.storage.ReentrancyGuard` |
| `UUPSUpgradeable` | 实现地址 | ERC-1967 固定槽（存在**代理**存储中） |
| **本合约** | 见 2.2 | ERC-7201：`vault.storage.BlockchainVault` |

### 2.2 自定义状态（`VaultStorage.Layout`）

```solidity
struct Layout {
    mapping(address account => bool isAdmin)        admins;               // Owner 之外可提款的管理员
    mapping(address signer  => uint256 nonce)       nonces;               // 每个签名者的顺序 nonce
    mapping(address account => bool allowed)        whitelist;            // 提款白名单
    bool                                            whitelistEnabled;     // 白名单是否生效
    mapping(address token   => uint256 limit)       singleWithdrawLimit;  // 单笔上限（0 = 不限）
    mapping(address token   => uint256 limit)       dailyWithdrawLimit;   // UTC 日累计上限（0 = 不限）
    mapping(address token   => uint256 spent)       spentToday;           // 当日已提
    mapping(address token   => uint256 day)         lastSpendDay;         // spentToday 所属的 UTC 日序号
}
```

字段顺序即存储 ABI：**只允许在末尾追加**，不得重排或删除。

### 2.3 ERC-7201 命名空间槽位

自定义状态不占用 slot 0，而是位于由命名空间字符串推导出的槽位：

```
slot = keccak256(abi.encode(uint256(keccak256("vault.storage.BlockchainVault")) - 1)) & ~bytes32(uint256(0xff))
     = 0x3db71306f2ca18d7ee18ab1454c13a0cf765f604472057f73023c55cec037800
```

V2 新增状态使用独立命名空间：

```
"vault.storage.BlockchainVaultV2"
     = 0xf3f2427fbe6a50c90783b9c9fa31dbcbbfc7fbdf9c3821d38644fc4a07c67200
```

两个常量由 `test/VaultStorageSlot.t.sol` 按公式重算校验，避免硬编码笔误。

**为什么用 ERC-7201 而不是 `uint256[50] __gap`**：

1. 基类（OZ 模块）与派生类各自命名空间化，新增基类或调整继承顺序不会移动任何已有状态；
2. 新版本追加字段不需维护 gap 长度；
3. 无需依赖「谁继承了谁」的顺序推导。

---

## 3. 签名消息结构（EIP-712）

### 3.1 结构体

```solidity
struct WithdrawRequest {
    address to;        // 收款地址，不可为零地址
    address token;     // address(0) = ETH，其它为 ERC20
    uint256 amount;    // 最小单位金额
    uint256 nonce;     // 必须等于 signer 的当前 nonce
    uint256 deadline;  // block.timestamp <= deadline 才有效
}
```

### 3.2 常量（实测值）

| 名称 | 值 |
| --- | --- |
| `EIP712Domain` type hash | `0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f` |
| `WithdrawRequest` type hash | `0x082f96acc278d3d84703ce41c785c3b7de62ceb46697aad70df60b171341e42a` |
| `keccak256("BlockchainVault")` | `0xc62e4683a378d882b3dfd045fe01e9b961cfec8484e054d62a3f96019855533e` |
| `keccak256("1")` | `0xc89efdaa54c0f20c7adf612882df0950f5a951637e0307cdcb4c672f298b8bc6` |

`WITHDRAW_REQUEST_TYPEHASH` 以 `public constant` 暴露，链下客户端可直接读取，避免手写字符串出错。

### 3.3 摘要计算

```
structHash = keccak256(abi.encode(
    WITHDRAW_REQUEST_TYPEHASH, to, token, amount, nonce, deadline))

domainSeparator = keccak256(abi.encode(
    EIP712Domain_TYPEHASH,
    keccak256(bytes("BlockchainVault")),
    keccak256(bytes("1")),
    block.chainid,          // ← 防跨链重放
    address(this)           // ← 防跨合约重放
))

digest = keccak256(0x1901 ‖ domainSeparator ‖ structHash)
```

`domainSeparator` **不缓存**：OZ 5.6.1 的 `EIP712Upgradeable` 在每次 `_domainSeparatorV4()` 调用时
都重新计算（其源码注释说明这比读冷存储里的缓存更便宜）。因此 `block.chainid` 一旦变化，
分隔符自动随之改变——分叉或切换测试网后，旧签名自然失效。
（非可升级版的 `EIP712` 才使用 immutable 缓存 + chainid 失效重算。）

合约同时提供：

- `hashWithdrawRequest(request)` — 返回 `digest`，链下直接签它即可；
- `domainSeparator()` — 当前域分隔符；
- `eip712Domain()` — ERC-5267 标准域查询。

---

## 4. 事件与错误

### 4.1 事件

| 事件 | 签名 | 触发点 |
| --- | --- | --- |
| `Deposited` | `(address indexed from, address indexed token, uint256 amount)` | `receive` / `fallback` / `depositERC20`（`amount` 为**实际到账**量） |
| `Withdrawn` | `(address indexed to, address indexed token, uint256 amount)` | 所有提款通道（规范事件） |
| `WithdrawnWithSig` | `(address indexed signer, address indexed to, uint256 amount, uint256 nonce)` | 仅签名提款，先于 `Withdrawn` 发出 |
| `AdminAdded` / `AdminRemoved` | `(address indexed admin)` | `addAdmin` / `removeAdmin` |
| `WhitelistEnabledUpdated` | `(bool enabled)` | `setWhitelistEnabled` |
| `WhitelistUpdated` | `(address indexed account, bool allowed)` | `setWhitelisted` |
| `SingleWithdrawLimitUpdated` | `(address indexed token, uint256 limit)` | `setSingleWithdrawLimit` |
| `DailyWithdrawLimitUpdated` | `(address indexed token, uint256 limit)` | `setDailyWithdrawLimit` |
| `DailySpentReset` | `(address indexed token)` | `resetDailySpent` |
| `Paused` / `Unpaused` | `(address account)` | `pause` / `unpause`（由 OZ `Pausable` 提供，**参数未索引**） |
| `OwnershipTransferred` | `(address indexed previousOwner, address indexed newOwner)` | `transferOwnership` |
| `Upgraded` | `(address indexed implementation)` | `upgradeToAndCall` |

> 链下核算只累加 `Withdrawn`。签名提款会同时发出 `WithdrawnWithSig`（补充 signer 与 nonce），
> 两者相加会重复计账。

### 4.2 错误（custom errors）

| 错误 | 含义 |
| --- | --- |
| `ZeroAddress()` | `to` / `token` / `account` 为零地址 |
| `ZeroAmount()` | 金额为 0，或存入后实际到账为 0 |
| `InsufficientBalance(address token, uint256 requested, uint256 available)` | 余额不足 |
| `ETHTransferFailed(address to, uint256 amount)` | ETH 转账失败（收款方拒收 / 无 receive） |
| `NotAContract(address token)` | 代币地址无代码（EOA） |
| `UnauthorizedCaller(address caller)` | 调用者既非 Owner 也非 Admin |
| `AlreadyAdmin(address)` / `NotAdmin(address)` | 管理员状态冲突 |
| `NotWhitelisted(address account)` | 白名单生效但收款方不在名单 |
| `SingleWithdrawLimitExceeded(address token, uint256 amount, uint256 limit)` | 超过单笔上限 |
| `DailyWithdrawLimitExceeded(address token, uint256 amount, uint256 remaining)` | 超过当日剩余额度 |
| `SignatureExpired(uint256 deadline, uint256 blockTimestamp)` | 签名过期 |
| `InvalidNonce(address signer, uint256 provided, uint256 expected)` | nonce 不匹配 |
| `UnauthorizedSigner(address signer)` | 恢复出的签名者无权限 |
| `UnknownFunction(bytes4 selector)` | `fallback` 收到无 value 的未知调用 |
| `ECDSAInvalidSignature()` / `ECDSAInvalidSignatureLength(uint256)` / `ECDSAInvalidSignatureS(bytes32)` | OZ ECDSA 签名非法 / 长度错 / s 值可延展 |
| `EnforcedPause()` / `ExpectedPause()` | OZ Pausable 状态冲突 |
| `OwnableUnauthorizedAccount(address)` | OZ Ownable 权限不足 |
| `ReentrancyGuardReentrantCall()` | 重入被拦截 |
| `UUPSUnauthorizedCallContext()` / `ERC1967InvalidImplementation(address)` / `UUPSUnsupportedProxiableUUID(bytes32)` | UUPS 升级上下文或目标非法 |

采用 custom error 而非 `require` 字符串：更省 gas，且链下可按选择器精确判别。

---

## 5. 接口契约

`_withdraw(token, to, amount)` 是所有提款通道的公共路径，前置条件按下列**固定顺序**检查：

```
1. to != address(0)                          → ZeroAddress
2. amount != 0                               → ZeroAmount
3. 白名单（若启用）                            → NotWhitelisted
4. 单笔上限（若配置）                          → SingleWithdrawLimitExceeded
5. 单日累计上限（若配置），并记账               → DailyWithdrawLimitExceeded
6. token.code.length != 0（ERC20 路径）        → NotAContract
7. amount <= 可用余额                          → InsufficientBalance
8. emit Withdrawn
9. 转账（interaction）                          → ETHTransferFailed / SafeERC20FailedOperation
```

第 1–7 步全部是校验与状态写入（effects），第 8 步记录日志，第 9 步才发生外部交互，
因此任何失败都会整体回滚，不存在「扣了账没转账」或「转了账没记 nonce」的中间态。

### 5.1 各函数契约

| 函数 | 修饰符 | 前置条件 | 效果 | 事件 |
| --- | --- | --- | --- | --- |
| `receive()` | — | 可暂停期间调用 | 接受 ETH | `Deposited`（`value > 0` 时） |
| `fallback()` | — | `msg.value > 0` | 接受 ETH | `Deposited` |
| `depositERC20` | `nonReentrant` | `token` 有代码、`amount > 0`、已 approve | 拉取代币，按余额增量记账 | `Deposited` |
| `withdrawETH` | `nonReentrant whenNotPaused onlyOwnerOrAdmin` | 同 `_withdraw` | 转出 ETH | `Withdrawn` |
| `withdrawERC20` | 同上 | `token != 0` 且同 `_withdraw` | 转出代币 | `Withdrawn` |
| `withdrawWithSig` | `nonReentrant whenNotPaused` | deadline 未过、nonce 匹配、签名者为 Owner/Admin、风控通过 | 消耗 nonce → 转出 | `WithdrawnWithSig` + `Withdrawn` |
| `addAdmin` / `removeAdmin` | `onlyOwner` | 状态合法 | 更新 `admins` | `AdminAdded` / `AdminRemoved` |
| `pause` / `unpause` | `onlyOwner` | 状态未/已暂停 | 更新 `paused` | `Paused` / `Unpaused` |
| 风控 setter | `onlyOwner` | — | 更新配置 | 对应事件 |
| `_authorizeUpgrade` | `onlyOwner` | — | 允许升级 | `Upgraded`（由 UUPS 发出） |

修饰符顺序：`nonReentrant` 放在最前（满足 Foundry lint `non-reentrant-not-first`；
在本合约中其余修饰符都是纯检查，顺序不影响安全性）。

---

## 6. 关键流程

### 6.1 存款（任何人，暂停期间也可用）

```
用户 ──ETH──▶ receive()/fallback() ──▶ emit Deposited(sender, 0, value)
用户 ──approve──▶ depositERC20(token, amount)
                    ├─ 校验 token 有代码、amount > 0
                    ├─ before = balanceOf(this)
                    ├─ safeTransferFrom(user → this)
                    ├─ received = balanceOf(this) - before
                    └─ emit Deposited(sender, token, received)   ← 实际到账量
```

按余额增量记账可正确处理 fee-on-transfer 代币；`received == 0` 时直接 `ZeroAmount` 回滚。

### 6.2 直接提款（Owner / Admin）

```
owner/admin ──withdrawETH(to, amount)──▶ _withdraw(0, to, amount)
                                          ├─ 校验 + 记账（effects）
                                          ├─ emit Withdrawn
                                          └─ to.call{value: amount}("")   ← interaction
```

使用 `call` 而非 `transfer`/`send`：转发全部可用 gas，避免把多签钱包等需要 > 2300 gas 的
收款方误伤（`test_ETHPayoutToGasHungryReceiverSucceeds` 为该行为的回归测试）。

### 6.3 签名提款（核心）

```
【离线】Owner/Admin
   request = WithdrawRequest(to, token, amount, nonce, deadline)
   digest  = vault.hashWithdrawRequest(request)
   sig     = sign(ownerKey, digest)          // 65 字节 r ‖ s ‖ v

【链上】任意中继者
   withdrawWithSig(request, sig)
     ├─ whenNotPaused ?                      否 → EnforcedPause
     ├─ nonReentrant 锁
     ├─ block.timestamp <= request.deadline  否 → SignatureExpired
     ├─ signer = ECDSA.recoverCalldata(digest, sig)
     │     签名格式 / s 值非法 → ECDSAInvalidSignature*
     ├─ signer 是 Owner 或 Admin？            否 → UnauthorizedSigner
     ├─ request.nonce == nonces[signer] ?     否 → InvalidNonce
     ├─ nonces[signer] += 1                   ← 先消耗，防重放
     ├─ emit WithdrawnWithSig
     └─ _withdraw(token, to, amount)          ← 共享风控与 CEI 路径
```

要点：

- **任何人可提交**（`msg.sender` 不参与授权），因此 Owner 私钥可以不接触网络，中继者付 gas。
- **失败整体回滚**，包括已消耗的 nonce（`test_FailedSignatureWithdrawalRollsBackTheNonce`）。
- **状态先于交互**：`PayoutObserver` 在收款回调中读到 nonce 已 +1、当日额度已记账
  （`test_StateIsUpdatedBeforeTheExternalCall`）。

### 6.4 升级

```
Owner ──upgradeToAndCall(newImpl, data)──▶ ERC1967Proxy
    ├─ onlyProxy：必须是经代理的调用
    ├─ _authorizeUpgrade：仅 Owner（否则 OwnableUnauthorizedAccount）
    ├─ newImpl.proxiableUUID() == ERC-1967 实现槽？否则 ERC1967InvalidImplementation
    ├─ 写入实现槽 + emit Upgraded
    └─ data 非空时以新实现执行该调用
```

---

## 7. 风控语义

### 7.1 白名单（FR-5.4）

- `whitelistEnabled == false`（默认）时白名单**完全被忽略**；
- 启用后，**两条提款通道**都要求 `to` 在名单内；
- 白名单不影响存款。

### 7.2 限额（FR-5.5）

两个维度、**按代币**分别配置，`0` 表示关闭该项检查：

| 维度 | 存储 | 语义 |
| --- | --- | --- |
| 单笔 | `singleWithdrawLimit[token]` | `amount <= limit` |
| 单日累计 | `dailyWithdrawLimit[token]` | `spentToday + amount <= limit` |

- 日窗口为 **UTC 日序号** `block.timestamp / 1 days`，不是滑动 24 小时；
- 当日序号变化时计数器自动归零（`lastSpendDay[token] != today` ⇒ `spent = 0`）；
- 限额被下调到低于已用量时，剩余额度按 0 处理（饱和减法），不会下溢；
- `resetDailySpent(token)` 供 Owner 手动清零。

两个维度都作用于签名提款，因此不能用「换通道」或「换代币」绕过。

---

## 8. 可升级性设计

### 8.1 规则

1. 自定义状态全部位于 `vault.storage.BlockchainVault` 命名空间；
2. 新版本**追加字段**到 `Layout` 末尾，或启用**新命名空间**（如 `VaultV2Storage`）；
3. 不得重排 / 删除 / 改变已有字段类型；
4. 实现合约构造函数调用 `_disableInitializers()`，防止逻辑合约被直接初始化劫持；
5. `_authorizeUpgrade` 加 `onlyOwner`。

### 8.2 V2 演示（`test/mocks/VaultV2.sol`）

V2 新增 `version()` 与独立命名空间中的 `withdrawalCount`，测试验证：

- 升级后 `version() == "2.0.0"`；
- owner / admins / nonces / 余额 / 风控配置**全部保持**；
- 升级后两种提款通道继续可用，nonce 从 V1 的位置继续；
- V2 写入新状态**不影响** V1 状态（命名空间隔离）；
- `upgradeToAndCall` 的 `data` 参数确实以新实现执行。

---

## 9. 与需求文档的偏差与取舍

实现基本逐条覆盖需求，以下为**刻意的偏差**，均有理由：

| # | 需求文档 | 实现 | 理由 |
| --- | --- | --- | --- |
| 1 | `event Paused(address indexed by)` | 使用 OZ `Pausable` 的 `Paused(address account)`（**未 indexed**） | NFR-6 要求使用 OZ 标准库；语义相同（`account` 即调用者），且该签名是全生态公认的。代价：按地址过滤需扫描 data |
| 2 | `WithdrawnWithSig` 不含 `token` | 按文档定义实现，另**同时**发出 `Withdrawn`（含 token） | 补齐缺失的 token 维度；已在 NatSpec 注明「核算只累加 `Withdrawn`」 |
| 3 | `mapping(address => uint256) dailyLimit`（语义含糊） | 拆为 `singleWithdrawLimit[token]` 与 `dailyWithdrawLimit[token]` | 需求 FR-5.5 要求「单笔/单日」两种上限；按代币区分可防止换币绕过 |
| 4 | nonce 一次性 | **严格顺序**：必须等于当前值，不允许跳号 | 比「已用集合」更省 gas、更可预测；代价是链下并发签名需按序提交 |
| 5 | 白名单「只允许提款到预设地址」 | 作用于**全部**提款通道 | 只限制直接提款可用签名绕过，故选更严格一侧 |
| 6 | 存入 ERC20 后余额正确增加 | 按**余额增量**记账并 emit 实际到账量 | 兼容 fee-on-transfer 代币，避免虚增记账 |
| 7 | 「兼容 EVM 主网」 | EVM 目标 `cancun` | OZ 5.6 `Bytes.sol` 使用 `mcopy`，`paris` 无法编译；Cancun 自 2024-03 主网启用 |
| 8 | — | `renounceOwnership()` **保留** OZ 默认实现 | 不改变 `Ownable` 标准 ABI；但生产环境不应调用（见 SECURITY 第 5 节） |
| 9 | — | 额外校验 `token.code.length != 0` | 防止把 EOA 当代币地址（SafeERC20 对无代码地址会「成功」） |
| 10 | — | 签名提款使用 `ECDSA.recoverCalldata` | 避免 `bytes calldata → memory` 拷贝，省 gas |

「范围外」项（跨链桥接、链下后端、DAO 治理、收益聚合、前端 UI）未实现。

---

## 10. 文件与职责

| 文件 | 职责 |
| --- | --- |
| `src/BlockchainVault.sol` | 全部业务逻辑；对外入口、修饰符、CEI 顺序 |
| `src/interfaces/IBlockchainVault.sol` | 对外 ABI：结构体、事件、错误、函数声明（也作为文档） |
| `src/libraries/VaultStorage.sol` | ERC-7201 命名空间常量与 `Layout` 结构 |
| `test/mocks/VaultV2.sol` | 升级目标示例 + 独立命名空间演示 |
| `script/*.s.sol` | 部署 / 升级 / 离线签名 |
