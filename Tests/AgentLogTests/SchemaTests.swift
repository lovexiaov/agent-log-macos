import XCTest
import Logging
@testable import AgentLog

/// 守住 Schema v1（真源：ai-dev-spec `docs/logging-framework/schema/log-event.schema.json`）。
///
/// 规范会随时间腐化——只要线格式字段被无意改成 camelCase、或有人往顶层私加字段，
/// 这条测试就必须失败。跨端一致性靠这条断言 + Web 端同名测试共同保证。
final class SchemaTests: XCTestCase {

    /// Schema v1 顶层必填字段
    private static let requiredKeys: Set<String> = [
        "ts", "level", "service", "event_type", "session_id", "agent_auto", "message",
    ]
    /// Schema v1 顶层可选字段
    private static let optionalKeys: Set<String> = [
        "trace_id", "subsystem", "category", "env", "user_id", "payload",
    ]
    /// 历史 camelCase 命名，绝不允许回流到线格式
    private static let legacyKeys: Set<String> = [
        "eventType", "sessionId", "traceId", "agentAuto", "timestamp",
    ]

    private func jsonObject(_ entry: AgentLogEntry) throws -> [String: Any] {
        let data = Data(entry.jsonLine.utf8)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
            "jsonLine 必须是合法 JSON 对象")
    }

    private func fullEntry() -> AgentLogEntry {
        AgentLogEntry(
            ts: "2026-11-02T13:37:21.123Z",
            level: "info",
            service: "com.yourapp.agent",
            subsystem: "com.yourapp.agent",
            category: "auto",
            eventType: "network_request",
            sessionId: "s-1",
            traceId: "trace_abc",
            agentAuto: true,
            message: "GET https://api.example.com/orders -> 200",
            env: "prod",
            payload: ["status": 200, "duration_ms": 128])
    }

    // MARK: - 线格式

    func testWireKeysAreSubsetOfSchemaV1() throws {
        let obj = try jsonObject(fullEntry())
        let allowed = Self.requiredKeys.union(Self.optionalKeys)
        for key in obj.keys {
            XCTAssertTrue(allowed.contains(key), "顶层出现 schema 外字段: \(key)")
        }
        for key in Self.requiredKeys {
            XCTAssertNotNil(obj[key], "缺少必填字段 \(key)")
        }
    }

    func testCamelCaseKeysNeverLeak() throws {
        let obj = try jsonObject(fullEntry())
        for key in Self.legacyKeys {
            XCTAssertNil(obj[key], "线格式泄漏了内部命名 \(key)")
        }
        // 映射后的 snake_case 必须存在且值正确
        XCTAssertEqual(obj["event_type"] as? String, "network_request")
        XCTAssertEqual(obj["session_id"] as? String, "s-1")
        XCTAssertEqual(obj["trace_id"] as? String, "trace_abc")
        XCTAssertEqual(obj["agent_auto"] as? Bool, true)
    }

    func testPayloadStaysNested() throws {
        let obj = try jsonObject(fullEntry())
        let payload = try XCTUnwrap(obj["payload"] as? [String: Any])
        XCTAssertEqual(payload["status"] as? Int, 200)
        XCTAssertEqual(payload["duration_ms"] as? Int, 128)
        // 业务字段不得被提升到顶层
        XCTAssertNil(obj["status"])
        XCTAssertNil(obj["duration_ms"])
    }

    // MARK: - level 词表

    func testLevelVocabularyMatchesSchema() {
        let expected: Set<String> = ["trace", "debug", "info", "warn", "error", "critical"]
        for level in [Logging.Logger.Level.trace, .debug, .info, .warning, .error, .critical] {
            XCTAssertTrue(expected.contains(level.agentName), "非法 level: \(level.agentName)")
        }
        // Swift 枚举叫 .warning，但线格式必须写 warn
        XCTAssertEqual(Logging.Logger.Level.warning.agentName, "warn")
        // 读取端应兼容历史 warning 别名
        XCTAssertEqual(Logging.Logger.Level(agentName: "warning"), .warning)
        XCTAssertEqual(Logging.Logger.Level(agentName: "warn"), .warning)
    }

    // MARK: - 读写往返（Agent 消费 JSONL 依赖它）

    func testDecodeAcceptsSchemaLine() throws {
        let entry = fullEntry()
        let decoded = try JSONDecoder().decode(AgentLogEntry.self, from: Data(entry.jsonLine.utf8))
        XCTAssertEqual(decoded.eventType, "network_request")
        XCTAssertEqual(decoded.sessionId, "s-1")
        XCTAssertEqual(decoded.traceId, "trace_abc")
        XCTAssertEqual(decoded.agentAuto, true)
        XCTAssertEqual(decoded.env, "prod")
        XCTAssertEqual(decoded.payload?["status"], .int(200))
    }

    /// 直接吃 docs/logging-framework/schema/example.json 的等价内容，证明规范样例可被本端解析。
    func testDecodeCanonicalExample() throws {
        let json = """
        {"ts":"2026-11-02T13:37:21.123Z","level":"info","service":"com.yourapp.agent",
         "subsystem":"com.yourapp.agent","category":"auto","event_type":"network_request",
         "session_id":"8f14e45f-ea0a-4c1b-9c3e-0d5b2c7a9e11","trace_id":"trace_3f9a1c2b7d4e",
         "agent_auto":true,"message":"GET https://api.example.com/orders -> 200 (128ms)",
         "env":"prod","payload":{"host":"api.example.com","path":"/orders","method":"GET",
         "status":200,"duration_ms":128}}
        """
        let decoded = try JSONDecoder().decode(AgentLogEntry.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.eventType, "network_request")
        XCTAssertEqual(decoded.sessionId, "8f14e45f-ea0a-4c1b-9c3e-0d5b2c7a9e11")
        XCTAssertEqual(decoded.agentAuto, true)
        XCTAssertEqual(decoded.payload?["method"], .string("GET"))
    }
}
