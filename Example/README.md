# macOS 示例演示

演示 [AgentLog（Swift）](../Sources/AgentLog/README.md) 的接入方式（对应契约能力）：

- `bootstrap(subsystem:)` 一处接入，UI / 网络 / 崩溃 / 卡顿 **自动埋点默认全开**
- 6 档手动级别：`trace / debug / info / warning / error / critical`
- `traceId` 跨端串联；业务键（`userId` / `method`）进 `payload`
- 脱敏：默认敏感键（`password` / `token` / `secret` …）由 logger 层自动打码
- 崩溃自动埋点：未捕获异常被记为 `crash` 事件（`agent_auto=true`）

## 用法

本目录是一个 **可执行 SwiftPM target**（`AgentLogExample`，入口 `main.swift`，纯 Foundation，无需 AppKit / 应用生命周期）：

```bash
# 编译示例（验证 Example 与 AgentLog 公共 API 的契约一致性）
swift build --target AgentLogExample

# 运行示例
swift run AgentLogExample
```

`bootstrap` 时把 `minLevel` 设为 `.trace`，使 6 档级别全部可见；日志以 JSONL 落盘于
`~/Library/Logs/<bundleIdentifier>/agent-log.jsonl`，可被 Agent 按行消费。

> 运行依赖：Xcode / 命令行 Swift 工具链 + macOS 13+（Pulse 5.x 要求）。自动埋点使用了
> swift-log、Pulse、KSCrash 等可选增强，但核心 JSONL 落盘不依赖它们。
