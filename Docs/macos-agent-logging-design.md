# macOS App 面向 Agent 的统一日志框架 · 设计方案

> **落地状态（2026-11-01）**：4 项假设已确认（macOS 12+ / 不记网络 body / 纯本地 / 薄封装 `AgentLog`）。
> 可运行骨架已生成于独立仓库 `agent-log-macos`（`Package.swift` + `Sources/AgentLog/*` + 测试 + `README.md` 接入规范 + `Example/AppDelegate.swift`）。
> 本仓库以 git submodule 形式挂入 `ai-dev-spec/logging-framework/macos/AgentLog`；业务项目用纯 SPM 引用。

> 目标：为多个项目建立**统一、面向 Agent（AI 调试/排障）**的日志框架接入规范。
> 本期优先落地 **macOS App（原生 Swift / AppKit）** 实现；不重复造轮子，复用成熟开源方案。
> 交付物：① 需求澄清 ② 现有方案调研与对比 ③ 含接入规范与自动埋点机制的设计方案。

---

## 1. 需求澄清说明

### 1.1 背景与目标
- 多个项目需要一套**统一的日志接入规范**，让 AI Agent 能像人一样"读日志排障"，而不是每个项目各搞一套。
- 本期先做 **macOS App**：轻量、低侵入、可快速接入现有 App。
- 框架要"面向 Agent"——日志不仅是给人看的文本，更是**机器可解析、可按事件回溯、可一键导出**的结构化数据流。
- 核心诉求：**业务侧无需手动埋点**，框架默认自动为 Agent 记录关键埋点（UI 行为、网络、崩溃、性能）。

### 1.2 已与需求方确认的关键决策
| 维度 | 结论 |
|---|---|
| App 技术栈 | **原生 Swift / AppKit**（非 Electron / Flutter） |
| 日志汇聚方式 | **本地持久化 + 易导出**（不引入后端/云端依赖，保持轻量） |
| 自动埋点范围 | **默认全开**：UI 交互与页面浏览、网络请求、崩溃与未捕获异常、性能与卡顿 |

### 1.3 派生的明确需求
**功能性**
- F1 常规日志：分级（debug/info/warning/error/fault）、多输出目标（控制台 / 文件 / 结构化存储）、本地持久化与轮转。
- F2 结构化 & 机器可读：统一 Schema（含 `event_type`、`session_id`、`trace_id`），JSON/JSONL 输出，便于 Agent 解析。
- F3 自动埋点（默认开，可关闭）：UI 交互/页面浏览、网络请求全链路、崩溃/未捕获异常、主线程卡顿。
- F4 易导出：一键导出为 JSONL / 日志归档，Agent 可直接消费；支持按 subsystem / 时间 / 级别过滤。
- F5 低侵入接入：SPM 一行依赖 + 一处初始化，业务代码零改造即可获得自动埋点。

**非功能性**
- NF1 轻量：依赖少、无后台服务、包体/启动开销可控。
- NF2 低侵入：不强制改造现有日志调用；自动埋点靠运行时钩子，业务无感。
- NF3 隐私安全：默认脱敏（密钥/PII/请求体不落盘），与既有 `ai-dev-spec` 可观测包口径一致。
- NF4 可替换：底层存储引擎可插拔（OSLog / 文件 / SQLite），不因选型锁死。

### 1.4 待确认 / 假设项（落地前请拍板）
1. **最低部署版本**：Pulse 要求 macOS 12+。若需支持更老系统，改用 CocoaLumberjack 文件方案（见 §2.4）。
2. **网络请求是否记录 query/body**：默认只记 method/host/path/status/耗时/error（参照 OpenTelemetry 默认不记 payload），避免敏感信息落盘；如需记录需显式开启并走脱敏。
3. **是否允许偶发上报云端**：本期定为纯本地；如后续要做聚合分析，再叠一层可选 exporter（不影响本期）。
4. **框架交付形态**：建议做成薄封装 `AgentLog`（壳），底层组合 swift-log + Pulse + KSCrash，而非自研存储；文档即"接入规范"。

---

## 2. 现有方案调研与对比

