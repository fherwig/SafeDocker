import Foundation

/// A .crypt file that was opened, with what is needed to save it again.
public struct OpenedFile {
    /// The .crypt file.
    public let url: URL
    /// The file name without ".crypt".
    public let originalName: String
    /// What the decrypted content is.
    public let kind: FileKind
    /// The format the file was written in.
    public let variant: CryptVariant
    /// SHA-256 of the file as read, for the conflict check at save.
    public let ciphertextSHA256: Data
    /// Whether Safe could confirm that the password was right.
    public let check: PasswordCheck
}

/// How sure Safe is that the password that opened a file was right (building
/// plan 4.4, 5.1, 5.2). Only `confirmed` results are shown without asking; for
/// the others the user decides, because the right password must never be
/// refused and garbage must never be shown as if it were the file.
public enum PasswordCheck: Equatable {
    /// The content is plausible for the original name; or the current format
    /// opened a file whose type cannot be checked and removed more than one byte
    /// of padding, which a wrong password does about once in 65,000 tries.
    case confirmed
    /// The current format or an older AES variant opened it with valid padding,
    /// but the content does not look like a file with this name: text that is not
    /// UTF-8, for example, or a picture in a format Safe does not know. Or an older
    /// RC4 variant gave text in another encoding for a text name. The password may
    /// be wrong (about 1 in 256 wrong passwords passes the padding check), or the
    /// file is unusual.
    case contentMismatch
    /// Safe cannot check the type: the current format with one byte of padding,
    /// an older variant of a type that cannot be checked, or an RC4 text shorter
    /// than Plausibility.shortestUncheckedText. Or the text is too short to tell
    /// from what a wrong password gives: a text of 15 bytes from an AES variant
    /// that removed one byte of padding (CryptFile.decrypt).
    case unchecked
}

/// Encrypt, open, save and export single files (R1, R2, R3).
public enum CryptFile {
    /// Set by the app when its self-test failed (G5): encryptFile and save then
    /// throw .selfTestFailed with this text, so the app never writes a file it
    /// might not read back. nil allows writing.
    public static var writeRefusal: String? {
        get { State.locked { State.refusal } }
        set { State.locked { State.refusal = newValue } }
    }

    /// Test hook: when true, the read-back check in encryptFile and save fails
    /// as if the new file were damaged. The app never sets it.
    public static var testHookFailCheck: Bool {
        get { State.locked { State.failCheck } }
        set { State.locked { State.failCheck = newValue } }
    }

    /// The largest file encryptFile takes, in bytes. Encrypting holds the file, its
    /// encryption and the check's copies in memory, about four times its size;
    /// larger files belong in a volume (R4). The tests lower it.
    public static var largestFileToEncrypt: Int {
        get { State.locked { State.largest } }
        set { State.locked { State.largest = newValue } }
    }

    /// The message for a file above largestFileToEncrypt, naming the file, or
    /// starting with "It" if `name` is nil (or the English word "It").
    public static func tooLargeMessage(_ name: String?) -> String {
        let limit = largestFileToEncrypt
        let size: String
        if limit >= 1 << 30 && limit % (1 << 30) == 0 {
            size = "\(limit >> 30) GB"
        } else if limit >= 1 << 20 {
            size = "\(limit >> 20) MB"
        } else {
            size = Lp(limit, "%ld byte", "%ld bytes")
        }
        guard let name = name, name != "It" else {
            return L("""
                It is larger than %@, too large to encrypt as one file. Put it in an encrypted \
                volume instead: make one in Safe's Volumes window and move the file there
                """, size)
        }
        return L("""
            %@ is larger than %@, too large to encrypt as one file. Put it in an encrypted \
            volume instead: make one in Safe's Volumes window and move the file there
            """, name, size)
    }

    /// The message for a file with other names (hard links): deleting one name
    /// would leave the plaintext on the disk under the others.
    public static func hardLinksMessage(_ name: String) -> String {
        L("""
            %@ has other names (hard links), which would keep it unencrypted on the disk after \
            the original is deleted, so it was not encrypted
            """, name)
    }

