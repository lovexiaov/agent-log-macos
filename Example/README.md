# macOS 示例演示

演示 [AgentLog（Swift）](../Sources/AgentLog/README.md) 的接入方式（对应契约能力）：

- `bootstrap(subsystem:)` 一处接入，UI / 网络 / 崩溃 / 卡顿 **自动埋点默认全开**
- 5 档手动级别：`trace / debug / info / warning / error`
- `traceId` 跨端串联；业务键（`userId` / `method`）进 `payload`
- 脱敏：默认敏感键（`password` / `token` / `secret` …）由 logger 层自动打码
- 崩溃自动埋点：未捕获异常被记为 `crash` 事件（`agent_auto=true`）

## 用法

本目录的 `AppDelegate.swift` 是**片段式示例**（非独立 SPM target）：把它作为你 macOS App 的
`AppDelegate` 即可。`@main` 已标注为应用入口。

1. 在 `applicationDidFinishLaunching` 最早处调用 `AgentLog.bootstrap(subsystem: "com.yourapp.agent")`。
2. 之后像普通日志一样调用 `AgentLog.info(...)` 等，无需任何埋点代码。
3. 日志以 JSONL 落盘于 `~/Library/Logs/<bundleIdentifier>/agent-log.jsonl`，可被 Agent 按行消费。

> 运行依赖：Xcode / 命令行 Swift 工具链 + macOS 13+（Pulse 5.x 要求）。自动埋点使用了
> swift-log、Pulse、KSCrash 等可选增强，但核心 JSONL 落盘不依赖它们。
