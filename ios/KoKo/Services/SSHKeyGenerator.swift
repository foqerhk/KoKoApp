import Crypto
import Foundation
import NIOSSH
import Security

enum SSHKeyGeneratorError: LocalizedError {
    case unsupportedAlgorithm
    case rsaGenerationFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedAlgorithm: return "Unsupported key algorithm"
        case .rsaGenerationFailed(let reason): return "RSA key generation failed: \(reason)"
        }
    }
}

struct GeneratedSSHKey {
    let algorithm: SSHKeyAlgorithm
    let publicKeyOpenSSH: String
    let privateKeyData: Data
}

enum SSHKeyGenerator {
    static func generate(label: String, algorithm: SSHKeyAlgorithm) throws -> GeneratedSSHKey {
        let comment = sanitizeComment(label)
        switch algorithm {
        case .ed25519:
            let key = Curve25519.Signing.PrivateKey()
            let base = String(openSSHPublicKey: NIOSSHPrivateKey(ed25519Key: key).publicKey)
            return GeneratedSSHKey(
                algorithm: algorithm,
                publicKeyOpenSSH: "\(base) \(comment)",
                privateKeyData: key.rawRepresentation
            )
        case .ecdsaP256:
            let key = P256.Signing.PrivateKey()
            let base = String(openSSHPublicKey: NIOSSHPrivateKey(p256Key: key).publicKey)
            return GeneratedSSHKey(
                algorithm: algorithm,
                publicKeyOpenSSH: "\(base) \(comment)",
                privateKeyData: key.derRepresentation
            )
        case .ecdsaP384:
            let key = P384.Signing.PrivateKey()
            let base = String(openSSHPublicKey: NIOSSHPrivateKey(p384Key: key).publicKey)
            return GeneratedSSHKey(
                algorithm: algorithm,
                publicKeyOpenSSH: "\(base) \(comment)",
                privateKeyData: key.derRepresentation
            )
        case .rsa2048:
            return try generateRSA(label: comment)
        }
    }

    /// Rebuild OpenSSH public key using the same serializer Citadel/NIOSSH uses for auth.
    static func openSSHPublicKey(for keyPair: SSHKeyPair) throws -> String {
        let privateData = try KeychainService.shared.load(
            account: KeychainAccount.privateKey.rawValue,
            keyId: keyPair.id
        )
        let comment = sanitizeComment(keyPair.label)
        let base: String
        switch keyPair.algorithm {
        case .ed25519:
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateData)
            base = String(openSSHPublicKey: NIOSSHPrivateKey(ed25519Key: key).publicKey)
        case .ecdsaP256:
            let key = try P256.Signing.PrivateKey(derRepresentation: privateData)
            base = String(openSSHPublicKey: NIOSSHPrivateKey(p256Key: key).publicKey)
        case .ecdsaP384:
            let key = try P384.Signing.PrivateKey(derRepresentation: privateData)
            base = String(openSSHPublicKey: NIOSSHPrivateKey(p384Key: key).publicKey)
        case .rsa2048:
            let parts = keyPair.publicKeyOpenSSH.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 2 else { throw SSHKeyGeneratorError.unsupportedAlgorithm }
            base = "\(parts[0]) \(parts[1])"
        }
        return "\(base) \(comment)"
    }

    /// OpenSSH comments should be a single token (no spaces/newlines).
    private static func sanitizeComment(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = trimmed.replacingOccurrences(of: "\\s+", with: "-", options: .regularExpression)
        return collapsed.isEmpty ? "koko" : collapsed
    }

    private static func generateRSA(label: String) throws -> GeneratedSSHKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: false
            ]
        ]

        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            let message = error?.takeRetainedValue().localizedDescription ?? "SecKeyCreateRandomKey failed"
            throw SSHKeyGeneratorError.rsaGenerationFailed(message)
        }
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw SSHKeyGeneratorError.rsaGenerationFailed("Missing public key")
        }

        var exportError: Unmanaged<CFError>?
        guard let privateDER = SecKeyCopyExternalRepresentation(privateKey, &exportError) as Data? else {
            let message = exportError?.takeRetainedValue().localizedDescription ?? "Private key export failed"
            throw SSHKeyGeneratorError.rsaGenerationFailed(message)
        }
        guard let publicDER = SecKeyCopyExternalRepresentation(publicKey, &exportError) as Data? else {
            let message = exportError?.takeRetainedValue().localizedDescription ?? "Public key export failed"
            throw SSHKeyGeneratorError.rsaGenerationFailed(message)
        }

        let publicFields = try PKCS1RSAPublicKey.parse(publicDER)
        let blob = encodeRSAPublicKeyBlob(modulus: publicFields.modulus, exponent: publicFields.publicExponent)
        let publicLine = "ssh-rsa \(blob.base64EncodedString()) \(label)"

        // Store OpenSSH private key so auth never needs PKCS#1→OpenSSH conversion (that path used to crash).
        let pkcs1PEM = pemEncode(type: "RSA PRIVATE KEY", der: privateDER)
        let openSSHPEM = try RSAOpenSSHConverter.openSSHPrivateKey(fromPKCS1PEM: pkcs1PEM, comment: label)
        guard let privateData = openSSHPEM.data(using: .utf8) else {
            throw SSHKeyGeneratorError.rsaGenerationFailed("PEM encoding failed")
        }

        return GeneratedSSHKey(
            algorithm: .rsa2048,
            publicKeyOpenSSH: publicLine,
            privateKeyData: privateData
        )
    }

    private static func pemEncode(type: String, der: Data) -> String {
        let b64 = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN \(type)-----\n\(b64)\n-----END \(type)-----\n"
    }

    private static func encodeRSAPublicKeyBlob(modulus: Data, exponent: Data) -> Data {
        var buffer = Data()
        appendSSHString("ssh-rsa", to: &buffer)
        appendSSHMPInt(exponent, to: &buffer)
        appendSSHMPInt(modulus, to: &buffer)
        return buffer
    }

    private static func appendSSHString(_ string: String, to data: inout Data) {
        appendSSHString(Data(string.utf8), to: &data)
    }

    private static func appendSSHString(_ bytes: Data, to data: inout Data) {
        var length = UInt32(bytes.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(bytes)
    }

    private static func appendSSHMPInt(_ bytes: Data, to data: inout Data) {
        // Copy to a contiguous buffer — mutating a Data slice via insert() can trap (EXC_BREAKPOINT).
        var value = Data(bytes)
        while value.count > 1 && value.first == 0 {
            value.removeFirst()
        }
        if value.isEmpty {
            value = Data([0])
        }
        if let first = value.first, first & 0x80 != 0 {
            value = Data([0]) + value
        }
        appendSSHString(value, to: &data)
    }
}

