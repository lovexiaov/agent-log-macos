# AgentLog — 面向 Agent 的 macOS 日志框架

为多个项目提供**统一、面向 Agent（AI 调试/排障）**的日志接入规范。本期实现 **macOS App（原生 Swift / AppKit）**，基于成熟开源方案组合，不重复造轮子。

- **轻量便捷**：SPM 一行依赖 + App 入口一处 `bootstrap`。
- **低侵入**：自动埋点默认全开，**业务侧零埋点代码**。
- **Agent 友好**：结构化 JSONL 落盘 + 系统日志双写，机器可直接按行读取；统一 Schema 与 Web 端对齐。

## 设计理念

| 原则 | 落地 |
|---|---|
| 人退居需求/决策，AI Agent 主导排障 | 日志默认开启自动埋点，Agent 无需业务改造即可观测 |
| 统一、跨端一致 | Schema 字段对齐 `ai-dev-spec/packages/observability`（`event_type`/`trace_id`/`session_id`） |
| 轻量、本地优先 | 本地 SQLite（Pulse）+ JSONL 文件，无后端依赖 |
| 隐私兜底 | 日志层强制脱敏，默认不记网络 body |

## 架构

```
业务代码 ──► AgentLog.{info,warn,error}  ─┐
自动埋点(swizzle) ─► AgentLog.recordAuto ─┤
                                          ├─► FileSink   → ~/Library/Logs/<app>/agent-log.jsonl (JSONL, 主消费源)
                                          └─► Pulse      → SQLite + Pulse macOS 查看器（供人看）
崩溃/卡顿 ─► KSCrash + HangMonitor ───────► 同上述两路
```

- **swift-log**：统一日志 API。
- **Pulse（MIT）**：本地 SQLite 结构化存储 + 自动 URLSession 网络捕获 + 查看器（**可选增强**，用 `#if canImport(PulseLogHandler)` 守卫，缺失不影响核心能力）。
- **KSCrash（MIT）**：崩溃/卡顿采集（**可选增强**，用 `#if canImport(KSCrashInstallations)` 守卫；缺失时自动降级为 no-op）。
- **自动埋点**：AppKit 运行时钩子（Objective-C runtime swizzling），业务零改动。

## 接入规范（业务项目）

### 1. 添加依赖
```swift
// Package.swift（若是 SPM 管理的 App）或 Xcode SPM 依赖
.package(url: "https://github.com/lovexiaov/agent-log-macos.git", from: "0.1.0")
// target dependencies: ["AgentLog"]
```

### 2. 一处 bootstrap（App 启动最早处）
```swift
import AgentLog

func applicationDidFinishLaunching(_ notification: Notification) {
    AgentLog.bootstrap(subsystem: "com.yourapp.agent")  // 自动埋点默认全开
}
```

### 3. 业务日志（替代裸 `print` / `NSLog`）
```swift
AgentLog.info("user opened settings", category: "settings")
AgentLog.error("save failed", traceId: "trace_abc", payload: ["reason": "disk full"])
```
> 业务侧**不需要写任何埋点代码**——UI/网络/崩溃/卡顿由框架自动记录。

### 4. 按需关闭自动埋点
```swift
let config = AgentLogConfig(subsystem: "com.yourapp.agent",
                            autoInstrumentation: [.network, .crash])  // 仅保留网络+崩溃
AgentLog.bootstrap(config: config)
```

### 5. 不提交日志文件
`.gitignore` 增加：
```
*.agent-log.jsonl
```

## 自动埋点范围（默认全开）

| 信号 | 机制 | event_type | 默认 |
|---|---|---|---|
| 页面浏览 | swizzle `NSViewController.viewDidAppear` | `screen_view` | ON |
| UI 交互 | swizzle `NSApplication.sendAction(_:to:from:)`（AppKit action 总入口，覆盖菜单/按钮/控件） | `ui_interaction` | ON |
| 网络请求 | swizzle `URLSession` 的 `dataTask`/`uploadTask`/`downloadTask` 系列，自动注入并串联 `traceparent` | `network_request` | ON（**不记 body**，只记 method/host/path/status/耗时/error） |
| 崩溃/异常 | **KSCrash 2.x**（`KSCrashConfiguration` + `CrashInstallationConsole`，本地落盘不上报） | `crash` | ON（未接入 KSCrash 时自动降级） |
| 主线程卡顿 | 后台 watchdog 线程 + 主线程心跳（>250ms，能捕获 runloop 不转的真实卡顿） | `hang` | ON |

## 日志 Schema（面向 Agent）

线格式遵循 **Schema v1**（真源：`ai-dev-spec/docs/logging-framework/schema/log-event.schema.json`）。
Swift 侧属性名是 camelCase，但 `AgentLogEntry` 通过 `CodingKeys` **只在序列化边界**映射为 snake_case；顶层字段集封闭，业务字段一律进 `payload`。

每行一条 JSON（`agent-log.jsonl`）：
```json
{"ts":"2026-11-01T14:03:21Z","level":"info","service":"com.yourapp",
 "subsystem":"com.yourapp.agent","category":"settings","event_type":"ui_interaction",
 "session_id":"...","trace_id":"trace_abc","agent_auto":true,
 "message":"ui_interaction NSButton","env":"dev",
 "payload":{"control":"NSButton","identifier":"btn_save"}}
```

