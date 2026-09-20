import Citadel
import Foundation
import NIO
import NIOSSH

enum PublicKeyInstallError: LocalizedError {
    case notSSHHost
    case missingCredentials
    case commandFailed(String)
    case enablePubkeyFailed(String)
    case verifyFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notSSHHost:
            return String(localized: "Only SSH hosts support public key install")
        case .missingCredentials:
            return String(localized: "Host has no password or usable key to connect with first")
        case .commandFailed(let detail):
            return detail
        case .enablePubkeyFailed(let detail):
            return String(localized: "Could not enable public-key login on the server") + ": " + detail
        case .verifyFailed(let detail):
            return String(
                format: String(localized: "Public key was written, but key login still failed: %@. Password login was kept."),
                detail
            )
        case .cancelled:
            return String(localized: "Cancelled")
        }
    }
}

enum PublicKeyInstallStep: Equatable {
    case connecting
    case waitingHostKey
    case authenticating
    case installing
    case enablingPubkeyAuth
    case verifying
    case updatingProfile
    case done
    case failed(String)

    var title: String {
        switch self {
        case .connecting: return String(localized: "Connecting to server…")
        case .waitingHostKey: return String(localized: "Confirm host fingerprint to continue…")
        case .authenticating: return String(localized: "Authenticating…")
        case .installing: return String(localized: "Writing authorized_keys…")
        case .enablingPubkeyAuth: return String(localized: "Enabling public-key login on server…")
        case .verifying: return String(localized: "Verifying key login…")
        case .updatingProfile: return String(localized: "Switching host to key login…")
        case .done: return String(localized: "Setup complete")
        case .failed: return String(localized: "Setup failed")
        }
    }

    var detailMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

/// Installs an OpenSSH public key into the login user's `~/.ssh/authorized_keys` over SSH,
/// and ensures the server accepts public-key authentication (`PubkeyAuthentication yes`).
enum PublicKeyInstaller {
    @discardableResult
    static func install(
        keyPair: SSHKeyPair,
        server: ServerProfile,
        existingKeyPair: SSHKeyPair?,
        onHostKeyUnknown: @escaping @Sendable (String) -> Void,
        onStep: @escaping @MainActor (PublicKeyInstallStep) -> Void
    ) async throws -> String {
        guard server.isSSHConfigured else { throw PublicKeyInstallError.notSSHHost }

        let publicKeyOpenSSH = try SSHKeyGenerator.openSSHPublicKey(for: keyPair)
        if keyPair.algorithm != .rsa2048 {
            let parts = publicKeyOpenSSH.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 2,
                  let _ = try? NIOSSHPublicKey(openSSHPublicKey: "\(parts[0]) \(parts[1])") else {
                throw PublicKeyInstallError.commandFailed(String(localized: "Generated public key is invalid"))
            }
        }

        await onStep(.connecting)

        let bootstrapAuth: SSHAuthenticationMethod
        do {
            bootstrapAuth = try SSHAuthBuilder.makeAuthenticationMethod(profile: server, keyPair: existingKeyPair)
        } catch {
            throw PublicKeyInstallError.missingCredentials
        }

        let sudoPassword = loadPassword(for: server)

        await onStep(.authenticating)

        let validator = TOFUHostKeyValidator(expectedFingerprint: server.hostKeyFingerprint) { fingerprint in
            Task { @MainActor in
                onStep(.waitingHostKey)
            }
            onHostKeyUnknown(fingerprint)
        }

        let client: SSHClient
        do {
            client = try await SSHClient.connect(
                host: server.host,
                port: server.port,
                authenticationMethod: bootstrapAuth,
                hostKeyValidator: .custom(validator),
                reconnect: .never,
                algorithms: .all
            )
        } catch {
            throw PublicKeyInstallError.commandFailed(SSHErrorMapper.message(for: error))
        }

        do {
            try Task.checkCancellation()
            await onStep(.installing)
            try await writeAuthorizedKey(publicKeyLine: publicKeyOpenSSH, using: client)

            try Task.checkCancellation()
            await onStep(.enablingPubkeyAuth)
            try await ensurePubkeyAuthenticationEnabled(using: client, sudoPassword: sudoPassword)
        } catch {
            try? await client.close()
            throw error
        }
        try? await client.close()

        try Task.checkCancellation()
        await onStep(.verifying)

        var keyProfile = server
        keyProfile.authType = .key
        keyProfile.keyPairId = keyPair.id

        do {
            let keyAuth = try SSHAuthBuilder.makeAuthenticationMethod(profile: keyProfile, keyPair: keyPair)
            let verifyClient = try await SSHClient.connect(
                host: server.host,
                port: server.port,
                authenticationMethod: keyAuth,
                hostKeyValidator: .acceptAnything(),
                reconnect: .never,
                algorithms: .all
            )
            try? await verifyClient.close()
        } catch {
            throw PublicKeyInstallError.verifyFailed(SSHErrorMapper.message(for: error))
        }

        await onStep(.updatingProfile)
        return publicKeyOpenSSH
    }

