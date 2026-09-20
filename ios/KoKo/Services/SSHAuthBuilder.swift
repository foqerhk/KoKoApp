import Citadel
import Crypto
import Foundation
import NIOSSH

enum SSHAuthBuilderError: LocalizedError {
    case missingKeyPair
    case invalidPrivateKey
    case missingPassword

    var errorDescription: String? {
        switch self {
        case .missingKeyPair: return "No SSH key selected"
        case .invalidPrivateKey: return "Invalid private key data"
        case .missingPassword: return "Missing SSH password"
        }
    }
}

enum SSHAuthBuilder {
    static func makeAuthenticationMethod(
        profile: ServerProfile,
        keyPair: SSHKeyPair?
    ) throws -> SSHAuthenticationMethod {
        switch profile.authType {
        case .password:
            let data = try KeychainService.shared.load(
                account: KeychainAccount.password.rawValue,
                keyId: profile.id
            )
            guard let password = String(data: data, encoding: .utf8), !password.isEmpty else {
                throw SSHAuthBuilderError.missingPassword
            }
            return .passwordBased(username: profile.username, password: password)

        case .key:
            guard let keyPair else { throw SSHAuthBuilderError.missingKeyPair }
            let privateData = try KeychainService.shared.load(
                account: KeychainAccount.privateKey.rawValue,
                keyId: keyPair.id
            )
            switch keyPair.algorithm {
            case .ed25519:
                let key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateData)
                return .ed25519(username: profile.username, privateKey: key)
            case .ecdsaP256:
                let key = try P256.Signing.PrivateKey(derRepresentation: privateData)
                return .p256(username: profile.username, privateKey: key)
            case .ecdsaP384:
                let key = try P384.Signing.PrivateKey(derRepresentation: privateData)
                return .p384(username: profile.username, privateKey: key)
            case .rsa2048:
                guard let pem = String(data: privateData, encoding: .utf8) else {
                    throw SSHAuthBuilderError.invalidPrivateKey
                }
                if pem.contains("OPENSSH PRIVATE KEY") {
                    let key = try Insecure.RSA.PrivateKey(sshRsa: pem)
                    return .rsa(username: profile.username, privateKey: key)
                }
                let openSSH = try RSAOpenSSHConverter.openSSHPrivateKey(fromPKCS1PEM: pem, comment: keyPair.label)
                let key = try Insecure.RSA.PrivateKey(sshRsa: openSSH)
                return .rsa(username: profile.username, privateKey: key)
            }
        }
    }
}

enum RSAOpenSSHConverter {
    static func openSSHPrivateKey(fromPKCS1PEM pem: String, comment: String) throws -> String {
        let der = try pemDecode(pem)
        let fields = try PKCS1RSAPrivateKey.parse(der)
        return encodeOpenSSHPrivateKey(fields: fields, comment: comment)
    }

    private static func pemDecode(_ pem: String) throws -> Data {
        let lines = pem
            .components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") && !$0.isEmpty }
        guard let data = Data(base64Encoded: lines.joined()) else {
            throw SSHAuthBuilderError.invalidPrivateKey
        }
        return data
    }

