# BlockchainVault — 智能合约金库

一个可升级（UUPS）的智能合约金库，安全托管 **ETH 与 ERC20**，并通过**角色权限**与
**EIP-712 离线签名授权**两条独立通道管理资金流出，内置防重放、防重入、暂停、白名单与限额风控。

> 需求来源：项目需求文档（功能 / 非功能 / 安全 / 数据模型 / 接口 / 验收标准 六维分析）。
> 本仓库是其设计与实现落地。

| 项目 | 值 |
| --- | --- |
| 语言 / 编译器 | Solidity `0.8.24`（EVM 目标 `cancun`） |
| 开发框架 | Foundry（forge / cast / anvil `1.8.0`） |
| 标准库 | OpenZeppelin `5.6.1`（`contracts` + `contracts-upgradeable`） |
| 测试框架 | forge-std `1.11.0` |
| 升级模式 | UUPS（ERC-1967 代理） |
| 存储布局 | ERC-7201 命名空间存储 |
| 测试 | **166 个测试全部通过**，含攻击场景与模糊测试 |
| 覆盖率 | **100%**（行 / 语句 / 分支 / 函数） |
| 静态检查 | `forge lint --deny warnings src script` 零告警；Slither 0.11.6 无高危（1 条误报已论证，见 `docs/SECURITY.md`） |
| 合约大小 | 10,524 B 运行时（EIP-170 上限 24,576 B，余量 14,052 B） |

---

## 1. 目录结构

```
study/
├── src/
│   ├── BlockchainVault.sol              # 金库主合约（UUPS 可升级）
│   ├── interfaces/
│   │   └── IBlockchainVault.sol         # 对外接口、数据结构、事件、错误
│   └── libraries/
│       └── VaultStorage.sol             # ERC-7201 命名空间存储布局
├── test/
│   ├── VaultTestBase.sol                # 测试夹具 + 独立实现的 EIP-712 工具
│   ├── Deposit.t.sol                    # FR-1  资产管理             (14)
│   ├── Withdraw.t.sol                   # FR-2  提款                 (20)
│   ├── SignatureWithdraw.t.sol          # FR-3  离线签名提款          (35)
│   ├── AccessControl.t.sol              # FR-4/FR-5.1-5.3 权限与暂停  (23)
│   ├── RiskControl.t.sol                # FR-5.4/5.5 白名单与限额     (31)
│   ├── Attack.t.sol                     # SC-1..SC-6 攻击场景        (15)
│   ├── Upgrade.t.sol                    # UUPS 升级与状态保持        (15)
│   ├── Fuzz.t.sol                       # 不变量模糊测试             (10)
│   ├── VaultStorageSlot.t.sol           # ERC-7201 槽位常量自校验     (3)
│   └── mocks/                           # 测试替身（见第 8 节）
├── script/
│   ├── DeployVault.s.sol                # 一键部署（逻辑合约 + 代理 + 初始化）
│   ├── UpgradeVault.s.sol               # 通用 UUPS 升级脚本
│   └── SignWithdrawRequest.s.sol        # 离线生成 EIP-712 提款签名
├── docs/
│   ├── DESIGN.md                        # M2 接口设计 + 数据模型
│   └── SECURITY.md                       # 威胁模型、安全检查清单、局限性
├── foundry.toml
├── remappings.txt
└── package.json
```

> 仓库根目录下的 `ERC20.sol`（`contract MyToken`）是既有练习文件，不属于本项目。
> 因为 `src = "src"`，forge 不会编译它（已实测：构建产物中不存在 `MyToken`），
> 因此它对本地构建、测试与覆盖率没有任何影响。
>
> ⚠️ 说明：该文件在本次会话开始时存在（366 字节），中途一度从工作区消失。我未能定位到原因
> （本次执行的所有命令均未指向该文件），现已按会话开始时读取到的内容逐字节还原
> （366 字节，13 行，CRLF，含原有的尾随空白行），与原文件大小一致。若你本地有该文件的其它版本，
> 请以你自己的为准。

---

## 2. 快速开始

### 2.1 安装依赖

```bash
npm install                 # @openzeppelin/contracts + contracts-upgradeable (5.6.1)
```

`forge-std` 已随仓库以源码形式放在 `lib/forge-std`（v1.11.0），无需额外安装。
若需重新获取：

