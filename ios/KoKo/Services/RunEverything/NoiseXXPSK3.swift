import Foundation
import CryptoKit

/// Noise_XXpsk3_25519_ChaChaPoly_SHA256 (initiator = client).
/// Interoperable with github.com/flynn/noise used by RunEverything.
final class NoiseXXPSK3 {
    private let psk: Data
    private let prologue: Data
    private let staticKey: Curve25519.KeyAgreement.PrivateKey
    private var ephemeralKey: Curve25519.KeyAgreement.PrivateKey?
    private var peerStatic: Data?
    private var peerEphemeral: Data?

    private var ck: Data
    private var h: Data
    private var k: Data?
    private var n: UInt64 = 0

    private(set) var sendCipher: NoiseCipherState?
    private(set) var recvCipher: NoiseCipherState?

    init(psk: Data, prologue: Data = RE2.noisePrologue, staticKey: Curve25519.KeyAgreement.PrivateKey = .init()) throws {
        guard psk.count == 32 else { throw RE2Error.noise("psk must be 32 bytes") }
        self.psk = psk
        self.prologue = prologue
        self.staticKey = staticKey

        // handshake_name = Noise_XXpsk3_25519_ChaChaPoly_SHA256
        let name = Data("Noise_XXpsk3_25519_ChaChaPoly_SHA256".utf8)
        if name.count <= 32 {
            var h = Data(count: 32)
            h.replaceSubrange(0..<name.count, with: name)
            self.h = h
        } else {
            self.h = Data(SHA256.hash(data: name))
        }
        self.ck = self.h
        mixHash(prologue)
    }

    var peerStaticPublicKey: Data? { peerStatic }
    /// Local XX static public (initiator ephemeral identity for this handshake).
    var localStaticPublicKey: Data { staticKey.publicKey.rawRepresentation }

    /// Client initiator: msg1 -> (wait msg2) -> msg3. Returns (msg1 producer / continue).
    func writeMessage1() throws -> Data {
        let e = Curve25519.KeyAgreement.PrivateKey()
        ephemeralKey = e
        var msg = Data()
        // e
        msg.append(e.publicKey.rawRepresentation)
        mixHash(e.publicKey.rawRepresentation)
        // Noise PSK modes: after every `e` token, MixKey(e.public_key) (flynn willPsk).
        // Without this, msg1 is 32 bytes and the Agent fails with
        // chacha20poly1305: message authentication failed.
        mixKey(e.publicKey.rawRepresentation)
        // empty payload (now AEAD-tagged → msg1 is 48 bytes)
        msg.append(try encryptAndHash(Data()))
        return msg
    }

    func readMessage2(_ data: Data) throws {
        var buf = data
        // e
        guard buf.count >= 32 else { throw RE2Error.noise("msg2 short") }
        let re = Data(buf.prefix(32))
        buf = Data(buf.dropFirst(32))
        peerEphemeral = re
        mixHash(re)
        // PSK mode: MixKey(re) after MixHash(re), before ee.
        mixKey(re)
        // ee
        guard let e = ephemeralKey else { throw RE2Error.noise("no local e") }
        mixKey(try dh(e, re))
        // s (encrypted)
        guard buf.count >= 32 + 16 else { throw RE2Error.noise("msg2 missing s") }
        let encS = Data(buf.prefix(32 + 16))
        buf = Data(buf.dropFirst(32 + 16))
        let rs = try decryptAndHash(encS)
        guard rs.count == 32 else { throw RE2Error.noise("bad remote static") }
        peerStatic = rs
        // es
        mixKey(try dh(e, rs))
        // payload
        _ = try decryptAndHash(buf)
    }

    func writeMessage3() throws -> (Data, NoiseCipherState, NoiseCipherState) {
        var msg = Data()
        // s
        let sPub = staticKey.publicKey.rawRepresentation
        msg.append(try encryptAndHash(sPub))
        // se
        guard let re = peerEphemeral else { throw RE2Error.noise("no peer e") }
        mixKey(try dh(staticKey, re))
        // psk
        mixKeyAndHash(psk)
        // empty payload
        msg.append(try encryptAndHash(Data()))

        let (c1, c2) = try split()
        // initiator: cs0 = send, cs1 = recv
        sendCipher = c1
        recvCipher = c2
        return (msg, c1, c2)
    }

    // MARK: - Symmetric

    private func mixHash(_ data: Data) {
        h = Data(SHA256.hash(data: h + data))
    }