    private static func encodeOpenSSHPrivateKey(fields: PKCS1RSAPrivateKey, comment: String) -> String {
        var publicBlob = Data()
        appendSSHString("ssh-rsa", to: &publicBlob)
        appendSSHMPInt(fields.publicExponent, to: &publicBlob)
        appendSSHMPInt(fields.modulus, to: &publicBlob)

        var privateBlob = Data()
        let check = UInt32.random(in: 0...UInt32.max)
        appendUInt32(check, to: &privateBlob)
        appendUInt32(check, to: &privateBlob)
        appendSSHString("ssh-rsa", to: &privateBlob)
        appendSSHMPInt(fields.modulus, to: &privateBlob)
        appendSSHMPInt(fields.publicExponent, to: &privateBlob)
        appendSSHMPInt(fields.privateExponent, to: &privateBlob)
        appendSSHMPInt(fields.coefficient, to: &privateBlob)
        appendSSHMPInt(fields.prime1, to: &privateBlob)
        appendSSHMPInt(fields.prime2, to: &privateBlob)
        appendSSHString(comment, to: &privateBlob)

        var pad: UInt8 = 1
        while privateBlob.count % 8 != 0 {
            privateBlob.append(pad)
            pad &+= 1
        }

        var body = Data()
        body.append(contentsOf: Array("openssh-key-v1".utf8))
        body.append(0)
        appendSSHString("none", to: &body)
        appendSSHString("none", to: &body)
        appendSSHString(Data(), to: &body)
        appendUInt32(1, to: &body)
        appendSSHString(publicBlob, to: &body)
        appendSSHString(privateBlob, to: &body)

        let b64 = body.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN OPENSSH PRIVATE KEY-----\n\(b64)\n-----END OPENSSH PRIVATE KEY-----\n"
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var be = value.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }

    private static func appendSSHString(_ string: String, to data: inout Data) {
        appendSSHString(Data(string.utf8), to: &data)
    }

    private static func appendSSHString(_ bytes: Data, to data: inout Data) {
        appendUInt32(UInt32(bytes.count), to: &data)
        data.append(bytes)
    }

    private static func appendSSHMPInt(_ bytes: Data, to data: inout Data) {
        // Copy first — insert() on a Data slice can trap with EXC_BREAKPOINT.
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

struct PKCS1RSAPrivateKey {
    let modulus: Data
    let publicExponent: Data
    let privateExponent: Data
    let prime1: Data
    let prime2: Data
    let coefficient: Data

    static func parse(_ der: Data) throws -> PKCS1RSAPrivateKey {
        var parser = ASN1Parser(der)
        try parser.expectSequence()
        _ = try parser.readInteger() // version
        let n = try parser.readInteger()
        let e = try parser.readInteger()
        let d = try parser.readInteger()
        let p = try parser.readInteger()
        let q = try parser.readInteger()
        _ = try parser.readInteger() // exponent1
        _ = try parser.readInteger() // exponent2
        let iqmp = try parser.readInteger()
        return PKCS1RSAPrivateKey(
            modulus: n,
            publicExponent: e,
            privateExponent: d,
            prime1: p,
            prime2: q,
            coefficient: iqmp
        )
    }
}

private struct ASN1Parser {
    private let data: Data
    private var index: Data.Index

    init(_ data: Data) {
        self.data = data
        self.index = data.startIndex
    }

    mutating func expectSequence() throws {
        let (tag, _) = try readTagLength()
        guard tag == 0x30 else { throw SSHAuthBuilderError.invalidPrivateKey }
    }

    mutating func readInteger() throws -> Data {
        let (tag, length) = try readTagLength()
        guard tag == 0x02 else { throw SSHAuthBuilderError.invalidPrivateKey }
        guard index + length <= data.endIndex else { throw SSHAuthBuilderError.invalidPrivateKey }
        let slice = data[index..<index + length]
        index += length
        return Data(slice)
    }

    private mutating func readTagLength() throws -> (UInt8, Int) {
        guard index < data.endIndex else { throw SSHAuthBuilderError.invalidPrivateKey }
        let tag = data[index]
        index += 1
        guard index < data.endIndex else { throw SSHAuthBuilderError.invalidPrivateKey }
        let first = data[index]
        index += 1
        if first & 0x80 == 0 {
            return (tag, Int(first))
        }
        let count = Int(first & 0x7f)
        guard count > 0, count <= 4, index + count <= data.endIndex else {
            throw SSHAuthBuilderError.invalidPrivateKey
        }
        var length = 0
        for _ in 0..<count {
            length = (length << 8) | Int(data[index])
            index += 1
        }
        return (tag, length)
    }
}
