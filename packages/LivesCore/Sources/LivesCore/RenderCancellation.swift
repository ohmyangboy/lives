import Foundation

/// 每次生成独立持有；取消同时通知原生解码器、编码器与封面读取器。
public final class RenderCancellation: @unchecked Sendable {
    public enum Reason: Sendable { case user, timedOut, backgroundExpired }
    private let lock = NSLock()
    private var stopReason: Reason?
    private var handlers: [UUID: () -> Void] = [:]

    public init() {}

    public var reason: Reason? {
        lock.lock(); defer { lock.unlock() }
        return stopReason
    }

    public var failureMessage: String? {
        switch reason {
        case .timedOut: return "生成等待超时，请重试或降低画质。"
        case .backgroundExpired: return "生成因后台时间不足而中断，请保持 App 在前台后重试。"
        case .user, nil: return nil
        }
    }

    public func cancel(reason: Reason = .user) {
        lock.lock()
        guard stopReason == nil else { lock.unlock(); return }
        stopReason = reason
        let callbacks = Array(handlers.values)
        handlers.removeAll()
        lock.unlock()
        // cancelWriting 会等待原生收尾，不能阻塞点按取消的主线程。
        DispatchQueue.global(qos: .userInitiated).async {
            callbacks.forEach { $0() }
        }
    }

    @discardableResult
    func onCancel(_ handler: @escaping () -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        let stopped = stopReason != nil
        if !stopped { handlers[id] = handler }
        lock.unlock()
        if stopped { DispatchQueue.global(qos: .userInitiated).async(execute: handler) }
        return id
    }

    func removeHandler(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        handlers.removeValue(forKey: id)
    }

    public func check() throws {
        if let message = failureMessage { throw LivesCoreError.renderFailed(message) }
        if reason != nil { throw CancellationError() }
        try Task.checkCancellation()
    }

    public var isCancelled: Bool { reason != nil || Task.isCancelled }
}

/// 独立队列保证同步解码阻塞时仍能触发原生取消；资源在原生工作返回后释放。
final class RenderWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private let started = ProcessInfo.processInfo.systemUptime
    private var lastActivity = ProcessInfo.processInfo.systemUptime
    private var finished = false
    private let timer: DispatchSourceTimer

    init(cancellation: RenderCancellation, idleTimeout: TimeInterval = 60,
         totalTimeout: TimeInterval = 300, pollInterval: TimeInterval = 1) {
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "lives.render-deadline", qos: .utility))
        timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let now = ProcessInfo.processInfo.systemUptime
            let expired = !self.finished && (now - self.lastActivity >= idleTimeout || now - self.started >= totalTimeout)
            self.lock.unlock()
            if expired { cancellation.cancel(reason: .timedOut) }
        }
        timer.resume()
    }

    func recordActivity() {
        lock.lock(); defer { lock.unlock() }
        lastActivity = ProcessInfo.processInfo.systemUptime
    }

    func finish() {
        lock.lock()
        finished = true
        lock.unlock()
        timer.cancel()
    }

    deinit { timer.cancel() }
}