```bash
git clone --depth 1 --branch v1.11.0 https://github.com/foundry-rs/forge-std.git lib/forge-std
```

### 2.2 构建与测试

```bash
forge build                 # 编译
forge test                  # 166 个测试
forge test -vvv             # 带调用轨迹
forge test --gas-report     # Gas 报表
```

### 2.3 覆盖率（≥ 90% 为验收要求）

```bash
forge coverage --report summary --no-match-coverage "(test|script)/"
# 或
npm run coverage
```

`forge coverage` 会在 IR 流水线下编译（`[profile.coverage] via_ir = true`），以避免深层测试栈过深。
若需显式指定 profile：`FOUNDRY_PROFILE=coverage forge coverage ...`。

### 2.4 静态检查

```bash
forge lint --deny warnings src script
```

---

## 3. 架构总览

### 3.1 合约继承结构

```
BlockchainVault
├── IBlockchainVault          接口：结构体 / 事件 / 错误 / 对外函数声明
├── Initializable             一次性初始化（构造函数中 _disableInitializers）
├── OwnableUpgradeable        Owner：最高权限（权限管理、风控配置、升级）
├── PausableUpgradeable       暂停开关（Paused / Unpaused 事件由此提供）
├── EIP712Upgradeable         EIP-712 域分隔符（绑定 chainId + 本合约地址）
├── UUPSUpgradeable           升级入口 upgradeToAndCall（onlyProxy）+ _authorizeUpgrade
└── ReentrancyGuard           重入锁（OZ 5.x 中已改为 ERC-7201 无状态实现，代理安全）
```

### 3.2 部署形态

```
        ┌──────────────────────────────┐
用户 ──▶│  ERC1967Proxy  (金库地址)      │
        │  ─ ERC-1967 实现槽            │
        │  ─ 全部金库状态（含 ERC-7201） │
        └──────────────┬───────────────┘
                       │ delegatecall
        ┌──────────────▼───────────────┐
        │  BlockchainVault (逻辑合约)    │  ← 自身不可初始化
        └──────────────────────────────┘
```

代理是唯一对外地址；升级只替换逻辑合约，资金与状态原地保留。

### 3.3 资金流出通道

| 通道 | 入口 | 授权方式 |
| --- | --- | --- |
| 直接提款 | `withdrawETH` / `withdrawERC20` | `msg.sender` 为 Owner 或 Admin |
| 离线签名提款 | `withdrawWithSig` | Owner/Admin 的 EIP-712 签名，任何人（中继者）可提交 |

两条通道共享同一套内部 `_withdraw`，因此**风控（暂停、白名单、限额）、余额校验、CEI 顺序与重入锁完全一致**。

---

## 4. 对外接口

| 函数 | 可见性 | 权限 | 说明 |
| --- | --- | --- | --- |
| `receive()` | external payable | 任何人 | 接收 ETH，emit `Deposited` |
| `fallback()` | external payable | 任何人 | 携带 value 的未知调用同样计为存款；无 value 则 `UnknownFunction` |
| `depositERC20(address,uint256)` | external | 任何人 | 存入代币，按**余额增量**记账 |
| `withdrawETH(address,uint256)` | external | Owner/Admin | 提取 ETH |
| `withdrawERC20(address,address,uint256)` | external | Owner/Admin | 提取 ERC20 |
| `withdrawWithSig(WithdrawRequest,bytes)` | external | 有效签名 | 离线签名提款 |
| `addAdmin(address)` / `removeAdmin(address)` | external | Owner | 增删管理员，emit 事件 |
| `transferOwnership(address)` | external | Owner | 转移所有权（OZ） |
| `pause()` / `unpause()` | external | Owner | 暂停 / 恢复，emit `Paused` / `Unpaused` |
| `setWhitelistEnabled(bool)` | external | Owner | 开关提款白名单 |
| `setWhitelisted(address,bool)` | external | Owner | 增删白名单 |
| `setSingleWithdrawLimit(address,uint256)` | external | Owner | 单笔限额（按代币，0 = 关闭） |
| `setDailyWithdrawLimit(address,uint256)` | external | Owner | 单日累计限额（按代币，UTC 日，0 = 关闭） |
| `resetDailySpent(address)` | external | Owner | 手动清零当日已用额度 |
| `getETHBalance()` | view | 任何人 | 查 ETH 余额 |
| `getTokenBalance(address)` | view | 任何人 | 查代币余额 |
| `getNonce(address)` | view | 任何人 | 查签名者当前 nonce |
| `isAdmin(address)` / `isWhitelisted(address)` / `whitelistEnabled()` | view | 任何人 | 权限与风控查询 |
| `getSingleWithdrawLimit(address)` / `getDailyWithdrawLimit(address)` / `getSpentToday(address)` | view | 任何人 | 限额查询 |
| `domainSeparator()` / `hashWithdrawRequest(WithdrawRequest)` | view | 任何人 | EIP-712 辅助（链下签名用） |
| `eip712Domain()` | view | 任何人 | ERC-5267 域信息 |
| `proxiableUUID()` / `upgradeToAndCall(address,bytes)` | external | 见说明 | UUPS：经代理调用 `proxiableUUID` 会 revert；升级仅 Owner |

