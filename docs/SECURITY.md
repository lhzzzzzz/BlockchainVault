# 安全文档 — BlockchainVault

> 对应需求文档第四章「安全需求」与第七章「验收标准」，逐项给出防护措施、对应代码位置与验证测试。
> 所有测试名均可在 `test/` 下检索到；运行 `forge test` 可复现。

---

## 1. 威胁模型与防护映射（需求 4.1）

| # | 威胁 | 攻击场景 | 防护实现 | 验证测试 |
| --- | --- | --- | --- | --- |
| 1 | 越权提款 | 普通用户直接调用 `withdrawETH` | `onlyOwnerOrAdmin`（`_checkOwnerOrAdmin`） | `Attack.t.sol::test_StrangerCannotWithdrawEth`、`test_StrangerCannotWithdrawTokens`、`Fuzz.t.sol::testFuzz_OnlyOwnerOrAdminCanWithdraw` |
| 2 | 重放攻击 | 同一签名重复提交 | 顺序 nonce，转账**前**消耗 | `test_ReplayingTheSameSignatureReverts`、`test_StaleNonceReverts`、`Attack.t.sol::test_ReplayAttackIsRejected` |
| 3 | 跨链重放 | 签名拿到另一条链使用 | 域分隔符绑定 `block.chainid` | `test_SignatureSignedForAnotherChainIdReverts`、`Attack.t.sol::test_CrossChainReplayIsRejected`、`test_DomainSeparatorTracksChainId` |
| 4 | 跨合约重放 | 签名拿到另一个金库使用 | 域分隔符绑定 `address(this)` | `test_SignatureSignedForAnotherVaultReverts` |
| 5 | 签名过期 | 捡起旧签名使用 | `block.timestamp <= deadline` | `test_ExpiredSignatureReverts`、`test_SignatureBecomesInvalidAfterDeadlinePasses` |
| 6 | 签名伪造 | 攻击者伪造 / 篡改签名 | OZ `ECDSA`（含 `v` 校验、长度校验、`s` 上限校验） | `test_TamperedAmountReverts`、`test_TamperedRecipientReverts`、`test_TamperedTokenReverts`、`test_TamperedNonceReverts`、`test_TamperedDeadlineReverts`、`test_EmptySignatureReverts`、`test_ShortSignatureReverts`、`test_InvalidVValueReverts` |
| 7 | 重入攻击 | 收款回调 / 代币回调中再次提款 | `ReentrancyGuard` + CEI（状态先写，交互最后） | `test_ReentrancyGuardBlocksEthReentrancy`、`test_ReentrancyGuardBlocksErc20Reentrancy`、`test_StateIsUpdatedBeforeTheExternalCall` |
| 8 | 非标准代币 | USDT 无返回值 / 返回 false | SafeERC20（`safeTransfer` / `safeTransferFrom`） | `test_NonStandardTokenCannotBrickTheVault`、`test_TokenReturningFalseAbortsWithdrawal` |
| 9 | 私钥泄露 | Owner 私钥被盗 | `Pausable` 可在发现后立即冻结提款；建议 Owner 使用多签（见第 5 节） | `AccessControl.t.sol::test_PauseEmitsPausedEvent`、`Withdraw.t.sol::test_WithdrawETHRevertsWhilePaused` |
| 10 | 恶意 Owner | Owner 作恶 | **未在合约内实现**（需求列为「进阶」）；对策为把 Owner 设为多签或时间锁合约 | 见第 5 节局限性 |
| 11 | 零地址转账 | 转到 `0x0` 丢币 | `_withdraw` 首要校验 | `test_WithdrawETHRevertsToZeroAddress`、`test_WithdrawERC20RevertsToZeroAddress`、`test_SignatureWithdrawalRevertsToZeroAddress` |
| 12 | 整数溢出 | 金额计算溢出 | Solidity 0.8 内置检查；限额减法使用饱和处理避免下溢 | `test_LoweringTheDailyLimitBelowSpendBlocksFurtherWithdrawals`、`Fuzz.t.sol::testFuzz_DailyLimitIsNeverExceeded` |

补充的、需求未列但已处理的威胁：