### 2.1 候选方案概览
- **OSLog / Unified Logging System**：Apple 官方统一日志，高性能、隐私感知、系统级集成；`OSLogStore` 可程序化读取（macOS 10.15+/iOS 15+），`log show --style ndjson` 直接出 JSON。缺点：生产环境不持久化 debug 级；跨进程/历史读取受限、偏底层。
- **swift-log**（Apple 官方 API，Apache-2.0）：标准化日志**接口**，后端可插拔（OSLog / 文件 / Pulse）。定位是"日志 API 标准"，本身不做存储。
- **CocoaLumberjack**（BSD-3，13.3k⭐）：成熟、快、文件轮转（`DDFileLogger`）开箱即用，多目标，ObjC 血统。适合纯文件持久化，但结构化/查询/自动网络捕获需自接。
- **Pulse**（kean/Pulse，MIT，7.2k⭐）：原生 Swift，**本地 SQLite 存储结构化日志 + 自动捕获 URLSession 网络请求**，自带 SwiftUI 查看器（PulseUI）、可导出、Pulse Pro macOS 实时查看。与 swift-log 集成（`PulseLogHandler`）。**最贴合"本地持久化 + 易导出 + 面向 Agent + 自动网络埋点"**。非代理、不抓全流量。
- **SwiftyBeaver**（轻量）：云+文件+控制台，但结构化查询/导出能力弱于 Pulse。
- **Sentry / Datadog / Embrace**（商业 APM）：自动埋点强、但重、强依赖云端——与"轻量、本地优先"相悖，仅作反例参考。
- **KSCrash**（MIT，2.6）：Apple 平台最佳开源崩溃框架，捕获 Mach/signal/C++/ObjC 异常、主线程卡顿（250ms+）、OOM/thermal/CPU 终止，报告落盘，SPM/CocoaPods。**补"崩溃与性能"短板**。
- **PLCrashReporter**（Microsoft 开源）：protobuf 崩溃报告，深度高但需自解码；可作 KSCrash 备选。
- **OpenTelemetry Swift**：其 `URLSessionInstrumentation` 用 swizzling 自动追踪网络请求（span + trace 上下文注入），是"网络自动埋点"的成熟实现范本。

### 2.2 对比结论表
| 方案 | 轻量/侵入 | 本地持久化 | 结构化/可查询 | 自动网络埋点 | 自动崩溃/性能 | Agent 友好（导出/JSON） | 许可 |
|---|---|---|---|---|---|---|---|
| OSLog | ★★★★★ | △(debug 不持久) | ★★（需 OSLogStore） | ✗ | ✗ | ★★★（ndjson） | Apple |
| swift-log | ★★★★★ | 取决于后端 | ★★★★（靠后端） | ✗ | ✗ | 取决于后端 | Apache-2.0 |
| CocoaLumberjack | ★★★★ | ★★★★（文件轮转） | ★★ | ✗ | ✗ | ★★ | BSD-3 |
| **Pulse** | ★★★★ | ★★★★★（SQLite） | ★★★★★ | ★★★★★（URLSession） | △(需配) | ★★★★★（导出/查看器） | MIT |
| Sentry/Datadog | ★★（重/云端） | 云端 | ★★★★ | ★★★★★ | ★★★★★ | ★★★★ | 商业 |
| KSCrash | ★★★★ | ★★★★★（报告落盘） | ★★★（报告文件） | ✗ | ★★★★★ | ★★★（报告可解析） | MIT |

### 2.3 自动埋点的可用实现"积木"
- **UI / 页面浏览**：Objective-C 运行时 swizzling `NSViewController.viewDidAppear()` → 发 `screen_view` 事件（类名 + 标题）；swizzling `NSControl.sendAction(_:to:from:)` → 发 `ui_interaction`（控件类 + `accessibilityIdentifier`/标题）。Swift 5.1 的 `@_dynamicReplacement` 可作为替代（非官方下划线 API，谨慎）。
- **网络请求**：swizzling `URLSession` 的 `dataTask/downloadTask/uploadTask` 与 `URLSessionTask.resume()` 及 delegate 回调（OpenTelemetry Swift、Pulse 均采用此模式）→ 自动记录 method/host/path/status/耗时/error，并注入 `trace_id` 串联。
- **崩溃 / 异常**：`NSSetUncaughtExceptionHandler` + signal handler 捕获未处理异常；**KSCrash** 进一步捕获 Mach/signal/C++ 异常、主线程卡顿、OOM 等，报告落盘。
- **性能 / 卡顿**：`CFRunLoopObserver` 监听主线程卡顿；KSCrash Watchdog（250ms+ 卡顿带完整回溯）；可选 `CVDisplayLink` 统计 FPS。

