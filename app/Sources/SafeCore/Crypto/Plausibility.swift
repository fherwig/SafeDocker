import Foundation

// About 1 in 256 wrong passwords gets through the padding check and yields
// garbage. These checks catch it: text must be valid UTF-8 without NUL bytes,
// and known binary types must start with their magic bytes. docs/format.md
// lists the rules.
//
// A check that fails does not prove that the password was wrong: a text file
// in ISO Latin-1 or UTF-16 is not UTF-8, and a picture can be in a format that
// Safe does not know. CryptFile therefore never refuses a current-format result
// whose padding is right; it reports that the password could not be confirmed,
// and the user decides (building plan 4.4).

/// Decides whether decrypted bytes are believable, so a wrong password is never shown as text.
public enum Plausibility {
    /// Is this decrypted content believable for a file originally named `originalName`?
    /// Text endings need valid UTF-8 (no NUL); known binary types need their magic bytes.
    ///
    /// - Content that starts with the magic bytes of a known type (Magic.isStrongType)
    ///   counts whatever the ending, because files are often misnamed.
    /// - Text endings: valid UTF-8 without NUL bytes, else implausible. A text
    ///   shorter than `shortestUncheckedText` bytes must also be free of control
    ///   bytes other than tab, line feed, form feed and carriage return: 15 random
    ///   bytes are strict UTF-8 without NUL about once in 6,600 tries, but also
    ///   without such control bytes only once in 107,000 (finding of review
    ///   round 4). Longer texts keep the plain rule, so that a log with escape
    ///   codes still counts.
    /// - Endings of known binary types: the magic bytes of their type, else implausible.
    /// - Other endings: UTF-8 text of at least `shortestUncheckedText` bytes counts;
    ///   anything else is unknownType.
    public static func check(_ plaintext: Data, originalName: String) -> Verdict {
        let ending = FileEnding.of(originalName)
        if Magic.isStrongType(plaintext) {
            return .plausible
        }
        if FileEnding.text.contains(ending) {
            guard Magic.isUTF8TextWithoutNUL(plaintext) else { return .implausible }
            if plaintext.count < shortestUncheckedText && plaintext.contains(where: Magic.isControlByte) {
                return .implausible
            }
            return .plausible
        }
        if let family = FileFamily.of(ending: ending) {
            return family.matches(plaintext) ? .plausible : .implausible
        }
        if plaintext.count >= shortestUncheckedText && Magic.isUTF8TextWithoutNUL(plaintext) {
            return .plausible
        }
        return .unknownType
    }

    /// The answer of check(_:originalName:).
    public enum Verdict { case plausible, implausible, unknownType }

    /// The shortest UTF-8 text that counts as plausible for a name whose type Safe
    /// cannot check. 32 random bytes are strict UTF-8 without NUL about once in 10^8
    /// tries; 16 bytes about once in 12,000. RC4 results shorter than this are never
    /// trusted without the user's yes (CryptFile.decrypt).
    public static let shortestUncheckedText = 32

    /// True if the bytes look like text in another encoding than UTF-8, which the
    /// check above refuses for a text name: an 8-bit encoding (ISO Latin-1,
    /// Windows-1252, MacRoman and the like), or UTF-16 after a byte order mark.
    /// It does not confirm a password; it tells such text apart from the random
    /// bytes that a wrong password gives, which practically never pass it.
    ///
    /// - 8-bit text: at least `shortestUncheckedText` bytes, no NUL or other
    ///   control byte except tab, line feed, form feed and carriage return, and at
    ///   least 80 % ASCII. Random bytes of 32 bytes pass about once in 3 million
    ///   tries, 48 bytes once in 3 billion, longer ones even more rarely.
    /// - UTF-16: the byte order mark FF FE or FE FF, an even number of at least
    ///   `shortestUncheckedText` bytes, valid UTF-16 without control characters
    ///   other than those four, and at least 90 % of the characters in the common
    ///   scripts (Latin, Greek, Cyrillic, Hebrew, Arabic, CJK, Hangul, punctuation)
    ///   or outside the basic plane, such as emoji. Random bytes have the byte
    ///   order mark once in 32,768 tries, and then pass the rest about once in a
    ///   thousand for 32 bytes, more rarely when longer.
    public static func looksLikeText(_ data: Data) -> Bool {
        Magic.isEightBitText(data) || Magic.isUTF16Text(data)
    }

