import Foundation
import AppKit

/// 自动埋点：基于 Objective-C 运行时钩子，业务侧零改动。
/// 默认全开，可按 `AgentLogConfig.autoInstrumentation` 逐项关闭。
enum AutoInstrumentation {
    static func install(config: AgentLogConfig) {
        if config.autoInstrumentation.contains(.screenView) { swizzleViewController() }
        if config.autoInstrumentation.contains(.uiInteraction) { swizzleAppAction() }
        if config.autoInstrumentation.contains(.network) { NetworkInstrumentation.install() }
        // crash 由 CrashReporter 处理；hang 由 HangMonitor 处理（见 AgentLog.installAuto）
    }

    // MARK: - 页面浏览：swizzle NSViewController.viewDidAppear

    private static func swizzleViewController() {
        let cls = NSViewController.self
        guard let original = class_getInstanceMethod(cls, #selector(cls.viewDidAppear)),
              let replacement = class_getInstanceMethod(cls, #selector(cls.agentlog_viewDidAppear)) else { return }
        method_exchangeImplementations(original, replacement)
    }

    // MARK: - UI 交互：swizzle NSApplication.sendAction(_:to:from:)
    // 这是 AppKit 所有 action 消息的总分发入口（菜单、按钮、控件统一经过它），
    // 比钩 NSControl 更全面（NSControl 无 sendAction(_:to:from:) 三参方法）。

    private static func swizzleAppAction() {
        let cls = NSApplication.self
        let sel = Selector(("sendAction:to:from:"))
        guard let original = class_getInstanceMethod(cls, sel),
              let replacement = class_getInstanceMethod(cls, #selector(cls.agentlog_sendAction(_:to:from:))) else { return }
        method_exchangeImplementations(original, replacement)
    }
}

// MARK: - NSViewController 扩展

extension NSViewController {
    @objc fileprivate func agentlog_viewDidAppear(_ animated: Bool) {
        // 调用「原始」实现（已与 agentlog_ 交换）
        self.agentlog_viewDidAppear(animated)
        let name = String(describing: type(of: self))
        AgentLog.shared?.recordAuto(
            eventType: .screenView,
            message: "screen_view \(name)",
            payload: ["view": .string(name), "title": .string(self.title ?? "")])
    }
}

// MARK: - NSApplication 扩展

extension NSApplication {
    @objc fileprivate func agentlog_sendAction(_ action: Selector, to target: Any?, from sender: Any?) -> Bool {
        let handled = self.agentlog_sendAction(action, to: target, from: sender) // 原始
        let senderKind = String(describing: type(of: sender ?? NSNull()))
        let ident = (sender as? NSView)?.accessibilityIdentifier()
            ?? (sender as? NSControl)?.identifier?.rawValue
            ?? ""
        AgentLog.shared?.recordAuto(
            eventType: .uiInteraction,
            message: "ui_interaction \(senderKind).\(NSStringFromSelector(action))",
            payload: [
                "sender": .string(senderKind),
                "identifier": .string(ident),
                "action": .string(NSStringFromSelector(action)),
                "target_kind": .string(target.map { String(describing: type(of: $0)) } ?? "nil")
            ])
        return handled
    }
}

// MARK: - 网络自动埋点（NetworkInstrumentation）

/// 通过 swizzle 自动记录 URLSession 请求/响应，注入并串联 traceparent，
/// 业务侧无需任何手动埋点。覆盖 completionHandler 任务与 delegate 任务
/// （含大部分 async/await 走 delegate 的情形）。
///
/// 已知边界：`URLSession.data(for:)` 等 async/await 入口使用内部委托类，
/// 不经过公开 `dataTask(with:delegate:)` 工厂，故本 swizzle 不一定能捕获；
/// 如需 100% 覆盖，可叠加 Pulse 的 `URLSessionProxy` / `enableAutomaticNetworkLogging()`，
/// 二者互补（Pulse 负责全量网络落盘，本框架负责面向 Agent 的结构化 network_request 事件）。
enum NetworkInstrumentation {
    static func install() {
        swizzleDataTaskWithCompletion()
        swizzleDataTaskWithDelegate()
        swizzleUploadTaskWithDelegate()
        swizzleDownloadTaskWithDelegate()
    }

    /// 从请求中解析 trace id：优先取 W3C `traceparent` 第 2 段（32 位 hex），
    /// 否则新生成。Schema v1.2 要求 trace id 必须是 32 位 hex。
    fileprivate static func resolveTraceId(_ request: URLRequest) -> String {
        if let tp = request.value(forHTTPHeaderField: "traceparent"), !tp.isEmpty {
            let parts = tp.split(separator: "-")
            if parts.count == 4, let trace = TraceIdentifier.normalize(String(parts[1])) {
                return trace
            }
        }
        return TraceIdentifier.newTraceId()
    }

    /// 把 trace id 以合法的 W3C `traceparent` 形态注入出站请求头。
    fileprivate static func injectTraceId(_ request: inout URLRequest, _ traceId: String) {
        if request.value(forHTTPHeaderField: "traceparent") == nil {
            let span = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)).lowercased()
            request.setValue("00-\(traceId)-\(span)-01", forHTTPHeaderField: "traceparent")
        }
    }

    private static func swizzleDataTaskWithCompletion() {
        let cls = URLSession.self
        let original = Selector(("dataTaskWithRequest:completionHandler:"))
        guard let o = class_getInstanceMethod(cls, original),
              let s = class_getInstanceMethod(cls, #selector(URLSession.agentlog_dataTask(with:completionHandler:))) else { return }
        method_exchangeImplementations(o, s)
    }

    private static func swizzleDataTaskWithDelegate() {
        let cls = URLSession.self
        let original = Selector(("dataTaskWithRequest:delegate:delegateQueue:"))
        guard let o = class_getInstanceMethod(cls, original),
              let s = class_getInstanceMethod(cls, #selector(URLSession.agentlog_dataTask(with:delegate:delegateQueue:))) else { return }
        method_exchangeImplementations(o, s)
    }

    private static func swizzleUploadTaskWithDelegate() {
        let cls = URLSession.self
        let original = Selector(("uploadTaskWithRequest:fromData:delegate:delegateQueue:"))
        guard let o = class_getInstanceMethod(cls, original),
              let s = class_getInstanceMethod(cls, #selector(URLSession.agentlog_uploadTask(with:from:delegate:delegateQueue:))) else { return }
        method_exchangeImplementations(o, s)
    }

    private static func swizzleDownloadTaskWithDelegate() {
        let cls = URLSession.self
        let original = Selector(("downloadTaskWithRequest:delegate:delegateQueue:"))
        guard let o = class_getInstanceMethod(cls, original),
              let s = class_getInstanceMethod(cls, #selector(URLSession.agentlog_downloadTask(with:delegate:delegateQueue:))) else { return }
        method_exchangeImplementations(o, s)
    }

    // 对 delegate 任务的委托类，懒 swizzle 其 `urlSession:task:didCompleteWithError:` 以捕获完成事件。
    private static var swizzledClasses = Set<ObjectIdentifier>()
    private static let delegateLock = NSLock()

    fileprivate static func ensureDelegateSwizzled(_ delegate: AnyObject?) {
        guard let delegate = delegate, let cls: AnyClass = object_getClass(delegate) else { return }
        let key = ObjectIdentifier(cls)
        delegateLock.lock(); defer { delegateLock.unlock() }
        if swizzledClasses.contains(key) { return }
        swizzledClasses.insert(key)

        let sel = Selector(("urlSession:task:didCompleteWithError:"))
        guard let original = class_getInstanceMethod(cls, sel),
              let replacement = class_getInstanceMethod(NSObject.self,
                #selector(NSObject.agentlog_urlSession(_:task:didCompleteWithError:))) else { return }
        method_exchangeImplementations(original, replacement)
    }
}

extension URLSession {
    @objc fileprivate func agentlog_dataTask(with request: URLRequest,
                                             completionHandler: @escaping (Data?, URLResponse?, Error?) -> Void)
        -> URLSessionDataTask {
        var req = request
        let traceId = NetworkInstrumentation.resolveTraceId(request)
        NetworkInstrumentation.injectTraceId(&req, traceId)

        // 包装完成回调：在原回调执行前，先把本次请求收敛成一条 network_request 事件。
        // task 在返回后赋值，闭包延迟执行时即可正确引用。
        var task: URLSessionDataTask!
        let wrapped: (Data?, URLResponse?, Error?) -> Void = { data, resp, err in
            NetworkTracker.shared.complete(task: task, response: resp, error: err)
            completionHandler(data, resp, err)
        }
        task = self.agentlog_dataTask(with: req, completionHandler: wrapped)
        NetworkTracker.shared.attach(task: task, request: req, traceId: traceId)
        return task
    }

    @objc fileprivate func agentlog_dataTask(with request: URLRequest,
                                             delegate: URLSessionTaskDelegate?,
                                             delegateQueue queue: OperationQueue?)
        -> URLSessionDataTask {
        NetworkInstrumentation.ensureDelegateSwizzled(delegate)
        var req = request
        let traceId = NetworkInstrumentation.resolveTraceId(request)
        NetworkInstrumentation.injectTraceId(&req, traceId)

        let task = self.agentlog_dataTask(with: req, delegate: delegate, delegateQueue: queue)
        NetworkTracker.shared.attach(task: task, request: req, traceId: traceId)
        return task
    }

    @objc fileprivate func agentlog_uploadTask(with request: URLRequest,
                                              from bodyData: Data?,
                                              delegate: URLSessionTaskDelegate?,
                                              delegateQueue queue: OperationQueue?)
        -> URLSessionUploadTask {
        NetworkInstrumentation.ensureDelegateSwizzled(delegate)
        var req = request
        let traceId = NetworkInstrumentation.resolveTraceId(request)
        NetworkInstrumentation.injectTraceId(&req, traceId)

        let task = self.agentlog_uploadTask(with: req, from: bodyData, delegate: delegate, delegateQueue: queue)
        NetworkTracker.shared.attach(task: task, request: req, traceId: traceId)
        return task
    }

    @objc fileprivate func agentlog_downloadTask(with request: URLRequest,
                                                delegate: URLSessionDownloadDelegate?,
                                                delegateQueue queue: OperationQueue?)
        -> URLSessionDownloadTask {
        NetworkInstrumentation.ensureDelegateSwizzled(delegate)
        var req = request
        let traceId = NetworkInstrumentation.resolveTraceId(request)
        NetworkInstrumentation.injectTraceId(&req, traceId)

        let task = self.agentlog_downloadTask(with: req, delegate: delegate, delegateQueue: queue)
        NetworkTracker.shared.attach(task: task, request: req, traceId: traceId)
        return task
    }
}

// delegate 完成回调的 swizzle 目标（挂在 NSObject 上，由 ensureDelegateSwizzled 按需交换到具体委托类）。
extension NSObject {
    @objc fileprivate func agentlog_urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        NetworkTracker.shared.complete(task: task, response: task.response, error: error)
        // 调用原始实现（已交换）
        self.agentlog_urlSession(session, task: task, didCompleteWithError: error)
    }
}

// MARK: - NetworkTracker：把请求/响应收敛成一条 network_request 事件

/// 线程安全的请求跨度记录器。以 task（class 实例）为键，统一在「完成」时产出一条事件。
final class NetworkTracker {
    static let shared = NetworkTracker()

    private let lock = NSLock()
    private var spans = [ObjectIdentifier: Span]()

    struct Span {
        let traceId: String
        let start: CFAbsoluteTime
        let request: URLRequest
    }

    /// 在 task 创建后立即登记起点（request 已注入 traceparent）。
    func attach(task: URLSessionTask, request: URLRequest, traceId: String) {
        lock.lock(); defer { lock.unlock() }
        spans[ObjectIdentifier(task)] = Span(traceId: traceId, start: CFAbsoluteTimeGetCurrent(), request: request)
    }

    /// 在任务完成（completionHandler / delegate 回调）时收敛为一条 network_request 事件。
    func complete(task: URLSessionTask, response: URLResponse?, error: Error?) {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        guard let span = spans.removeValue(forKey: ObjectIdentifier(task)) else { lock.unlock(); return }
        lock.unlock()

        let duration = (now - span.start) * 1000
        let req = span.request
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let method = req.httpMethod ?? "GET"
        let host = req.url?.host ?? ""
        let path = req.url?.path ?? ""

        var payload: [String: AgentValue] = [
            "method": .string(method),
            "host": .string(host),
            "path": .string(path),
            "status": .int(status),
            "duration_ms": .double(round(duration * 100) / 100),
            "task_type": .string(String(describing: type(of: task)))
        ]
        if let e = error { payload["error"] = .string(e.localizedDescription) }
        payload["trace_id"] = .string(span.traceId)

        AgentLog.shared?.recordAuto(
            eventType: .networkRequest,
            message: "network \(method) \(path) -> \(status)",
            traceId: span.traceId,
            payload: payload)
    }
}

// MARK: - 主线程卡顿监控（>250ms 记 hang）

/// 主线程卡顿监控：独立后台 watchdog 线程每 100ms 检查主线程心跳。
///
/// 为什么不能只用 runloop observer：主线程被业务代码阻塞时 runloop **根本不转**，
/// observer 不会回调，也就永远测不到真正的卡顿。因此必须由后台线程独立计时：
/// 主线程每次 runloop 活动刷新心跳，后台线程发现心跳超过阈值未更新即判定 hang。
final class HangMonitor {
    static let shared = HangMonitor()
    private var observer: CFRunLoopObserver?
    private var thread: Thread?
    private var running = false
    private let lock = NSLock()
    private var lastPing: CFAbsoluteTime = 0
    private var reported = false
    let threshold: CFTimeInterval = 0.25
    var isInstalled: Bool { observer != nil }

    func start() {
        guard observer == nil else { return } // 幂等：避免重复 bootstrap 时多注册
        running = true
        lastPing = CFAbsoluteTimeGetCurrent()

        // 主线程 runloop 每次活动刷新心跳（表明主线程仍在响应）
        let obs = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.allActivities.rawValue, true, 0) { [weak self] _, _ in
            guard let self = self else { return }
            self.lock.lock()
            self.lastPing = CFAbsoluteTimeGetCurrent()
            self.reported = false
            self.lock.unlock()
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), obs, .commonModes)
        observer = obs

        // 后台线程独立检测，不受主线程阻塞影响
        let t = Thread { [weak self] in
            guard let self = self else { return }
            while self.running {
                Thread.sleep(forTimeInterval: 0.1)
                let now = CFAbsoluteTimeGetCurrent()
                self.lock.lock()
                let elapsed = now - self.lastPing
                var shouldReport = false
                if elapsed > self.threshold && !self.reported {
                    self.reported = true
                    shouldReport = true
                }
                self.lock.unlock()
                if shouldReport {
                    AgentLog.shared?.recordAuto(
                        eventType: .hang,
                        message: "main thread blocked \(Int(elapsed * 1000))ms",
                        payload: ["duration_ms": .int(Int(elapsed * 1000))])
                }
            }
        }
        t.name = "AgentLog.HangMonitor"
        t.stackSize = 512 * 1024
        t.start()
        thread = t
    }
}
