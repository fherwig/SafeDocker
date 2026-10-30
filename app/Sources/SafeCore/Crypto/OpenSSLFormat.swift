import CommonCrypto
import Foundation

// The file format of openssl enc, as crypt.sh writes it, implemented here so
// that no update of the system's openssl can change what the app reads or
// writes (G5). docs/format.md describes it byte by byte.

/// The ways a .crypt file can have been written; only `current` is ever written.
public enum CryptVariant: String, Codable, CaseIterable {
    /// Salted__ + PBKDF2-HMAC-SHA512 100000 + AES-256-CBC (G3).
    case current
    /// EVP_BytesToKey(MD5), AES-256-CBC, salted or not.
    case legacyAESMD5
    /// EVP_BytesToKey(SHA-256), AES-256-CBC, salted or not.
    case legacyAESSHA256
    /// EVP_BytesToKey(MD5), RC4 128-bit, salted or not.
    case legacyRC4MD5
    /// EVP_BytesToKey(SHA-256), RC4 128-bit, salted or not.
    case legacyRC4SHA256
}

/// Everything that can go wrong with an encrypted file.
public enum CryptError: Error, Equatable {
    case notEncrypted, wrongPassword, corrupt, conflict, checkFailed,
         alreadyExists(String), io(String), selfTestFailed(String)
    /// A salted file whose length is not whole AES blocks: an old RC4 file with
    /// a wrong password, or a file cut short, by an interrupted copy or sync for
    /// example. The app asks for the password again, as for wrongPassword.
    case wrongPasswordOrDamaged
    /// The password seems right, but the end of the file is missing: the current
    /// format's padding check failed, while the start of what the key gives looks
    /// like the start of such a file (a copy or a sync cut short at a block
    /// boundary). CryptFile.readablePart gives what can be read.
    case damaged
}

/// The openssl enc file format, implemented in the app (G3, G5).
public enum OpenSSLFormat {
    /// "Salted__", the first 8 bytes of a salted file.
    static let magic: [UInt8] = Array("Salted__".utf8)
    static let saltLength = 8
    static let headerLength = 16
    static let iterations: UInt32 = 100_000
    static let keyLength = 32
    static let ivLength = 16
    static let blockLength = 16

    /// Encrypts in the current format with a fresh random 8-byte salt.
    public static func encrypt(_ plaintext: Data, password: SecureBytes) throws -> Data {
        var salt = [UInt8](repeating: 0, count: saltLength)
        guard CCRandomGenerateBytes(&salt, saltLength) == CCRNGStatus(kCCSuccess) else {
            throw CryptError.io("no random bytes for the salt")
        }
        return try encrypt(plaintext, password: password, salt: salt)
    }

