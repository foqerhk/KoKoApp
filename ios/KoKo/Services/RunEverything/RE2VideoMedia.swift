import Foundation
import CryptoKit
import Security

/// Gap-tolerant video AEAD (Agent `re2.VideoMedia`). Wire: `V1` || nonce12 || ct+tag.
final class RE2VideoMedia {
    static let magic0: UInt8 = 0x56 // 'V'
    static let magic1: UInt8 = 0x31 // '1'
    private static let nonceSize = 12
    private static let tagSize = 16
    private static let overhead = 2 + nonceSize + tagSize

    private let sendKey: SymmetricKey
    private let recvKey: SymmetricKey

    /// Client: send=c2a, recv=a2c.
    init(a2c: Data, c2a: Data) throws {
        guard a2c.count == 32, c2a.count == 32 else {
            throw RE2Error.noise("video media keys must be 32 bytes")
        }
        self.sendKey = SymmetricKey(data: c2a)
        self.recvKey = SymmetricKey(data: a2c)
    }

    static func isVideoPlane(_ payload: Data) -> Bool {
        payload.count >= overhead
            && payload[payload.startIndex] == magic0
            && payload[payload.startIndex + 1] == magic1
    }

    /// Largest inner plaintext that fits one REUDP DATA after `seal` (magic+nonce+tag).
    static var maxPlainUDP: Int { REUDP.maxPayload - overhead }

    /// Derive keys matching Agent `DeriveVideoMediaKeys`.
    static func deriveKeys(psk: Data, initiatorStatic: Data, responderStatic: Data) throws -> (a2c: Data, c2a: Data) {
        guard psk.count == 32, initiatorStatic.count == 32, responderStatic.count == 32 else {
            throw RE2Error.noise("video media key material must be 32 bytes")
        }
        let salt = Data(SHA256.hash(data: Data("re2-video-v1".utf8)))
        var ikm = Data()
        ikm.append(psk)
        ikm.append(initiatorStatic)
        ikm.append(responderStatic)
        let okm = hkdfSHA256(ikm: ikm, salt: salt, info: Data("re2-video-v1".utf8), length: 64)
        return (Data(okm.prefix(32)), Data(okm.suffix(32)))
    }

    func seal(plain: Data) throws -> Data {
        var nonce = Data(count: Self.nonceSize)
        let status = nonce.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, Self.nonceSize, $0.baseAddress!) }
        guard status == errSecSuccess else { throw RE2Error.noise("video nonce rng failed") }
        let box = try ChaChaPoly.seal(plain, using: sendKey, nonce: ChaChaPoly.Nonce(data: nonce))
        var out = Data([Self.magic0, Self.magic1])
        out.append(nonce)
        out.append(box.ciphertext)
        out.append(box.tag)
        return out
    }

    func open(packet: Data) throws -> Data {
        guard Self.isVideoPlane(packet) else { throw RE2Error.noise("not video plane") }
        let nonce = packet.subdata(in: 2..<(2 + Self.nonceSize))
        let ctAndTag = packet.subdata(in: (2 + Self.nonceSize)..<packet.count)
        guard ctAndTag.count >= Self.tagSize else { throw RE2Error.noise("video ct short") }
        let ct = ctAndTag.prefix(ctAndTag.count - Self.tagSize)
        let tag = ctAndTag.suffix(Self.tagSize)
        let box = try ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: nonce), ciphertext: ct, tag: tag)
        return try ChaChaPoly.open(box, using: recvKey)
    }

    private static func hkdfSHA256(ikm: Data, salt: Data, info: Data, length: Int) -> Data {
        let prk = HMAC<SHA256>.authenticationCode(for: ikm, using: SymmetricKey(data: salt))
        var okm = Data()
        var prev = Data()
        var counter: UInt8 = 1
        while okm.count < length {
            var block = Data()
            block.append(prev)
            block.append(info)
            block.append(counter)
            let t = HMAC<SHA256>.authenticationCode(for: block, using: SymmetricKey(data: Data(prk)))
            prev = Data(t)
            okm.append(prev)
            counter += 1
        }
        return okm.prefix(length)
    }
}
