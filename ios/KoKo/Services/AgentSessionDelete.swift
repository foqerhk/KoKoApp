import Citadel
import Foundation
import NIO
import NIOSSH

enum SessionDeleteStep: Equatable {
    case connecting
    case stoppingRemote
    case removingRemoteData
    case removingLocal
    case done
    case failed(String)

    var title: String {
        switch self {
        case .connecting:
            return String(localized: "Connecting to server…")
        case .stoppingRemote:
            return String(localized: "Stopping remote session…")
        case .removingRemoteData:
            return String(localized: "Removing remote session data…")
        case .removingLocal:
            return String(localized: "Removing local cache…")
        case .done:
            return String(localized: "Session deleted")
        case .failed:
            return String(localized: "Delete failed")
        }
    }

    var detailMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

enum AgentSessionDeleteError: LocalizedError {
    case missingHostOrProject
    case missingCredentials
    case remoteDeleteFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingHostOrProject:
            return String(localized: "Host or project path is missing")
        case .missingCredentials:
            return String(localized: "Host has no password or usable key")
        case .remoteDeleteFailed(let detail):
            return detail
        }
    }
}

/// Deletes an agent session on the server (stop + metadata) before the caller removes local cache.
enum AgentSessionDelete {
    static func deleteOnServer(
        session: TerminalSession,
        server: ServerProfile,
        projectPath: String,
        keyPair: SSHKeyPair?,
        onStep: @escaping @MainActor (SessionDeleteStep) -> Void,
        onHostKeyUnknown: (@Sendable (String) -> Void)? = nil
    ) async throws {
        guard server.isSSHConfigured, !projectPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentSessionDeleteError.missingHostOrProject
        }

        await onStep(.connecting)

        let auth: SSHAuthenticationMethod
        do {
            auth = try SSHAuthBuilder.makeAuthenticationMethod(profile: server, keyPair: keyPair)
        } catch {
            throw AgentSessionDeleteError.missingCredentials
        }

        let validator: SSHHostKeyValidator = .custom(
            TOFUHostKeyValidator(expectedFingerprint: server.hostKeyFingerprint) { fingerprint in
                onHostKeyUnknown?(fingerprint)
            }
        )

        let client: SSHClient
        do {
            client = try await SSHClient.connect(
                host: server.host,
                port: server.port,
                authenticationMethod: auth,
                hostKeyValidator: validator,
                reconnect: .never,
                algorithms: .all
            )
        } catch {
            throw AgentSessionDeleteError.remoteDeleteFailed(SSHErrorMapper.message(for: error))
        }
        defer { Task { try? await client.close() } }

        await onStep(.stoppingRemote)

        let script = deleteScript()
        let scriptB64 = Data(script.utf8).base64EncodedString()
        let chatArg = session.agentChatId ?? "-"
        let command = """
        echo \(scriptB64) | (base64 -d 2>/dev/null || base64 -D 2>/dev/null || base64 --decode) | python3 - \
        \(shellEscape(projectPath)) \(shellEscape(session.agentKind.rawValue)) \(shellEscape(chatArg)) \(shellEscape(session.remoteSessionName))
        """

        let outputData: ByteBuffer
        do {
            outputData = try await client.executeCommand(command, mergeStreams: true)
        } catch {
            throw AgentSessionDeleteError.remoteDeleteFailed(SSHErrorMapper.message(for: error))
        }

        await onStep(.removingRemoteData)

        let output = outputData.getString(at: outputData.readerIndex, length: outputData.readableBytes) ?? ""
        if output.contains("KOKO_DELETE_OK") {
            return
        }

        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw AgentSessionDeleteError.remoteDeleteFailed(
                String(localized: "Server did not confirm session deletion")
            )
        }
        throw AgentSessionDeleteError.remoteDeleteFailed(trimmed)
    }

    private static func deleteScript() -> String {
        """
        import json, hashlib, os, pathlib, shlex, shutil, subprocess, sys

        def real(p):
            try:
                return os.path.realpath(p)
            except Exception:
                return os.path.abspath(p)

        project = real(sys.argv[1] if len(sys.argv) > 1 else ".")
        kind = (sys.argv[2] if len(sys.argv) > 2 else "").strip().lower()
        chat_id = (sys.argv[3] if len(sys.argv) > 3 else "").strip()
        if chat_id in ("-", "none", "null"):
            chat_id = ""
        screen_name = (sys.argv[4] if len(sys.argv) > 4 else "").strip()

        errors = []

        def run_shell(cmd):
            try:
                subprocess.run(cmd, shell=True, timeout=30, check=False)
            except Exception as exc:
                errors.append(str(exc))

        if screen_name:
            quoted = shlex.quote(screen_name)
            run_shell(f"screen -S {quoted} -X quit 2>/dev/null || true")

        if kind == "cursor":
            if chat_id:
                chats_root = pathlib.Path.home() / ".cursor" / "chats"
                primary = chats_root / hashlib.md5(project.encode()).hexdigest() / chat_id
                if primary.is_dir():
                    shutil.rmtree(primary, ignore_errors=True)
                if chats_root.is_dir():
                    for workspace in chats_root.iterdir():
                        if not workspace.is_dir():
                            continue
                        target = workspace / chat_id
                        if target.is_dir():
                            shutil.rmtree(target, ignore_errors=True)
            run_shell("agent persist stop 2>/dev/null || true")
        elif kind == "claude" and chat_id:
            root = pathlib.Path.home() / ".claude" / "projects"
            if root.is_dir():
                for path in root.rglob(f"{chat_id}.jsonl"):
                    try:
                        path.unlink(missing_ok=True)
                    except Exception as exc:
                        errors.append(f"claude:{path}:{exc}")
        elif kind == "codex" and chat_id:
            target = pathlib.Path.home() / ".codex" / "sessions" / chat_id
            if target.is_dir():
                shutil.rmtree(target, ignore_errors=True)
        elif kind == "gemini" and chat_id:
            for sub in ["chats", "tmp"]:
                root = pathlib.Path.home() / ".gemini" / sub
                if not root.is_dir():
                    continue
                for path in root.rglob("*.json"):
                    try:
                        data = json.loads(path.read_text())
                    except Exception:
                        continue
                    if not isinstance(data, dict):
                        continue
                    sid = str(data.get("sessionId") or data.get("id") or "")
                    if sid == chat_id:
                        try:
                            path.unlink(missing_ok=True)
                        except Exception as exc:
                            errors.append(f"gemini:{path}:{exc}")

        if errors:
            print("KOKO_DELETE_FAIL")
            print(json.dumps(errors, ensure_ascii=False))
            sys.exit(1)

        print("KOKO_DELETE_OK")
        """
    }

    private static func shellEscape(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