| 威胁 | 防护 | 验证 |
| --- | --- | --- |
| 把 EOA 当作代币地址（SafeERC20 对无代码地址会「成功」） | `token.code.length != 0` ⇒ `NotAContract` | `test_DepositERC20RevertsForAddressWithoutCode`、`test_WithdrawERC20RevertsForAddressWithoutCode` |
| 收款方 gas griefing / 多签需 > 2300 gas | 用 `call` 而非 `transfer`/`send` | `test_ETHPayoutToGasHungryReceiverSucceeds` |
| 逻辑合约被直接初始化劫持 | 构造函数 `_disableInitializers()` | `test_ImplementationCannotBeInitialized` |
| 非 Owner 升级实现 | `_authorizeUpgrade` + `onlyOwner` | `test_NonOwnerCannotUpgrade`、`test_AdminCannotUpgrade` |
| 升级到非 UUPS 合约导致代理损坏 | OZ 校验 `proxiableUUID` | `test_CannotUpgradeToContractThatIsNotUUPS` |
| 代理被升级为自身（无限 delegatecall） | `proxiableUUID` 经代理调用会 revert | `test_ImplementationRejectsProxyOnlyEntryPoints` |
| 前端抢跑替换收款地址 | 收款地址在签名摘要内 | `Attack.t.sol::test_ValidSignatureCannotBeFrontRunToAnotherRecipient` |
| 失败提款白白消耗 nonce | 整笔交易回滚，nonce 一并回滚 | `test_FailedSignatureWithdrawalRollsBackTheNonce` |

---

## 2. 验收标准对照

### 2.1 功能验收（需求 7.1）

| 编号 | 场景 | 预期 | 对应测试 | 结果 |
| --- | --- | --- | --- | --- |
| AC-1 | 用户向合约转 ETH | 成功，余额增加，emit `Deposited` | `Deposit::test_ReceiveCreditsETHAndEmitsDeposited`、`test_FallbackWithValueCreditsETH` | ✅ |
| AC-2 | 用户存入 ERC20 | 成功，余额增加 | `Deposit::test_DepositERC20CreditsVault` | ✅ |
| AC-3 | Owner 提取 ETH | 成功，到账 | `Withdraw::test_OwnerWithdrawsETH` | ✅ |
| AC-4 | 普通用户提取 | revert | `Attack::test_StrangerCannotWithdrawEth` | ✅ |
| AC-5 | 有效签名提款 | 成功，nonce +1 | `SignatureWithdraw::test_OwnerSignatureWithdrawsETH`、`test_NonceIncrementsAfterEachUse` | ✅ |
| AC-6 | 重复使用签名 | revert | `test_ReplayingTheSameSignatureReverts` | ✅ |
| AC-7 | 过期签名 | revert | `test_ExpiredSignatureReverts` | ✅ |
| AC-8 | 篡改金额的签名 | revert | `test_TamperedAmountReverts` | ✅ |
| AC-9 | 暂停后提款 | revert | `Withdraw::test_WithdrawETHRevertsWhilePaused`、`SignatureWithdraw::test_SignatureWithdrawalRevertsWhilePaused` | ✅ |
| AC-10 | 暂停后存款 | 成功 | `Deposit::test_DepositsAreAllowedWhilePaused` | ✅ |
| AC-11 | 余额不足提款 | revert | `Withdraw::test_WithdrawETHRevertsWhenBalanceInsufficient`、`Fuzz::testFuzz_OverBalanceWithdrawalAlwaysReverts` | ✅ |
| AC-12 | 提款到零地址 | revert | `Withdraw::test_WithdrawETHRevertsToZeroAddress` | ✅ |

### 2.2 安全验收（需求 7.2）

