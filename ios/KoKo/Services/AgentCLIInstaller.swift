import Citadel
import Foundation
import NIO

enum AgentCLIInstallError: LocalizedError {
    case installFailed(String)
    case npmBootstrapFailed(String)
    case outboundNetworkRestricted(agentName: String, detail: String?)

    var errorDescription: String? {
        switch self {
        case .installFailed(let detail):
            return detail
        case .npmBootstrapFailed(let detail):
            return detail
        case .outboundNetworkRestricted(let agentName, let detail):
            let message = String(
                format: String(
                    localized: "Server outbound network is restricted — cannot reach %@ install sources. Configure an HTTP/HTTPS proxy on the server, or install the CLI manually on a machine with internet access."
                ),
                agentName
            )
            var full = message
            if let detail, !detail.isEmpty {
                full += "\n" + detail
            }
            return full
        }
    }
}

/// Remote checks and one-shot install for agent CLIs before PTY attach.
/// All commands run on the **server over SSH** — the phone only sends shell commands.
enum AgentCLIInstaller {
    static func isInstalled(kind: AgentKind, using client: SSHClient) async throws -> Bool {
        let output = try await runRemote(RemoteBootstrap.agentInstalledCheckCommand(kind: kind), using: client)
        return output.contains(kind.cliSuccessToken)
    }

    static func isLoggedIn(kind: AgentKind, using client: SSHClient) async throws -> Bool {
        let output = try await runRemote(RemoteBootstrap.agentAuthCheckCommand(kind: kind), using: client)
        return output.contains(kind.authSuccessToken)
    }

    static func install(kind: AgentKind, using client: SSHClient) async throws {
        if kind.needsNpmBootstrap {
            try await ensureNpm(using: client)
        }

        let networkOutput = try await runRemote(RemoteBootstrap.outboundNetworkCheckCommand(kind: kind), using: client)
        if networkOutput.contains("NET_OUTBOUND_BLOCKED") {
            throw AgentCLIInstallError.outboundNetworkRestricted(agentName: kind.displayName, detail: nil)
        }

        let output = try await runRemote(RemoteBootstrap.agentInstallCommand(kind: kind), using: client)
        guard output.contains(kind.cliSuccessToken) else {
            let detail = sanitizedInstallOutput(output)
            if looksLikeNetworkFailure(detail) {
                throw AgentCLIInstallError.outboundNetworkRestricted(agentName: kind.displayName, detail: detail)
            }
            let message = detail.isEmpty
                ? String(format: String(localized: "%@ CLI install did not finish successfully on the server"), kind.displayName)
                : detail
            throw AgentCLIInstallError.installFailed(message)
        }
    }

    private static func ensureNpm(using client: SSHClient) async throws {
        let output = try await runRemote(RemoteBootstrap.npmBootstrapCommand(), using: client)
        guard output.contains("NPM_OK") else {
            let detail = sanitizedInstallOutput(output)
            let message = detail.isEmpty
                ? String(localized: "Could not install Node.js/npm on the server")
                : detail
            throw AgentCLIInstallError.npmBootstrapFailed(message)
        }
    }

    private static func looksLikeNetworkFailure(_ text: String) -> Bool {
        let lower = text.lowercased()
        let markers = [
            "could not resolve host",
            "connection timed out",
            "failed to connect",
            "network is unreachable",
            "connection refused",
            "name or service not known",
            "eai_again",
            "enotfound",
            "etimedout",
            "unable to access",
            "getaddrinfo",
            "curl: (6)",
            "curl: (7)",
            "curl: (28)",
            "npm err! code econnreset",
            "npm err! code enotfound",
            "npm err! network"
        ]
        return markers.contains { lower.contains($0) }
    }

    /// Collect stdout/stderr even when the remote command exits non-zero (Citadel throws otherwise).
    private static func runRemote(_ command: String, using client: SSHClient) async throws -> String {
        var result = ""
        let stream = try await client.executeCommandStream(command)
        do {
            for try await chunk in stream {
                switch chunk {
                case .stdout(let buffer), .stderr(let buffer):
                    if let text = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) {
                        result += text
                    }
                }
            }
        } catch let error as SSHClient.CommandFailed where result.isEmpty {
            result = String(
                format: String(localized: "Remote command failed (exit %lld)"),
                Int64(error.exitCode)
            )
        }
        return result
    }

    private static func sanitizedInstallOutput(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 4000 else { return trimmed }
        return String(trimmed.suffix(4000))
    }
}
