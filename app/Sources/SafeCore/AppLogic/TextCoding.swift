import Foundation

// How the editor turns a decrypted file into text and back (R2). Saving writes
// the encoding the file was read in, so that a text saved without changes gives
// the same bytes: a UTF-8 file keeps its byte order mark if it had one, as
// Windows Notepad writes it, and a file that is not UTF-8 keeps its encoding.

/// The encoding of a text in the editor, and how to write it back.
public enum TextCoding: Equatable {
    /// UTF-8 without a byte order mark: what the plausibility check accepts.
    case utf8
    /// UTF-8 that starts with the byte order mark EF BB BF.
    case utf8WithBOM
    /// UTF-16 with its byte order mark, as Excel's "Unicode text" is written.
    case utf16LittleEndian, utf16BigEndian
    /// ISO Latin-1, for text that is neither: every byte is one character, so a
    /// text saved without changes gives the same bytes again.
    case latin1

    static let utf8BOM: [UInt8] = [0xEF, 0xBB, 0xBF]

    /// The text of a file that is UTF-8, with or without a byte order mark; nil
    /// if it is not strict UTF-8 without NUL bytes.
    public static func decodeUTF8(_ data: Data) -> (text: String, coding: TextCoding)? {
        guard Magic.isUTF8TextWithoutNUL(data) else { return nil }
        if data.starts(with: utf8BOM) {
            return (String(decoding: data.dropFirst(utf8BOM.count), as: UTF8.self), .utf8WithBOM)
        }
        // String(decoding:) keeps every scalar; String(data:encoding:) would drop a BOM
        return (String(decoding: data, as: UTF8.self), .utf8)
    }

    /// The text of a file that may not be UTF-8, to show it read only when Safe
    /// could not confirm the password: UTF-8 if it is valid (also with NUL bytes),
    /// UTF-16 if it starts with a byte order mark and is valid, else ISO Latin-1,
    /// which turns any bytes into text without losing one.
    public static func decodeAnyway(_ data: Data) -> (text: String, coding: TextCoding) {
        if let decoded = decodeUTF8(data) {
            return decoded
        }
        if Magic.isStrictUTF8(data, allowingNUL: true) {
            if data.starts(with: utf8BOM) {
                return (String(decoding: data.dropFirst(utf8BOM.count), as: UTF8.self), .utf8WithBOM)
            }
            return (String(decoding: data, as: UTF8.self), .utf8)
        }
        if let text = decodeUTF16(data, bom: [0xFF, 0xFE], encoding: .utf16LittleEndian) {
            return (text, .utf16LittleEndian)
        }
        if let text = decodeUTF16(data, bom: [0xFE, 0xFF], encoding: .utf16BigEndian) {
            return (text, .utf16BigEndian)
        }
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: data.map { Unicode.Scalar($0) })
        return (String(scalars), .latin1)
    }

    /// UTF-16 after the given byte order mark; nil without it or if not valid.
    private static func decodeUTF16(_ data: Data, bom: [UInt8], encoding: String.Encoding) -> String? {
        guard data.starts(with: bom), (data.count - bom.count) % 2 == 0 else { return nil }
        // Foundation refuses lone surrogates, so the text writes back to the same bytes
        guard let text = String(data: data.dropFirst(bom.count), encoding: encoding) else { return nil }
        return text
    }

    /// The bytes to write for `text`, or nil if this encoding cannot hold one of
    /// its characters (only ISO Latin-1 can fail).
    public func encode(_ text: String) -> Data? {
        switch self {
        case .utf8:
            return Data(text.utf8)
        case .utf8WithBOM:
            return Data(Self.utf8BOM) + Data(text.utf8)
        case .utf16LittleEndian:
            var data = Data([0xFF, 0xFE])
            for unit in text.utf16 {
                data.append(UInt8(unit & 0xFF))
                data.append(UInt8(unit >> 8))
            }
            return data
        case .utf16BigEndian:
            var data = Data([0xFE, 0xFF])
            for unit in text.utf16 {
                data.append(UInt8(unit >> 8))
                data.append(UInt8(unit & 0xFF))
            }
            return data
        case .latin1:
            var data = Data(capacity: text.unicodeScalars.count)
            for scalar in text.unicodeScalars {
                guard scalar.value <= 0xFF else { return nil }
                data.append(UInt8(scalar.value))
            }
            return data
        }
    }

    /// The encoding's name for the status line and messages.
    public var name: String {
        switch self {
        case .utf8: return "UTF-8"
        case .utf8WithBOM: return L("UTF-8 with a byte order mark")
        case .utf16LittleEndian, .utf16BigEndian: return "UTF-16"
        case .latin1: return "ISO Latin-1"
        }
    }
}
