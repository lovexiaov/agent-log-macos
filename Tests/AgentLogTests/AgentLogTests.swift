import XCTest
@testable import AgentLog

final class AgentLogTests: XCTestCase {

    func testEntryRoundTrip() throws {
        let entry = AgentLogEntry(level: "info", service: "test", subsystem: "test.agent",
            category: "app", eventType: "log", sessionId: "s1", agentAuto: false,
            message: "hello", payload: ["code": 404, "msg": "x"])
        let line = entry.jsonLine
        XCTAssertFalse(line.isEmpty)
        let decoded = try JSONDecoder().decode(AgentLogEntry.self, from: Data(line.utf8))
        XCTAssertEqual(decoded.message, "hello")
        XCTAssertEqual(decoded.payload?["code"], .int(404))
    }

    func testRedactorMasksSensitiveKeys() {
        let r = Redactor()
        let payload = ["password": AgentValue.string("secret123"), "name": AgentValue.string("ok")]
        let masked = r.maskSensitiveKeys(payload)
        XCTAssertEqual(masked["password"], .string("***REDACTED***"))
        XCTAssertEqual(masked["name"], .string("ok"))
    }

    func testRedactorRegex() {
        let r = Redactor()
        let out = r.redact("Authorization: Bearer abcdef123456")
        XCTAssertFalse(out.contains("abcdef123456"))
        XCTAssertTrue(out.contains("***REDACTED***"))
    }

    func testExporterParsesJSONL() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("agent-test.jsonl")
        try? FileManager.default.removeItem(at: tmp)
        let entry = AgentLogEntry(level: "info", service: "s", subsystem: "sub", category: "c",
            eventType: "log", sessionId: "s1", agentAuto: false, message: "m")
        try Data((entry.jsonLine + "\n").utf8).write(to: tmp)
        let exporter = AgentLogExporter(sourceFile: tmp)
        let entries = try exporter.loadEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.message, "m")
    }

    func testAgentValueObjectRoundTrip() throws {
        let v: AgentValue = ["user": "marco", "score": 42, "ratio": 0.5, "ok": true,
                             "nested": ["inner": "x"], "list": [1, 2, 3]]
        let data = try JSONEncoder().encode(v)
        let decoded = try JSONDecoder().decode(AgentValue.self, from: data)
        XCTAssertEqual(decoded, v)
    }

    func testRedactorMasksUnderscoredKeys() {
        let r = Redactor()
        // api_key / access_token 等带分隔符的键也应被掩码
        let payload = ["api_key": AgentValue.string("sk-12345"),
                      "access_token": AgentValue.string("tok-abc"),
                      "username": AgentValue.string("marco")]
        let masked = r.maskSensitiveKeys(payload)
        XCTAssertEqual(masked["api_key"], .string("***REDACTED***"))
        XCTAssertEqual(masked["access_token"], .string("***REDACTED***"))
        XCTAssertEqual(masked["username"], .string("marco"))
    }

    func testRedactorRegexCaseInsensitive() {
        let r = Redactor()
        let out = r.redact("Authorization: Bearer TOKEN123")
        XCTAssertFalse(out.contains("TOKEN123"))
        XCTAssertTrue(out.contains("***REDACTED***"))
    }
}