    /// True if a file with this name must start with the first bytes of its type:
    /// PDF, ZIP-based documents, the Office compound file, archives, media, RTF and
    /// SQLite. A result of such a name that matches no known type is nearly always
    /// a wrong password, and the app says so (building plan 4.4). Pictures are not
    /// counted, because a picture may be in a format Safe does not know.
    public static func needsMagicBytes(_ originalName: String) -> Bool {
        let ending = FileEnding.of(originalName)
        guard let family = FileFamily.of(ending: ending) else { return false }
        return family.endings != FileEnding.image
    }

    /// True for content that the current format may confirm whatever the name:
    /// a picture (JPEG's three bytes included) or gzip. With the padding check
    /// before it, a wrong password gets this far about once in 4 billion tries.
    static func isKnownTypeForCurrentFormat(_ data: Data) -> Bool {
        Magic.isImage(data) || Magic.isGzip(data)
    }

    /// True if `start`, the beginning of what a key gives for a file whose
    /// padding check failed, looks like the beginning of a real file of this
    /// name: then the password is very likely right and the end of the file is
    /// missing (CryptError.damaged). There is no padding check before this, so
    /// the evidence must be strong: the first bytes of a known type (JPEG and
    /// gzip with one more byte than usual), or for a text name or a name whose
    /// type cannot be checked, UTF-8 text of at least `shortestUncheckedText`
    /// bytes, whose last character may be cut, or for a text name text in
    /// another encoding of at least 64 bytes. Random bytes pass about once in
    /// 10^8 tries.
    static func looksLikeStartOfFile(_ start: Data, originalName: String) -> Bool {
        if Magic.isStrongType(start) || Magic.isStrongJPEG(start) || Magic.isStrongGzip(start)
            || Magic.isBzip2(start) {
            return true
        }
        let ending = FileEnding.of(originalName)
        let textName = FileEnding.text.contains(ending)
        if !textName && FileFamily.of(ending: ending) != nil {
            return false
        }
        if start.count >= shortestUncheckedText && Magic.isUTF8TextAllowingCutEnd(start) {
            return true
        }
        return textName && start.count >= 2 * shortestUncheckedText && looksLikeText(start)
    }

    /// True if RC4's result could be kept by CryptFile.decrypt, judged from its
    /// first bytes only (`start`, at most a few KB): false only if the whole
    /// result cannot be plausible or text, so that the rest need not be
    /// decrypted. For a name whose type cannot be checked, in a file that cannot
    /// be AES, any result is kept, so this is true.
    static func rc4StartCouldBeKept(_ start: Data, originalName: String, cannotBeAES: Bool) -> Bool {
        if Magic.isStrongType(start) {
            return true
        }
        let ending = FileEnding.of(originalName)
        if FileEnding.text.contains(ending) {
            // UTF-8, or text in an 8-bit encoding (no control byte anywhere), or UTF-16
            return Magic.isUTF8TextAllowingCutEnd(start) || !start.contains(where: Magic.isControlByte)
                || Magic.hasUTF16ByteOrderMark(start)
        }
        if let family = FileFamily.of(ending: ending) {
            return family.matches(start)
        }
        return cannotBeAES || Magic.isUTF8TextAllowingCutEnd(start)
    }
}

/// File endings, lower case and without the dot.
enum FileEnding {
    /// Endings of text files; "" is a file without an ending, such as safe.
    static let text: Set<String> = ["", "txt", "md", "markdown", "csv", "json", "yaml", "yml",
                                    "xml", "tex", "log"]
    static let pdf: Set<String> = ["pdf"]
    static let image: Set<String> = ["png", "jpg", "jpeg", "gif", "tif", "tiff", "heic", "heif",
                                     "webp", "bmp", "avif"]