完整签名与语义见 [`docs/DESIGN.md`](docs/DESIGN.md)。

---

## 5. EIP-712 离线签名提款

### 5.1 签名结构

```solidity
struct WithdrawRequest {
    address to;        // 收款地址
    address token;     // 代币地址；address(0) 表示 ETH
    uint256 amount;    // 金额
    uint256 nonce;     // 一次性随机数（每个签名者各自递增）
    uint256 deadline;  // 过期时间戳
}
```

Type hash：

```
WithdrawRequest(address to,address token,uint256 amount,uint256 nonce,uint256 deadline)
```

### 5.2 域分隔符（Domain）

```
EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)
name    = "BlockchainVault"
version = "1"
```

`chainId` 与 `verifyingContract` 被写进域分隔符，因此签名**不可跨链、不可跨合约重放**。
`EIP712Upgradeable` 会在 `block.chainid` 变化时自动重算域分隔符。

### 5.3 校验顺序（防重放的三道锁）

```
deadline 未过期  →  nonce 等于签名者当前值  →  恢复出的地址是 Owner/Admin
        ↓
   消耗 nonce（先改状态）  →  风控校验并记账  →  余额校验  →  转账（后交互）
```

- **FR-3.5 nonce**：每个签名者独立递增，必须是当前值（不允许跳号），用后作废。
- **FR-3.6 deadline**：`block.timestamp <= deadline` 才有效，恰好等于 deadline 仍有效。
- **FR-3.7 / FR-3.8 域绑定**：换链或换合约地址后恢复出的地址不同，判为 `UnauthorizedSigner`。
- **SC-4 签名可延展性**：使用 OZ `ECDSA`，`s > secp256k1n/2` 直接 `ECDSAInvalidSignatureS`。
- 提款失败会整体回滚，nonce 不会被白白消耗。

### 5.4 端到端示例（已在本地链实测通过）

```bash
# 1) 部署
forge script script/DeployVault.s.sol \
  --rpc-url http://127.0.0.1:8545 \
  --private-key $PRIVATE_KEY --broadcast

# 2) Owner/Admin 在离线机器上签名（只读调用，不广播）
VAULT_PROXY=0xProxy SIGNER_PRIVATE_KEY=0xKey \
TO=0xRecipient AMOUNT=3000000000000000000 \
forge script script/SignWithdrawRequest.s.sol --rpc-url $RPC_URL
# 输出 digest 与 signature (r || s || v)

# 3) 任意账户（中继者）提交，无需 Owner 私钥
cast send 0xProxy \
  'withdrawWithSig((address,address,uint256,uint256,uint256),bytes)' \
  "(0xRecipient,0x0000000000000000000000000000000000000000,3000000000000000000,0,$DEADLINE)" \
  0xSignature --rpc-url $RPC_URL --private-key $RELAYER_KEY
```

用同一签名再提交一次会得到：

```
InvalidNonce(0xf39F..., 0, 1)
```

非授权账户提款会得到：

```
UnauthorizedCaller(0x90F7...)
```

---

## 6. 需求追溯矩阵

### 6.1 功能需求

