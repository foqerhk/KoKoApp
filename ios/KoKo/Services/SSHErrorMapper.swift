import Citadel
import Foundation

enum SSHErrorMapper {
    static func message(for error: Error) -> String {
        if let failed = error as? SSHClient.CommandFailed {
            return String(
                format: String(localized: "Remote command failed (exit %lld)"),
                Int64(failed.exitCode)
            )
        }
        if let ssh = error as? SSHClientError {
            switch ssh {
            case .allAuthenticationOptionsFailed:
                return String(localized: "SSH authentication failed. Check username / key / password. If you switched to key login, re-run Quick Setup on Server or restore password auth.")
            case .channelCreationFailed:
                return String(localized: "SSH channel could not be opened. Try Reconnect.")
            case .unsupportedPasswordAuthentication:
                return String(localized: "Server rejected password authentication.")
            case .unsupportedPrivateKeyAuthentication:
                return String(localized: "Server disabled public-key login (PubkeyAuthentication no). Ask the admin to enable it in sshd_config, then retry.")
            case .unsupportedHostBasedAuthentication:
                return String(localized: "Server rejected host-based authentication.")
            }
        }
        if error is AuthenticationFailed {
            return String(localized: "SSH authentication failed. Check username / key / password.")
        }
        let text = error.localizedDescription
        // Citadel often surfaces as NSError "error 4" without a useful message.
        if text.contains("SSHClientError") && (text.contains("错误4") || text.contains("error 4")) {
            return String(localized: "SSH authentication failed. Check username / key / password. If you switched to key login, re-run Quick Setup on Server or restore password auth.")
        }
        return text
    }
}