| 编号 | 攻击场景 | 预期 | 对应测试 | 结果 |
| --- | --- | --- | --- | --- |
| SC-1 | 重入攻击 | 被 `ReentrancyGuard` 拦截 | `Attack::test_ReentrancyGuardBlocksEthReentrancy`、`test_ReentrancyGuardBlocksErc20Reentrancy` | ✅ |
| SC-2 | 重放攻击 | nonce 拦截 | `Attack::test_ReplayAttackIsRejected` | ✅ |
| SC-3 | 跨链重放 | chainId 拦截 | `Attack::test_CrossChainReplayIsRejected` | ✅ |
| SC-4 | 签名可延展性 | `s` 值校验拦截 | `SignatureWithdraw::test_MalleableSignatureReverts`、`Attack::test_MalleableCounterpartIsRejected` | ✅ |
| SC-5 | 非标准代币攻击 | SafeERC20 处理 | `Attack::test_NonStandardTokenCannotBrickTheVault`、`test_TokenReturningFalseAbortsWithdrawal` | ✅ |
| SC-6 | 越权调用 | 权限修饰符拦截 | `Attack::test_StrangerCannot*`（5 例）、`AccessControl::test_NonOwner*` | ✅ |

**SC-1 的可信度说明**：重入测试中的攻击者合约**同时被授予 Admin 角色**。
因此重入调用能通过 `onlyOwnerOrAdmin`，唯一可能拦截它的就是重入锁——
测试进一步断言被拒的具体错误选择器为 `ReentrancyGuardReentrantCall()`，
从而把「被权限拦住」和「被重入锁拦住」区分开。

---

## 3. 安全检查清单核对（需求 4.2）

| 检查项 | 状态 | 说明 |
| --- | --- | --- |
| ☑ 所有 external 函数明确可见性 | ✅ | 全部显式 `external` / `public` / `private` / `internal` |
| ☑ 状态变更遵循 Checks-Effects-Interactions | ✅ | `_withdraw` 先校验并记账，最后转账；nonce 与限额均在外部调用前写入。`test_StateIsUpdatedBeforeTheExternalCall` 为可执行证据 |
| ☑ 使用 `call` 而非 `transfer` 转账 ETH | ✅ | `to.call{value: amount}("")` + 返回值校验 ⇒ `ETHTransferFailed` |
| ☑ ERC20 使用 SafeERC20 | ✅ | `SafeERC20.safeTransfer` / `safeTransferFrom` |
| ☑ nonce 在转账前标记为已用 | ✅ | `$.nonces[signer] = expectedNonce + 1` 位于 `_withdraw` 之前 |
| ☑ deadline 校验使用 `block.timestamp` | ✅ | `if (block.timestamp > request.deadline) revert SignatureExpired(...)` |
| ☑ `ecrecover` 检查 `s` 值（防可延展性） | ✅ | 使用 OZ `ECDSA`，`s > secp256k1n/2` ⇒ `ECDSAInvalidSignatureS` |
| ☑ 关键函数加 `nonReentrant` | ✅ | `depositERC20`、`withdrawETH`、`withdrawERC20`、`withdrawWithSig` |
| ☑ 权限函数加 `onlyOwner` / 角色修饰符 | ✅ | 权限管理与风控配置 `onlyOwner`；提款 `onlyOwnerOrAdmin`；升级 `onlyOwner` |
| ☑ 暂停函数加 `whenNotPaused` | ✅ | 三个提款入口；存款**不加**（需求 FR-5.3 要求暂停期间仍可存款） |

---

## 4. 静态分析

### 4.1 Foundry 内建 linter

```bash
forge lint --deny warnings src script
# → exit 0（无 warning；仅剩 3 条 info 级提示）
```

> `src/` 与 `script/` 是实际交付的代码。`test/` 目录刻意包含违反生产规则的辅助合约
> （只收不付的 ETH 接收器、循环内外部调用、忽略 ERC20 返回值），因此不纳入该门禁。
> 注意 `[lint] ignore` 配置不会过滤传递引入的依赖与测试树，必须显式传路径。

被显式排除的规则及其理由（写在 `foundry.toml`）：