    /// R1: NAME -> NAME.crypt, read back and compare, then delete NAME.
    public static func encryptFile(at url: URL, password: SecureBytes) throws -> URL {
        try checkWritesAllowed()
        let path = url.path
        let name = url.lastPathComponent
        guard FileIO.isRegularFile(path) else {
            throw CryptError.io(L("%@ is not a regular file, so it cannot be encrypted", path))
        }
        if let size = FileIO.size(path), size > largestFileToEncrypt {
            throw CryptError.io(tooLargeMessage(name))
        }
        let target = path + ".crypt"
        let temporary = path + ".crypt_new"
        if FileIO.exists(target) {
            throw CryptError.alreadyExists(target)
        }
        // another name of the same file would keep the plaintext after the delete
        if FileIO.linkCount(path) > 1 {
            throw CryptError.io(hardLinksMessage(name))
        }
        // only the data fork is encrypted; a resource fork would be lost with the original
        if getxattr(path, XATTR_RESOURCEFORK_NAME, nil, 0, 0, XATTR_NOFOLLOW) > 0 {
            throw CryptError.io(L("""
                %@ has a resource fork, which an encrypted file cannot keep, so it was not \
                encrypted. Put it in an encrypted volume instead
                """, name))
        }
        let plaintext = try FileIO.read(path)
        let ciphertext = try OpenSSLFormat.encrypt(plaintext, password: password)

        // building plan 5.3, from step 2
        try FileIO.removeIfPresent(temporary)
        try FileIO.writeNew(temporary, ciphertext)
        _ = try readBackAndCompare(temporary, plaintext, password)
        do {
            try FileIO.renameExclusive(temporary, target)
        } catch {
            unlink(temporary)
            throw error
        }
        FileIO.syncDirectory(FileIO.directory(of: path))

        // the original goes only if it is still what was encrypted
        guard let now = try? FileIO.read(path), now == plaintext else {
            throw CryptError.io(L("%@ changed while it was being encrypted, so it was kept; %@.crypt holds the earlier version",
                                  name, name))
        }
        if unlink(path) != 0 {
            throw CryptError.io(L("%@.crypt was written, but cannot delete %@: %@", name, path, FileIO.reason()))
        }
        FileIO.syncDirectory(FileIO.directory(of: path))
        return URL(fileURLWithPath: target)
    }

    /// R2, R3: read and decrypt; tries the current format, then legacy variants (G5).
    ///
    /// Throws .wrongPassword only when no format gives a result that could be
    /// right. A result that Safe cannot confirm comes back with
    /// `OpenedFile.check` other than `.confirmed`: the app must then ask the user
    /// before showing or exporting it (building plan 4.4 and 5.2).
    public static func open(at url: URL, password: SecureBytes,
                            allowLegacy: Bool) throws -> (OpenedFile, Data) {
        // a link is followed, so that saving replaces the file and not the link
        let fileURL = url.resolvingSymlinksInPath()
        let data = try FileIO.read(fileURL.path)
        let name = originalName(of: url.lastPathComponent)
        let result = try decrypt(data, originalName: name, password: password, allowLegacy: allowLegacy)
        let opened = OpenedFile(url: fileURL, originalName: name,
                                kind: FileKind.classify(originalName: name, plaintext: result.plaintext),
                                variant: result.variant, ciphertextSHA256: FileIO.sha256(data),
                                check: result.check)
        return (opened, result.plaintext)
    }

    /// R2: save in the current format (sequence in 5.3). Throws .conflict if the file
    /// changed on disk since it was opened.
    public static func save(_ plaintext: Data, over opened: OpenedFile,
                            password: SecureBytes) throws -> OpenedFile {
        try save(plaintext, over: opened, password: password, replacingBackup: true)
    }

