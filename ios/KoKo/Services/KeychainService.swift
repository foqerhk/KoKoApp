import Foundation
import Security

enum KeychainError: LocalizedError {
    case saveFailed(OSStatus)
    case loadFailed(OSStatus)
    case deleteFailed(OSStatus)
    case dataConversionFailed

    var errorDescription: String? {
        switch self {
        case .saveFailed(let status): return "Keychain save failed (\(status))"
        case .loadFailed(let status): return "Keychain load failed (\(status))"
        case .deleteFailed(let status): return "Keychain delete failed (\(status))"
        case .dataConversionFailed: return "Keychain data conversion failed"
        }
    }
}

enum KeychainAccount: String {
    case privateKey = "ssh-private-key"
    case password = "ssh-password"
}

final class KeychainService {
    static let shared = KeychainService()
    private let service = "com.koko.app"

    private init() {}

    func save(data: Data, account: String, keyId: UUID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "\(account).\(keyId.uuidString)",
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    func load(account: String, keyId: UUID) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "\(account).\(keyId.uuidString)",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            throw KeychainError.loadFailed(status)
        }
        guard let data = item as? Data else {
            throw KeychainError.dataConversionFailed
        }
        return data
    }

    func delete(account: String, keyId: UUID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "\(account).\(keyId.uuidString)"
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }
}
