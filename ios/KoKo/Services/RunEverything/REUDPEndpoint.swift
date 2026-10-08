import Foundation
import Network
import Darwin

enum REUDP {
    static let magic0: UInt8 = 0x52 // 'R'
    static let magic1: UInt8 = 0x55 // 'U'
    static let version: UInt8 = 0x01
    static let headerSize = 20
    static let maxPayload = 1200

    enum PType {
        static let assoc: UInt8 = 0x01
        static let assocOK: UInt8 = 0x02
        static let data: UInt8 = 0x10
        static let ack: UInt8 = 0x11
        static let ping: UInt8 = 0x1E
        static let pong: UInt8 = 0x1F
        static let error: UInt8 = 0x20
    }

    enum Flag {
        static let reliable: UInt8 = 1 << 0
        static let fin: UInt8 = 1 << 1
        static let latest: UInt8 = 1 << 2
    }

    /// FNV-1a 32-bit over UTF-8 device_id (matches Go hash/fnv).
    static func routeHash(_ deviceID: String) -> UInt32 {
        var hash: UInt32 = 2166136261
        for b in deviceID.utf8 {
            hash ^= UInt32(b)
            hash &*= 16777619
        }
        return hash
    }

    struct Packet {
        var type: UInt8
        var flags: UInt8 = 0
        var routeHash: UInt32
        var seq: UInt32 = 0
        var ack: UInt32 = 0
        var payload: Data

        func encode() throws -> Data {
            guard payload.count <= maxPayload else { throw RE2Error.udp("payload too large") }
            var out = Data(capacity: headerSize + payload.count)
            out.append(magic0)
            out.append(magic1)
            out.append(version)
            out.append(type)
            out.append(flags)
            out.append(0) // rsv
            out.appendUInt32BE(routeHash)
            out.appendUInt32BE(seq)
            out.appendUInt32BE(ack)
            out.appendUInt16BE(UInt16(payload.count))
            out.append(payload)
            return out
        }

        static func decode(_ data: Data) throws -> Packet {
            guard data.count >= headerSize else { throw RE2Error.udp("short packet") }
            guard data[0] == magic0, data[1] == magic1 else { throw RE2Error.udp("bad magic") }
            guard data[2] == version else { throw RE2Error.udp("bad version") }
            let plen = Int(data.readUInt16BE(at: 18))
            guard plen <= maxPayload, data.count >= headerSize + plen else { throw RE2Error.udp("bad plen") }
            return Packet(
                type: data[3],
                flags: data[4],
                routeHash: data.readUInt32BE(at: 6),
                seq: data.readUInt32BE(at: 10),
                ack: data.readUInt32BE(at: 14),
                payload: Data(data[headerSize..<(headerSize + plen)])
            )
        }
    }
}

/// Client-side REUDP endpoint (ASSOC + reliable/unreliable DATA).
final class REUDPEndpoint: @unchecked Sendable {
    /// A 5K IDR can exceed 400 datagrams. Keep at least two complete bursts so
    /// control-priority draining does not evict the first half of the picture.
    private static let maxVideoQueue = 1024
    private let connection: NWConnection
    /// Outbound direct path to Agent (LAN / punched peer).
    private var directOut: NWConnection?
    /// Inbound unconnected listener — required so Agent REHP1 / PreferDirect DATA can reach us.
    private var directListener: NWListener?
    private var preferDirect = false
    /// While true and PreferDirect is latched, also copy DATA to the relay socket
    /// (Noise msg1 fan-out — Agent may only answer on one path).
    private var fanoutRelayWhileDirect = false
    private(set) var localHostPort: String = ""
    /// host:port of the direct inbound listener (for hole-punch offer / connected).
    private(set) var directListenHostPort: String = ""
    private let queue = DispatchQueue(label: "reudp.endpoint")
    private var routeHash: UInt32 = 0
    private var nextSeq: UInt32 = 0
    private var nextExpect: UInt32 = 0
    private var inflight: [UInt32: (data: Data, sentAt: Date, retries: Int)] = [:]
    private var recvBuf: [UInt32: Data] = [:]
    /// Split queues: video-plane IDRs used to share one 512-cap buffer with Noise
    /// control. Under PreferDirect the oldest slots (FileList/ACK replies) were
    /// discarded while video kept flowing — MENU-07/08 saw TX OK / RX silence.
    private var incomingControl = [Data]()
    private var incomingVideo = [Data]()
    private var incomingWaiters: [CheckedContinuation<Data, Error>] = []
    private var assocWaiter: CheckedContinuation<[String: Any], Error>?
    /// Re-send ASSOC on the same socket when reliable traffic is unacknowledged.
    /// Cellular NAT/relay route bindings can change while the NWConnection itself
    /// remains `.ready`, producing a one-way stream (video in, input/control out).
    private var assocRefreshPacket: Data?
    private var lastAssocRefreshAt: Date?
    private var closed = false
    private var retransmitTimer: DispatchSourceTimer?
    private var startContinuation: CheckedContinuation<Void, Error>?

