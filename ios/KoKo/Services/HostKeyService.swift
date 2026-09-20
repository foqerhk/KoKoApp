import Crypto
import Foundation
import NIO
import NIOSSH

enum HostKeyError: LocalizedError {
    case unknownHost
    case mismatch
    case userRejected
    case invalidStoredKey

    var errorDescription: String? {
        switch self {
        case .unknownHost: return "Unknown host key"
        case .mismatch: return "Host key fingerprint changed"
        case .userRejected: return "Host key was rejected"
        case .invalidStoredKey: return "Stored host key is invalid"
        }
    }
}

enum HostKeyFingerprint {
    static func sha256(_ hostKey: NIOSSHPublicKey) -> String {
        let openSSH = String(openSSHPublicKey: hostKey)
        let parts = openSSH.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else {
            return "SHA256:unknown"
        }
        let digest = SHA256.hash(data: blob)
        return "SHA256:" + Data(digest).base64EncodedString()
    }
}

@MainActor
final class HostKeyApprovalGate {
    static let shared = HostKeyApprovalGate()

    private var continuation: CheckedContinuation<Bool, Never>?

    func requestApproval() async -> Bool {
        // Never leave a previous waiter hanging (e.g. timed-out connect).
        resume(false)
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func approve() {
        resume(true)
    }

    func reject() {
        resume(false)
    }

    /// Cancel any in-flight prompt (disconnect / timeout).
    func reset() {
        resume(false)
    }

    private func resume(_ value: Bool) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}

final class TOFUHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let expectedFingerprint: String?
    private let onUnknown: @Sendable (String) -> Void

    init(expectedFingerprint: String?, onUnknown: @escaping @Sendable (String) -> Void) {
        self.expectedFingerprint = expectedFingerprint
        self.onUnknown = onUnknown
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let fingerprint = HostKeyFingerprint.sha256(hostKey)

        if let expectedFingerprint {
            if fingerprint == expectedFingerprint {
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(HostKeyError.mismatch)
            }
            return
        }

        onUnknown(fingerprint)

        Task { @MainActor in
            let approved = await HostKeyApprovalGate.shared.requestApproval()
            if approved {
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(HostKeyError.userRejected)
            }
        }
    }
}