| 编号 | 需求 | 实现 | 测试 |
| --- | --- | --- | --- |
| FR-1.1 | 接收 ETH（receive/fallback） | `receive` / `fallback` | `Deposit.t.sol` 4 例 |
| FR-1.2 | 存入 ERC20 | `depositERC20` | `test_DepositERC20CreditsVault` |
| FR-1.3 / 1.4 | 余额查询 | `getETHBalance` / `getTokenBalance` | `test_Get*BalanceReportsOnChainBalance` |
| FR-1.5 | 非标准 ERC20 | SafeERC20 | `test_DepositERC20SupportsNonStandardToken`、`test_NonStandardTokenCannotBrickTheVault` |
| FR-2.1 / 2.2 | Owner/Admin 提取 | `withdrawETH` / `withdrawERC20` | `Withdraw.t.sol` |
| FR-2.3 | 非零地址 | `_withdraw` 首行校验 | `test_Withdraw*RevertsToZeroAddress` |
| FR-2.4 | 不超余额 | `InsufficientBalance` | `test_Withdraw*RevertsWhenBalanceInsufficient` |
| FR-2.5 | 失败不丢币 | 先校验后转账、整体回滚 | `test_FailedETHPayoutRevertsAndKeepsFunds` |
| FR-3.1 | EIP-712 | `EIP712Upgradeable` | `test_Eip712DomainIsExposed`、`test_HashWithdrawRequestMatchesIndependentDigest` |
| FR-3.2 | 签名字段完整 | `WithdrawRequest` + type hash | `test_WithdrawRequestTypehashMatchesSpec` |
| FR-3.3 | ecrecover | OZ `ECDSA.recoverCalldata` | 全部签名测试 |
| FR-3.4 | 签名者须为 Owner/Admin | `_isAuthorized(signer)` | `test_SignatureFromUnauthorisedAccountReverts` |
| FR-3.5 | nonce 一次性 | 顺序 nonce，先消耗后转账 | `test_ReplayingTheSameSignatureReverts`、`test_StaleNonceReverts` |
| FR-3.6 | deadline | `SignatureExpired` | `test_ExpiredSignatureReverts`、`test_DeadlineAtExactlyNowIsStillValid` |
| FR-3.7 | 防跨链 | 域含 chainId | `test_SignatureSignedForAnotherChainIdReverts` |
| FR-3.8 | 防跨合约 | 域含 verifyingContract | `test_SignatureSignedForAnotherVaultReverts` |
| FR-4.1 | 部署者即 Owner | `initialize(initialOwner)` | `test_InitializerBecomesOwner` |
| FR-4.2 | 增删 Admin | `addAdmin` / `removeAdmin` | `AccessControl.t.sol` |
| FR-4.3 | 转移所有权 | OZ `transferOwnership` | `test_TransferOwnershipEmitsAndTakesEffect` |
| FR-4.4 | 权限事件 | `AdminAdded` / `AdminRemoved` / `OwnershipTransferred` | `test_AddAdmin*`、`test_RemoveAdmin*` |
| FR-4.5 | 非 Owner 无法管权限 | `onlyOwner` | `test_NonOwner*`、`test_AdminCannot*` |
| FR-5.1 / 5.2 | 暂停 / 恢复 | `pause` / `unpause` | `test_Pause*`、`test_Unpause*` |
| FR-5.3 | 暂停禁提款、允许存款 | `whenNotPaused` 仅作用于提款 | `test_DepositsAreAllowedWhilePaused`、`test_Withdraw*RevertsWhilePaused` |
| FR-5.4 | 白名单 | `setWhitelistEnabled` / `setWhitelisted` | `RiskControl.t.sol` 9 例 |
| FR-5.5 | 单笔 / 单日限额 | `setSingleWithdrawLimit` / `setDailyWithdrawLimit` | `RiskControl.t.sol` 14 例 |
| FR-6.1..6.5 | 事件日志 | `Deposited` / `Withdrawn` / `WithdrawnWithSig` / `AdminAdded` / `AdminRemoved` / `Paused` / `Unpaused` | 各 `expectEmit` 断言 |

### 6.2 非功能需求

| 编号 | 需求 | 落地情况 |
| --- | --- | --- |
| NFR-1 | Gas 效率 | 无循环；限额未配置时走零开销分支；`ECDSA.recoverCalldata` 避免拷贝。见第 9 节 Gas 报表 |
| NFR-2 | 兼容性 | Solidity 0.8.24 + Cancun（OZ 5.6 的 `Bytes.sol` 使用 `mcopy`，故 Cancun 为目标下限） |
| NFR-3 | 可升级性 | UUPS + ERC-7201 命名空间存储，状态扩展无槽位冲突 |
| NFR-4 | 可测试性 | 166 测试，覆盖率 100%，含攻击场景与模糊测试 |
| NFR-5 | 可读性 | 全部 `public`/`external` 函数带 NatSpec（`@notice`/`@param`/`@inheritdoc`） |
| NFR-6 | 标准化 | OpenZeppelin 5.6.1；ERC-1967 代理；ERC-7201 存储；ERC-5267 域信息 |
| NFR-7 | 可观测性 | 所有关键状态变更 emit 事件 |

