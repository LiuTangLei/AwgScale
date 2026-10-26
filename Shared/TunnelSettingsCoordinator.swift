import Foundation

enum TunnelSettingsError: Error, LocalizedError, Equatable {
    case cancelled
    case superseded
    case timedOut

    var errorDescription: String? {
        switch self {
        case .cancelled: return "VPN network configuration was cancelled."
        case .superseded: return "VPN network configuration was replaced by a newer update."
        case .timedOut: return "iOS did not finish applying VPN network settings. Reconnect to try again."
        }
    }
}

/// Serializes the asynchronous system settings API and bounds each request's lifetime.
/// Hooks run on the private queue and must not block. Completions run on completionQueue.
final class TunnelSettingsCoordinator<Value> {
    typealias Generation = UUID
    typealias Completion = (Error?) -> Void

    private struct Request {
        let id = UUID()
        let generation: Generation
        let value: Value
        let completion: Completion?
    }

    private let queue = DispatchQueue(label: "top.yesican.awgscale.tunnel-settings")
    private let queueKey = DispatchSpecificKey<Void>()
    private let completionQueue: DispatchQueue
    private let timeout: TimeInterval
    private let apply: (Value, @escaping Completion) -> Void
    private let didApply: (Value) -> Void
    private let activityChanged: (Bool) -> Void
    private let didFail: (Error, Generation) -> Void
    private var generation = Generation()
    private var stopped = true
    private var inFlight: Request?
    private var pending: Request?
    private var deadline: DispatchWorkItem?

    init(timeout: TimeInterval = 15,
         completionQueue: DispatchQueue = .main,
         apply: @escaping (Value, @escaping Completion) -> Void,
         didApply: @escaping (Value) -> Void,
         activityChanged: @escaping (Bool) -> Void,
         didFail: @escaping (Error, Generation) -> Void) {
        self.timeout = timeout
        self.completionQueue = completionQueue
        self.apply = apply
        self.didApply = didApply
        self.activityChanged = activityChanged
        self.didFail = didFail
        queue.setSpecific(key: queueKey, value: ())
    }

    deinit { deadline?.cancel() }

    @discardableResult
    func begin() -> Generation {
        synchronized {
            cancelRequests()
            generation = Generation()
            stopped = false
            return generation
        }
    }

    func stop() {
        synchronized {
            stopped = true
            cancelRequests()
            // Invalidate failure cleanup already queued for the old session too.
            generation = Generation()
        }
    }

    var isStopped: Bool { synchronized { stopped } }
    var currentGeneration: Generation { synchronized { generation } }

    func isCurrent(_ candidate: Generation) -> Bool {
        synchronized { generation == candidate }
    }

    func isActive(_ candidate: Generation) -> Bool {
        synchronized { generation == candidate && !stopped }
    }

    func enqueue(_ value: Value, generation: Generation, completion: Completion? = nil) {
        let request = Request(generation: generation, value: value, completion: completion)
        queue.async { [self] in
            guard self.generation == generation, !stopped else {
                deliver(request, error: TunnelSettingsError.cancelled)
                return
            }
            if inFlight != nil {
                if let previous = pending {
                    deliver(previous, error: TunnelSettingsError.superseded)
                }
                pending = request
            } else {
                perform(request)
            }
        }
    }

    private func perform(_ request: Request) {
        inFlight = request
        activityChanged(true)
        let deadline = DispatchWorkItem { [weak self] in
            self?.finish(request, error: TunnelSettingsError.timedOut)
        }
        self.deadline = deadline
        queue.asyncAfter(deadline: .now() + timeout, execute: deadline)
        apply(request.value) { [weak self] error in
            self?.queue.async { [weak self] in self?.finish(request, error: error) }
        }
    }

    private func finish(_ request: Request, error: Error?) {
        guard generation == request.generation, !stopped, inFlight?.id == request.id else { return }
        deadline?.cancel()
        deadline = nil
        inFlight = nil
        if let error {
            stopped = true
            cancelRequests()
            didFail(error, request.generation)
            deliver(request, error: error)
            return
        }

        didApply(request.value)
        deliver(request, error: nil)
        if let next = pending {
            pending = nil
            perform(next)
        } else {
            activityChanged(false)
        }
    }

    private func cancelRequests() {
        deadline?.cancel()
        deadline = nil
        let cancelled = [inFlight, pending].compactMap { $0 }
        inFlight = nil
        pending = nil
        activityChanged(false)
        cancelled.forEach { deliver($0, error: TunnelSettingsError.cancelled) }
    }

    private func deliver(_ request: Request, error: Error?) {
        guard let completion = request.completion else { return }
        completionQueue.async { [weak self] in
            // Success queued before stop/restart must not revive the old session.
            if error == nil, self?.isActive(request.generation) != true {
                completion(TunnelSettingsError.cancelled)
            } else {
                completion(error)
            }
        }
    }

    private func synchronized<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return body() }
        return queue.sync(execute: body)
    }
}
