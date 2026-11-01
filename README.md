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
- **Pulse（MIT）**：本地 SQLite 结构化存储 + 自动 URLSession 网络捕获 + 查看器。
- **KSCrash（MIT）**：崩溃/卡顿采集。
- **自动埋点**：AppKit 运行时钩子（Objective-C runtime swizzling），业务零改动。

## 接入规范（业务项目）

### 1. 添加依赖
```swift
// Package.swift（若是 SPM 管理的 App）或 Xcode SPM 依赖
.package(url: "<agent-log-repo-url>", from: "0.1.0")
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
| UI 交互 | swizzle `NSControl.sendAction` | `ui_interaction` | ON |
| 网络请求 | swizzle `URLSession` task/resume，注入 `trace_id` | `network_request` | ON（**不记 body**） |
| 崩溃/异常 | `NSSetUncaughtExceptionHandler` + **KSCrash** | `crash` | ON |
| 主线程卡顿 | `CFRunLoopObserver`（>250ms） | `hang` | ON |

## 日志 Schema（面向 Agent）

每行一条 JSON（`agent-log.jsonl`）：
```json
{"ts":"2026-11-01T14:03:21Z","level":"info","service":"com.yourapp",
 "subsystem":"com.yourapp.agent","category":"settings","event_type":"ui_interaction",
 "session_id":"...","trace_id":null,"agent_auto":true,
 "message":"ui_interaction NSButton","payload":{"control":"NSButton","identifier":"btn_save"}}
```

| 字段 | 说明 | 对齐 Web 端 |
|---|---|---|
| `ts` | ISO8601 时间戳 | 同 |
| `level` | trace/debug/info/warning/error/critical | 同 |
| `service` | bundle id | — |
| `subsystem` | 约定以 `.agent` 结尾，便于过滤 | — |
| `category` | 业务分类 | `category` |
| `event_type` | screen_view/ui_interaction/network_request/crash/hang/log | `event` |
| `session_id` | 一次启动稳定标识 | `sessionId` |
| `trace_id` | 跨端/跨调用串联（网络自动注入） | `traceId` |
| `agent_auto` | true=自动埋点 / false=业务手动 | — |
| `message` | 可读摘要 | `message` |
| `payload` | 结构化附加信息 | `payload` |

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

- `agent-log` 是**独立仓库**，业务项目用纯 SPM 引用（`.package(url:..., from:)`），最轻、对 AI Agent 最友好。
- 在脚手架 `ai-dev-spec` 内，以 **git submodule** 形式挂入 `logging-framework/macos/AgentLog`，便于在此编辑模板、改完推回本仓库。
- 设计方案文档见 [`Docs/macos-agent-logging-design.md`](./Docs/macos-agent-logging-design.md)。

## 接入 Checklist

- [ ] `Package.swift`/Xcode 加入 `AgentLog` 依赖
- [ ] App 启动最早处调用 `AgentLog.bootstrap(subsystem:)`
- [ ] 业务日志改用 `AgentLog.*`（替代 print/NSLog）
- [ ] 确认自动埋点范围（默认全开，按需裁剪）
- [ ] `.gitignore` 忽略 `*.agent-log.jsonl`
- [ ] Agent 排障路径已验证：`AgentLog.export()` 或 `log show --predicate 'subsystem == "*.agent"'`

## 已知 TODO（真实集成时核对）

- Pulse / KSCrash 的确切版本号与 SPM product 名。
- `URLSession` swizzle 在 Swift 桥接下的方法签名、类簇（`__NSCFURLSessionTask`）覆盖；delegate-based 任务的响应捕获需补 KVO/delegate 包装。
- KSCrash 的 `deadlockWatchdogInterval` / `KSCrashInstallation` 实际 API。
- 发布版（Release）可默认关闭 UI 埋点以降低开销（配置项已预留）。
