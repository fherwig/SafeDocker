import CryptoKit
import Foundation

// WP2. Checks a volume made from a folder against the folder before the folder
// is deleted (building plan 4.8). Besides the regular files, folders and
// symbolic links must match too, so that nothing in the folder is lost.

/// Compares a folder with the volume made from it, before the folder is deleted (R4).
public enum FolderVerifier {
    /// Same relative paths, sizes and SHA-256 for every regular file (ignoring .DS_Store,
    /// .fseventsd, .Spotlight-V100, .Trashes and other volume metadata).
    public static func sameContents(_ a: URL, _ b: URL) throws -> Bool {
        try firstDifference(a, b) == nil
    }

    /// The first difference found between the two folders, as a sentence, or nil
    /// if they have the same contents. Throws .io if a folder cannot be read.
    public static func firstDifference(_ a: URL, _ b: URL) throws -> String? {
        let left = try listing(a), right = try listing(b)
        let paths = left.keys.sorted()
        for path in paths where right[path] == nil {
            return L("%@ is missing in %@.", path, b.path)
        }
        for path in right.keys.sorted() where left[path] == nil {
            return L("%@ is in %@ but not in %@.", path, b.path, a.path)
        }
        var files: [(String, String, String)] = []
        for path in paths {
            let (x, xPath) = left[path]!, (y, yPath) = right[path]!
            switch (x, y) {
            case let (.file(s), .file(t)):
                if s != t {
                    return L("%@ has %ld bytes in %@ and %ld bytes in %@.", path, Int(s), a.path, Int(t), b.path)
                }
                files.append((path, xPath, yPath))
            case let (.link(s), .link(t)):
                if s != t {
                    return L("The link %@ points to %@ in %@ and to %@ in %@.", path, s, a.path, t, b.path)
                }
            case (.folder, .folder), (.other, .other):
                break
            default:
                return L("%@ is not the same kind of item in %@ and %@.", path, a.path, b.path)
            }
        }
        // the expensive part last
        for (path, xPath, yPath) in files {
            if try sha256(a.appendingPathComponent(xPath)) != sha256(b.appendingPathComponent(yPath)) {
                return L("%@ has different contents in %@ and %@.", path, a.path, b.path)
            }
        }
        return nil
    }

    private enum Item: Equatable {
        case file(Int64), folder, link(String), other
    }

    /// Ignored at every level.
    private static let ignoredEverywhere: Set<String> = [".DS_Store"]

    /// Ignored at the top level, where macOS keeps a volume's metadata.
    private static let ignoredAtTop: Set<String> = [
        ".fseventsd", ".Spotlight-V100", ".Trashes", ".TemporaryItems",
        ".DocumentRevisions-V100", ".apdisk", ".com.apple.timemachine.donotpresent",
    ]

    /// Every item under `root` by relative path, with the path as it is on disk
    /// (the key compares names the way Swift strings do, so the two Unicode forms
    /// of a name such as café are the same key).
    private static func listing(_ root: URL) throws -> [String: (Item, String)] {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isFolder),
              isFolder.boolValue else {
            throw CryptError.io(L("%@ is not a folder.", root.path))
        }
        var items: [String: (Item, String)] = [:]
        try walk(root.path, relative: "", into: &items)
        return items
    }

    private static func walk(_ folder: String, relative: String,
                             into items: inout [String: (Item, String)]) throws {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: folder)
        } catch {
            throw CryptError.io(L("Cannot read the folder %@: %@", folder, error.localizedDescription))
        }
        for name in names {
            if ignoredEverywhere.contains(name) || (relative.isEmpty && ignoredAtTop.contains(name)) {
                continue
            }
            let path = folder + "/" + name
            let rel = relative.isEmpty ? name : relative + "/" + name
            var st = stat()
            guard lstat(path, &st) == 0 else {
                throw CryptError.io(L("Cannot read %@: %@", path, String(cString: strerror(errno))))
            }
            switch st.st_mode & S_IFMT {
            case S_IFREG:
                items[rel] = (.file(Int64(st.st_size)), rel)
            case S_IFDIR:
                items[rel] = (.folder, rel)
                try walk(path, relative: rel, into: &items)
            case S_IFLNK:
                let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) ?? ""
                items[rel] = (.link(target), rel)
            default:
                items[rel] = (.other, rel)
            }
        }
    }

    private static func sha256(_ file: URL) throws -> Data {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: file)
        } catch {
            throw CryptError.io(L("Cannot read %@: %@", file.path, error.localizedDescription))
        }
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: 1 << 20)
            } catch {
                throw CryptError.io(L("Cannot read %@: %@", file.path, error.localizedDescription))
            }
            guard let data = chunk, !data.isEmpty else {
                break
            }
            hash.update(data: data)
        }
        return Data(hash.finalize())
    }
}
