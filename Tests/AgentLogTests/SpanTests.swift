import XCTest
import Logging
@testable import AgentLog

/// Schema v1.1 span_id：大小写归一、非法值丢弃、线格式键名正确。
///
/// 与 Java/Kotlin `SpanIdTests`、Go `span_test.go`、Python `test_schema.py`
/// 保持同一套断言口径：**坏值绝不写出**，否则 C7 会输出违规行。
final class SpanTests: XCTestCase {

    private let trace = "0123456789abcdef0123456789abcdef"
    private let span = "a1b2c3d4e5f60718"

    private func jsonObject(_ entry: AgentLogEntry) throws -> [String: Any] {
        let data = Data(entry.jsonLine.utf8)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
            "jsonLine 必须是合法 JSON 对象")
    }

    private func entry(traceId: String? = nil, spanId: String? = nil) -> AgentLogEntry {
        AgentLogEntry(
            level: "info",
            service: "com.yourapp.agent",
            subsystem: "com.yourapp.agent",
            category: "app",
            eventType: "log",
            sessionId: "s-1",
            traceId: traceId,
            spanId: spanId,
            agentAuto: false,
            message: "hello")
    }

    // MARK: - normalize

    func testNormalizeAcceptsOnly16HexChars() {
        XCTAssertEqual(SpanIdentifier.normalize("A1B2C3D4E5F60718"), span)
        XCTAssertEqual(SpanIdentifier.normalize("  a1b2c3d4e5f60718 "), span)
        XCTAssertNil(SpanIdentifier.normalize(nil))
        XCTAssertNil(SpanIdentifier.normalize("a1b2c3d4e5f6071"))   // 15 位
        XCTAssertNil(SpanIdentifier.normalize("a1b2c3d4e5f607189")) // 17 位
        XCTAssertNil(SpanIdentifier.normalize("g1b2c3d4e5f60718"))  // 非 hex
        XCTAssertNil(SpanIdentifier.normalize(""))
    }

    // MARK: - 线格式

    func testSpanIdIsWrittenLowercase() throws {
        let obj = try jsonObject(entry(traceId: trace, spanId: "A1B2C3D4E5F60718"))
        XCTAssertEqual(obj["span_id"] as? String, span)
        XCTAssertEqual(obj["trace_id"] as? String, trace)
    }

    func testInvalidSpanIdIsDropped() throws {
        for bad in ["not-a-span", "a1b2c3d4e5f6071", "zzzzzzzzzzzzzzzz"] {
            let obj = try jsonObject(entry(traceId: trace, spanId: bad))
            XCTAssertNil(obj["span_id"], "非法 span_id（\(bad)）不应写出")
            XCTAssertEqual(obj["trace_id"] as? String, trace, "trace_id 不受影响")
        }
    }

    func testNoSpanIdKeyWhenAbsent() throws {
        let obj = try jsonObject(entry(traceId: trace))
        XCTAssertNil(obj["span_id"])
    }

    func testSpanIdNeverAppearsAsCamelCase() throws {
        let obj = try jsonObject(entry(traceId: trace, spanId: span))
        XCTAssertNil(obj["spanId"], "线格式只能是 snake_case")
    }
}
