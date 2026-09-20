import Citadel
import Foundation
import NIO
import NIOSSH

enum RemoteBootstrap {
    private static let pathPrefix = "export PATH=\"$HOME/.local/bin:$HOME/.npm-global/bin:/usr/local/bin:$PATH\""

    enum LaunchMode {
        case preferExisting
        case forceNew
    }

    static func shellCommand(
        projectPath: String,
        session: TerminalSession,
        mode: LaunchMode,
        useCursorAgent: Bool = true
    ) -> String {
        guard useCursorAgent else {
            return plainShellCommand(projectPath: projectPath)
        }

        switch session.agentKind {
        case .cursor:
            return cursorShellCommand(projectPath: projectPath, session: session, mode: mode)
        case .claude, .codex, .gemini:
            return screenShellCommand(projectPath: projectPath, session: session, mode: mode)
        }
    }

    private static func cursorShellCommand(
        projectPath: String,
        session: TerminalSession,
        mode: LaunchMode
    ) -> String {
        let escapedPath = shellEscape(projectPath)
        switch mode {
        case .preferExisting:
            if let chatId = session.agentChatId, !chatId.isEmpty {
                let escapedId = shellEscape(chatId)
                return "\(pathPrefix) && cd \(escapedPath) && (agent persist attach 2>/dev/null || exec agent persist --trust --resume=\(escapedId))\n"
            }
            return "\(pathPrefix) && cd \(escapedPath) && (agent persist attach 2>/dev/null || exec agent persist --trust)\n"
        case .forceNew:
            return "\(pathPrefix) && cd \(escapedPath) && (agent persist stop 2>/dev/null || true) && exec agent persist --trust\n"
        }
    }

    private static func screenShellCommand(
        projectPath: String,
        session: TerminalSession,
        mode: LaunchMode
    ) -> String {
        let escapedPath = shellEscape(projectPath)
        let screenName = shellEscape(session.remoteSessionName)
        let inner = agentStartCommand(kind: session.agentKind, session: session, mode: mode, projectPath: projectPath)
        let escapedInner = shellEscape(inner)

        if mode == .forceNew {
            return """
            \(pathPrefix) && (screen -S \(screenName) -X quit 2>/dev/null || true) && cd \(escapedPath) && exec screen -S \(screenName) -h 10000 bash -lc \(escapedInner)
            """
        }

        return """
        \(pathPrefix) && cd \(escapedPath) && if screen -ls 2>/dev/null | grep -Fq '.${session.remoteSessionName}'; then exec screen -x \(screenName); else exec screen -S \(screenName) -h 10000 bash -lc \(escapedInner); fi
        """
    }

    private static func agentStartCommand(
        kind: AgentKind,
        session: TerminalSession,
        mode: LaunchMode,
        projectPath: String
    ) -> String {
        let cd = "cd \(shellQuote(projectPath)) && "
        switch kind {
        case .cursor:
            return cd + "agent"
        case .claude:
            if mode == .preferExisting, let id = session.agentChatId, !id.isEmpty {
                return cd + "claude --resume \(shellQuote(id))"
            }
            return cd + "claude"
        case .codex:
            if mode == .preferExisting, let id = session.agentChatId, !id.isEmpty {
                return cd + "codex resume \(shellQuote(id))"
            }
            return cd + "codex"
        case .gemini:
            if mode == .preferExisting, let id = session.agentChatId, !id.isEmpty {
                return cd + "gemini --resume \(shellQuote(id))"
            }
            return cd + "gemini"
        }
    }

    static func cursorInstalledCheckCommand() -> String {
        agentInstalledCheckCommand(kind: .cursor)
    }

    static func cursorInstallCommand() -> String {
        agentInstallCommand(kind: .cursor)
    }

    static func agentInstalledCheckCommand(kind: AgentKind) -> String {
        let binary = shellEscape(kind.cliBinaryName)
        let token = kind.cliSuccessToken
        return "\(pathPrefix) && (command -v \(binary) >/dev/null && echo \(token) || true)"
    }

