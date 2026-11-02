import XCTest
import AppKit
@testable import AgentLog

/// 端到端验证四类自动埋点（UI / 网络 / 崩溃 / 卡顿）在真实运行时会落到 AgentLog JSONL 流。
///
/// 注意：AutoInstrumentation 的 swizzle 是类级全局的，重复 bootstrap 会反向交换（还原）。
/// 因此本套测试只在首个用例里 bootstrap 一次，后续用例共享同一 AgentLog 单例与 JSONL 文件。
final class InstrumentationTests: XCTestCase {

    private static var bootstrapped = false

    override func setUp() {
        super.setUp()
        if !Self.bootstrapped {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agentlog-it-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let cfg = AgentLogConfig(
                subsystem: "com.test.agent",
                autoInstrumentation: .all,
                redactSensitive: true,
                exportDirectory: dir,
                minLevel: .debug)
            AgentLog.bootstrap(subsystem: "com.test.agent", config: cfg)
            Self.bootstrapped = true
        }
    }

    private func entries() -> [AgentLogEntry] {
        (try? AgentLog.exporter().loadEntries()) ?? []
    }

    private func eventTypes() -> Set<String> {
        Set(entries().map { $0.eventType })
    }

    // MARK: - 1. UI 交互埋点

    func testUIInteractionRecorded() {
        let app = NSApplication.shared
        // sendAction 走 swizzle 后的 agentlog_sendAction：无论原始分发是否命中，hook 都会记录一条 ui_interaction。
        _ = app.sendAction(Selector(("agentlogTestUiAction:")), to: nil, from: nil)

        let types = eventTypes()
        XCTAssertTrue(types.contains("ui_interaction"),
                      "UI 埋点应记录 ui_interaction，实际 eventTypes: \(types)")
    }

    // MARK: - 2. 网络埋点 + traceparent 注入

    private class StubURLProtocol: URLProtocol {
        static var capturedTraceParent: String?
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            StubURLProtocol.capturedTraceParent = request.value(forHTTPHeaderField: "traceparent")
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("ok".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    func testNetworkRequestRecordedAndTraceInjected() {
        StubURLProtocol.capturedTraceParent = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)

        let exp = expectation(description: "network request completes")
        let req = URLRequest(url: URL(string: "https://stub.test/path")!)
        let task = session.dataTask(with: req) { _, _, _ in exp.fulfill() }
        task.resume()
        wait(for: [exp], timeout: 5)

        // 验证 swizzle 真正注入了 traceparent
        let tp = StubURLProtocol.capturedTraceParent
        XCTAssertNotNil(tp, "网络请求应被注入 traceparent 头")
        XCTAssertTrue((tp ?? "").hasPrefix("trace_"), "traceparent 格式应为 trace_xxx，实际: \(tp ?? "")")

        // 验证收敛成一条 network_request 事件落到 JSONL
        let types = eventTypes()
        XCTAssertTrue(types.contains("network_request"),
                      "网络埋点应记录 network_request，实际 eventTypes: \(types)")

        // traceparent 与事件中记录的 trace_id 应一致
        let netEntry = entries().first { $0.eventType == "network_request" }
        XCTAssertEqual(netEntry?.traceId, tp, "事件 trace_id 应与注入的 traceparent 一致")
    }

    // MARK: - 3. 崩溃埋点

    func testCrashReportRecorded() {
        // 注入一条用户异常报告（不终止进程），并立即转写进 AgentLog 流
        CrashReporter.simulateAndFlush { entry in
            AgentLog.shared?.append(entry: entry)
        }

        let types = eventTypes()
        XCTAssertTrue(types.contains("crash"),
                      "崩溃埋点应记录 crash，实际 eventTypes: \(types)")
        let crashEntry = entries().first { $0.eventType == "crash" }
        XCTAssertEqual(crashEntry?.agentAuto, true, "崩溃事件 agentAuto 应为 true")
        XCTAssertEqual(crashEntry?.level, "critical", "崩溃事件 level 应为 critical")
    }

    // MARK: - 4. 主线程卡顿埋点

    func testHangRecorded() {
        // 先驱动一次 runloop，让心跳基准落在此刻
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        // 主线程真实阻塞 0.4s（> 250ms 阈值）——这正是 runloop 不转的真实卡顿场景
        Thread.sleep(forTimeInterval: 0.4)
        // 给后台 watchdog 线程留出轮询与落盘时间
        let exp = expectation(description: "hang recorded")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { exp.fulfill() }
        wait(for: [exp], timeout: 5)

        let types = eventTypes()
        XCTAssertTrue(types.contains("hang"),
                      "卡顿埋点应记录 hang，实际 eventTypes: \(types)")
    }
}