    /// The ending of the last path component: "notes.txt" gives "txt",
    /// "safe" and ".profile" give "".
    static func of(_ name: String) -> String {
        let last = name.split(separator: "/").last.map(String.init) ?? name
        guard let dot = last.lastIndex(of: "."), dot != last.startIndex else {
            return ""
        }
        return String(last[last.index(after: dot)...]).lowercased()
    }
}

/// Binary types whose files always start with the same bytes, by ending. A file
/// with one of these endings must start with the bytes of its type, or with
/// those of another known type (Magic.isStrongType).
struct FileFamily {
    let endings: Set<String>
    let matches: (Data) -> Bool

    static let all: [FileFamily] = [
        FileFamily(endings: FileEnding.pdf, matches: Magic.isPDF),
        // any picture counts for a picture ending, a PNG saved as .jpg for example
        FileFamily(endings: FileEnding.image, matches: Magic.isImage),
        // not .key: besides Keynote, a private key (PEM text or DER) is named so,
        // and an unknown ending counts with ZIP's first bytes or with UTF-8 text
        FileFamily(endings: ["zip", "docx", "docm", "xlsx", "xlsm", "pptx", "pptm", "odt", "ods",
                             "odp", "odg", "epub", "pages", "numbers", "jar", "kmz"],
                   matches: Magic.isZIP),
        FileFamily(endings: ["doc", "xls", "ppt", "msg"], matches: Magic.isOLE2),
        FileFamily(endings: ["gz", "tgz"], matches: Magic.isGzip),
        FileFamily(endings: ["bz2", "tbz", "tbz2"], matches: Magic.isBzip2),
        FileFamily(endings: ["xz", "txz"], matches: Magic.isXZ),
        FileFamily(endings: ["zst"], matches: Magic.isZstd),
        FileFamily(endings: ["7z"], matches: Magic.is7z),
        FileFamily(endings: ["rar"], matches: Magic.isRAR),
        FileFamily(endings: ["wav"], matches: { Magic.isRIFF($0, form: "WAVE") }),
        FileFamily(endings: ["avi"], matches: { Magic.isRIFF($0, form: "AVI ") }),
        FileFamily(endings: ["mp4", "m4a", "m4v", "3gp"], matches: Magic.isISOMedia),
        FileFamily(endings: ["flac"], matches: Magic.isFLAC),
        FileFamily(endings: ["ogg", "oga", "ogv", "opus"], matches: Magic.isOgg),
        FileFamily(endings: ["rtf"], matches: Magic.isRTF),
        FileFamily(endings: ["sqlite", "sqlite3"], matches: Magic.isSQLite),
    ]

    static func of(ending: String) -> FileFamily? {
        all.first { $0.endings.contains(ending) }
    }
}

/// Content checks.
enum Magic {
    static func hasPrefix(_ data: Data, _ prefix: [UInt8], at offset: Int = 0) -> Bool {
        guard data.count >= offset + prefix.count else { return false }
        let start = data.startIndex + offset
        return data[start ..< start + prefix.count].elementsEqual(prefix)
    }

    static func hasPrefix(_ data: Data, _ text: String, at offset: Int = 0) -> Bool {
        hasPrefix(data, Array(text.utf8), at: offset)
    }

    /// Known types whose first bytes are long enough that random bytes match them
    /// less than about once in 10^9 tries: these count for any file name. JPEG
    /// (3 bytes), gzip and bzip2 count only for their own endings.
    static func isStrongType(_ data: Data) -> Bool {
        isPDF(data) || isPNG(data) || isGIF(data) || isTIFF(data) || isISOImage(data) ||
            isRIFF(data, form: "WEBP") || isBMP(data) || isZIP(data) || isOLE2(data) || isXZ(data) ||
            isZstd(data) || is7z(data) || isRAR(data) || isRIFF(data, form: "WAVE") ||
            isRIFF(data, form: "AVI ") || isISOMedia(data) || isFLAC(data) || isOgg(data) ||
            isRTF(data) || isSQLite(data) || isBinaryPlist(data) || isTar(data)
    }

