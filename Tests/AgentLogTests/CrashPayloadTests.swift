import XCTest
@testable import AgentLog

/// 崩溃 payload 的标准异常词表（Schema v1.3 / INTERFACE.md）。
///
/// KSCrash 的报告结构随版本演进，故这里用**固定样报**（不依赖真实崩溃）覆盖各类
/// `crash.error` 分支，验证 `exception` / `exception_message` / `stack` /
/// `mechanism` 的提取口径，以及「解析不出来也不丢事件」的降级行为。
final class CrashPayloadTests: XCTestCase {

    private func payload(_ report: [String: Any]) -> [String: AgentValue] {
        CrashReporter.standardPayload(from: report)
    }

    // MARK: - Objective-C 异常

    func testNSExceptionReportYieldsStandardVocabulary() throws {
        let report: [String: Any] = [
            "crash": [
                "error": [
                    "type": "nsexception",
                    "reason": "unrecognized selector sent to instance",
                    "nsexception": [
                        "name": "NSInvalidArgumentException",
                        "reason": "unrecognized selector sent to instance",
                    ],
                ],
                "threads": [
                    [
                        "index": 0, "crashed": false,
                        "backtrace": [["symbol_name": "start", "object_name": "DemoApp"]],
                    ],
                    [
                        "index": 2, "crashed": true, "name": "main",
                        "backtrace": [
                            ["symbol_name": "-[Cart total]", "object_name": "DemoApp"],
                            ["symbol_name": "__pthread_kill", "object_name": "libsystem_kernel.dylib"],
                        ],
                    ],
                ],
            ],
        ]
        let payload = self.payload(report)
        XCTAssertEqual(payload["exception"], .string("NSInvalidArgumentException"))
        XCTAssertEqual(payload["exception_message"], .string("unrecognized selector sent to instance"))
        XCTAssertEqual(payload["mechanism"], .string("uncaught"))
        XCTAssertEqual(payload["thread"], .string("main"), "应取崩溃线程而不是主线程")

        guard case .string(let stack)? = payload["stack"] else {
            return XCTFail("stack 必须是单字符串")
        }
        let lines = stack.split(separator: "\n")
        XCTAssertEqual(lines.count, 2, "每个帧一行")
        XCTAssertTrue(stack.contains("-[Cart total]"))
        XCTAssertTrue(stack.contains("__pthread_kill"))
        XCTAssertTrue(lines[0].hasPrefix("0   "), "帧序号从 0 开始")
    }

    // MARK: - 信号 / Mach 异常

    func testSignalReportFallsBackToSignalName() {
        let report: [String: Any] = [
            "crash": [
                "error": [
                    "type": "signal",
                    "signal": ["signal": 11, "name": "SIGSEGV", "code": 1],
                ],
                "threads": [["index": 0, "crashed": true, "queue_name": "com.apple.main-thread"]],
            ],
        ]
        let payload = self.payload(report)
        XCTAssertEqual(payload["exception"], .string("SIGSEGV"))
        XCTAssertEqual(payload["thread"], .string("queue:com.apple.main-thread"))
        XCTAssertNil(payload["stack"], "没有帧就不写 stack（不造空字符串）")
        XCTAssertEqual(payload["mechanism"], .string("uncaught"))
    }

    func testMachExceptionReportUsesExceptionName() {
        let report: [String: Any] = [
            "crash": [
                "error": [
                    "type": "mach_exception",
                    "mach_exception": ["exception": 1, "exception_name": "EXC_BAD_ACCESS"],
                ],
                "threads": [["index": 0, "crashed": true]],
            ],
        ]
        XCTAssertEqual(self.payload(report)["exception"], .string("EXC_BAD_ACCESS"))
    }

    /// 只有报告级 `type` 时才退到它本身，保证 `exception` 尽量不为空。
    func testReportTypeIsLastResortForException() {
        let report: [String: Any] = [
            "crash": ["error": ["type": "cpp_exception"], "threads": [["index": 0, "crashed": true]]],
        ]
        XCTAssertEqual(self.payload(report)["exception"], .string("cpp_exception"))
    }

    // MARK: - 用户上报

