import Foundation
import AppKit

/// 自动埋点：运行时钩子，业务侧零改动。默认全开，可按 AgentLogConfig 逐项关闭。
enum AutoInstrumentation {
    static func install(config: AgentLogConfig) {
        if config.autoInstrumentation.contains(.screenView) { swizzleViewController() }
        if config.autoInstrumentation.contains(.uiInteraction) { swizzleControl() }
        if config.autoInstrumentation.contains(.network) { swizzleURLSession() }
        if config.autoInstrumentation.contains(.hang) { HangMonitor.shared.start() }
        // crash 由 CrashReporter 处理
    }

    // MARK: - 页面浏览：swizzle NSViewController.viewDidAppear
    private static func swizzleViewController() {
        let cls = NSViewController.self
        guard let o = class_getInstanceMethod(cls, #selector(cls.viewDidAppear)),
              let s = class_getInstanceMethod(cls, #selector(cls.agentlog_viewDidAppear)) else { return }
        method_exchangeImplementations(o, s)
    }

    // MARK: - UI 交互：swizzle NSControl.sendAction(_:to:from:)
    private static func swizzleControl() {
        let cls = NSControl.self
        guard let o = class_getInstanceMethod(cls, #selector(cls.sendAction(_:to:from:))),
              let s = class_getInstanceMethod(cls, #selector(cls.agentlog_sendAction(_:to:from:))) else { return }
        method_exchangeImplementations(o, s)
    }

    // MARK: - 网络：swizzle URLSession task 创建 + resume，注入 trace_id
    private static func swizzleURLSession() {
        // TODO（真实集成时核对）：Swift 桥接的方法签名与类簇（__NSCFURLSessionTask）覆盖。
        // 此处给出 completionHandler-based 范式；delegate-based 任务响应捕获需补 KVO/delegate 包装。
        if let o = class_getInstanceMethod(URLSession.self, #selector(cls_dataTaskWithCompletion)),
           let s = class_getInstanceMethod(URLSession.self, #selector(URLSession.agentlog_dataTask(with:completionHandler:))) {
            method_exchangeImplementations(o, s)
        }
        if let o = class_getInstanceMethod(URLSessionTask.self, #selector(URLSessionTask.resume)),
           let s = class_getInstanceMethod(URLSessionTask.self, #selector(URLSessionTask.agentlog_resume)) {
            method_exchangeImplementations(o, s)
        }
    }

    // 辅助：避免 #selector 在闭包外取不到重载方法的歧义
    private static let cls_dataTaskWithCompletion = #selector(URLSession.dataTask(with:completionHandler:) as (URLSession) -> (URLRequest, @escaping (Data?, URLResponse?, Error?) -> Void) -> URLSessionDataTask)
}

// MARK: - NSViewController 扩展（swizzle 目标方法须 @objc 且存在于该类）

extension NSViewController {
    @objc fileprivate func agentlog_viewDidAppear(_ animated: Bool) {
        self.agentlog_viewDidAppear(animated) // 调用原始实现（已交换）
        let name = String(describing: type(of: self))
        AgentLog.shared?.recordAuto(
            eventType: .screenView,
            message: "screen_view \(name)",
            payload: ["view": .string(name), "title": .string(self.title ?? "")])
    }
}

extension NSControl {
    @objc fileprivate func agentlog_sendAction(_ action: Selector?, to target: Any?, from sender: Any?) -> Bool {
        let handled = self.agentlog_sendAction(action, to: target, from: sender) // 原始
        let kind = String(describing: type(of: self))
        let ident = self.identifier?.rawValue
            ?? (self as? NSView)?.accessibilityIdentifier() ?? ""
        AgentLog.shared?.recordAuto(
            eventType: .uiInteraction,
            message: "ui_interaction \(kind)",
            payload: [
                "control": .string(kind),
                "identifier": .string(ident),
                "action": .string(action.map { NSStringFromSelector($0) } ?? "")
            ])
        return handled
    }
}

extension URLSession {
    @objc fileprivate func agentlog_dataTask(with request: URLRequest,
                                            completionHandler: @escaping (Data?, URLResponse?, Error?) -> Void)
        -> URLSessionDataTask {
        // 生成/提取 trace_id（优先读取已有 traceparent 头，实现跨端/跨调用串联）
        let traceId = request.value(forHTTPHeaderField: "traceparent")
            ?? "trace_\(UUID().uuidString)"
        let start = CFAbsoluteTimeGetCurrent()
        let wrapped: (Data?, URLResponse?, Error?) -> Void = { data, resp, err in
            let duration = CFAbsoluteTimeGetCurrent() - start
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            var payload: [String: AgentValue] = [
                "method": .string(request.httpMethod ?? "GET"),
                "host": .string(request.url?.host ?? ""),
                "path": .string(request.url?.path ?? ""),
                "status": .int(status),
                "duration_ms": .double(round(duration * 1000 * 100) / 100)
            ]
            if let e = err { payload["error"] = .string(e.localizedDescription) }
            AgentLog.shared?.recordAuto(
                eventType: .networkRequest,
                message: "network \(request.httpMethod ?? "GET") \(request.url?.path ?? "") -> \(status)",
                traceId: traceId,
                payload: payload)
            completionHandler(data, resp, err)
        }
        // 调用原始 dataTask（已交换）
        return self.agentlog_dataTask(with: request, completionHandler: wrapped)
    }
}

extension URLSessionTask {
    @objc fileprivate func agentlog_resume() {
        self.agentlog_resume() // 原始
        // delegate-based 任务的请求信息取自 originalRequest / currentRequest
        let req = self.originalRequest ?? self.currentRequest
        let traceId = req?.value(forHTTPHeaderField: "traceparent") ?? "trace_\(UUID().uuidString)"
        AgentLog.shared?.recordAuto(
            eventType: .networkRequest,
            message: "network resume \(req?.url?.path ?? "")",
            traceId: traceId,
            payload: [
                "method": .string(req?.httpMethod ?? "GET"),
                "host": .string(req?.url?.host ?? ""),
                "path": .string(req?.url?.path ?? "")
            ])
    }
}

/// 主线程卡顿监控（>250ms 记 hang）。独立于 KSCrash deadlock，便于在 Agent 日志中直接观测。
final class HangMonitor {
    static let shared = HangMonitor()
    private var observer: CFRunLoopObserver?
    var startTime: CFAbsoluteTime = 0
    let threshold: CFTimeInterval = 0.25

    func start() {
        let observer = CFRunLoopObserverCreateWithHandler(nil, kCFRunLoopAllActivities, true, 0) { _, activity in
            if activity.contains(.beforeSources) || activity.contains(.afterWaiting) {
                HangMonitor.shared.startTime = CFAbsoluteTimeGetCurrent()
            } else if activity.contains(.beforeWaiting) {
                let elapsed = CFAbsoluteTimeGetCurrent() - HangMonitor.shared.startTime
                if elapsed > HangMonitor.shared.threshold {
                    AgentLog.shared?.recordAuto(
                        eventType: .hang,
                        message: "main thread blocked \(Int(elapsed * 1000))ms",
                        payload: ["duration_ms": .int(Int(elapsed * 1000))])
                }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }
}