    /// Pop next Noise/control datagram only (never video). Used by file-plane waiters
    /// to drain Agent replies when the normal recv loop is starved.
    func popControl() -> Data? {
        queue.sync {
            guard !incomingControl.isEmpty else { return nil }
            return incomingControl.removeFirst()
        }
    }

    /// Debug snapshot for file-plane timeouts (control vs video backlog / HOL).
    func debugIngressSnapshot() -> String {
        queue.sync {
            "ctrl=\(incomingControl.count) vid=\(incomingVideo.count) recvBuf=\(recvBuf.count) nextExpect=\(nextExpect) waiters=\(incomingWaiters.count)"
        }
    }

    /// Prefer Noise/control over video-plane when both are buffered.
    private func dequeueIncoming() -> Data? {
        if !incomingControl.isEmpty {
            return incomingControl.removeFirst()
        }
        if !incomingVideo.isEmpty {
            return incomingVideo.removeFirst()
        }
        return nil
    }

    init(hostPort: String) throws {
        let parts = hostPort.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let port = NWEndpoint.Port(parts[1]) else {
            throw RE2Error.udp("bad udp host:port \(hostPort)")
        }
        let host = NWEndpoint.Host(parts[0])
        connection = NWConnection(host: host, port: port, using: .udp)
    }

    var usingDirect: Bool {
        queue.sync { preferDirect && directOut != nil }
    }

    /// Reset reliable seq/ACK after a new Noise session (must match Agent).
    func resetReliableSession() {
        queue.sync {
            self.nextSeq = 0
            self.nextExpect = 0
            self.inflight.removeAll()
            self.recvBuf.removeAll()
        }
    }