    /// KSCrash 2.x 把宿主自报异常写在 `crash.error.user_reported`（`type: "user"`）。
    func testUserReportedUnderCrashErrorMarksReported() {
        let report: [String: Any] = [
            "crash": [
                "error": [
                    "type": "user",
                    "user_reported": [
                        "name": "TestException",
                        "reason": "injected by test",
                        "language": "swift",
                        "backtrace": ["frame-0", "frame-1"],
                    ],
                ],
                "threads": [["index": 0, "crashed": true, "name": "main"]],
            ],
        ]
        let payload = self.payload(report)
        XCTAssertEqual(payload["exception"], .string("TestException"))
        XCTAssertEqual(payload["exception_message"], .string("injected by test"))
        XCTAssertEqual(payload["mechanism"], .string("reported"), "宿主主动上报记 reported")
    }

    /// 旧图纸 / 其它实现写在顶层 `user.user_exception`，同样要能识别。
    func testUserReportedUnderTopLevelUserSection() {
        let report: [String: Any] = [
            "crash": ["threads": [["index": 0, "crashed": true, "name": "main"]]],
            "user": [
                "user_exception": ["name": "TestException", "reason": "injected by test"],
            ],
        ]
        let payload = self.payload(report)
        XCTAssertEqual(payload["exception"], .string("TestException"))
        XCTAssertEqual(payload["exception_message"], .string("injected by test"))
        XCTAssertEqual(payload["mechanism"], .string("reported"), "宿主主动上报记 reported")
    }

    /// 只有 `type: "user"` 而没有 user 区块时，仍应判为 reported。
    func testUserTypeAloneIsEnoughForReported() {
        let report: [String: Any] = [
            "crash": ["error": ["type": "user"], "threads": [["index": 0, "crashed": true]]],
        ]
        let payload = self.payload(report)
        XCTAssertEqual(payload["mechanism"], .string("reported"))
        XCTAssertEqual(payload["exception"], .string("user"), "类型名缺省时退到报告级 type")
    }

    /// 宿主自报的栈可能直接是字符串数组。
    func testCustomStringStackTraceIsJoined() {
        let report: [String: Any] = [
            "crash": [
                "error": ["type": "user", "user_reported": ["name": "X"]],
                "threads": [[
                    "index": 0, "crashed": true,
                    "backtrace": ["at foo (a.swift:1)", "at bar (a.swift:2)"],
                ]],
            ],
        ]
        guard case .string(let stack)? = self.payload(report)["stack"] else {
            return XCTFail("字符串帧数组也要能拼成 stack")
        }
        XCTAssertEqual(stack, "at foo (a.swift:1)\nat bar (a.swift:2)")
    }

    // MARK: - 降级

    func testUnparsableReportStillEmitsMechanism() {
        // 结构完全不符：不抛错、不造字段，只保留 mechanism（raw 由调用方兜底）。
        let payload = self.payload(["hello": "world"])
        XCTAssertEqual(payload, ["mechanism": .string("uncaught")])
    }

    func testEmptyValuesAreTreatedAsAbsent() {
        let report: [String: Any] = [
            "crash": [
                "error": ["type": "nsexception", "nsexception": ["name": "", "reason": ""]],
                "threads": [["index": 0, "crashed": true, "name": "", "backtrace": []]],
            ],
        ]
        let payload = self.payload(report)
        // 具体类型名为空 → 退到报告级 `type`，而不是写出一个空串。
        XCTAssertEqual(payload["exception"], .string("nsexception"))
        XCTAssertNil(payload["exception_message"])
        XCTAssertNil(payload["stack"], "没有帧就不写 stack（不造空字符串）")
        XCTAssertEqual(payload["thread"], .string("thread #0"), "空线程名退到 thread #<index>")
    }

    /// 旧格式（`contents` + `crashed_thread.index`）也要能读出栈。
    func testLegacyContentsAndCrashedThreadIndex() {
        let report: [String: Any] = [
            "crash": [
                "error": ["type": "signal", "signal": ["name": "SIGABRT"]],
                "crashed_thread": ["index": 1],
                "threads": [
                    ["index": 0, "contents": [["symbol_name": "not-crashed"]]],
                    ["index": 1, "contents": [["symbol_name": "abort", "object_name": "libsystem_c.dylib"]]],
                ],
            ],
        ]
        let payload = self.payload(report)
        XCTAssertEqual(payload["thread"], .string("thread #1"))
        guard case .string(let stack)? = payload["stack"] else {
            return XCTFail("旧格式的 contents 也要能读出栈")
        }
        XCTAssertTrue(stack.contains("abort"))
        XCTAssertFalse(stack.contains("not-crashed"), "只取崩溃线程")
    }
}