### 6.3 验收标准

功能验收 AC-1 … AC-12 与安全验收 SC-1 … SC-6 **逐条已有对应测试**，见
[`docs/SECURITY.md`](docs/SECURITY.md) 第 1、2 节。

质量验收：

- 单元测试覆盖率 ≥ 90% → **实测 100%（行/语句/分支/函数）**
- 所有 public/external 函数有 NatSpec → 满足
- 静态分析无高危告警 → `forge lint --deny warnings src script` **零告警**；
  Slither `0.11.6` 实测 8 条结果，其中唯一的 High 分类项（`arbitrary-send-eth`）已论证为**误报**
  （`_withdraw` 为 `private`，三个调用点分别有权限门禁或签名门禁），其余均为 Low/Informational。
  详见 [`docs/SECURITY.md`](docs/SECURITY.md) 第 4 节。
- 部署脚本可一键部署 → 已在本地链（anvil, chain 31337）实测：部署 → 存款 → 离线签名 → 中继提款 → 重放被拒 → 非授权被拒 → 升级 V2 → 状态保持 → 升级后继续提款

---

## 7. 测试与覆盖率

```
Ran 9 test suites: 166 tests passed, 0 failed, 0 skipped

src/BlockchainVault.sol       100.00% (138/138 lines)  100.00% (147/147 stmts)  100.00% (29/29 branches)  100.00% (36/36 funcs)
src/libraries/VaultStorage.sol 100.00% (2/2 lines)      100.00% (1/1 stmts)      N/A                      100.00% (1/1 funcs)
Total                          100.00% (140/140)        100.00% (148/148)        100.00% (29/29)          100.00% (37/37)
```

测试设计要点：

- **独立实现 EIP-712**：`test/VaultTestBase.sol` 从标准出发重算域分隔符与摘要，而不是回读合约的
  `hashWithdrawRequest`，因此签名测试是「实现 vs 标准」而非「实现 vs 自己」。
- **攻击场景可观测**：`ReentrancyAttacker` / `ReentrantERC20` 用 `try/catch` 捕获重入调用被拒的
  **具体错误选择器**，从而证明拦截者是 `ReentrancyGuard` 而非权限修饰符（攻击者同时被授予 Admin）。
- **CEI 可验证**：`PayoutObserver` 在收款回调中读取 nonce 与当日已用额度，证明状态先于外部调用写入。
- **槽位自校验**：`VaultStorageSlot.t.sol` 按 ERC-7201 公式重算两个命名空间槽位，防止硬编码常量笔误。
- **模糊测试**：限额、余额、nonce、权限的不变量在随机输入下成立。

---

## 8. 测试替身（`test/mocks/`）

| 合约 | 用途 |
| --- | --- |
| `MockERC20` | 标准 ERC20 |
| `MockNonStandardERC20` | 仿 USDT：`transfer`/`transferFrom`/`approve` 无返回值（SC-5） |
| `MockFeeOnTransferERC20` | 转账抽成，验证「按余额增量记账」 |
| `MockReturnFalseERC20` | 返回 `false` 且余额虚报，验证 SafeERC20 会中止提款（SC-5） |
| `ReentrancyAttacker` | ETH 收款回调重入（SC-1） |
| `ReentrantERC20` | 代币 `_update` 中重入（SC-1） |
| `PayoutObserver` | 记录付款期间的合约状态（CEI 验证） |
| `VaultV2` | 升级目标：新增函数 + 新 ERC-7201 命名空间 |

---

## 9. Gas 与合约大小

| 方法 | Min | Avg | Median | Max | 调用次数 |
| --- | --- | --- | --- | --- | --- |
| `depositERC20` | 5,627 | 42,805 | 31,141 | 62,104 | 433 |
| `withdrawETH` | 592 | 28,874 | 28,377 | 74,626 | 2,098 |
| `withdrawERC20` | 737 | 51,773 | 52,998 | 80,738 | 273 |
| `withdrawWithSig` | 7,884 | 46,384 | 47,231 | 178,465 | 2,403 |
| `addAdmin` | 2,660 | 26,074 | 26,246 | 26,246 | 535 |
| `removeAdmin` | 2,683 | 9,084 | 9,125 | 9,125 | 262 |
| `pause` / `unpause` | 2,480 | 20,649 / 5,427 | 25,884 / 4,646 | 25,884 / 8,765 | 13 / 5 |
| `initialize` | 2,864 | 93,305 | 94,698 | 94,698 | 168 |