    /// Fan-out reliable/unreliable DATA to relay while PreferDirect is latched.
    func setNoiseFanout(_ enabled: Bool) {
        queue.async { self.fanoutRelayWhileDirect = enabled }
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            startContinuation = cont
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    if let path = self.connection.currentPath,
                       let local = path.localEndpoint,
                       case .hostPort(let host, let port) = local {
                        self.localHostPort = "\(host):\(port)"
                    }
                    self.startReceiveLoop(on: self.connection)
                    self.startRetransmitLoop()
                    if let c = self.startContinuation {
                        self.startContinuation = nil
                        c.resume()
                    }
                    self.connection.stateUpdateHandler = { state in
                        if case .failed(let err) = state {
                            self.failAll(err)
                        }
                    }
                case .failed(let err):
                    if let c = self.startContinuation {
                        self.startContinuation = nil
                        c.resume(throwing: err)
                    }
                case .cancelled:
                    if let c = self.startContinuation {
                        self.startContinuation = nil
                        c.resume(throwing: RE2Error.cancelled)
                    }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    /// Start inbound UDP listener for Agent hole-punch + PreferDirect DATA.
    @discardableResult
    func ensureDirectListener() async -> String {
        if !directListenHostPort.isEmpty { return directListenHostPort }
        return await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            self.queue.async(execute: {
                if !self.directListenHostPort.isEmpty {
                    cont.resume(returning: self.directListenHostPort)
                    return
                }
                guard let listener = try? NWListener(using: .udp) else {
                    cont.resume(returning: "")
                    return
                }
                self.directListener = listener
                var resumed = false
                listener.newConnectionHandler = { [weak self] conn in
                    guard let self else { return }
                    conn.start(queue: self.queue)
                    self.receiveDirect(on: conn)
                }
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    if case .ready = state {
                        let port = listener.port?.rawValue ?? 0
                        let ip = Self.primaryPrivateIPv4() ?? "0.0.0.0"
                        if port > 0 {
                            self.directListenHostPort = "\(ip):\(port)"
                        }
                        if !resumed {
                            resumed = true
                            cont.resume(returning: self.directListenHostPort)
                        }
                    } else if case .failed = state, !resumed {
                        resumed = true
                        cont.resume(returning: "")
                    }
                }
                listener.start(queue: self.queue)
            })
        }
    }

    /// Switch media DATA/ACK writes to a punched peer; inbound stays on directListener.
    func preferDirect(hostPort: String) async throws {
        let parts = hostPort.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[1] != "0", let port = NWEndpoint.Port(parts[1]) else {
            throw RE2Error.udp("bad direct peer \(hostPort)")
        }
        _ = await ensureDirectListener()
        let conn = NWConnection(host: NWEndpoint.Host(parts[0]), port: port, using: .udp)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                self.directOut?.cancel()
                self.directOut = conn
                var resumed = false
                conn.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        self.preferDirect = true
                        // Also receive on outbound conn (some stacks deliver replies here).
                        self.startReceiveLoop(on: conn)
                        if !resumed { resumed = true; cont.resume() }
                    case .failed(let err):
                        if !resumed { resumed = true; cont.resume(throwing: err) }
                    case .cancelled:
                        if !resumed { resumed = true; cont.resume(throwing: RE2Error.cancelled) }
                    default:
                        break
                    }
                }
                conn.start(queue: self.queue)
            }
        }
    }

    func clearDirect() {
        queue.async {
            self.preferDirect = false
            self.directOut?.cancel()
            self.directOut = nil
        }
    }

    func close() {
        queue.async {
            self.closed = true
            self.retransmitTimer?.cancel()
            self.directOut?.cancel()
            self.directOut = nil
            self.directListener?.cancel()
            self.directListener = nil
            self.preferDirect = false
            self.directListenHostPort = ""
            self.connection.cancel()
            let waiters = self.incomingWaiters
            self.incomingWaiters.removeAll()
            waiters.forEach { $0.resume(throwing: RE2Error.cancelled) }
            if let w = self.assocWaiter {
                self.assocWaiter = nil
                w.resume(throwing: RE2Error.cancelled)
            }
        }
    }

    func assocClient(deviceID: String, sessionTicket: String, timeout: TimeInterval = 15) async throws {
        routeHash = REUDP.routeHash(deviceID)
        let body = RE2Codec.jsonData([
            "role": "client",
            "device_id": deviceID,
            "session_ticket": sessionTicket
        ])
        let encoded = try REUDP.Packet(type: REUDP.PType.assoc, routeHash: routeHash, payload: body).encode()
        queue.sync {
            self.assocRefreshPacket = encoded
            self.lastAssocRefreshAt = Date()
        }

        // Retransmit ASSOC while waiting — volunteer-relay UDP is often lossy.
        let ok: [String: Any] = try await withThrowingTaskGroup(of: [String: Any].self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String: Any], Error>) in
                    self.queue.async {
                        self.assocWaiter = cont
                    }
                }
            }
            group.addTask {
                let deadline = Date().addingTimeInterval(timeout)
                while Date() < deadline {
                    if Task.isCancelled { throw CancellationError() }
                    try await self.sendBytes(encoded)
                    try await Task.sleep(nanoseconds: 800_000_000)
                }
                await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                    self.queue.async {
                        if let w = self.assocWaiter {
                            self.assocWaiter = nil
                            w.resume(throwing: RE2Error.udp("ASSOC timeout"))
                        }
                        done.resume()
                    }
                }
                throw RE2Error.udp("ASSOC timeout")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
        if let okFlag = ok["ok"] as? Bool, !okFlag {
            throw RE2Error.udp("ASSOC rejected")
        }
    }

    func sendReliable(_ payload: Data) async throws {
        try await sendData(payload, flags: REUDP.Flag.reliable)
    }

    func sendUnreliable(_ payload: Data) async throws {
        try await sendData(payload, flags: 0)
    }

    func reliableDebugSnapshot() async -> String {
        await withCheckedContinuation { cont in
            queue.async {
                let maxRetries = self.inflight.values.map(\.retries).max() ?? 0
                cont.resume(returning: "inflight=\(self.inflight.count) maxRetries=\(maxRetries) nextSeq=\(self.nextSeq) nextExpect=\(self.nextExpect) direct=\(self.preferDirect)")
            }
        }
    }

    /// Fire-and-forget unreliable DATA — do not wait for NW `contentProcessed`.
    /// Used for phone-cam VideoMedia bursts so multipart frames are not paced
    /// by per-datagram ACK of the local UDP stack (multi-second glass latency).
    func sendUnreliableBestEffort(_ payload: Data) {
        queue.async {
            do {
                let ack: UInt32 = self.nextExpect > 0 ? self.nextExpect &- 1 : UInt32.max
                let pkt = REUDP.Packet(
                    type: REUDP.PType.data,
                    flags: 0,
                    routeHash: self.routeHash,
                    seq: 0,
                    ack: ack,
                    payload: payload
                )
                let data = try pkt.encode()
                let relay = self.connection
                if self.preferDirect, let d = self.directOut {
                    if self.fanoutRelayWhileDirect {
                        relay.send(content: data, completion: .contentProcessed { _ in })
                    }
                    d.send(content: data, completion: .contentProcessed { _ in })
                } else {
                    relay.send(content: data, completion: .contentProcessed { _ in })
                }
            } catch {
                // Best-effort — drop on encode failure.
            }
        }
    }

    func sendLatest(_ payload: Data) async throws {
        try await sendData(payload, flags: REUDP.Flag.latest)
    }

    func recv() async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                if let data = self.dequeueIncoming() {
                    cont.resume(returning: data)
                } else {
                    self.incomingWaiters.append(cont)
                }
            }
        }
    }

    func recv(timeout: TimeInterval) async throws -> Data {
        // Must fail the continuation waiter on timeout — otherwise TaskGroup cleanup
        // waits forever on recv() and UI sticks on "Encrypting…".
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await self.recv() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self.failIncomingWaiters(RE2Error.udp("recv timeout"))
                throw RE2Error.udp("recv timeout")
            }
            do {
                let first = try await group.next()!
                group.cancelAll()
                return first
            } catch {
                group.cancelAll()
                await failIncomingWaiters(error)
                throw error
            }
        }
    }

    private func failIncomingWaiters(_ error: Error) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async {
                let waiters = self.incomingWaiters
                self.incomingWaiters.removeAll()
                waiters.forEach { $0.resume(throwing: error) }
                done.resume()
            }
        }
    }

    // MARK: - private

    private func sendData(_ payload: Data, flags: UInt8) async throws {
        let (seq, ack, packetData): (UInt32, UInt32, Data) = try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let seq: UInt32
                    if flags & REUDP.Flag.reliable != 0 {
                        seq = self.nextSeq
                        self.nextSeq &+= 1
                    } else {
                        // Must not consume reliable seq — see Agent reudp.sendData.
                        seq = 0
                    }
                    let ack: UInt32 = self.nextExpect > 0 ? self.nextExpect &- 1 : UInt32.max
                    let pkt = REUDP.Packet(
                        type: REUDP.PType.data,
                        flags: flags,
                        routeHash: self.routeHash,
                        seq: seq,
                        ack: ack,
                        payload: payload
                    )
                    let data = try pkt.encode()
                    if flags & REUDP.Flag.reliable != 0 {
                        self.inflight[seq] = (data, Date(), 0)
                    }
                    cont.resume(returning: (seq, ack, data))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
        _ = seq
        _ = ack
        try await sendBytes(packetData)
    }

    private func sendRaw(_ packet: REUDP.Packet) async throws {
        let data = try packet.encode()
        try await sendBytes(data)
    }

    private func sendBytes(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.queue.async {
                let relay = self.connection
                let fanout = self.fanoutRelayWhileDirect
                if self.preferDirect, let d = self.directOut {
                    // Always try LAN first; optionally also spray the same datagram on relay.
                    if fanout {
                        relay.send(content: data, completion: .contentProcessed { _ in })
                    }
                    d.send(content: data, completion: .contentProcessed { error in
                        if let error {
                            // Keep preferDirect — relay fan-out may still deliver.
                            if fanout {
                                relay.send(content: data, completion: .contentProcessed { err2 in
                                    if let err2 { cont.resume(throwing: err2) }
                                    else { cont.resume() }
                                })
                            } else {
                                self.preferDirect = false
                                relay.send(content: data, completion: .contentProcessed { err2 in
                                    if let err2 { cont.resume(throwing: err2) }
                                    else { cont.resume() }
                                })
                            }
                        } else {
                            cont.resume()
                        }
                    })
                } else {
                    relay.send(content: data, completion: .contentProcessed { error in
                        if let error { cont.resume(throwing: error) }
                        else { cont.resume() }
                    })
                }
            }
        }
    }

    private func receiveDirect(on conn: NWConnection) {
        conn.receiveMessage { [weak self] content, _, _, error in
            guard let self else { return }
            if let content {
                if content.count >= 6,
                   let s = String(data: content.prefix(64), encoding: .utf8),
                   s.hasPrefix("REHP1|") {
                    if !s.contains("pong") {
                        conn.send(content: Data("REHP1|pong".utf8), completion: .contentProcessed { _ in })
                    }
                } else {
                    self.queue.async { self.handleDatagram(content) }
                }
            }
            if error == nil, !self.closed {
                self.receiveDirect(on: conn)
            }
        }
    }

    private func startReceiveLoop(on conn: NWConnection) {
        conn.receiveMessage { [weak self] content, _, _, error in
            guard let self else { return }
            if let content {
                self.queue.async { self.handleDatagram(content) }
            }
            if error == nil, !self.closed {
                self.startReceiveLoop(on: conn)
            }
        }
    }

    private func handleDatagram(_ data: Data) {
        guard let pkt = try? REUDP.Packet.decode(data) else { return }
        switch pkt.type {
        case REUDP.PType.assocOK:
            let obj = RE2Codec.jsonObject(pkt.payload)
            if let w = assocWaiter {
                assocWaiter = nil
                w.resume(returning: obj)
            }
        case REUDP.PType.ack:
            if pkt.payload.count >= 4 {
                let cum = pkt.payload.readUInt32BE(at: 0)
                let sack = pkt.payload.count >= 12 ? pkt.payload.readUInt64BE(at: 4) : 0
                handleAck(cum, sack: sack)
            }
        case REUDP.PType.data:
            // Zero validly acknowledges reliable sequence 0; UInt32.max is the
            // explicit "nothing received" sentinel.
            handleAck(pkt.ack, sack: 0)
            handleData(pkt)
        case REUDP.PType.ping:
            let pong = REUDP.Packet(type: REUDP.PType.pong, routeHash: routeHash, payload: pkt.payload)
            if let data = try? pong.encode() {
                connection.send(content: data, completion: .contentProcessed { _ in })
            }
        case REUDP.PType.error:
            let obj = RE2Codec.jsonObject(pkt.payload)
            let msg = (obj["message"] as? String) ?? (obj["code"] as? String) ?? "udp error"
            if let w = assocWaiter {
                assocWaiter = nil
                w.resume(throwing: RE2Error.udp(msg))
            }
        default:
            break
        }
    }

    private func handleAck(_ cum: UInt32, sack: UInt64) {
        let base = cum &+ 1 // UInt32.max sentinel wraps to sequence zero.
        let acknowledgedAfterRetries = inflight.contains { seq, info in
            let cumulative = cum != UInt32.max && seq <= cum
            let delta = seq &- base
            let selective = delta < 64 && sack & (UInt64(1) << UInt64(delta)) != 0
            return (cumulative || selective) && info.retries >= 5
        }
        inflight = inflight.filter { seq, _ in
            if cum != UInt32.max, seq <= cum { return false }
            let delta = seq &- base
            if delta < 64, sack & (UInt64(1) << UInt64(delta)) != 0 { return false }
            return true
        }
        // A direct uplink can die while Agent→phone video still arrives. If an ACK
        // only appears after relay fan-out began, route future low-latency input
        // through relay too instead of continuing to send moves to a stale tuple.
        if preferDirect, acknowledgedAfterRetries {
            preferDirect = false
        }
    }

    private func handleData(_ pkt: REUDP.Packet) {
        if pkt.flags & REUDP.Flag.reliable == 0 {
            deliver(pkt.payload)
            return
        }
        if pkt.seq < nextExpect {
            sendAck(nextExpect &- 1)
            return
        }
        recvBuf[pkt.seq] = pkt.payload
        while let body = recvBuf[nextExpect] {
            recvBuf.removeValue(forKey: nextExpect)
            nextExpect &+= 1
            deliver(body)
        }
        if nextExpect > 0 {
            sendAck(nextExpect &- 1)
        }
    }

    private func sendAck(_ cum: UInt32) {
        let actualCum = nextExpect == 0 ? UInt32.max : cum
        var sack: UInt64 = 0
        for seq in recvBuf.keys {
            let delta = seq &- nextExpect
            if delta < 64 {
                sack |= UInt64(1) << UInt64(delta)
            }
        }
        var payload = Data()
        payload.appendUInt32BE(actualCum)
        payload.appendUInt64BE(sack)
        let pkt = REUDP.Packet(type: REUDP.PType.ack, routeHash: routeHash, ack: actualCum, payload: payload)
        if let data = try? pkt.encode() {
            let target = (preferDirect ? directOut : nil) ?? connection
            target.send(content: data, completion: .contentProcessed { _ in })
        }
    }

    private func deliver(_ data: Data) {
        if !incomingWaiters.isEmpty {
            // Prefer handing control to a waiter immediately; if this is video and
            // more control is already queued, keep video buffered and feed control.
            if RE2VideoMedia.isVideoPlane(data), !incomingControl.isEmpty {
                incomingVideo.append(data)
                if incomingVideo.count > Self.maxVideoQueue {
                    incomingVideo.removeFirst(incomingVideo.count - Self.maxVideoQueue)
                }
                let w = incomingWaiters.removeFirst()
                w.resume(returning: incomingControl.removeFirst())
                return
            }
            let w = incomingWaiters.removeFirst()
            w.resume(returning: data)
            return
        }
        if RE2VideoMedia.isVideoPlane(data) {
            incomingVideo.append(data)
            // Latest-wins for video — never evict Noise/control for IDR spray.
            if incomingVideo.count > Self.maxVideoQueue {
                incomingVideo.removeFirst(incomingVideo.count - Self.maxVideoQueue)
            }
        } else {
            incomingControl.append(data)
            if incomingControl.count > 256 {
                // Extremely defensive — dropping control desyncs Noise; keep newest.
                incomingControl.removeFirst(incomingControl.count - 256)
            }
        }
    }

    private func startRetransmitLoop() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.05, repeating: 0.05)
        t.setEventHandler { [weak self] in
            guard let self, !self.closed else { return }
            let now = Date()
            let target = (self.preferDirect ? self.directOut : nil) ?? self.connection
            if !self.preferDirect,
               self.inflight.values.contains(where: { $0.retries >= 5 }),
               let assoc = self.assocRefreshPacket,
               self.lastAssocRefreshAt.map({ now.timeIntervalSince($0) >= 2 }) ?? true {
                // Always refresh through the relay connection, then retry the
                // outstanding DATA below. ASSOC_OK is harmless without a waiter.
                self.connection.send(content: assoc, completion: .contentProcessed { _ in })
                self.lastAssocRefreshAt = now
            }
            for (seq, var inf) in self.inflight {
                // Keep retransmitting while unacked (matches Agent) — volunteer relays
                // drop heavily; giving up HOL-blocks OPEN / keyframe / hole-punch.
                let gap: TimeInterval = inf.retries > 10 ? 0.5 : 0.2
                if now.timeIntervalSince(inf.sentAt) > gap {
                    target.send(content: inf.data, completion: .contentProcessed { _ in })
                    // A punched "direct" path can be asymmetric: Agent→phone video
                    // still arrives while phone→Agent control goes to a stale peer
                    // tuple. After a few unacked retries, duplicate the same REUDP
                    // sequence through the relay. Receiver dedup keeps Noise ordered.
                    if self.preferDirect, inf.retries >= 5 {
                        self.connection.send(content: inf.data, completion: .contentProcessed { _ in })
                    }
                    inf.sentAt = now
                    inf.retries += 1
                    self.inflight[seq] = inf
                }
            }
        }
        t.resume()
        retransmitTimer = t
    }

    private static func primaryPrivateIPv4() -> String? {
        var ptr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ptr) == 0, let first = ptr else { return nil }
        defer { freeifaddrs(first) }
        var cur: UnsafeMutablePointer<ifaddrs>? = first
        var found: String?
        while let c = cur {
            let flags = Int32(c.pointee.ifa_flags)
            if flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
               let sa = c.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(sa, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                let ip = String(cString: host)
                if ip.hasPrefix("192.168.") || ip.hasPrefix("10.") {
                    return ip
                }
                if ip.hasPrefix("172.") {
                    let parts = ip.split(separator: ".")
                    if parts.count >= 2, let second = Int(parts[1]), (16...31).contains(second) {
                        found = found ?? ip
                    }
                }
            }
            cur = c.pointee.ifa_next
        }
        return found
    }

    private func failAll(_ error: Error) {
        closed = true
        let waiters = incomingWaiters
        incomingWaiters.removeAll()
        waiters.forEach { $0.resume(throwing: error) }
        if let w = assocWaiter {
            assocWaiter = nil
            w.resume(throwing: error)
        }
    }
}
