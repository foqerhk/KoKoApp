import Foundation
import UIKit

/// Headless connect probe for simulator (`-E2EAutoConnect` launch argument).
/// Writes `Documents/e2e-result.json` so the host machine can verify without UI taps.
@MainActor
enum E2EAutoConnect {
    static func runIfRequested(store: AppStore) {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-E2EAutoConnect") else { return }

        Task {
            var result: [String: Any] = [
                "startedAt": ISO8601DateFormatter().string(from: Date()),
                "ok": false
            ]
            defer { write(result) }

            guard let server = store.servers.first else {
                result["error"] = "no SSH host configured"
                return
            }
            guard let session = store.sessions.first(where: { $0.serverId == server.id }) else {
                result["error"] = "no session for host"
                return
            }
            let projectPath = store.project(for: session)?.remotePath ?? ""
            let keyPair = store.keyPair(for: server.keyPairId)

            result["server"] = "\(server.username)@\(server.host):\(server.port)"
            result["session"] = session.displayName
            result["projectPath"] = projectPath
            result["auth"] = server.authType.rawValue

            let workspace = WorkspaceRegistry.shared.workspace(for: session.id)
            var hostKeyApproved = false

            workspace.connect(
                server: server,
                keyPair: keyPair,
                session: session,
                projectPath: projectPath.isEmpty ? "/home/ubuntu/hkw" : projectPath,
                mode: .preferExisting,
                onHostKeyPrompt: { prompt in
                    store.saveHostKey(serverId: prompt.serverId, fingerprint: prompt.fingerprint)
                    workspace.approvePendingHostKey(serverId: prompt.serverId) { serverId, fingerprint in
                        store.saveHostKey(serverId: serverId, fingerprint: fingerprint)
                    }
                    hostKeyApproved = true
                },
                onHostKeySaved: { serverId, fingerprint in
                    store.saveHostKey(serverId: serverId, fingerprint: fingerprint)
                }
            )

            // Wait up to 35s for connected / failed.
            let deadline = Date().addingTimeInterval(35)
            while Date() < deadline {
                switch workspace.connectionState {
                case .connected:
                    result["connectionState"] = "connected"
                    result["hostKeyApproved"] = hostKeyApproved
                    result["localStatus"] = workspace.localStatusEvents.map(\.message)
                    // Probe stdin: write a unique marker the PTY should echo or ignore harmlessly.
                    let marker = "KOKO_E2E_\(Int(Date().timeIntervalSince1970))"
                    workspace.sendText("\necho \(marker)\n")
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    let scroll = ScrollbackStore.shared.load(sessionId: session.id).flatMap {
                        String(data: $0, encoding: .utf8)
                    } ?? ""
                    result["scrollbackBytes"] = scroll.utf8.count
                    result["scrollbackTail"] = String(scroll.suffix(800))
                    result["marker"] = marker
                    result["markerSeen"] = scroll.contains(marker)
                    result["ok"] = true
                    store.e2eOpenSessionId = session.id
                    // Leave session attached for manual inspection screenshots.
                    return
                case .failed(let message):
                    result["connectionState"] = "failed"
                    result["error"] = message
                    result["localStatus"] = workspace.localStatusEvents.map(\.message)
                    return
                case .ended:
                    result["connectionState"] = "ended"
                    result["localStatus"] = workspace.localStatusEvents.map(\.message)
                    return
                default:
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
            result["connectionState"] = String(describing: workspace.connectionState)
            result["error"] = "timeout waiting for connected"
            result["localStatus"] = workspace.localStatusEvents.map(\.message)
        }
    }

    private static func write(_ result: [String: Any]) {
        guard
            let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return }
        let url = docs.appendingPathComponent("e2e-result.json")
        try? data.write(to: url, options: .atomic)
        // Also mirror to a well-known shared path via NSLog for simctl log stream.
        if let text = String(data: data, encoding: .utf8) {
            NSLog("KOKO_E2E_RESULT %@", text)
        }
    }
}