| 规则 | 排除理由 |
| --- | --- |
| `arbitrary-send-eth` | 「向调用者指定地址发送 ETH」正是金库的功能本身。已由 Owner/Admin 权限、暂停开关与可选白名单三重约束 |
| `block-timestamp` | 签名 deadline 与 UTC 日限额按需求定义就是基于 `block.timestamp`；矿工可微调时间戳，但影响仅限于 ±数秒的限额窗口，且金额受余额与权限限制 |
| `asm-keccak256` | 纯 gas 微优化，代价是可读性 |
| `reentrancy-events` | **已确认的误报**。该规则会把继承自 `onlyOwner` 修饰符内部的 `owner()` 调用计入被保护函数体，并把「内部调用 public 函数」误判为外部交互；它同样会对 OpenZeppelin 自带的 `Ownable` / `Pausable` 报警。本合约中所有 `emit` 均位于其全部校验之后（CEI），并已由 `test/StateIsUpdatedBeforeTheExternalCall` 与各 `expectEmit` 断言覆盖 |

剩余 info 级提示为 2 条 `inline-assembly`（ERC-7201 槽位获取、`fallback` 选择器提取）
与 1 条 `low-level-calls`（提款用的 `call`），均为上述刻意设计。

### 4.2 Slither（已实际运行）

```bash
pip install slither-analyzer
slither . --compile-force-framework foundry --filter-paths "node_modules|lib/|test/|script/"
```

实测结果（Slither `0.11.6`，31 个合约 / 102 个检测器，**共 8 条结果**）：

| 检测器 | 位置 | 严重性 | 判定 |
| --- | --- | --- | --- |
| `arbitrary-send-eth` | `_withdraw` 中的 `to.call{value: amount}` | High（分类） | **误报**，理由见下 |
| `incorrect-equality` ×2 | `lastSpendDay[token] == today`、`received == 0` | Medium | 非问题：前者是 UTC 日序号**桶比较**，后者是零金额校验 |
| `timestamp` ×2 | `block.timestamp > deadline`、日序号比较 | Low | 刻意设计：deadline 与 UTC 日限额按需求即基于 `block.timestamp` |
| `assembly` ×2 | ERC-7201 槽位获取、`fallback` 提取选择器 | Informational | 刻意设计，已就地注释说明 |
| `low-level-calls` | `to.call{value: amount}("")` | Informational | 刻意设计：需求 4.2 明确要求用 `call` 而非 `transfer` |

**未出现**的检测器（说明这些风险类别已排除）：`reentrancy-eth`、`reentrancy-no-eth`、
`unprotected-upgrade`、`uninitialized-state`、`arbitrary-send-erc20`、`unchecked-transfer`、
`controlled-delegatecall`、`unprotected-initializer`。

#### 关于唯一的 High 分类项 `arbitrary-send-eth`

Slither 报告：*`BlockchainVault._withdraw` sends eth to arbitrary user*。判定为**误报**，依据：

1. `_withdraw` 是 **`private`**（`src/BlockchainVault.sol`），外部不可达；
2. 它只有三个调用点，全部对外部调用者设了门禁：
   - `withdrawETH` / `withdrawERC20` → `onlyOwnerOrAdmin`（`nonReentrant whenNotPaused`）
   - `withdrawWithSig` → EIP-712 签名必须是 Owner/Admin + nonce + deadline（`nonReentrant whenNotPaused`）
3. 因此「向调用者指定地址发送 ETH」只在 Owner/Admin 授权（直接或签名）后发生，
   再加上暂停开关与可选白名单；
4. Slither 的该检测器**不跨 `private` 函数边界追踪调用点上的访问控制**，也无法识别签名式授权，
   只能孤立地分析 `_withdraw`，于是认为缺少调用者限制。

可执行的反证：`Attack.t.sol::test_StrangerCannotWithdrawEth`、
`test_StrangerCannotWithdrawTokens`、`test_StrangerCannotUpgrade`、
`Fuzz.t.sol::testFuzz_OnlyOwnerOrAdminCanWithdraw`（256 次随机地址全部被
`UnauthorizedCaller` 拒绝），以及 `SignatureWithdraw.t.sol` 中全部伪造/篡改签名用例。

若需要在 CI 中把该条标记为已确认的误报，可用 Slither 的 triage 模式生成基线：

```bash
slither . --compile-force-framework foundry --triage-mode   # 生成 slither.db.json
```

> 注意：**不建议**用 `detectors_to_exclude` 全局屏蔽 `arbitrary-send-eth`——该规则在
> 真正的越权转账场景中价值很高，这里应当按实例 triage 而不是关闭规则。

### 4.3 Mythril

