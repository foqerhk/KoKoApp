import Foundation
import Network
import Darwin

/// UDP hole-punch compatible with RunEverything `internal/holepunch` (REHP1|token).
enum RE2HolePunch {
    static let prefix = "REHP1|"

    /// Try to establish a direct UDP path to peer. Returns peer host:port on success.
    static func tryDirect(peerHostPort: String, token: String, timeout: TimeInterval = 3) async -> String? {
        let parts = peerHostPort.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[1] != "0", let port = NWEndpoint.Port(parts[1]) else { return nil }

        let msg = Data((prefix + token).utf8)

        return await withCheckedContinuation { cont in
            var resumed = false
            let queue = DispatchQueue(label: "re2.holepunch.probe")
            let probe = NWConnection(host: NWEndpoint.Host(parts[0]), port: port, using: .udp)

            func finish(_ value: String?) {
                guard !resumed else { return }
                resumed = true
                probe.cancel()
                cont.resume(returning: value)
            }

            probe.stateUpdateHandler = { state in
                if case .ready = state {
                    for i in 0..<12 {
                        queue.asyncAfter(deadline: .now() + Double(i) * 0.12) {
                            probe.send(content: msg, completion: .contentProcessed { _ in })
                        }
                    }
                } else if case .failed = state {
                    finish(nil)
                }
            }
            probe.receiveMessage { content, _, _, _ in
                defer {
                    if !resumed {
                        probe.receiveMessage { _, _, _, _ in }
                    }
                }
                guard let content, let s = String(data: content, encoding: .utf8), s.contains("pong") else { return }
                finish(peerHostPort)
            }
            probe.start(queue: queue)

            queue.asyncAfter(deadline: .now() + timeout) {
                finish(nil)
            }
        }
    }

    /// Local RFC1918 candidates with a real UDP port when available.
    static func localCandidates(preferredPortHint: String?) -> [String] {
        var out: [String] = []
        var port = 0
        if let hint = preferredPortHint {
            let parts = hint.split(separator: ":", maxSplits: 1)
            if parts.count == 2, let p = Int(parts[1]), p > 0 { port = p }
        }
        var ptr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ptr) == 0, let first = ptr else { return out }
        defer { freeifaddrs(first) }
        var cur: UnsafeMutablePointer<ifaddrs>? = first
        while let c = cur {
            let flags = Int32(c.pointee.ifa_flags)
            if flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
               let sa = c.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(sa, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                let ip = String(cString: host)
                if isPrivateIPv4(ip) {
                    out.append(port > 0 ? "\(ip):\(port)" : "\(ip):0")
                }
            }
            cur = c.pointee.ifa_next
        }
        return out
    }

    private static func isPrivateIPv4(_ host: String) -> Bool {
        if host.hasPrefix("10.") { return true }
        if host.hasPrefix("192.168.") { return true }
        if host.hasPrefix("172.") {
            let parts = host.split(separator: ".")
            if parts.count >= 2, let second = Int(parts[1]), (16...31).contains(second) {
                return true
            }
        }
        return false
    }
}