    /// "%PDF-" within the first 1024 bytes, as PDF readers accept it.
    static func isPDF(_ data: Data) -> Bool {
        let head = data.prefix(1024)
        return head.range(of: Data("%PDF-".utf8)) != nil
    }

    static func isPNG(_ data: Data) -> Bool {
        hasPrefix(data, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }

    static func isJPEG(_ data: Data) -> Bool {
        hasPrefix(data, [0xFF, 0xD8, 0xFF])
    }

    static func isGIF(_ data: Data) -> Bool {
        hasPrefix(data, "GIF87a") || hasPrefix(data, "GIF89a")
    }

    /// Classic and BigTIFF, both byte orders.
    static func isTIFF(_ data: Data) -> Bool {
        hasPrefix(data, [0x49, 0x49, 0x2A, 0x00]) || hasPrefix(data, [0x4D, 0x4D, 0x00, 0x2A]) ||
            hasPrefix(data, [0x49, 0x49, 0x2B, 0x00]) || hasPrefix(data, [0x4D, 0x4D, 0x00, 0x2B])
    }

    /// "BM", the file size, then four reserved bytes that are zero.
    static func isBMP(_ data: Data) -> Bool {
        hasPrefix(data, "BM") && hasPrefix(data, [0, 0, 0, 0], at: 6)
    }

    /// An ISO base media file whose major brand is one of HEIF's or AVIF's.
    static let imageBrands: Set<String> = ["heic", "heix", "hevc", "hevx", "heim", "heis", "hevm",
                                           "hevs", "mif1", "msf1", "avif", "avis"]

    static func isISOImage(_ data: Data) -> Bool {
        guard isISOMedia(data), data.count >= 12 else { return false }
        let start = data.startIndex + 8
        let brand = String(decoding: data[start ..< start + 4], as: UTF8.self)
        return imageBrands.contains(brand)
    }

    /// The pictures the viewer shows: PNG, JPEG, GIF, TIFF, HEIC and AVIF, WebP, BMP.
    static func isImage(_ data: Data) -> Bool {
        isPNG(data) || isJPEG(data) || isGIF(data) || isTIFF(data) || isISOImage(data) ||
            isRIFF(data, form: "WEBP") || isBMP(data)
    }

    /// "ftyp" at byte 4: MP4, MOV, M4A, HEIC and the other ISO base media files.
    static func isISOMedia(_ data: Data) -> Bool {
        hasPrefix(data, "ftyp", at: 4)
    }

    /// "RIFF", the size, then the form: WEBP, WAVE or "AVI ".
    static func isRIFF(_ data: Data, form: String) -> Bool {
        hasPrefix(data, "RIFF") && hasPrefix(data, form, at: 8)
    }

    /// ZIP, and so Office documents, OpenDocument, EPUB and iWork files: a local
    /// file header, or the end record of an empty archive.
    static func isZIP(_ data: Data) -> Bool {
        hasPrefix(data, [0x50, 0x4B, 0x03, 0x04]) || hasPrefix(data, [0x50, 0x4B, 0x05, 0x06])
    }

    /// The compound file of older Office documents (.doc, .xls, .ppt).
    static func isOLE2(_ data: Data) -> Bool {
        hasPrefix(data, [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])
    }

    /// gzip with deflate, the only method in use.
    static func isGzip(_ data: Data) -> Bool {
        hasPrefix(data, [0x1F, 0x8B, 0x08])
    }

    /// JPEG with a marker after FF D8 FF that real files have (a quantisation
    /// table, a frame, a Huffman table, a comment, or an APPn segment such as
    /// JFIF or Exif): one byte more than isJPEG, for the damage check.
    static func isStrongJPEG(_ data: Data) -> Bool {
        guard isJPEG(data), data.count >= 4 else { return false }
        let marker = data[data.startIndex + 3]
        return (0xE0 ... 0xEF).contains(marker) || [0xDB, 0xC0, 0xC2, 0xC4, 0xFE].contains(marker)
    }

    /// gzip whose flag byte has its reserved bits clear, as every real file has.
    static func isStrongGzip(_ data: Data) -> Bool {
        guard isGzip(data), data.count >= 4 else { return false }
        return data[data.startIndex + 3] & 0xE0 == 0
    }

    /// "BZh" and the block size, 1 to 9.
    static func isBzip2(_ data: Data) -> Bool {
        guard hasPrefix(data, "BZh"), data.count >= 4 else { return false }
        return (0x31 ... 0x39).contains(data[data.startIndex + 3])
    }

    static func isXZ(_ data: Data) -> Bool {
        hasPrefix(data, [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00])
    }

    static func isZstd(_ data: Data) -> Bool {
        hasPrefix(data, [0x28, 0xB5, 0x2F, 0xFD])
    }

    static func is7z(_ data: Data) -> Bool {
        hasPrefix(data, [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C])
    }

    static func isRAR(_ data: Data) -> Bool {
        hasPrefix(data, [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07])
    }

    static func isFLAC(_ data: Data) -> Bool {
        hasPrefix(data, "fLaC")
    }

    static func isOgg(_ data: Data) -> Bool {
        hasPrefix(data, "OggS")
    }

    static func isRTF(_ data: Data) -> Bool {
        hasPrefix(data, "{\\rtf")
    }

    static func isSQLite(_ data: Data) -> Bool {
        hasPrefix(data, Array("SQLite format 3".utf8) + [0])
    }

    static func isBinaryPlist(_ data: Data) -> Bool {
        hasPrefix(data, "bplist0")
    }

    /// A POSIX tar archive: "ustar" at byte 257.
    static func isTar(_ data: Data) -> Bool {
        hasPrefix(data, "ustar", at: 257)
    }

    /// A control byte that text does not hold: C0 other than tab, line feed,
    /// form feed and carriage return, and DEL.
    static func isControlByte(_ c: UInt8) -> Bool {
        (c < 0x20 && c != 0x09 && c != 0x0A && c != 0x0C && c != 0x0D) || c == 0x7F
    }

    /// Text in an 8-bit encoding: see Plausibility.looksLikeText.
    static func isEightBitText(_ data: Data) -> Bool {
        guard data.count >= Plausibility.shortestUncheckedText else { return false }
        return data.withUnsafeBytes { (b: UnsafeRawBufferPointer) -> Bool in
            var ascii = 0
            for c in b {
                if isControlByte(c) { return false }
                if c < 0x80 { ascii += 1 }
            }
            return ascii * 5 >= b.count * 4
        }
    }

    /// FF FE or FE FF at the start.
    static func hasUTF16ByteOrderMark(_ data: Data) -> Bool {
        hasPrefix(data, [0xFF, 0xFE]) || hasPrefix(data, [0xFE, 0xFF])
    }

    /// Text in UTF-16 after a byte order mark: see Plausibility.looksLikeText.
    static func isUTF16Text(_ data: Data) -> Bool {
        guard data.count >= Plausibility.shortestUncheckedText, data.count % 2 == 0 else { return false }
        let start = data.startIndex
        let littleEndian: Bool
        switch (data[start], data[start + 1]) {
        case (0xFF, 0xFE): littleEndian = true
        case (0xFE, 0xFF): littleEndian = false
        default: return false
        }
        var units: [UInt16] = []
        units.reserveCapacity(data.count / 2 - 1)
        var i = start + 2
        while i < data.endIndex {
            let a = UInt16(data[i]), b = UInt16(data[i + 1])
            units.append(littleEndian ? a | b << 8 : a << 8 | b)
            i += 2
        }
        var characters = 0, common = 0
        var k = 0
        while k < units.count {
            let u = units[k]
            characters += 1
            if u >= 0xD800 && u <= 0xDBFF {
                // a surrogate pair: a character outside the basic plane, such as an emoji
                guard k + 1 < units.count, units[k + 1] >= 0xDC00 && units[k + 1] <= 0xDFFF else { return false }
                common += 1
                k += 2
                continue
            }
            if u >= 0xDC00 && u <= 0xDFFF { return false }
            if u < 0x80 && isControlByte(UInt8(u)) { return false }
            if u == 0xFFFE || u == 0xFFFF { return false }
            if commonTextRanges.contains(where: { $0.contains(u) }) { common += 1 }
            k += 1
        }
        return characters > 0 && common * 10 >= characters * 9
    }

    /// Code points of the common scripts, for isUTF16Text.
    static let commonTextRanges: [ClosedRange<UInt16>] = [
        0x0009 ... 0x000D, 0x0020 ... 0x007E,   // ASCII text
        0x00A0 ... 0x052F,                     // Latin, IPA, Greek, Cyrillic
        0x0590 ... 0x06FF,                     // Hebrew, Arabic
        0x2000 ... 0x206F, 0x20A0 ... 0x20CF,  // punctuation, currency
        0x2100 ... 0x214F,                     // letterlike symbols
        0x3000 ... 0x30FF,                     // CJK punctuation, kana
        0x4E00 ... 0x9FFF,                     // CJK ideographs
        0xAC00 ... 0xD7A3,                     // Hangul
        0xFF00 ... 0xFFEF,                     // full-width forms
    ]

    /// Strict UTF-8 (no overlong forms, no surrogates, nothing above
    /// U+10FFFF) without NUL bytes. An empty file passes.
    static func isUTF8TextWithoutNUL(_ data: Data) -> Bool {
        isStrictUTF8(data, allowingNUL: false)
    }

    /// isUTF8TextWithoutNUL for the start of a text: a character cut at the end
    /// (a lead byte and fewer continuation bytes than it needs, at most three
    /// bytes) is allowed.
    static func isUTF8TextAllowingCutEnd(_ data: Data) -> Bool {
        if isUTF8TextWithoutNUL(data) {
            return true
        }
        let n = data.count
        // the last lead byte among the last three bytes, if the bytes after it are
        // all continuation bytes and fewer than it needs
        for back in 1 ... min(3, n) {
            let c = data[data.startIndex + n - back]
            if c & 0xC0 == 0x80 {
                continue        // a continuation byte: look further back
            }
            let need: Int
            if c & 0xE0 == 0xC0 {
                need = 1
            } else if c & 0xF0 == 0xE0 {
                need = 2
            } else if c & 0xF8 == 0xF0 {
                need = 3
            } else {
                return false
            }
            return back - 1 < need && isUTF8TextWithoutNUL(data.prefix(n - back))
        }
        return false
    }

    /// Strict UTF-8, with or without NUL bytes.
    static func isStrictUTF8(_ data: Data, allowingNUL: Bool) -> Bool {
        data.withUnsafeBytes { (b: UnsafeRawBufferPointer) -> Bool in
            let n = b.count
            var i = 0
            while i < n {
                let c = b[i]
                if c == 0 && !allowingNUL { return false }
                if c < 0x80 {
                    i += 1
                    continue
                }
                var need: Int
                var cp: UInt32
                var minimum: UInt32
                if c & 0xE0 == 0xC0 {
                    need = 1; cp = UInt32(c & 0x1F); minimum = 0x80
                } else if c & 0xF0 == 0xE0 {
                    need = 2; cp = UInt32(c & 0x0F); minimum = 0x800
                } else if c & 0xF8 == 0xF0 {
                    need = 3; cp = UInt32(c & 0x07); minimum = 0x10000
                } else {
                    return false
                }
                guard i + need < n else { return false }
                for k in 1 ... need {
                    let d = b[i + k]
                    guard d & 0xC0 == 0x80 else { return false }
                    cp = cp << 6 | UInt32(d & 0x3F)
                }
                if cp < minimum || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF) {
                    return false
                }
                i += need + 1
            }
            return true
        }
    }
}