private struct PKCS1RSAPublicKey {
    let modulus: Data
    let publicExponent: Data

    static func parse(_ der: Data) throws -> PKCS1RSAPublicKey {
        // Apple may return PKCS#1 RSAPublicKey or X.509 SubjectPublicKeyInfo.
        if looksLikeSubjectPublicKeyInfo(der) {
            let pkcs1 = try unwrapSubjectPublicKeyInfo(der)
            return try parsePKCS1(pkcs1)
        }
        return try parsePKCS1(der)
    }

    private static func parsePKCS1(_ der: Data) throws -> PKCS1RSAPublicKey {
        var parser = SimpleASN1Parser(der)
        try parser.expectSequence()
        let n = try parser.readInteger()
        let e = try parser.readInteger()
        guard !n.isEmpty, !e.isEmpty else {
            throw SSHKeyGeneratorError.rsaGenerationFailed("Empty RSA public key integers")
        }
        return PKCS1RSAPublicKey(modulus: n, publicExponent: e)
    }

    private static func looksLikeSubjectPublicKeyInfo(_ der: Data) -> Bool {
        // SPKI: SEQUENCE { SEQUENCE (alg), BIT STRING }
        // PKCS#1: SEQUENCE { INTEGER, INTEGER }
        var parser = SimpleASN1Parser(der)
        do {
            try parser.expectSequence()
            let (tag, _) = try parser.peekTagLength()
            return tag == 0x30 // nested sequence => SPKI
        } catch {
            return false
        }
    }

    private static func unwrapSubjectPublicKeyInfo(_ der: Data) throws -> Data {
        var parser = SimpleASN1Parser(der)
        try parser.expectSequence()
        _ = try parser.readValue(expectedTag: 0x30) // AlgorithmIdentifier
        let bitString = try parser.readValue(expectedTag: 0x03)
        // BIT STRING: first byte is unused-bits count (usually 0), then payload.
        guard bitString.count >= 2, bitString[0] == 0 else {
            throw SSHKeyGeneratorError.rsaGenerationFailed("Invalid SPKI BIT STRING")
        }
        return Data(bitString.dropFirst())
    }
}

private struct SimpleASN1Parser {
    private let data: Data
    private var index: Data.Index

    init(_ data: Data) {
        self.data = data
        self.index = data.startIndex
    }

    mutating func expectSequence() throws {
        let (tag, _) = try readTagLength()
        guard tag == 0x30 else { throw SSHKeyGeneratorError.rsaGenerationFailed("Invalid ASN.1 sequence") }
    }

    mutating func peekTagLength() throws -> (UInt8, Int) {
        let saved = index
        defer { index = saved }
        return try readTagLength()
    }

    mutating func readValue(expectedTag: UInt8) throws -> Data {
        let (tag, length) = try readTagLength()
        guard tag == expectedTag else { throw SSHKeyGeneratorError.rsaGenerationFailed("Unexpected ASN.1 tag") }
        guard index + length <= data.endIndex else { throw SSHKeyGeneratorError.rsaGenerationFailed("Truncated ASN.1") }
        let slice = data[index..<index + length]
        index += length
        return Data(slice)
    }

    mutating func readInteger() throws -> Data {
        let (tag, length) = try readTagLength()
        guard tag == 0x02 else { throw SSHKeyGeneratorError.rsaGenerationFailed("Invalid ASN.1 integer") }
        guard index + length <= data.endIndex else { throw SSHKeyGeneratorError.rsaGenerationFailed("Truncated ASN.1") }
        let slice = data[index..<index + length]
        index += length
        return Data(slice)
    }

    private mutating func readTagLength() throws -> (UInt8, Int) {
        guard index < data.endIndex else { throw SSHKeyGeneratorError.rsaGenerationFailed("Truncated ASN.1") }
        let tag = data[index]
        index += 1
        guard index < data.endIndex else { throw SSHKeyGeneratorError.rsaGenerationFailed("Truncated ASN.1") }
        let first = data[index]
        index += 1
        if first & 0x80 == 0 {
            return (tag, Int(first))
        }
        let count = Int(first & 0x7f)
        guard count > 0, count <= 4, index + count <= data.endIndex else {
            throw SSHKeyGeneratorError.rsaGenerationFailed("Invalid ASN.1 length")
        }
        var length = 0
        for _ in 0..<count {
            length = (length << 8) | Int(data[index])
            index += 1
        }
        return (tag, length)
    }
}