### 2.4 选型建议
**主推（最贴合需求）：swift-log（统一 API）+ Pulse（SQLite 结构化存储 + 自动网络捕获 + 导出/查看）+ KSCrash（崩溃/卡顿）。**
- 全部 MIT/Apache/BSD、SPM、无后端，满足"轻量 + 本地 + 易导出 + 自动埋点"。
- 通过 `AgentLog` 薄封装统一接口与自动埋点开关，底层可替换。

**备选（若需更低 minOS 或不要 Pulse 查看器）：swift-log + CocoaLumberjack（文件轮转）作为存储，网络/UI/性能仍用上述 swizzling 自接，崩溃用 KSCrash。**

---

## 3. 设计方案

### 3.1 总体架构（分层）
```
┌──────────────────────────────────────────────────────────┐
│  业务代码 / 系统框架（业务零埋点）                          │
└───────────────┬──────────────────────────────────────────┘
                │  Logger.info(...) / 自动钩子
┌───────────────▼──────────────────────────────────────────┐
│  API 层：swift-log Logger（统一接口，零锁死）              │
├──────────────────────────────────────────────────────────┤
│  处理层：AgentLogProcessor                                │
│   · 统一 Schema 注入（event_type/session_id/trace_id）     │
│   · 脱敏（密钥/PII/请求体，在 logger 层强制）              │
│   · 标记 agent_auto:true 的自动事件                        │
├───────────────┬───────────────┬──────────────────────────┤
│  存储 Sink    │  存储 Sink    │  存储 Sink                 │
│  OSLog        │  File(轮转)   │  Pulse/SQLite             │
│ (系统/隐私)   │ (文本备份)    │ (结构化/Agent 主存储)      │
└───────────────┴───────┬───────┴──────────────────────────┘
                        │
┌───────────────▼──────────────────────────────────────────┐
│  自动埋点层（默认 ON，可关）：                            │
│   · UIInstrumentation  (NSViewController / NSControl)      │
│   · NetworkInstrumentation (URLSession swizzling)          │
│   · CrashInstrumentation  (KSCrash / 异常处理器)          │
│   · PerformanceInstrumentation (RunLoop / Watchdog / FPS) │
└───────────────┬──────────────────────────────────────────┘
                │
┌───────────────▼──────────────────────────────────────────┐
│  Agent 获取层：                                           │
│   · 一键导出 JSONL 到固定目录                              │
│   · OSLogStore / `log show --style ndjson` 过滤 subsystem  │
│   · Pulse macOS / Pulse Pro 可视化（人+AIAgent 协作）      │
└──────────────────────────────────────────────────────────┘
```

### 3.2 技术选型与依赖（SPM）
```swift
// Package.swift 依赖（建议以 AgentLog 薄封装暴露，业务只依赖 AgentLog）
.package(url: "https://github.com/apple/swift-log.git", .upToNextMajor(from: "1.6.0")),
.package(url: "https://github.com/kean/Pulse.git", .upToNextMajor(from: "5.0.0")),
.package(url: "https://github.com/kstenerud/KSCrash.git", .upToNextMajor(from: "2.6.0")),
```
> 注：Pulse 要求 macOS 12+；若不支持，将 Pulse sink 换成 CocoaLumberjack `DDFileLogger`。

### 3.3 统一日志 Schema（面向 Agent）
所有日志（含自动埋点）统一为以下字段，确保跨项目（Web/mac 等）一致：
```jsonc
{
  "ts": "2026-11-01T14:03:21.123Z",   // ISO8601
  "level": "info",                     // debug|info|warning|error|fault
  "service": "com.org.app",            // 应用标识
  "subsystem": "com.org.app.agent",    // Agent 专用 subsystem，便于过滤
  "category": "network|ui|crash|perf|app",
  "event_type": "network_request|screen_view|ui_interaction|crash|hang|log",
  "session_id": "uuid",                // 一次运行/会话
  "trace_id": "uuid",                  // 跨调用串联（网络注入）
  "agent_auto": true,                  // 是否为框架自动埋点
  "message": "human readable",
  "payload": { /* 结构化上下文，已脱敏 */ }
}
```
- 自动埋点事件统一带 `agent_auto: true` 与明确 `event_type`，Agent 可一键筛选"机器视角时间线"。
- 与 `ai-dev-spec/packages/observability` 的字段（`event/traceId/userId/timestamp/level/message/service/env`）对齐，保证多端一致。

