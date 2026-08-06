# TOS iOS 钱包自动化测试报告

- 日期：2026-08-06（Asia/Tokyo）
- 分支：`codex/ios-wallet-full-test`
- 工作树：`/Users/tomisetsu/ios/worktrees/ios-wallet-full-test`
- iOS 运行环境：Xcode iOS Simulator，`TOS Wallet QA`（`ADB5A9E1-1715-419E-B542-85D3968AA341`）
- TOS 环境：3 个本地 validator 节点，JSON-RPC `http://127.0.0.1:18545`

## 结论

本次定义并执行的自动化测试矩阵完成率为 **100%**，最终结果为 **全部通过、0 个未解决产品 Bug**。三节点持续出块，最终健康检查区块高度为 `10530`，同步延迟为 `0` 秒。

“100%”指下表中已定义、可重复执行的功能与回归矩阵全部执行完成，不等同于数学意义上的 100% 代码行覆盖率。真实主网、真实法币供应商、硬件钱包及系统生物识别硬件不属于本地三节点测试边界。

## 测试结果

| 范围 | 自动化验证内容 | 结果 |
| --- | --- | --- |
| 三节点网络 | 3 validator 启动、`/readyz`、持续出块、masterchain 查询 | 通过 |
| 链上资金 | faucet 为 active 且有余额；演示转账后目标地址余额 `4.999999 TOS` | 通过 |
| iOS RPC | 查询账户、查询 masterchain、区块高度推进、无效地址错误透传 | 2/2 通过 |
| 新建钱包 UI | 新建入口、数字安全键盘、首次密码、二次确认、进入恢复词备份步骤 | 通过 |
| 导入钱包 UI | 导入入口、Existing Wallet、恢复词输入页、Paste/Continue 操作 | 通过 |
| 首屏/合规 UI | TOS Wallet 标识、新建/导入入口、Terms of Use | 通过 |
| WalletCore | CoreComponents、KeeperCore、WalletCore 与签名相关测试 | 全部通过 |
| 其他本地包 | TronSwift、TKCryptoKit、TKCore、TKLocalize、TKChart | 全部通过 |

最终 UI 结果：3 项测试，0 failure，耗时 32.665 秒。

## 发现并修复的 Bug

1. **首次启动错误访问旧法币接口**
   - 现象：新用户打开钱包即请求 `https://api.tos.network/fiat/methods`，本地/离线环境产生 DNS 错误；这项数据并非首屏必需。
   - 修复：移除 RootController 启动阶段对 `BuySellProvider` 的无条件预加载，改为仅在相应业务需要时加载。
   - 回归：干净启动及全部 UI 流程通过。

2. **节点 HTTP 422 的 JSON-RPC 错误信息被吞掉**
   - 现象：节点对无效地址返回结构化 RPC 错误时，客户端先按 HTTP 状态拒绝响应，最终只得到模糊的 `invalidResponse`。
   - 修复：先解析 JSON-RPC envelope 和 server error，再对没有结构化错误的非 2xx 响应执行通用失败处理。
   - 回归：mock 422 与真实三节点无效地址测试均通过。

3. **引导页和安全键盘缺少可靠的辅助功能语义**
   - 现象：视觉上可点击的元素在 VoiceOver/XCUITest 层级中表现为 `Other`，按钮语义与稳定标识缺失。
   - 修复：为新建、导入、条款、数字键、退格和生物识别键补充 accessibility identifier、label 与 button trait。
   - 回归：三条端到端 UI 用例全部通过。

## 可重复执行命令

```sh
make test_all TEST_BUILD_DIR=/Users/tomisetsu/ios/build \
  TEST_DESTINATION='platform=iOS Simulator,id=ADB5A9E1-1715-419E-B542-85D3968AA341'

make test_tos_live TEST_BUILD_DIR=/Users/tomisetsu/ios/build \
  TEST_DESTINATION='platform=iOS Simulator,id=ADB5A9E1-1715-419E-B542-85D3968AA341'

make test_ui TEST_BUILD_DIR=/Users/tomisetsu/ios/build \
  TEST_DESTINATION='platform=iOS Simulator,id=ADB5A9E1-1715-419E-B542-85D3968AA341'
```

## 测试证据

- UI：`/Users/tomisetsu/ios/build/DerivedData-tests/TOSWalletUITests/Logs/Test/Test-TOSWalletUITests-2026.08.06_12-44-29-+0900.xcresult`
- WalletCore：`/Users/tomisetsu/ios/build/DerivedData-tests/WalletCore/Logs/Test/Test-WalletCore-2026.08.06_12-38-29-+0900.xcresult`
- TKCore：`/Users/tomisetsu/ios/build/DerivedData-tests/TKCore/Logs/Test/Test-TKCore-2026.08.06_12-40-14-+0900.xcresult`
- TKLocalize：`/Users/tomisetsu/ios/build/DerivedData-tests/TKLocalize/Logs/Test/Test-TKLocalize-2026.08.06_12-42-46-+0900.xcresult`
- TKChart：`/Users/tomisetsu/ios/build/DerivedData-tests/TKChart/Logs/Test/Test-TKChart-2026.08.06_12-43-22-+0900.xcresult`

## 非阻塞风险

构建中仍有来自 BigInt、Kingfisher、swift-collections、swift-http-types、TONWalletKit 等第三方依赖的 Swift 6 兼容性或弃用警告。本次构建和测试没有因此失败，但升级到严格 Swift 6 模式前应升级或修补这些依赖。