Mythril 为符号执行工具，对含 EIP-712 与 ERC-1967 代理的项目通常需要较长分析时间。
建议在 CI 中对实现合约单独运行：

```bash
pip install mythril
myth analyze src/BlockchainVault.sol --execution-timeout 300
```

未在本机运行（本次实测的静态分析门禁为 `forge lint --deny warnings src script` 零告警 + Slither 0.11.6）。

### 4.4 人工审查要点

- `_withdraw` 的**校验顺序**是安全核心：白名单 → 限额 → 余额 → 日志 → 转账。
- `withdrawWithSig` 中 nonce 的写入早于 `_withdraw`，而 `_withdraw` 内部不再有可重入的外部调用
  （`ReentrancyGuard` 亦覆盖）。
- `_isAuthorized` 同时承认 `owner()` 与 `admins[]`，移除管理员即刻生效（同一交易内后续调用即失效）。
- 代币地址与金额均参与签名摘要，攻击者无法替换。

---

## 5. 刻意的取舍与已知局限

1. **Owner 单点风险**（需求 4.1 第 10 行列为「恶意 Owner」）。
   本合约未内建时间锁或多签。推荐做法：把 Owner 设为一个多签合约（如 Safe）或
   `TimelockController`，并把 Admin 设为日常运营账户。
   可选的事件响应是 `pause()`——但它需要 Owner 私钥，因此 Owner 私钥泄露时
   `pause` 与 `withdraw` 会同时失守。**生产部署务必使用多签作为 Owner。**

2. **`renounceOwnership()` 未禁用**。
   沿用 OZ `Ownable` 默认实现，一旦调用将永久失去暂停、风控配置与升级能力
   （Admin 仍可提款）。保留它是为了不改变标准 ABI；**生产环境不应调用**。
   若需彻底杜绝，可在下一版本覆写为 `revert`。

3. **ETH 转账不做 gas 上限**。
   `call` 转发全部可用 gas，恶意收款方可以消耗大量 gas 迫使交易回滚（DoS 单笔提款），
   但**不会造成资金损失**（整笔回滚）。若必须兼容此类收款方，可改为拉取式（pull）提款。

4. **白名单与限额是粗粒度风控**，不替代链下风控、监控与告警。

5. **日限额窗口是 UTC 日**（`block.timestamp / 1 days`），不是滑动 24 小时。
   跨日瞬间额度会重置，属预期语义。

6. **nonce 为严格顺序**：链下若并发生成多个签名，必须按 nonce 顺序提交，
   否则后续签名会因 `InvalidNonce` 失败（状态不会被破坏）。

7. **限额以「代币地址」为键**：同一种代币的不同合约地址各自独立计数。
   若同一资产存在多个合约地址，需要分别配置。

8. **未实现的功能**（需求「范围外」）：跨链桥接、链下后端、DAO 治理、收益聚合、前端 UI。
   另外，需求 FR-5.4/5.5 标注的「可选」项已全部实现。

---

## 6. 上线前检查清单

- [ ] Owner 已设为多签（Safe / Timelock），而非 EOA
- [ ] Admin 列表已核对，且为最小必要集合
- [ ] 若启用白名单，已导入目标地址且在测试网演练过 `NotWhitelisted` 分支
- [ ] 单笔 / 单日限额已按运营需求配置（注意 `0` 表示**不限制**）
- [ ] 部署后立即核对 `owner()`、`isAdmin()`、`eip712Domain()`（name/version/chainId/verifyingContract）
- [ ] 合约已在区块浏览器验证源码（`--verify`）
- [ ] 已用真实硬件钱包/多签对一笔小额提款做过全流程演练（直接提款 + 离线签名提款）
- [ ] 已配置链上监控：`Withdrawn`、`WithdrawnWithSig`、`AdminAdded`、`AdminRemoved`、`Paused`、`Upgraded` 告警
- [ ] 已明确暂停（`pause`）的应急响应流程与责任人
- [ ] 升级前已核对新旧实现的存储布局兼容性（`forge inspect <Contract> storage-layout`）
- [ ] CI 中已跑通：`forge test`、`forge coverage`、`forge lint --deny warnings src script`、Slither