    static func agentInstallCommand(kind: AgentKind) -> String {
        let binary = shellEscape(kind.cliBinaryName)
        let token = kind.cliSuccessToken
        let body: String
        switch kind {
        case .cursor:
            body = "curl https://cursor.com/install -fsS | bash"
        case .claude:
            body = """
            if curl -fsSL https://claude.ai/install.sh | bash; then :; \
            elif command -v npm >/dev/null; then npm install -g @anthropic-ai/claude-code; \
            else echo 'Need curl or npm to install Claude Code' >&2; exit 1; fi
            """
        case .codex:
            body = """
            if curl -fsSL https://chatgpt.com/codex/install.sh | sh; then :; \
            elif command -v npm >/dev/null; then npm install -g @openai/codex; \
            else echo 'Need curl or npm to install Codex CLI' >&2; exit 1; fi
            """
        case .gemini:
            body = "npm install -g @google/gemini-cli"
        }
        return """
        \(pathPrefix); \
        install_log=$(mktemp 2>/dev/null || echo /tmp/koko-install-$$); \
        ( \(body) ) >"$install_log" 2>&1; \
        cat "$install_log"; rm -f "$install_log"; \
        if command -v \(binary) >/dev/null; then echo \(token); else echo \(token)_FAIL; fi
        """
    }

    /// Install Node.js + npm via the server package manager when npm is missing.
    static func npmBootstrapCommand() -> String {
        """
        \(pathPrefix); \
        if command -v npm >/dev/null 2>&1; then echo NPM_OK; exit 0; fi; \
        install_log=$(mktemp 2>/dev/null || echo /tmp/koko-npm-$$); \
        ( \
          if command -v apt-get >/dev/null 2>&1; then \
            export DEBIAN_FRONTEND=noninteractive; \
            if [ "$(id -u)" = "0" ]; then apt-get update -qq && apt-get install -y -qq nodejs npm; \
            elif sudo -n true 2>/dev/null; then sudo -n apt-get update -qq && sudo -n apt-get install -y -qq nodejs npm; \
            else echo 'Need root or passwordless sudo: sudo apt install -y nodejs npm' >&2; exit 1; fi; \
          elif command -v dnf >/dev/null 2>&1; then \
            if [ "$(id -u)" = "0" ]; then dnf install -y nodejs npm; \
            elif sudo -n true 2>/dev/null; then sudo -n dnf install -y nodejs npm; \
            else echo 'Need root or passwordless sudo: sudo dnf install -y nodejs npm' >&2; exit 1; fi; \
          elif command -v yum >/dev/null 2>&1; then \
            if [ "$(id -u)" = "0" ]; then yum install -y nodejs npm; \
            elif sudo -n true 2>/dev/null; then sudo -n yum install -y nodejs npm; \
            else echo 'Need root or passwordless sudo: sudo yum install -y nodejs npm' >&2; exit 1; fi; \
          elif command -v apk >/dev/null 2>&1; then \
            if [ "$(id -u)" = "0" ]; then apk add --no-cache nodejs npm; \
            elif sudo -n true 2>/dev/null; then sudo -n apk add --no-cache nodejs npm; \
            else echo 'Need root or passwordless sudo: sudo apk add nodejs npm' >&2; exit 1; fi; \
          else \
            echo 'No supported package manager (apt/dnf/yum/apk) for automatic npm install' >&2; exit 1; \
          fi \
        ) >"$install_log" 2>&1; \
        cat "$install_log"; rm -f "$install_log"; \
        if command -v npm >/dev/null 2>&1; then echo NPM_OK; else echo NPM_FAIL; fi
        """
    }

    /// Probe outbound HTTPS from the **server** (not the phone).
    static func outboundNetworkCheckCommand(kind: AgentKind) -> String {
        let check = "curl -fsSL -o /dev/null --connect-timeout 8 --max-time 15"
        switch kind {
        case .cursor:
            return """
            \(pathPrefix); \
            if \(check) https://cursor.com/install 2>/dev/null; then echo NET_OK; \
            else echo NET_OUTBOUND_BLOCKED; fi
            """
        case .claude:
            return """
            \(pathPrefix); \
            CL=0; NPM=0; \
            \(check) https://claude.ai/install.sh 2>/dev/null && CL=1; \
            \(check) https://registry.npmjs.org/ 2>/dev/null && NPM=1; \
            if [ "$CL" = "1" ] || [ "$NPM" = "1" ]; then echo NET_OK; else echo NET_OUTBOUND_BLOCKED; fi
            """
        case .codex:
            return """
            \(pathPrefix); \
            CX=0; NPM=0; \
            \(check) https://chatgpt.com/codex/install.sh 2>/dev/null && CX=1; \
            \(check) https://registry.npmjs.org/ 2>/dev/null && NPM=1; \
            if [ "$CX" = "1" ] || [ "$NPM" = "1" ]; then echo NET_OK; else echo NET_OUTBOUND_BLOCKED; fi
            """
        case .gemini:
            return """
            \(pathPrefix); \
            if \(check) https://registry.npmjs.org/ 2>/dev/null; then echo NET_OK; \
            else echo NET_OUTBOUND_BLOCKED; fi
            """
        }
    }