- 合约运行时大小：**10,524 B**（上限 24,576 B，余量 14,052 B）
- `withdrawWithSig` 的最小值（7,884）来自「暂停 / 无权限」等早退路径，优化器已消除大部分开销。

---

## 10. 部署指南

### 10.1 本地链（一键验证）

```bash
anvil --port 8545

VAULT_ADMINS=0xAdmin1,0xAdmin2 \
forge script script/DeployVault.s.sol \
  --rpc-url http://127.0.0.1:8545 \
  --private-key $PRIVATE_KEY --broadcast
```

脚本会输出并写入 `deployments/<chainId>.json`：

```json
{
  "chainId": 31337,
  "implementation": "0x5FbD...",
  "owner": "0xf39F...",
  "proxy": "0xe7f1..."
}
```

环境变量：

| 变量 | 必填 | 说明 |
| --- | --- | --- |
| `VAULT_OWNER` | 否 | 金库 Owner，默认取广播账户 |
| `VAULT_ADMINS` | 否 | 逗号分隔的初始管理员地址列表 |

签名后端由 CLI 决定，`--private-key` / `--account` / `--ledger` / `--unlocked` 均可。

### 10.2 测试网部署 + 验证源码

```bash
VAULT_OWNER=0xOwner VAULT_ADMINS=0xAdmin1 \
forge script script/DeployVault.s.sol \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast --verify --etherscan-api-key $ETHERSCAN_API_KEY
```

### 10.3 升级

新版实现单独部署后，用通用升级脚本切换代理指向（调用者必须是 Owner）：

```bash
# 1) 部署新实现
forge create src/BlockchainVaultV3.sol:BlockchainVaultV3 \
  --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast

# 2) 切换代理（自动读取 deployments/<chainId>.json 中的 proxy）
NEW_IMPLEMENTATION=0xNewImpl \
forge script script/UpgradeVault.s.sol \
  --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast
```

可选：`UPGRADE_CALLDATA=0x...` 可在同一次交易中执行升级后的初始化调用。

> 升级前请核对新旧实现的存储布局兼容性。本项目所有自定义状态都放在 ERC-7201 命名空间下
> （见 [`docs/DESIGN.md`](docs/DESIGN.md) 第 2 节），新版本只需追加新的命名空间或新的字段。

---

## 11. 已知限制与范围外

按需求文档「范围外」执行，另补充实现中的刻意取舍：

- 不包含跨链桥接、链下后端服务、DAO 治理、收益聚合、前端 UI。
- Owner 为单点（需求文档列为风险）；进阶可对接多签（如 Safe）或时间锁作为 Owner。
- `renounceOwnership()` 未覆写，沿用 OZ 默认行为——一旦调用将永久失去暂停与升级能力，**生产环境不应调用**。详见 `docs/SECURITY.md` 第 5 节。
- 白名单 / 限额为链上粗粒度风控，不替代链下风控与监控。
- 收款地址若为恶意合约，可选择耗尽 gas 使交易回滚（资金不会损失，仅该笔失败）。
  如需兼容，可在未来版本改为「拉取式」提款（pull-payment）。

---

## 12. 参考

- [`docs/DESIGN.md`](docs/DESIGN.md) — 接口设计、数据模型、存储布局、时序流程（M2 交付物）
- [`docs/SECURITY.md`](docs/SECURITY.md) — 威胁模型、检查清单、静态分析说明、上线清单
- [EIP-712](https://eips.ethereum.org/EIPS/eip-712) · [ERC-1967](https://eips.ethereum.org/EIPS/eip-1967) · [ERC-7201](https://eips.ethereum.org/EIPS/eip-7201) · [ERC-5267](https://eips.ethereum.org/EIPS/eip-5267)
- [OpenZeppelin Contracts 5.6](https://docs.openzeppelin.com/contracts/5.x/)
- [Foundry Book](https://book.getfoundry.sh/)
