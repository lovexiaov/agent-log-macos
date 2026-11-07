# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/); this project adheres to
Schema v1 (frozen 2026-11-02).

## [Unreleased]

### Changed（Schema v1.2，破坏性）

- `trace_id` 收紧为 **32 位小写 hex**（8 字节，与 OTLP `traceId` / W3C traceparent
  trace-id 同构）。大写自动归一；非法值在序列化边界**丢弃该字段、事件照写**，与
  `span_id` 策略一致。适配器不再对非 hex 值做 `sha256("agentlog:trace:"+raw)` 派生。
  发布时尚无生产使用方（Schema v1.2 描述内已注明）。
- session id 默认生成值改为 32 位小写 hex：`trace_id = session_id` 这个最自然的
  绑定永远合法。

### Added

- `newTraceId()`：生成 Schema 合法的 trace id（uuid4 去横线）。

### Added
- OTLP/JSON adapter (`Sources/AgentLog/OtlpMapper.swift`): one `LogRecord` per event, plus a
  `SPAN_KIND_CLIENT`(3) span for `network_request` / `db_query` (HTTP and database semantic
  conventions). Severity 6→6 (`critical` → `FATAL`=21), `payload.*` flattened one level,
  int64 (nanos / counts) emitted as strings. Only Foundation + CryptoKit — deliberately
  **not** bound to the OpenTelemetry Swift SDK (its logs signal is still Beta).
  Entry points: `toOtlp`, `toOtlpLogs`, `toOtlpSpans`, `logRecord(for:)`, `span(for:)`,
  `json(_:)`, and `AgentLogExporter.otlpBatch(extraResource:)`.
- Deterministic OTLP ids via `SHA256` (retry-safe, no randomness): 32-hex `trace_id` passes
  through lowercased, otherwise `sha256("agentlog:trace:"+raw)[:32]`; a span without a trace
  falls back to `sha256("agentlog:session:"+session_id)[:32]`; a missing `span_id` is derived
  from `session_id|trace_id|event_type|ts|message`, while a schema-valid event `span_id` is
  passed through as-is. `LogRecord` only carries `spanId` when a trace id exists, so no
  orphan spans are produced.
- Hand-written RFC 3339 timestamp parser: `ISO8601DateFormatter` rejects the `+0800` offset
  form and the space-separated variant, and would also lose sub-millisecond precision.
- `AgentLogEntry.userId` (wire key `user_id`): the field was previously missing, which made
  the `enduser.id` OTLP attribute dead code. `AgentLog.recordAuto` and the six static
  convenience methods now accept `userId:`, and Pulse metadata carries `user_id`.
- `Tests/AgentLogTests/OtlpMapperTests.swift` (25 cases): severity table, `warning` alias,
  AnyValue typing, timestamp offsets / space separator / sub-nanosecond truncation, id
  derivation and pass-through, LogRecord shape, HTTP + DB spans, fractional durations,
  non-operation events producing no span, resource grouping, `extraResource` conflicts.