    static func agentAuthCheckCommand(kind: AgentKind) -> String {
        let binary = shellEscape(kind.cliBinaryName)
        let token = kind.authSuccessToken
        switch kind {
        case .cursor:
            return "\(pathPrefix) && command -v \(binary) >/dev/null && \(binary) status >/dev/null 2>&1 && echo \(token)"
        case .claude:
            return "\(pathPrefix) && command -v \(binary) >/dev/null && \(binary) auth status >/dev/null 2>&1 && echo \(token)"
        case .codex:
            return "\(pathPrefix) && command -v \(binary) >/dev/null && \(binary) login status >/dev/null 2>&1 && echo \(token)"
        case .gemini:
            return """
            \(pathPrefix) && command -v \(binary) >/dev/null && \
            if [ -f "$HOME/.gemini/oauth_creds.json" ] || [ -n "${GEMINI_API_KEY:-}" ]; then echo \(token); fi
            """
        }
    }

    static func agentLoginShellCommand(kind: AgentKind, projectPath: String) -> String {
        let escapedPath = shellEscape(projectPath)
        switch kind {
        case .cursor:
            return "\(pathPrefix) && cd \(escapedPath) && NO_OPEN_BROWSER=1 exec agent login\n"
        case .claude:
            return "\(pathPrefix) && cd \(escapedPath) && exec claude auth login\n"
        case .codex:
            return "\(pathPrefix) && cd \(escapedPath) && exec codex login --device-auth\n"
        case .gemini:
            return "\(pathPrefix) && cd \(escapedPath) && NO_BROWSER=true exec gemini\n"
        }
    }

    static func plainShellCommand(projectPath: String) -> String {
        let escapedPath = shellEscape(projectPath)
        return "\(pathPrefix) && cd \(escapedPath) && exec ${SHELL:-/bin/bash} -l\n"
    }

    static func killSessionCommand(session: TerminalSession) -> String {
        switch session.agentKind {
        case .cursor:
            return "\(pathPrefix) && (agent persist stop 2>/dev/null || true); exit\n"
        case .claude, .codex, .gemini:
            let name = shellEscape(session.remoteSessionName)
            return "\(pathPrefix) && (screen -S \(name) -X quit 2>/dev/null || true); exit\n"
        }
    }

    static func prerequisiteCheckCommand() -> String {
        agentAuthCheckCommand(kind: .cursor)
    }

    static func cursorLoginCommand() -> String {
        "\(pathPrefix) && cd \"$HOME\" && NO_OPEN_BROWSER=1 exec agent login\n"
    }

    static func shellEscape(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func shellQuote(_ value: String) -> String {
        shellEscape(value)
    }
}

enum LoginURLParser {
    private static let cursorHostSuffixes = [
        "authenticator.cursor.sh",
        "cursor.sh",
        "cursor.com"
    ]

    private static let claudeHostSuffixes = [
        "claude.ai",
        "claude.com",
        "platform.claude.com",
        "console.anthropic.com",
        "anthropic.com"
    ]

    private static let codexHostSuffixes = [
        "chatgpt.com",
        "openai.com",
        "auth.openai.com"
    ]

    private static let geminiHostSuffixes = [
        "accounts.google.com",
        "codeassist.google.com",
        "google.com"
    ]

    static func extract(from output: String, preferredKind: AgentKind? = nil) -> String? {
        for url in extractOSCHyperlinks(from: output) {
            if isAgentLoginURL(url, kind: preferredKind) {
                return url
            }
        }

        let cleaned = normalizeForURLScan(output)
        let patterns = [
            #"https://[^\s\x1b\]\"'<>]+"#,
            #"http://[^\s\x1b\]\"'<>]+"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = cleaned as NSString
            let range = NSRange(location: 0, length: ns.length)
            for match in regex.matches(in: cleaned, range: range) {
                var url = ns.substring(with: match.range)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                url = url.trimmingCharacters(in: CharacterSet(charactersIn: ".,;)]}>\"'"))
                if isAgentLoginURL(url, kind: preferredKind) {
                    return url
                }
            }
        }
        return nil
    }