    private static func loadPassword(for server: ServerProfile) -> String? {
        guard let data = try? KeychainService.shared.load(
            account: KeychainAccount.password.rawValue,
            keyId: server.id
        ),
        let password = String(data: data, encoding: .utf8),
        !password.isEmpty else {
            return nil
        }
        return password
    }

    private static func writeAuthorizedKey(publicKeyLine: String, using client: SSHClient) async throws {
        let script = """
        set -e
        KEY=$(printf %s \(shellEscape(Data(publicKeyLine.utf8).base64EncodedString())) | (base64 -d 2>/dev/null || base64 -D 2>/dev/null || base64 --decode))
        if [ -z "$KEY" ]; then echo KOKO_PUBKEY_EMPTY; exit 1; fi
        umask 077
        chmod go-w "$HOME" 2>/dev/null || true
        mkdir -p "$HOME/.ssh"
        chmod 700 "$HOME/.ssh" || true
        touch "$HOME/.ssh/authorized_keys"
        chmod 600 "$HOME/.ssh/authorized_keys" || true
        if ! grep -Fqx -- "$KEY" "$HOME/.ssh/authorized_keys" 2>/dev/null; then
          printf '%s\\n' "$KEY" >> "$HOME/.ssh/authorized_keys"
        fi
        chmod 600 "$HOME/.ssh/authorized_keys" || true
        if grep -Fqx -- "$KEY" "$HOME/.ssh/authorized_keys"; then
          echo KOKO_PUBKEY_OK
        else
          echo KOKO_PUBKEY_MISSING
          exit 1
        fi
        """

        let output = try await runRemoteBash(script, using: client)
        guard output.contains("KOKO_PUBKEY_OK") else {
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw PublicKeyInstallError.commandFailed(
                trimmed.isEmpty
                    ? String(localized: "Server did not confirm key install")
                    : trimmed
            )
        }
    }

