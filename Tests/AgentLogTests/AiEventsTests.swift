import XCTest
import Foundation
@testable import AgentLog

/// Schema v1.4 AI 交互事件契约测试：六端共用的 6 个 `event_type`、snake_case
/// payload 词表、level 约定、`agent_auto=false`，以及「OTLP 不产 span」。
final class AiEventsTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // 每个用例一份全新的 JSONL；关闭全部自动埋点，避免 swizzle / crash handler 干扰。
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentlog-ai-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cfg = AgentLogConfig(
            subsystem: "com.test.agent",
            service: "svc",
            autoInstrumentation: [],
            exportDirectory: dir,
            minLevel: .debug)
        AgentLog.bootstrap(subsystem: "com.test.agent", config: cfg)
    }

    private func entries() -> [AgentLogEntry] {
        (try? AgentLog.exporter().loadEntries()) ?? []
    }

    private func payload(_ index: Int) -> [String: AgentValue] {
        entries()[index].payload ?? [:]
    }

    func testRequestUsesStandardEventTypeAndPayload() {
        AgentLog.aiRequest(model: "gpt-4o", promptText: "summarize this",
                           extra: ["request_id": "r1", "provider": "openai"])
        let e = entries()[0]
        XCTAssertEqual(e.eventType, "ai_request_initiated")
        XCTAssertEqual(e.level, "info")
        XCTAssertFalse(e.agentAuto)
        XCTAssertEqual(e.category, "ai")
        XCTAssertEqual(payload(0)["model"], .string("gpt-4o"))
        XCTAssertEqual(payload(0)["prompt_text"], .string("summarize this"))
        XCTAssertEqual(payload(0)["request_id"], .string("r1"))
        XCTAssertNil(payload(0)["promptText"])
    }

    func testResponseTokensAndRequestId() {
        AgentLog.aiResponse(model: "gpt-4o", totalTokens: 530,
                            extra: ["request_id": "r1", "prompt_tokens": 320])
        let e = entries()[0]
        XCTAssertEqual(e.eventType, "ai_response_received")
        XCTAssertEqual(e.level, "info")
        XCTAssertEqual(payload(0)["total_tokens"], .int(530))
        XCTAssertEqual(payload(0)["prompt_tokens"], .int(320))
        XCTAssertEqual(payload(0)["request_id"], .string("r1"))
        XCTAssertNil(payload(0)["tokenUsage"])
    }

    func testToolCallAndResult() {
        AgentLog.aiToolCall(toolName: "search", toolArguments: ["q": "x"],
                            extra: ["request_id": "r2"])
        XCTAssertEqual(entries()[0].eventType, "ai_tool_call_initiated")
        XCTAssertEqual(payload(0)["tool_name"], .string("search"))
        XCTAssertEqual(payload(0)["tool_arguments"], .object(["q": .string("x")]))
        XCTAssertEqual(payload(0)["request_id"], .string("r2"))

        AgentLog.aiToolResult(toolName: "search", ok: true,
                              extra: ["tool_call_latency_ms": 12, "request_id": "r2"])
        XCTAssertEqual(entries()[1].eventType, "ai_tool_call_completed")
        XCTAssertEqual(payload(1)["ok"], .bool(true))
        XCTAssertEqual(payload(1)["tool_call_latency_ms"], .int(12))
        XCTAssertEqual(payload(1)["request_id"], .string("r2"))
        XCTAssertNil(payload(1)["toolCallLatency"])
    }

    func testGuardrailIsWarn() {
        AgentLog.aiGuardrail(guardrailType: "toxicity", reason: "blocked")
        let e = entries()[0]
        XCTAssertEqual(e.eventType, "ai_guardrail_triggered")
        XCTAssertEqual(e.level, "warn")
        XCTAssertFalse(e.agentAuto)
        XCTAssertEqual(payload(0)["guardrail_type"], .string("toxicity"))
        XCTAssertNil(payload(0)["guardrailType"])
    }

    func testErrorUsesExceptionVocabulary() {
        AgentLog.aiError(errorType: "RateLimitError", message: "429 too many requests",
                         extra: ["request_id": "r9", "stack": "frame1"])
        let e = entries()[0]
        XCTAssertEqual(e.eventType, "ai_error")
        XCTAssertEqual(e.level, "error")
        XCTAssertFalse(e.agentAuto)
        XCTAssertEqual(payload(0)["exception"], .string("RateLimitError"))
        XCTAssertEqual(payload(0)["exception_message"], .string("429 too many requests"))
        XCTAssertEqual(payload(0)["mechanism"], .string("handled"))
        XCTAssertEqual(payload(0)["stack"], .string("frame1"))
        XCTAssertNil(payload(0)["errorMessage"])
    }

    func testAllSixEventTypesAndNoSpans() throws {
        AgentLog.aiRequest(model: "m", promptText: "p")
        AgentLog.aiResponse(model: "m", totalTokens: 1)
        AgentLog.aiToolCall(toolName: "t", toolArguments: .null)
        AgentLog.aiToolResult(toolName: "t", ok: true)
        AgentLog.aiGuardrail(guardrailType: "g", reason: "r")
        AgentLog.aiError(errorType: "E", message: "m")

        let all = entries()
        XCTAssertEqual(all.count, 6)
        let expected = [
            "ai_request_initiated", "ai_response_received", "ai_tool_call_initiated",
            "ai_tool_call_completed", "ai_guardrail_triggered", "ai_error",
        ]
        XCTAssertEqual(all.map { $0.eventType }, expected)
        XCTAssertEqual(all.map { $0.level }, ["info", "info", "info", "info", "warn", "error"])
        XCTAssertTrue(all.allSatisfy { !$0.agentAuto })
        for entry in all {
            XCTAssertNil(try OtlpMapper.span(for: entry), "\(entry.eventType) 不应产 span")
        }
    }
}