    private static func extractOSCHyperlinks(from output: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\u{1b}\]8;;([^\u{07}\u{1b}]+)"#) else {
            return []
        }
        let ns = output as NSString
        let range = NSRange(location: 0, length: ns.length)
        return regex.matches(in: output, range: range).map {
            ns.substring(with: $0.range(at: 1))
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,;)]}>\"'"))
        }
    }

    private static func normalizeForURLScan(_ output: String) -> String {
        var cleaned = output.replacingOccurrences(of: "\u{1b}\\][^\u{07}]*(\u{07}|\u{1b}\\\\)", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "\u{1b}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "\r", with: "")
        // OAuth URLs are sometimes wrapped by the terminal UI.
        cleaned = cleaned.replacingOccurrences(of: "\n", with: "")
        cleaned = cleaned.replacingOccurrences(of: "\t", with: "")
        return cleaned
    }

    static func isAgentLoginURL(_ raw: String, kind: AgentKind? = nil) -> Bool {
        switch kind {
        case .cursor:
            return isCursorLoginURL(raw)
        case .claude:
            return isClaudeLoginURL(raw)
        case .codex:
            return isCodexLoginURL(raw)
        case .gemini:
            return isGeminiLoginURL(raw)
        case nil:
            return isCursorLoginURL(raw)
                || isClaudeLoginURL(raw)
                || isCodexLoginURL(raw)
                || isGeminiLoginURL(raw)
        }
    }

    static func isCursorLoginURL(_ raw: String) -> Bool {
        guard let url = URL(string: raw), let host = url.host?.lowercased() else { return false }
        let hostOK = cursorHostSuffixes.contains { host == $0 || host.hasSuffix(".\($0)") }
        guard hostOK else { return false }
        if host.contains("authenticator") { return true }
        let path = url.path.lowercased()
        let query = url.query?.lowercased() ?? ""
        return path.contains("login")
            || path.contains("auth")
            || path.contains("oauth")
            || query.contains("login")
            || query.contains("challenge")
            || query.contains("deeplink")
    }

    static func isClaudeLoginURL(_ raw: String) -> Bool {
        guard let url = URL(string: raw), let host = url.host?.lowercased() else { return false }
        let hostOK = claudeHostSuffixes.contains { host == $0 || host.hasSuffix(".\($0)") }
        guard hostOK else { return false }
        let path = url.path.lowercased()
        let query = url.query?.lowercased() ?? ""
        return path.contains("oauth")
            || path.contains("authorize")
            || path.contains("login")
            || query.contains("oauth")
            || query.contains("code=")
            || query.contains("code_challenge")
    }

    static func isCodexLoginURL(_ raw: String) -> Bool {
        guard let url = URL(string: raw), let host = url.host?.lowercased() else { return false }
        if host == "auth.openai.com" || host.hasSuffix(".auth.openai.com") {
            return true
        }
        let hostOK = codexHostSuffixes.contains { host == $0 || host.hasSuffix(".\($0)") }
        guard hostOK else { return false }
        let path = url.path.lowercased()
        let query = url.query?.lowercased() ?? ""
        return path.contains("oauth")
            || path.contains("login")
            || path.contains("auth")
            || path.contains("codex")
            || path.contains("device")
            || query.contains("oauth")
    }

    /// Codex device-auth one-time code, e.g. `K1SL-RL91A`.
    static func extractDeviceCode(from output: String, kind: AgentKind? = nil) -> String? {
        guard kind == nil || kind == .codex else { return nil }
        let cleaned = normalizeForURLScan(output)
        if let range = cleaned.range(of: "one-time code", options: .caseInsensitive) {
            let tail = String(cleaned[range.upperBound...])
            if let code = firstDeviceCode(in: tail) { return code }
        }
        if let range = cleaned.range(of: "device code", options: .caseInsensitive) {
            let tail = String(cleaned[range.upperBound...])
            if let code = firstDeviceCode(in: tail) { return code }
        }
        return nil
    }

    static func sanitizeDeviceCode(_ raw: String) -> String? {
        let upper = raw.uppercased()
        guard let regex = try? NSRegularExpression(pattern: #"([A-Z0-9]{4}-[A-Z0-9]{4,})"#) else {
            return nil
        }
        let ns = upper as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: upper, range: range), match.numberOfRanges > 1 else {
            return nil
        }
        return ns.substring(with: match.range(at: 1))
    }

    private static func firstDeviceCode(in text: String) -> String? {
        let clipped: String
        if let stop = text.range(of: "continue", options: .caseInsensitive) {
            clipped = String(text[..<stop.lowerBound])
        } else {
            clipped = text
        }
        return sanitizeDeviceCode(clipped)
    }

    static func isGeminiLoginURL(_ raw: String) -> Bool {
        guard let url = URL(string: raw), let host = url.host?.lowercased() else { return false }
        let hostOK = geminiHostSuffixes.contains { host == $0 || host.hasSuffix(".\($0)") }
        guard hostOK else { return false }
        if host.contains("accounts.google.com") || host.contains("codeassist.google.com") {
            return true
        }
        let path = url.path.lowercased()
        let query = url.query?.lowercased() ?? ""
        return path.contains("oauth") || path.contains("auth") || query.contains("oauth")
    }
}