| 字段 | 说明 | 线格式 |
|---|---|---|
| `ts` | ISO8601 时间戳 | 必填 |
| `level` | trace/debug/info/**warn**/error/critical（`warning` 仅读取兼容，禁止写出） | 必填 |
| `service` | bundle id | 必填 |
| `subsystem` | 约定以 `.agent` 结尾，便于过滤 | 可选 |
| `category` | 业务分类 | 可选 |
| `event_type` | screen_view/ui_interaction/network_request/crash/hang/log | 必填 |
| `session_id` | 一次启动稳定标识 | 必填 |
| `trace_id` | 跨端/跨调用串联（网络自动注入） | 可选 |
| `agent_auto` | true=自动埋点 / false=业务手动 | 必填 |
| `message` | 可读摘要（已脱敏） | 必填 |
| `env` | dev / staging / prod | 可选 |
| `payload` | 结构化附加信息（已脱敏） | 可选 |

> 改动线格式前先看 `Tests/AgentLogTests/SchemaTests.swift`——它断言字段集必须与 schema 一致，改名/私加顶层字段会让测试失败。

## Agent 如何获取日志

**主路径（推荐）**：读取 JSONL 文件
```
~/Library/Logs/<your-bundle-id>/agent-log.jsonl
```
或在代码中：`let url = try AgentLog.export()`（复制到桌面并返回路径）。

**系统路径**（如需实时/历史系统日志）：
```bash
log show --predicate 'subsystem == "*.agent"' --style ndjson --last 1h
```

**人 + Agent 协作**：Pulse macOS 查看器实时浏览；Agent 读 JSONL 做聚合/异常聚类。

## 隐私与脱敏

- 日志层强制脱敏，不依赖调用方自觉（与 Web 端策略一致）。
- 默认脱敏键：`password / token / authorization / cookie / secret / api_key` 等；命中 key 直接整体掩码。
- 网络请求**默认只记** `method/host/path/status/耗时/error`，**不记** query 敏感参数与 body。
- 崩溃报告可能含敏感栈信息，导出/分享前提示复核。

## 与 ai-dev-spec 的关系

- `agent-log-macos` 是**独立仓库**，业务项目用纯 SPM 引用（`.package(url:..., from:)`），最轻、对 AI Agent 最友好。
- 在脚手架 `ai-dev-spec` 内，以 **git submodule** 形式挂入 `logging-framework/macos/AgentLog`，便于在此编辑模板、改完推回本仓库。
- 设计方案文档见 [`Docs/macos-agent-logging-design.md`](./Docs/macos-agent-logging-design.md)。

## 接入 Checklist

- [ ] `Package.swift`/Xcode 加入 `AgentLog` 依赖
- [ ] App 启动最早处调用 `AgentLog.bootstrap(subsystem:)`
- [ ] 业务日志改用 `AgentLog.*`（替代 print/NSLog）
- [ ] 确认自动埋点范围（默认全开，按需裁剪）
- [ ] `.gitignore` 忽略 `*.agent-log.jsonl`
- [ ] Agent 排障路径已验证：`AgentLog.export()` 或 `log show --predicate 'subsystem == "*.agent"'`

## 依赖与版本（重要）

`Package.swift` 中三个外部依赖均为成熟开源方案，**核心能力不依赖它们**：

| 依赖 | 作用 | 守卫 |
|---|---|---|
| `swift-log` | 统一日志 API | 硬依赖 |
| `Pulse` + `PulseLogHandler` | 本地 SQLite 存储 + 查看器（双写增强） | `#if canImport(PulseLogHandler)` |
| `KSCrash`（`Installations` 产品） | 崩溃/卡顿采集 | `#if canImport(KSCrashInstallations)` |

> ⚠️ **版本号是示例值**：`Package.swift` 里的 `from:` 区间（Pulse 5.x / PulseLogHandler 1.x / KSCrash 2.x）需在真实 Xcode/SPM 环境中 `swift package update` 解析并锁定到可用版本；若某版本 API 有差异，由 `#if canImport` 守卫保证**核心（JSONL 落盘 + 自动埋点 + 导出）始终可编译可运行**，不强依赖 Pulse/KSCrash 的具体符号。

## 已知边界（诚实说明）

- **网络自动埋点的 async/await 路径**：`URLSession.data(for:)` 等 async 入口使用框架内部委托类，不经过公开的 `dataTask(with:delegate:)` 工厂，本 swizzle 不一定能捕获其请求/响应。如需 100% 覆盖，可叠加启用 Pulse 的 `URLSessionProxy` / `URLSession.enableAutomaticNetworkLogging()`——二者互补（Pulse 负责全量网络落盘，本框架负责面向 Agent 的结构化 `network_request` 事件）。
- **swizzling 通用风险**：运行时钩子可能与其它同样 swizzle `URLSession`/`NSApplication.sendAction` 的库冲突；如遇冲突，可在 `AgentLogConfig.autoInstrumentation` 中关闭对应项。
- **发布版开销**：自动埋点有少量运行时开销，可在 Release 构建通过配置关闭 `screenView`/`uiInteraction`/`network`（崩溃/卡顿建议保留）。
- **崩溃报告含栈信息**：可能含敏感符号，导出/分享前请复核。