    private func mixKey(_ ikm: Data) {
        let (newCK, tempK) = hkdf(ck: ck, ikm: ikm, num: 2)
        ck = newCK
        k = tempK
        n = 0
    }

    private func mixKeyAndHash(_ ikm: Data) {
        let (newCK, tempH, tempK) = hkdf3(ck: ck, ikm: ikm)
        ck = newCK
        mixHash(tempH)
        k = tempK
        n = 0
    }

    private func encryptAndHash(_ plaintext: Data) throws -> Data {
        guard let key = k else {
            mixHash(plaintext)
            return plaintext
        }
        let ct = try chachaEncrypt(key: key, nonce: n, ad: h, plaintext: plaintext)
        n += 1
        mixHash(ct)
        return ct
    }

    private func decryptAndHash(_ ciphertext: Data) throws -> Data {
        guard let key = k else {
            mixHash(ciphertext)
            return ciphertext
        }
        let pt = try chachaDecrypt(key: key, nonce: n, ad: h, ciphertext: ciphertext)
        n += 1
        mixHash(ciphertext)
        return pt
    }

    private func split() throws -> (NoiseCipherState, NoiseCipherState) {
        let (k1, k2) = hkdf(ck: ck, ikm: Data(), num: 2)
        return (NoiseCipherState(key: k1), NoiseCipherState(key: k2))
    }

    private func dh(_ priv: Curve25519.KeyAgreement.PrivateKey, _ pubRaw: Data) throws -> Data {
        let pub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: pubRaw)
        let shared = try priv.sharedSecretFromKeyAgreement(with: pub)
        return shared.withUnsafeBytes { Data($0) }
    }

    /// HKDF-style as in Noise / flynn: HASHLEN=32, two outputs.
    private func hkdf(ck: Data, ikm: Data, num: Int) -> (Data, Data) {
        let temp = hmac(key: ck, data: ikm)
        let out1 = hmac(key: temp, data: Data([0x01]))
        let out2 = hmac(key: temp, data: out1 + Data([0x02]))
        return (out1, out2)
    }

    private func hkdf3(ck: Data, ikm: Data) -> (Data, Data, Data) {
        let temp = hmac(key: ck, data: ikm)
        let out1 = hmac(key: temp, data: Data([0x01]))
        let out2 = hmac(key: temp, data: out1 + Data([0x02]))
        let out3 = hmac(key: temp, data: out2 + Data([0x03]))
        return (out1, out2, out3)
    }

    private func hmac(key: Data, data: Data) -> Data {
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key))
        return Data(mac)
    }
}

final class NoiseCipherState {
    private let keyData: Data
    private var n: UInt64 = 0
    private let lock = NSLock()

    init(key: Data) {
        self.keyData = key
    }

    func encrypt(plaintext: Data, ad: Data = Data()) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        let out = try chachaEncrypt(key: keyData, nonce: n, ad: ad, plaintext: plaintext)
        n += 1
        return out
    }

    func decrypt(ciphertext: Data, ad: Data = Data()) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        let out = try chachaDecrypt(key: keyData, nonce: n, ad: ad, ciphertext: ciphertext)
        n += 1
        return out
    }
}

// MARK: - ChaCha20-Poly1305 (Noise nonce: 4 zero + 8 LE counter)

private func noiseNonce(_ n: UInt64) throws -> ChaChaPoly.Nonce {
    var bytes = [UInt8](repeating: 0, count: 12)
    for i in 0..<8 {
        bytes[4 + i] = UInt8((n >> (8 * i)) & 0xff)
    }
    return try ChaChaPoly.Nonce(data: Data(bytes))
}

private func chachaEncrypt(key: Data, nonce: UInt64, ad: Data, plaintext: Data) throws -> Data {
    let sk = SymmetricKey(data: key)
    let nn = try noiseNonce(nonce)
    let box = try ChaChaPoly.seal(plaintext, using: sk, nonce: nn, authenticating: ad)
    return box.ciphertext + box.tag
}

private func chachaDecrypt(key: Data, nonce: UInt64, ad: Data, ciphertext: Data) throws -> Data {
    guard ciphertext.count >= 16 else { throw RE2Error.noise("ciphertext short") }
    let sk = SymmetricKey(data: key)
    let nn = try noiseNonce(nonce)
    let ct = ciphertext.prefix(ciphertext.count - 16)
    let tag = ciphertext.suffix(16)
    let box = try ChaChaPoly.SealedBox(nonce: nn, ciphertext: ct, tag: tag)
    return try ChaChaPoly.open(box, using: sk, authenticating: ad)
}