    /// The same; with `replacingBackup` false an existing NAME.crypt.bak is kept
    /// instead of being replaced in step 4. The editor saves so after its first
    /// save of a file whose password Safe could not confirm: if the password was
    /// wrong after all, the .bak still holds the file as it was before.
    public static func save(_ plaintext: Data, over opened: OpenedFile, password: SecureBytes,
                            replacingBackup: Bool) throws -> OpenedFile {
        try checkWritesAllowed()
        let path = opened.url.path
        let temporary = path + "_new"
        let backup = path + ".bak"

        // 1. the file must be as it was when it was opened
        let before: Data
        do {
            before = try FileIO.read(path)
        } catch {
            if !FileIO.exists(path) {
                throw CryptError.conflict
            }
            throw error
        }
        guard FileIO.sha256(before) == opened.ciphertextSHA256 else {
            throw CryptError.conflict
        }

        // 2. encrypt into NAME.crypt_new
        let ciphertext = try OpenSSLFormat.encrypt(plaintext, password: password)
        try FileIO.removeIfPresent(temporary)
        try FileIO.writeNew(temporary, ciphertext)

        // 3. read it back and compare
        let written = try readBackAndCompare(temporary, plaintext, password)

        // 4. the previous version becomes NAME.crypt.bak
        do {
            if replacingBackup || !FileIO.exists(backup) {
                try FileIO.removeIfPresent(backup)
                try FileIO.writeNew(backup, before)
            }
        } catch {
            unlink(temporary)
            var reason = "\(error)"
            if case CryptError.io(let text) = error {
                reason = text
            }
            throw CryptError.io(L("cannot save %@, nothing changed: %@", backup, reason))
        }

        // 5. replace NAME.crypt in one step
        do {
            try FileIO.rename(temporary, path)
        } catch {
            unlink(temporary)
            throw error
        }
        FileIO.syncDirectory(FileIO.directory(of: path))

        // 6.
        return OpenedFile(url: opened.url, originalName: opened.originalName, kind: opened.kind,
                          variant: .current, ciphertextSHA256: FileIO.sha256(written),
                          check: opened.check)
    }

    /// R3: write the decrypted original to a place the user chose.
    /// An existing file there is replaced; the save panel has asked.
    public static func export(_ plaintext: Data, to url: URL) throws {
        let path = url.path
        let directory = FileIO.directory(of: path)
        let temporary = (directory as NSString).appendingPathComponent(exportTemporaryName(for: url.lastPathComponent))
        try FileIO.writeNew(temporary, plaintext)
        do {
            try FileIO.rename(temporary, path)
        } catch {
            unlink(temporary)
            throw error
        }
        FileIO.syncDirectory(directory)
    }

    /// The name of export's temporary file: visible, and named after the target,
    /// so that a copy left by a crash or a power cut can be seen and deleted
    /// ("notes.txt (exporting 1A2B3C4D).tmp").
    public static func exportTemporaryName(for name: String) -> String {
        var base = name
        while base.utf8.count > 150 {
            base.removeLast()
        }
        return "\(base) (exporting \(UUID().uuidString.prefix(8))).tmp"
    }

    // MARK: - files that open only in part, or only unchecked

    /// For a file that open reported as .damaged: the current format without its
    /// last whole block (and a partial block after it), which is what can be read
    /// of a file cut short, and the original name. Throws .wrongPassword unless
    /// the start still looks like a file of that name, as open found.
    public static func readablePart(at url: URL, password: SecureBytes) throws -> (originalName: String, data: Data) {
        try readablePart(at: url, password: password, checked: true)
    }

    /// The same; with `checked` false, whatever the start looks like: for a file
    /// that mayBeCutShort, whose start Safe cannot recognise, exported only after
    /// the user chose it and with the warning that Safe could not check it.
    public static func readablePart(at url: URL, password: SecureBytes,
                                    checked: Bool) throws -> (originalName: String, data: Data) {
        let data = try FileIO.read(url.resolvingSymlinksInPath().path)
        let name = originalName(of: url.lastPathComponent)
        let part = try OpenSSLFormat.decryptCurrentWithoutLastBlock(data, password: password)
        if checked && !Plausibility.looksLikeStartOfFile(part.prefix(damageCheckLength), originalName: name) {
            throw CryptError.wrongPassword
        }
        return (name, part)
    }

    /// True if a file that no variant confirmed may be a file in the current
    /// format cut short whose start Safe cannot recognise (G5, R2: the right
    /// password must not be refused): it has the Salted__ header and at least two
    /// whole blocks after it, and its name is a text name or of a type that Safe
    /// cannot check (for other types the start is recognised, and then open
    /// reports .damaged itself). Only the user can judge its readable part
    /// (readablePart(checked: false)).
    public static func mayBeCutShort(at url: URL) -> Bool {
        let name = originalName(of: url.lastPathComponent)
        guard FileKind.isTextName(name) || Plausibility.check(Data(), originalName: name) == .unknownType,
              let size = FileIO.size(url.resolvingSymlinksInPath().path),
              size >= OpenSSLFormat.headerLength + 2 * OpenSSLFormat.blockLength
        else { return false }
        return OpenSSLFormat.hasSaltedHeader(header(of: url))
    }