### 3.4 接入规范（Integration Spec）—— 业务零改造
**Step 1 · 依赖（SPM，一行）**
```swift
// 业务仅需依赖 AgentLog 封装（或上述三件套）
dependencies: [ .package(url: "https://github.com/org/AgentLog.git", .upToNextMajor(from: "1.0.0")) ]
```
**Step 2 · 初始化（App 入口一处）**
```swift
import AgentLog
// 早期调用（@main / AppDelegate.init 或 NSApplicationDelegate.applicationDidFinishLaunching）
AgentLog.bootstrap(
  subsystem: "com.org.app",
  config: .init(
    sinks: [.oslog, .file, .pulse],     // 多目标；file/pulse 本地持久化
    autoInstrumentation: [.ui, .network, .crash, .performance], // 默认全开
    redactKeys: ["password","token","authorization","cookie"]
  )
)
```
**Step 3 · 业务侧记日志（可选，保持 swift-log 习惯）**
```swift
import Logging
let logger = Logger(label: "com.org.app.feature")
logger.info("用户保存了配置", metadata: ["user_id": "u_123"])  // 自动带 schema 字段
```
**Step 4 · 导出给 Agent**
```swift
// 一键导出为 JSONL 到固定目录，供 Agent 读取
AgentLog.export(to: FileManager.default.homeDirectoryForCurrentUser
  .appendingPathComponent("Library/Logs/com.org.app/agent-log.jsonl"))
// 或命令行：log show --predicate 'subsystem == "com.org.app.agent"' --style ndjson
```
- **侵入性评估**：现有 App 只需加 1 个依赖 + 1 处初始化；自动埋点对业务透明，无需改任何 VC/按钮/网络代码。

### 3.5 自动埋点机制（默认开启，业务无感）
| 信号 | 实现手段（AppKit） | 产出事件 | 默认 |
|---|---|---|---|
| 页面浏览 | swizzle `NSViewController.viewDidAppear()` | `screen_view`（类名+标题+session） | ON |
| UI 交互 | swizzle `NSControl.sendAction(_:to:from:)` | `ui_interaction`（控件类型+accessibilityIdentifier） | ON |
| 网络请求 | swizzle `URLSession` task 创建/`resume()`/delegate（参照 OpenTelemetry Swift / Pulse） | `network_request`（method/host/path/status/耗时/error + 注入 trace_id） | ON（不记 body） |
| 崩溃/异常 | `NSSetUncaughtExceptionHandler` + signal + **KSCrash** | `crash`（类型/调用栈/线程状态） | ON |
| 主线程卡顿 | `CFRunLoopObserver` + KSCrash Watchdog（250ms+） | `hang`（时长+回溯） | ON |
| 性能（FPS/CPU） | 可选 `CVDisplayLink` / KSCrash CPU monitor | `perf_sample` | OFF（按需） |

**关键设计点**
- **单一开关**：`autoInstrumentation` 枚举集合，业务可按需关闭某类（如发布版本关 UI 埋点）。
- **swizzling 防重入**：类加载期+`dispatch_once` 执行，避免重复交换导致死循环；线程安全。
- **trace 串联**：网络埋点在出站请求注入 `trace_id`（HTTP header 或内部上下文），使"用户点击→网络请求→响应/错误"在 Agent 视角可回溯。
- **零成本门槛**：业务开发者不写任何埋点代码；埋点逻辑集中在 `AgentLog` 内部模块，随框架升级。