    /// Turns on `PubkeyAuthentication` when disabled. Idempotent if already yes.
    private static func ensurePubkeyAuthenticationEnabled(
        using client: SSHClient,
        sudoPassword: String?
    ) async throws {
        let passB64 = Data((sudoPassword ?? "").utf8).base64EncodedString()
        let hasPass = sudoPassword != nil && !(sudoPassword?.isEmpty ?? true)

        // Always exit 0 so Citadel returns stdout; Swift parses status markers.
        let script = """
        PASS_B64=\(shellEscape(passB64))
        HAS_PASS=\(hasPass ? "1" : "0")

        read_pubkey_auth() {
          local v=""
          v=$(sshd -T 2>/dev/null | awk '/^pubkeyauthentication /{print $2; exit}')
          if [ -n "$v" ]; then echo "$v"; return; fi
          if [ "$(id -u)" -eq 0 ]; then
            v=$(sshd -T 2>/dev/null | awk '/^pubkeyauthentication /{print $2; exit}')
            echo "$v"; return
          fi
          v=$(sudo -n sshd -T 2>/dev/null | awk '/^pubkeyauthentication /{print $2; exit}')
          if [ -n "$v" ]; then echo "$v"; return; fi
          if [ "$HAS_PASS" = "1" ]; then
            local pass
            pass=$(printf %s "$PASS_B64" | (base64 -d 2>/dev/null || base64 -D 2>/dev/null || base64 --decode))
            v=$(printf '%s\\n' "$pass" | sudo -S -p '' sshd -T 2>/dev/null | awk '/^pubkeyauthentication /{print $2; exit}')
            echo "$v"; return
          fi
          echo ""
        }

        CUR=$(read_pubkey_auth)
        if [ "$CUR" = "yes" ]; then
          echo KOKO_PUBKEY_AUTH_ALREADY_YES
          exit 0
        fi

        run_as_root() {
          mkdir -p /etc/ssh/sshd_config.d
          printf '%s\\n' 'PubkeyAuthentication yes' > /etc/ssh/sshd_config.d/50-koko-pubkey.conf
          if [ -f /etc/ssh/sshd_config ]; then
            sed -i -E 's/^[#[:space:]]*PubkeyAuthentication[[:space:]]+no/PubkeyAuthentication yes/I' /etc/ssh/sshd_config 2>/dev/null || true
          fi
          if ! sshd -t >/tmp/koko_sshd_t.err 2>&1; then
            echo KOKO_SSHD_T_FAIL
            cat /tmp/koko_sshd_t.err 2>/dev/null || true
            return 1
          fi
          systemctl reload ssh 2>/dev/null \\
            || systemctl reload sshd 2>/dev/null \\
            || service ssh reload 2>/dev/null \\
            || service sshd reload 2>/dev/null \\
            || true
          return 0
        }

        RC=1
        if [ "$(id -u)" -eq 0 ]; then
          run_as_root; RC=$?
        elif sudo -n true 2>/dev/null; then
          sudo -n bash -c '
            mkdir -p /etc/ssh/sshd_config.d
            printf "%s\\n" "PubkeyAuthentication yes" > /etc/ssh/sshd_config.d/50-koko-pubkey.conf
            if [ -f /etc/ssh/sshd_config ]; then
              sed -i -E "s/^[#[:space:]]*PubkeyAuthentication[[:space:]]+no/PubkeyAuthentication yes/I" /etc/ssh/sshd_config 2>/dev/null || true
            fi
            sshd -t || exit 1
            systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || service ssh reload 2>/dev/null || true
          '
          RC=$?
        elif [ "$HAS_PASS" = "1" ]; then
          PASS=$(printf %s "$PASS_B64" | (base64 -d 2>/dev/null || base64 -D 2>/dev/null || base64 --decode))
          printf '%s\\n' "$PASS" | sudo -S -p '' bash -c '
            mkdir -p /etc/ssh/sshd_config.d
            printf "%s\\n" "PubkeyAuthentication yes" > /etc/ssh/sshd_config.d/50-koko-pubkey.conf
            if [ -f /etc/ssh/sshd_config ]; then
              sed -i -E "s/^[#[:space:]]*PubkeyAuthentication[[:space:]]+no/PubkeyAuthentication yes/I" /etc/ssh/sshd_config 2>/dev/null || true
            fi
            sshd -t || exit 1
            systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || service ssh reload 2>/dev/null || true
          '
          RC=$?
        else
          echo KOKO_PUBKEY_AUTH_NEED_SUDO
          exit 0
        fi

        if [ "$RC" -ne 0 ]; then
          echo KOKO_PUBKEY_AUTH_SUDO_FAIL
          exit 0
        fi

        sleep 1
        CUR=$(read_pubkey_auth)
        if [ "$CUR" = "yes" ]; then
          echo KOKO_PUBKEY_AUTH_ENABLED
        else
          echo KOKO_PUBKEY_AUTH_STILL_NO
        fi
        exit 0
        """

        let output = try await runRemoteBash(script, using: client)

        if output.contains("KOKO_PUBKEY_AUTH_ALREADY_YES") || output.contains("KOKO_PUBKEY_AUTH_ENABLED") {
            return
        }
        if output.contains("KOKO_PUBKEY_AUTH_NEED_SUDO") {
            throw PublicKeyInstallError.enablePubkeyFailed(
                String(localized: "Need sudo (password) to turn on PubkeyAuthentication in sshd_config")
            )
        }
        if output.contains("KOKO_PUBKEY_AUTH_SUDO_FAIL") || output.contains("KOKO_SSHD_T_FAIL") {
            throw PublicKeyInstallError.enablePubkeyFailed(
                String(localized: "sudo failed while enabling PubkeyAuthentication. Check the account can use sudo.")
            )
        }
        if output.contains("KOKO_PUBKEY_AUTH_STILL_NO") {
            throw PublicKeyInstallError.enablePubkeyFailed(
                String(localized: "sshd still reports PubkeyAuthentication no after reload")
            )
        }
        // Could not read sshd -T (restricted image). Continue; verify step will catch real failures.
    }

    private static func runRemoteBash(_ script: String, using client: SSHClient) async throws -> String {
        let scriptB64 = Data(script.utf8).base64EncodedString()
        let command = "echo \(scriptB64) | (base64 -d 2>/dev/null || base64 -D 2>/dev/null || base64 --decode) | /bin/bash -s"
        let outputData = try await client.executeCommand(command, mergeStreams: true)
        return outputData.getString(at: outputData.readerIndex, length: outputData.readableBytes) ?? ""
    }

    private static func shellEscape(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