    /// True if a file that no variant opened may still be an old RC4 file that
    /// Safe cannot check (G5): it has something after its header, and its name is
    /// a text name or of a type that Safe cannot check. RC4 decrypts with any
    /// password, so only the user can judge the result (decryptOldRC4).
    public static func mayBeOldRC4(at url: URL) -> Bool {
        let name = originalName(of: url.lastPathComponent)
        guard FileKind.isTextName(name) || Plausibility.check(Data(), originalName: name) == .unknownType,
              let size = FileIO.size(url.resolvingSymlinksInPath().path)
        else { return false }
        let salted = OpenSSLFormat.hasSaltedHeader(header(of: url))
        return size > (salted ? OpenSSLFormat.headerLength : 0)
    }

    /// The first 16 bytes of the file (fewer if it is shorter, none if it cannot be read).
    private static func header(of url: URL) -> Data {
        guard let handle = FileHandle(forReadingAtPath: url.resolvingSymlinksInPath().path) else {
            return Data()
        }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: OpenSSLFormat.headerLength)) ?? Data()
    }

    /// The file decrypted with an RC4 variant, whatever comes out: only for Export
    /// after the user typed the same password twice and chose to (G5). Never shown
    /// in a window and never saved again: with a wrong password it is meaningless.
    public static func decryptOldRC4(at url: URL, password: SecureBytes,
                                     variant: CryptVariant) throws -> (originalName: String, data: Data) {
        guard Legacy.isRC4(variant) else {
            throw CryptError.io("\(variant.rawValue) is not an RC4 variant")
        }
        let data = try FileIO.read(url.resolvingSymlinksInPath().path)
        return (originalName(of: url.lastPathComponent),
                try Legacy.decrypt(data, password: password, variant: variant))
    }

    // MARK: - internals

    /// How much of the start of a file the damage check and the RC4 check look at.
    static let damageCheckLength = 4096

    private enum State {
        static let lock = NSLock()
        static var refusal: String?
        static var failCheck = false
        static var largest = 1 << 30

        static func locked<R>(_ body: () -> R) -> R {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }
    }

    static func checkWritesAllowed() throws {
        if let reason = writeRefusal {
            throw CryptError.selfTestFailed(reason)
        }
    }

    /// The name of the original file: "notes.txt.crypt" and
    /// "notes.txt.crypt.bak" give "notes.txt"; other names stay as they are.
    static func originalName(of fileName: String) -> String {
        for suffix in [".crypt", ".crypt.bak"] where fileName.count > suffix.count {
            if fileName.lowercased().hasSuffix(suffix) {
                return String(fileName.dropLast(suffix.count))
            }
        }
        return fileName
    }

    /// Reads the new file back, decrypts it and compares it with the
    /// plaintext; on a mismatch deletes it and throws .checkFailed.
    /// Returns the bytes read.
    static func readBackAndCompare(_ path: String, _ plaintext: Data,
                                   _ password: SecureBytes) throws -> Data {
        var written: Data?
        var same = false
        do {
            let bytes = try FileIO.read(path)
            written = bytes
            same = try OpenSSLFormat.decryptCurrent(bytes, password: password) == plaintext
        } catch {
            same = false
        }
        if testHookFailCheck {
            same = false
        }
        guard same, let bytes = written else {
            unlink(path)
            throw CryptError.checkFailed
        }
        return bytes
    }

    /// What decrypt found.
    struct Decrypted {
        let variant: CryptVariant
        let plaintext: Data
        let check: PasswordCheck
    }

    /// A result that could be right but was not confirmed, with what decides
    /// between several of them.
    struct Candidate {
        let result: Decrypted
        /// The bytes of padding removed; nil for RC4, which has none.
        let padding: Int?
        /// For a text name: the result is text, in UTF-8 or another encoding.
        let textLike: Bool

        var isCurrent: Bool { result.variant == .current }
        var removedMoreThanOneByte: Bool { (padding ?? 0) > 1 }

        /// True if this is a better guess than `other`: for a text name, text
        /// before anything else; then the current format before an older one,
        /// unless the older one removed more than one byte of padding and the
        /// current one only one, as a wrong key nearly always leaves; then more
        /// padding before less; otherwise the earlier attempt.
        func isBetter(than other: Candidate) -> Bool {
            if textLike != other.textLike {
                return textLike
            }
            if isCurrent != other.isCurrent {
                let (current, older) = isCurrent ? (self, other) : (other, self)
                let olderWins = older.removedMoreThanOneByte && current.padding == 1
                return isCurrent ? !olderWins : olderWins
            }
            if removedMoreThanOneByte != other.removedMoreThanOneByte {
                return removedMoreThanOneByte
            }
            return false
        }
    }

    /// Decrypts file contents: the current format first, then, if allowed, the
    /// legacy variants in the order of the building plan, 5.2.
    ///
    /// - A plausible result is confirmed: the current format's at once, else the
    ///   first older variant's. So is a current result of a type that cannot be
    ///   checked that removed more than one byte of padding, and a current result
    ///   that is a picture or gzip, whatever the name.
    /// - Any other result that could be right is kept, so that the right password
    ///   is never refused, and comes back unconfirmed if no plausible one turns
    ///   up: a current result whose padding is right (contentMismatch, or
    ///   unchecked for a type that cannot be checked); an older AES result whose
    ///   padding is right (contentMismatch, or unchecked); an older RC4 result,
    ///   which has no padding and so comes with any password, only if it is text
    ///   in another encoding for a text name (contentMismatch, see
    ///   Plausibility.looksLikeText), if it is plausible but shorter than
    ///   Plausibility.shortestUncheckedText (unchecked, and never ranked as text:
    ///   random bytes that short are UTF-8 too often), or, for a type that cannot
    ///   be checked, if the file cannot be AES, being salted and not whole blocks
    ///   (unchecked).
    /// - Between several kept results Candidate.isBetter decides.
    /// - A text of 15 bytes from an AES variant that removed one byte of padding
    ///   is kept unchecked, not confirmed (tooShortToConfirm).
    /// - Without a confirmed one: .damaged if the current format's padding check
    ///   failed, or its body is not whole blocks, but the start of what its key
    ///   gives looks like the start of a file of this name
    ///   (Plausibility.looksLikeStartOfFile: the file was cut short, and the
    ///   password is very likely right); then the best kept result; else .corrupt
    ///   for a salted file with nothing after the salt, .wrongPasswordOrDamaged
    ///   for a salted file that is not whole blocks (only RC4 or a damaged file
    ///   has that length), .notEncrypted for a file without the header that
    ///   already looks like its type, else .wrongPassword. Without allowLegacy a
    ///   salted file that is not whole blocks and does not look cut short is
    ///   .corrupt.
    static func decrypt(_ data: Data, originalName: String, password: SecureBytes,
                        allowLegacy: Bool) throws -> Decrypted {
        if data.isEmpty {
            throw CryptError.notEncrypted
        }
        let salted = OpenSSLFormat.hasSaltedHeader(data)
        if !salted && data.starts(with: OpenSSLFormat.magic) {
            // Salted__ without room for the salt
            throw CryptError.corrupt
        }
        let textName = FileKind.isTextName(originalName)
        func isText(_ plain: Data, _ verdict: Plausibility.Verdict) -> Bool {
            textName && (verdict == .plausible || Plausibility.looksLikeText(plain))
        }
        // a plausible text of 15 bytes with one byte of padding is not confirmed:
        // a wrong key leaves that about once in 27 million tries (review round 4)
        func tooShortToConfirm(_ plain: Data, padding: Int?) -> Bool {
            textName && padding == 1 && plain.count < OpenSSLFormat.blockLength
        }
        var best: Candidate?
        func keep(_ variant: CryptVariant, _ plain: Data, _ check: PasswordCheck, padding: Int?, text: Bool) {
            let candidate = Candidate(result: Decrypted(variant: variant, plaintext: plain, check: check),
                                      padding: padding, textLike: text)
            if best.map({ candidate.isBetter(than: $0) }) ?? true {
                best = candidate
            }
        }

        var failure = CryptError.wrongPassword
        // the current format's padding failed (or its body is not whole blocks),
        // but its start looks like a real file
        var cutShort = false
        let plainLooksRight = !salted && Plausibility.check(data, originalName: originalName) == .plausible
        let bodyLength = salted ? data.count - OpenSSLFormat.headerLength : data.count
        let cannotBeAES = salted && bodyLength % OpenSSLFormat.blockLength != 0
        if salted {
            do {
                switch try OpenSSLFormat.attemptCurrent(data, password: password, startLength: damageCheckLength) {
                case .opened(let plain, let padding):
                    let verdict = Plausibility.check(plain, originalName: originalName)
                    if verdict == .plausible && tooShortToConfirm(plain, padding: padding) {
                        keep(.current, plain, .unchecked, padding: padding, text: true)
                        break
                    }
                    if verdict == .plausible || Plausibility.isKnownTypeForCurrentFormat(plain) {
                        return Decrypted(variant: .current, plaintext: plain, check: .confirmed)
                    }
                    if verdict == .unknownType {
                        if padding > 1 {
                            return Decrypted(variant: .current, plaintext: plain, check: .confirmed)
                        }
                        keep(.current, plain, .unchecked, padding: padding, text: false)
                    } else {
                        keep(.current, plain, .contentMismatch, padding: padding, text: isText(plain, verdict))
                    }
                case .badPadding(let start):
                    cutShort = Plausibility.looksLikeStartOfFile(start, originalName: originalName)
                }
            } catch let error as CryptError {
                failure = error
            }
        } else {
            // without the header only an unsalted legacy file is possible. A file
            // that clearly looks like its type is not encrypted; short content can
            // look so by chance, so then the older variants are tried first
            if !allowLegacy || (plainLooksRight &&
                (data.count >= Plausibility.shortestUncheckedText || Magic.isStrongType(data))) {
                throw CryptError.notEncrypted
            }
        }
        guard allowLegacy else {
            if cutShort {
                throw CryptError.damaged
            }
            if let best = best {
                return best.result
            }
            throw cannotBeAES ? CryptError.corrupt : failure
        }

        for variant in Legacy.order {
            let rc4 = Legacy.isRC4(variant)
            if rc4 && bodyLength == 0 {
                continue    // RC4 of nothing is nothing, with any password
            }
            if rc4 && cutShort {
                // only a plausible RC4 result could beat the damage found, which with
                // the right password of a cut file is as unlikely as the reverse
                continue
            }
            if rc4 && bodyLength > damageCheckLength {
                // a look at the start first: most wrong passwords end here, without
                // a second copy of a large file
                guard let start = try? Legacy.decryptRC4Start(data, password: password, variant: variant,
                                                              length: damageCheckLength),
                      Plausibility.rc4StartCouldBeKept(start, originalName: originalName, cannotBeAES: cannotBeAES)
                else { continue }
            }
            guard let (plain, padding) = try? Legacy.decryptWithPadding(data, password: password,
                                                                         variant: variant) else {
                continue
            }
            let verdict = Plausibility.check(plain, originalName: originalName)
            switch verdict {
            case .plausible:
                if rc4 && plain.count < Plausibility.shortestUncheckedText {
                    // random bytes that short are UTF-8 often: not evidence of text
                    // (finding of review round 3: it beat the right current result)
                    keep(variant, plain, .unchecked, padding: padding, text: false)
                    continue
                }
                if !rc4 && tooShortToConfirm(plain, padding: padding) {
                    keep(variant, plain, .unchecked, padding: padding, text: true)
                    continue
                }
                return Decrypted(variant: variant, plaintext: plain, check: .confirmed)
            case .implausible:
                let text = isText(plain, verdict)
                if !rc4 || text {
                    keep(variant, plain, .contentMismatch, padding: padding, text: text)
                }
            case .unknownType:
                if !rc4 || cannotBeAES {
                    keep(variant, plain, .unchecked, padding: padding, text: false)
                }
            }
        }
        if cutShort {
            // stronger evidence than any result kept: about 1 in 256 wrong keys
            // passes an older AES padding check, 1 in 10^8 passes this one
            throw CryptError.damaged
        }
        if let best = best {
            return best.result
        }
        if salted && bodyLength == 0 {
            throw CryptError.corrupt
        }
        if cannotBeAES {
            throw CryptError.wrongPasswordOrDamaged
        }
        if plainLooksRight {
            throw CryptError.notEncrypted
        }
        throw CryptError.wrongPassword
    }
}