### 3.6 日志的 Agent 获取与导出
1. **主路径（推荐）**：Pulse/SQLite sink → `AgentLog.export()` 导出 JSONL 到 `~/Library/Logs/<app>/agent-log.jsonl`，Agent 直接解析。
2. **系统路径**：OSLog sink → `log show --predicate 'subsystem == "com.org.app.agent"' --style ndjson --last 1h`，适合无 App 访问权限时的系统级抓取。
3. **可视化协作**：Pulse macOS / Pulse Pro 供人+AIAgent 共同查看、过滤、分享日志归档。
4. **过滤约定**：Agent 优先按 `subsystem == "*.agent"` + `event_type` 重建"用户做了什么→App 做了什么→哪里失败"的时间线。

### 3.7 隐私与脱敏
- 在 **logger 层（AgentLogProcessor）** 强制脱敏，不依赖调用方自觉（与 `ai-dev-spec` 可观测包一致）。
- 默认脱敏键：`password / token / authorization / cookie / secret`；网络仅记 host/path，不记 query 敏感参数与 body。
- 崩溃报告可能含敏感栈信息，导出/分享前提示复核；可选对称加密落盘。

### 3.8 与 ai-dev-spec 可观测包的一致性
- 字段对齐（§3.3）：macOS 端 `event_type/session_id/trace_id` 与 Web 端 `packages/observability` 的 `event/traceId/userId` 同构，Agent 跨端排障用同一套心智模型。
- 脱敏策略、trace 串联、结构化输出三原则贯通，避免"每端一套日志方言"。

### 3.9 风险与缓解
| 风险 | 缓解 |
|---|---|
| swizzling 与系统升级/其他库冲突 | 仅 swizzle 稳定的系统选择器；`dispatch_once`+防重入；提供开关关闭；在 CI 跑回归 |
| Pulse minOS macOS 12+ 不满足 | 存储 sink 可换 CocoaLumberjack 文件方案 |
| 自动埋点带来性能开销 | 采样/异步写入；卡顿监控阈值保守；发布版可关 UI 埋点 |
| 敏感信息落盘 | logger 层强制脱敏 + 不记 body + 导出提示复核 |
| 多项目规范漂移 | 文档即规范，`AgentLog` 封装统一接口，禁止业务直连底层库 |

### 3.10 后续路线
1. **多项目复用**：将 `AgentLog` 抽为独立 SPM 包 + 本规范文档，作为各项目接入模板。
2. **跨端统一**：Web/服务端复用同一 Schema（参照 `packages/observability`），实现跨端 trace 串联。
3. **可选云端汇聚**：在本地优先之上，按需叠加 exporter（Sentry/自研），不影响本期纯本地设计。
4. **Agent 友好增强**：导出时附带"会话摘要/异常聚类"，让 Agent 首屏即见重点。

---

## 4. 参考来源
- Apple Developer：OSLog / OSLogStore（Unified Logging System）
- apple/swift-log（官方日志 API）
- CocoaLumberjack（CocoaLumberjack/CocoaLumberjack，BSD-3）
- kean/Pulse（MIT，本地 SQLite 结构化日志 + URLSession 网络捕获 + 查看器）
- kstenerud/KSCrash（MIT，崩溃/卡顿捕获）
- OpenTelemetry Swift — URLSessionInstrumentation（swizzling 网络自动埋点范本）
- Method Swizzling in Swift / AOP in Swift（UIViewController/UIControl swizzling 范式）
- 移动端监控技术原理（Runtime hook VC 生命周期、URLSession/CFNetwork、NSUncaughtExceptionHandler）

---

## 状态与落地（2026-11-01）

- **假设已确认**：① 最低 macOS 12+（Pulse 要求）；② 网络不记 query/body；③ 纯本地、无云端依赖；④ 交付形态为薄封装 `AgentLog`。
- **骨架已生成**：`Package.swift`、`Sources/AgentLog/{Model,Privacy,Export,CrashReporter,AgentLog,AutoInstrumentation}.swift`、`Tests/AgentLogTests`、`README.md`（接入规范）、`Example/AppDelegate.swift`。
- **仓库关系**：`agent-log-macos` 为独立仓库；业务项目用纯 SPM 引用（`.package(url:..., from:)`），ai-dev-spec 以 git submodule 引用。
- **已知 TODO（真实集成时核对）**：Pulse/KSCrash 精确版本与 API；`URLSession` 类簇 swizzle 与 delegate-based 响应捕获；发布版默认关闭 UI 埋点。