    /// Encrypts in the current format with the given salt; the self-test uses
    /// it to reproduce reference files byte by byte.
    static func encrypt(_ plaintext: Data, password: SecureBytes, salt: [UInt8]) throws -> Data {
        precondition(salt.count == saltLength)
        let keyIV = try deriveCurrent(password: password, salt: salt)
        defer { keyIV.wipe() }

        // PKCS#7: 1 to 16 bytes, each holding the number of bytes added
        let full = plaintext.count / blockLength * blockLength
        let pad = blockLength - (plaintext.count - full)
        var output = Data(count: headerLength + full + blockLength)
        try output.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) in
            out.copyBytes(from: magic + salt)
            try plaintext.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
                try keyIV.withUnsafeBytes { k in
                    let key = UnsafeRawBufferPointer(rebasing: k[0 ..< keyLength])
                    var chain = [UInt8](k[keyLength ..< keyLength + ivLength])
                    if full > 0 {
                        try aes(CCOperation(kCCEncrypt), key: key, iv: chain,
                                input: UnsafeRawBufferPointer(rebasing: input[0 ..< full]),
                                output: UnsafeMutableRawBufferPointer(rebasing: out[headerLength ..< headerLength + full]))
                        // CBC: the last ciphertext block is the IV of the next
                        chain = [UInt8](out[headerLength + full - blockLength ..< headerLength + full])
                    }
                    var last = [UInt8](repeating: UInt8(pad), count: blockLength)
                    for i in 0 ..< blockLength - pad {
                        last[i] = input[full + i]
                    }
                    defer { _ = memset_s(&last, blockLength, 0, blockLength) }
                    try last.withUnsafeBytes { block in
                        try aes(CCOperation(kCCEncrypt), key: key, iv: chain, input: block,
                                output: UnsafeMutableRawBufferPointer(rebasing: out[headerLength + full ..< out.count]))
                    }
                }
            }
        }
        return output
    }

    /// Decrypts the current format only, with a strict PKCS#7 check.
    public static func decryptCurrent(_ ciphertext: Data, password: SecureBytes) throws -> Data {
        try decryptCurrentWithPadding(ciphertext, password: password).plaintext
    }

    /// decryptCurrent, and the number of padding bytes it removed (1 to 16).
    /// Nearly every wrong password that passes the padding check leaves one
    /// byte of padding, while a real file has one only once in 16 times;
    /// CryptFile uses this to judge files whose type it cannot check.
    static func decryptCurrentWithPadding(_ ciphertext: Data,
                                          password: SecureBytes) throws -> (plaintext: Data, padding: Int) {
        // a body that is not whole blocks is not a file in this format, whatever the key
        let (salt, body) = try split(ciphertext)
        if salt != nil && body.count % blockLength != 0 {
            throw CryptError.corrupt
        }
        switch try attemptCurrent(ciphertext, password: password, startLength: 0) {
        case .opened(let plaintext, let padding):
            return (plaintext, padding)
        case .badPadding:
            throw CryptError.wrongPassword
        }
    }

    /// What one attempt at the current format found.
    enum CurrentAttempt {
        /// The padding was right.
        case opened(plaintext: Data, padding: Int)
        /// The padding was wrong, or the body is not whole blocks: a wrong
        /// password, or a file cut short, at a block boundary or inside a block.
        /// `start` is the beginning of what this key gives, up to the asked length
        /// and never the last whole block (nor a partial block after it), so that
        /// CryptFile can judge whether it looks like the start of a real file
        /// (CryptError.damaged).
        case badPadding(start: Data)
    }

    /// Decrypts the current format with one key derivation. The last block is
    /// decrypted first: a wrong key nearly always fails its padding, and is then
    /// refused without decrypting the rest (only the first `startLength` bytes,
    /// for the damage check). A body that is not whole blocks cannot be this
    /// format as it was written, but it can be such a file cut short: its start
    /// is returned for the damage check too (finding of review round 4: such a
    /// file was called a wrong password). Throws .notEncrypted without the
    /// Salted__ header and .corrupt if nothing follows the salt.
    static func attemptCurrent(_ ciphertext: Data, password: SecureBytes,
                               startLength: Int) throws -> CurrentAttempt {
        let (salt, body) = try split(ciphertext)
        guard let salt = salt else {
            throw CryptError.notEncrypted
        }
        guard !body.isEmpty else {
            throw CryptError.corrupt
        }
        let keyIV = try deriveCurrent(password: password, salt: salt)
        defer { keyIV.wipe() }
        let whole = body.count / blockLength * blockLength
        if whole == body.count {
            do {
                let (plaintext, padding) = try decryptAESStrictWithPadding(body, keyIV: keyIV)
                return .opened(plaintext: plaintext, padding: padding)
            } catch CryptError.wrongPassword {}
        }
        let length = max(0, min(startLength, whole - blockLength)) / blockLength * blockLength
        return .badPadding(start: try decryptAESPrefix(body, length: length, keyIV: keyIV))
    }

    /// The current format without its last whole block (and without a partial
    /// block after it), whatever the padding: what can be read of a file cut
    /// short, at a block boundary or inside a block (CryptFile.readablePart).
    static func decryptCurrentWithoutLastBlock(_ ciphertext: Data, password: SecureBytes) throws -> Data {
        let (salt, body) = try split(ciphertext)
        guard let salt = salt else {
            throw CryptError.notEncrypted
        }
        let whole = body.count / blockLength * blockLength
        guard whole >= 2 * blockLength else {
            throw CryptError.corrupt
        }
        let keyIV = try deriveCurrent(password: password, salt: salt)
        defer { keyIV.wipe() }
        return try decryptAESPrefix(body, length: whole - blockLength, keyIV: keyIV)
    }

    /// Decrypts one legacy variant (never used for writing).
    public static func decryptLegacy(_ ciphertext: Data, password: SecureBytes,
                                     variant: CryptVariant) throws -> Data {
        if variant == .current {
            return try decryptCurrent(ciphertext, password: password)
        }
        return try Legacy.decrypt(ciphertext, password: password, variant: variant)
    }

    // MARK: - helpers shared with Legacy

    /// True if the data starts with "Salted__" and has room for the salt.
    static func hasSaltedHeader(_ data: Data) -> Bool {
        data.count >= headerLength && data.prefix(magic.count).elementsEqual(magic)
    }

    /// The salt (nil for a file without the Salted__ header) and the rest.
    /// A file that starts with Salted__ but is too short for the salt is corrupt.
    static func split(_ data: Data) throws -> (salt: [UInt8]?, body: Data) {
        if hasSaltedHeader(data) {
            let start = data.startIndex
            let salt = [UInt8](data[start + magic.count ..< start + headerLength])
            return (salt, Data(data[(start + headerLength)...]))
        }
        if data.count >= magic.count && data.prefix(magic.count).elementsEqual(magic) {
            throw CryptError.corrupt
        }
        return (nil, data)
    }

    /// PBKDF2-HMAC-SHA512, 100000 iterations, 48 bytes: the key, then the IV.
    static func deriveCurrent(password: SecureBytes, salt: [UInt8]) throws -> SecureBytes {
        let keyIV = SecureBytes(zeros: keyLength + ivLength)
        let status: Int32 = password.withUnsafeBytes { pw in
            keyIV.withUnsafeMutableBytes { out in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                     pw.baseAddress?.assumingMemoryBound(to: CChar.self), pw.count,
                                     salt, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512), iterations,
                                     out.baseAddress?.assumingMemoryBound(to: UInt8.self), out.count)
            }
        }
        guard status == kCCSuccess else {
            keyIV.wipe()
            throw CryptError.io("PBKDF2 failed with status \(status)")
        }
        return keyIV
    }

    /// AES-256-CBC without padding over whole blocks; decrypts into new memory
    /// and checks the PKCS#7 padding itself, because CCCrypt with
    /// kCCOptionPKCS7Padding accepts wrong keys.
    static func decryptAESStrict(_ body: Data, keyIV: SecureBytes) throws -> Data {
        try decryptAESStrictWithPadding(body, keyIV: keyIV).plaintext
    }

    /// decryptAESStrict, and the number of padding bytes removed. The last block
    /// is decrypted and its padding checked first (CBC: its IV is the block before
    /// it), so that a wrong key costs one block, not a pass over the whole file.
    static func decryptAESStrictWithPadding(_ body: Data,
                                            keyIV: SecureBytes) throws -> (plaintext: Data, padding: Int) {
        guard body.count >= blockLength, body.count % blockLength == 0 else {
            throw CryptError.corrupt
        }
        let pad = try lastBlockPadding(body, keyIV: keyIV)
        var plain = try decryptAESPrefix(body, length: body.count, keyIV: keyIV)
        let padOK = plain.withUnsafeBytes { (p: UnsafeRawBufferPointer) -> Bool in
            p[(p.count - pad)...].allSatisfy { Int($0) == pad }
        }
        guard padOK else {
            throw CryptError.wrongPassword
        }
        plain.count -= pad
        return (plain, pad)
    }

    /// Decrypts the last block alone and returns its PKCS#7 padding (1 to 16);
    /// throws .wrongPassword if it is not valid.
    static func lastBlockPadding(_ body: Data, keyIV: SecureBytes) throws -> Int {
        var last = [UInt8](repeating: 0, count: blockLength)
        defer { _ = memset_s(&last, blockLength, 0, blockLength) }
        try body.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
            try keyIV.withUnsafeBytes { k in
                let n = input.count
                let iv = n >= 2 * blockLength
                    ? [UInt8](input[n - 2 * blockLength ..< n - blockLength])
                    : [UInt8](k[keyLength ..< keyLength + ivLength])
                try last.withUnsafeMutableBytes { out in
                    try aes(CCOperation(kCCDecrypt),
                            key: UnsafeRawBufferPointer(rebasing: k[0 ..< keyLength]), iv: iv,
                            input: UnsafeRawBufferPointer(rebasing: input[n - blockLength ..< n]), output: out)
                }
            }
        }
        let pad = Int(last[blockLength - 1])
        guard pad >= 1 && pad <= blockLength,
              last[(blockLength - pad)...].allSatisfy({ Int($0) == pad }) else {
            throw CryptError.wrongPassword
        }
        return pad
    }

    /// Decrypts the first `length` bytes (whole blocks) of the body into new
    /// memory, without looking at the padding.
    static func decryptAESPrefix(_ body: Data, length: Int, keyIV: SecureBytes) throws -> Data {
        precondition(length >= 0 && length % blockLength == 0 && length <= body.count)
        var plain = Data(count: length)
        if length == 0 {
            return plain
        }
        try plain.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) in
            try body.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
                try keyIV.withUnsafeBytes { k in
                    try aes(CCOperation(kCCDecrypt),
                            key: UnsafeRawBufferPointer(rebasing: k[0 ..< keyLength]),
                            iv: [UInt8](k[keyLength ..< keyLength + ivLength]),
                            input: UnsafeRawBufferPointer(rebasing: input[0 ..< length]), output: out)
                }
            }
        }
        return plain
    }

    /// AES-256 in CBC mode without padding over whole blocks. The mode is named
    /// (kCCModeCBC), not left to CCCrypt's default (G5: no default is relied on).
    static func aes(_ operation: CCOperation, key: UnsafeRawBufferPointer, iv: [UInt8],
                    input: UnsafeRawBufferPointer, output: UnsafeMutableRawBufferPointer) throws {
        precondition(key.count == keyLength && iv.count == ivLength)
        precondition(input.count % blockLength == 0 && output.count >= input.count)
        var cryptor: CCCryptorRef?
        var status = CCCryptorCreateWithMode(operation, CCMode(kCCModeCBC), CCAlgorithm(kCCAlgorithmAES),
                                             CCPadding(ccNoPadding), iv, key.baseAddress, key.count,
                                             nil, 0, 0, CCModeOptions(0), &cryptor)
        guard status == kCCSuccess, let ref = cryptor else {
            throw CryptError.io("AES failed with status \(status)")
        }
        defer { CCCryptorRelease(ref) }
        var moved = 0
        status = CCCryptorUpdate(ref, input.baseAddress, input.count, output.baseAddress, output.count, &moved)
        guard status == kCCSuccess, moved == input.count else {
            throw CryptError.io("AES failed with status \(status)")
        }
    }
}
