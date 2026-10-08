import Foundation

/// WebSocket signaling client for RE2 PAIR / BIND on `/re2?role=client`.
///
/// All writes are serialized on `writeQueue`. Do **not** use MainActor-inherited
/// `Task` chains for sends — that deadlocked BIND ("Binding…" forever) when a
/// ping/pong write raced the handshake write on the same actor.
final class RE2SignalingClient: NSObject, URLSessionWebSocketDelegate {
    private var task: URLSessionWebSocketTask?
    private var session: URLSession!
    private var frameWaiters: [CheckedContinuation<RE2Frame, Error>] = []
    private var pendingFrames: [RE2Frame] = []
    private let lock = NSLock()
    private var openedCont: CheckedContinuation<Void, Error>?

    /// Serial outbound WebSocket sends (tunnel + ping/pong + BIND).
    private let writeQueue = DispatchQueue(label: "com.foqerhk.koko.re2.ws.write")
    private let maxPendingFrames = 96

    override init() {
        super.init()
        let cfg = URLSessionConfiguration.default
        // Pairing/BIND on cellular must fail fast — waitsForConnectivity left
        // "正在配对…" spinning while URLSession waited for a LAN relay forever.
        cfg.waitsForConnectivity = false
        cfg.timeoutIntervalForRequest = 12
        // A WebSocket is a long-lived resource. A 20s resource timeout killed
        // the BIND socket even while UDP video was healthy; the relay then
        // removed the peer route and video froze at the last frame.
        // Connect/read/write deadlines are enforced separately below.
        cfg.timeoutIntervalForResource = 24 * 60 * 60
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    func connect(relay: String) async throws {
        guard let url = RE2.clientWebSocketURL(relay: relay) else {
            throw RE2Error.signaling("bad relay URL")
        }
        lock.lock()
        openedCont = nil
        lock.unlock()
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()
        receiveLoop()
        // Wait for TCP/TLS+WS open (delegate). Never swallow ping errors — that
        // used to return "success" on a dead socket and hang Pairing/Binding.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    self.lock.lock()
                    self.openedCont = cont
                    self.lock.unlock()
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 8_000_000_000)
                throw RE2Error.signaling("WebSocket connect timeout")
            }
            do {
                _ = try await group.next()!
                group.cancelAll()
            } catch {
                group.cancelAll()
                close()
                throw error
            }
        }
    }

    func close() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        failWaiters(RE2Error.cancelled)
    }

    /// True when a WebSocket task is still attached (may still be half-open).
    var isOpen: Bool {
        lock.lock(); defer { lock.unlock() }
        return task != nil
    }

    /// Application-level keepalive so the relay does not idle-close during UDP/LAN bring-up.
    /// Fire-and-forget — never bridge `sendPing` through CheckedContinuation (URLSession
    /// may invoke the callback more than once → Swift resume assertion / SIGTRAP crash).
    func sendKeepalivePing() {
        task?.sendPing { _ in }
    }

    /// Unblock `readFrame` waiters without closing the WebSocket (deadline abort).
    func failPendingReads(_ error: Error) {
        failWaiters(error)
    }

    func writeFrame(_ frame: RE2Frame) async throws {
        let data = try frame.encode()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            writeQueue.async {
                guard let task = self.task else {
                    cont.resume(throwing: RE2Error.signaling("WebSocket closed"))
                    return
                }
                let box = SendBox()
                task.send(.data(data)) { error in
                    box.finish(error)
                }
                // Bound wait — URLSession can stall forever on a half-open socket.
                if !box.wait(seconds: 10) {
                    cont.resume(throwing: RE2Error.signaling("WebSocket send timeout"))
                    return
                }
                if let error = box.error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            }
        }
    }

    func readFrame(timeout: TimeInterval = 20) async throws -> RE2Frame {
        try await withThrowingTaskGroup(of: RE2Frame.self) { group in
            group.addTask { try await self.readFrameOnce() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self.failWaiters(RE2Error.signaling("frame timeout"))
                throw RE2Error.signaling("frame timeout")
            }
            do {
                let first = try await group.next()!
                group.cancelAll()
                return first
            } catch {
                group.cancelAll()
                failWaiters(error)
                throw error
            }
        }
    }

    private func readFrameOnce() async throws -> RE2Frame {
        try await withCheckedThrowingContinuation { cont in
            lock.lock()
            if !pendingFrames.isEmpty {
                let f = pendingFrames.removeFirst()
                lock.unlock()
                cont.resume(returning: f)
            } else {
                frameWaiters.append(cont)
                lock.unlock()
            }
        }
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        lock.lock()
        let c = openedCont
        openedCont = nil
        lock.unlock()
        c?.resume()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        let c = openedCont
        openedCont = nil
        lock.unlock()
        c?.resume(throwing: error ?? RE2Error.signaling("WebSocket closed"))
        if let error {
            failWaiters(error)
        }
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let err):
                self.failWaiters(err)
            case .success(let message):
                switch message {
                case .data(let data):
                    if let frame = try? RE2Frame.decode(data) {
                        self.deliver(frame)
                    }
                case .string(let s):
                    if let data = s.data(using: .utf8), let frame = try? RE2Frame.decode(data) {
                        self.deliver(frame)
                    }
                @unknown default:
                    break
                }
                self.receiveLoop()
            }
        }
    }

    private func deliver(_ frame: RE2Frame) {
        if frame.type == RE2.OuterType.ping {
            Task {
                try? await self.writeFrame(
                    RE2Frame(type: RE2.OuterType.pong, routeID: frame.routeID, payload: frame.payload)
                )
            }
            return
        }
        lock.lock()
        if !frameWaiters.isEmpty {
            let w = frameWaiters.removeFirst()
            lock.unlock()
            w.resume(returning: frame)
        } else {
            pendingFrames.append(frame)
            while pendingFrames.count > maxPendingFrames {
                pendingFrames.removeFirst()
            }
            lock.unlock()
        }
    }

    private func failWaiters(_ error: Error) {
        lock.lock()
        let ws = frameWaiters
        frameWaiters.removeAll()
        lock.unlock()
        ws.forEach { $0.resume(throwing: error) }
        if let c = openedCont {
            openedCont = nil
            c.resume(throwing: error)
        }
    }
}

/// Synchronize one WebSocket send completion onto the serial write queue.
private final class SendBox: @unchecked Sendable {
    private let lock = NSLock()
    private let sem = DispatchSemaphore(value: 0)
    private var done = false
    private(set) var error: Error?

    func finish(_ error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        self.error = error
        sem.signal()
    }

    func wait(seconds: TimeInterval) -> Bool {
        sem.wait(timeout: .now() + seconds) == .success
    }
}
