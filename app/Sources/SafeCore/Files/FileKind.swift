import Foundation

/// What the app does with a decrypted file: edit, view or only export it.
public enum FileKind: Equatable {
    case text, pdf, image, other

    /// Classifies by the original file name and the decrypted content (R2, R3).
    /// Text needs a text ending and valid UTF-8; PDF and images are recognised
    /// by their content, whatever the ending.
    public static func classify(originalName: String, plaintext: Data) -> FileKind {
        if isTextName(originalName) && Magic.isUTF8TextWithoutNUL(plaintext) {
            return .text
        }
        if Magic.isPDF(plaintext) {
            return .pdf
        }
        if Magic.isImage(plaintext) {
            return .image
        }
        return .other
    }

    /// True if the name has a text ending (.txt, .md and the others of R2) or no
    /// ending, as today's safe.txt has inside its volume.
    public static func isTextName(_ originalName: String) -> Bool {
        FileEnding.text.contains(FileEnding.of(originalName))
    }
}
