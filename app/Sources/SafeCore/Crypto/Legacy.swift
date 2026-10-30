import CryptoKit
import Foundation

// The variants older tools wrote, for reading only (building plan 5.2, G5).
// openssl enc without -pbkdf2 derives key and IV with EVP_BytesToKey and one
// iteration; the digest was MD5 in old versions and is SHA-256 since OpenSSL
// 1.1.0. crypt.sh before 1.4 used RC4 with a 16-byte key and no IV. Files may
// be salted (Salted__ header) or not (-nosalt).

enum Legacy {
    /// The order in which CryptFile.open tries the variants when the current
    /// format fails.
    static let order: [CryptVariant] = [.legacyAESSHA256, .legacyAESMD5, .legacyRC4MD5, .legacyRC4SHA256]

    static let rc4KeyLength = 16

    enum Digest {
        case md5, sha256
    }

    static func digest(of variant: CryptVariant) -> Digest {
        switch variant {
        case .legacyAESMD5, .legacyRC4MD5: return .md5
        default: return .sha256
        }
    }

    static func isRC4(_ variant: CryptVariant) -> Bool {
        variant == .legacyRC4MD5 || variant == .legacyRC4SHA256
    }

    static func decrypt(_ ciphertext: Data, password: SecureBytes, variant: CryptVariant) throws -> Data {
        try decryptWithPadding(ciphertext, password: password, variant: variant).plaintext
    }

    /// decrypt, and for AES the number of padding bytes removed; nil for RC4,
    /// which has no padding.
    static func decryptWithPadding(_ ciphertext: Data, password: SecureBytes,
                                   variant: CryptVariant) throws -> (plaintext: Data, padding: Int?) {
        precondition(variant != .current)
        let (salt, body) = try OpenSSLFormat.split(ciphertext)
        let md = digest(of: variant)
        if isRC4(variant) {
            let key = bytesToKey(md, password: password, salt: salt, count: rc4KeyLength)
            defer { key.wipe() }
            return (rc4(key: key, body), nil)
        }
        let keyIV = bytesToKey(md, password: password, salt: salt,
                               count: OpenSSLFormat.keyLength + OpenSSLFormat.ivLength)
        defer { keyIV.wipe() }
        let (plain, padding) = try OpenSSLFormat.decryptAESStrictWithPadding(body, keyIV: keyIV)
        return (plain, padding)
    }

    /// The first `length` bytes (or fewer) of an RC4 variant's result: CryptFile
    /// looks at them before it decrypts a large file whole.
    static func decryptRC4Start(_ ciphertext: Data, password: SecureBytes, variant: CryptVariant,
                                length: Int) throws -> Data {
        precondition(isRC4(variant))
        let (salt, body) = try OpenSSLFormat.split(ciphertext)
        let key = bytesToKey(digest(of: variant), password: password, salt: salt, count: rc4KeyLength)
        defer { key.wipe() }
        return rc4(key: key, body.prefix(length))
    }

    /// EVP_BytesToKey with one iteration: D1 = H(password + salt),
    /// Di = H(Di-1 + password + salt), concatenated until there are `count` bytes.
    static func bytesToKey(_ md: Digest, password: SecureBytes, salt: [UInt8]?, count: Int) -> SecureBytes {
        let out = SecureBytes(zeros: count)
        var previous: [UInt8] = []
        var filled = 0
        out.withUnsafeMutableBytes { dest in
            while filled < count {
                let block: [UInt8] = password.withUnsafeBytes { pw in
                    switch md {
                    case .md5:
                        var h = Insecure.MD5()
                        h.update(data: previous)
                        h.update(bufferPointer: pw)
                        if let salt = salt { h.update(data: salt) }
                        return Array(h.finalize())
                    case .sha256:
                        var h = SHA256()
                        h.update(data: previous)
                        h.update(bufferPointer: pw)
                        if let salt = salt { h.update(data: salt) }
                        return Array(h.finalize())
                    }
                }
                let n = min(block.count, count - filled)
                for i in 0 ..< n {
                    dest[filled + i] = block[i]
                }
                filled += n
                wipe(&previous)
                previous = block
            }
        }
        wipe(&previous)
        return out
    }

    /// RC4: the key schedule, then the key stream XORed with the data.
    static func rc4(key: SecureBytes, _ data: Data) -> Data {
        var s = [UInt8](0 ... 255)
        key.withUnsafeBytes { k in
            var j = 0
            for i in 0 ..< 256 {
                j = (j + Int(s[i]) + Int(k[i % k.count])) & 0xFF
                s.swapAt(i, j)
            }
        }
        var out = Data(count: data.count)
        out.withUnsafeMutableBytes { (o: UnsafeMutableRawBufferPointer) in
            data.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
                var i = 0, j = 0
                for n in 0 ..< input.count {
                    i = (i + 1) & 0xFF
                    j = (j + Int(s[i])) & 0xFF
                    s.swapAt(i, j)
                    o[n] = input[n] ^ s[(Int(s[i]) + Int(s[j])) & 0xFF]
                }
            }
        }
        wipe(&s)
        return out
    }

    static func wipe(_ bytes: inout [UInt8]) {
        let n = bytes.count
        if n > 0 {
            _ = bytes.withUnsafeMutableBytes { memset_s($0.baseAddress, n, 0, n) }
        }
    }
}
