import CryptoKit
import Darwin
import Foundation

// POSIX file operations for CryptFile: new files with O_EXCL and mode 0600,
// F_FULLFSYNC, renames, and messages that say which file failed.

enum FileIO {
    /// The reason of a failed system call, as the system words it, for the
    /// messages that say which file failed ("cannot read PATH: REASON").
    static func reason(_ code: Int32 = errno) -> String {
        String(cString: strerror(code))
    }

    /// Reads the whole file.
    static func read(_ path: String) throws -> Data {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else {
            throw CryptError.io(L("cannot read %@: %@", path, reason()))
        }
        defer { close(fd) }
        var data = Data()
        var st = stat()
        if fstat(fd, &st) == 0 && st.st_size > 0 {
            // one buffer, so that no partial copies are left in freed memory
            data.reserveCapacity(Int(st.st_size) + 1)
        }
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                throw CryptError.io(L("cannot read %@: %@", path, reason()))
            }
            if n == 0 { break }
            data.append(chunk, count: n)
        }
        Legacy.wipe(&chunk)
        return data
    }

    /// True if something, even a dangling link, has this name.
    static func exists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    /// True for a regular file, not a link, folder or device.
    static func isRegularFile(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG
    }

    /// The number of names (hard links) of what is at the path, not following a
    /// link; 0 if nothing is there.
    static func linkCount(_ path: String) -> Int {
        var st = stat()
        return lstat(path, &st) == 0 ? Int(st.st_nlink) : 0
    }

    /// The size in bytes of what is at the path, not following a link; nil if nothing is there.
    static func size(_ path: String) -> Int? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return Int(st.st_size)
    }

    /// Removes the file if it is there.
    static func removeIfPresent(_ path: String) throws {
        if unlink(path) != 0 && errno != ENOENT {
            throw CryptError.io(L("cannot remove %@: %@", path, reason()))
        }
    }

    /// Writes a new file that must not exist yet (O_CREAT | O_EXCL), mode
    /// 0600, and flushes it to the disk with F_FULLFSYNC.
    static func writeNew(_ path: String, _ data: Data) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw CryptError.io(L("cannot create %@: %@", path, reason()))
        }
        var ok = false
        defer {
            close(fd)
            if !ok { unlink(path) }
        }
        try writeAll(fd, data, path)
        try fullSync(fd, path)
        ok = true
    }

    static func writeAll(_ fd: Int32, _ data: Data, _ path: String) throws {
        try data.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
            var done = 0
            while done < b.count {
                let n = write(fd, b.baseAddress! + done, b.count - done)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw CryptError.io(L("cannot write %@: %@", path, reason()))
                }
                done += n
            }
        }
    }

    /// F_FULLFSYNC asks the drive to write its cache too; file systems that
    /// do not know it, network volumes for example, get a plain fsync.
    static func fullSync(_ fd: Int32, _ path: String) throws {
        if fcntl(fd, F_FULLFSYNC) != 0 && fsync(fd) != 0 {
            throw CryptError.io(L("cannot flush %@: %@", path, reason()))
        }
    }

    /// Flushes a folder, so that a rename in it is on the disk.
    static func syncDirectory(_ path: String) {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        if fd >= 0 {
            if fcntl(fd, F_FULLFSYNC) != 0 { fsync(fd) }
            close(fd)
        }
    }

    /// Renames, replacing the target (atomic on one volume).
    static func rename(_ from: String, _ to: String) throws {
        if Darwin.rename(from, to) != 0 {
            throw CryptError.io(L("cannot rename %@ to %@: %@", from, to, reason()))
        }
    }

    /// Renames only if the target does not exist; throws .alreadyExists if it does.
    static func renameExclusive(_ from: String, _ to: String) throws {
        if renamex_np(from, to, UInt32(RENAME_EXCL)) == 0 {
            return
        }
        let code = errno
        if code == EEXIST {
            throw CryptError.alreadyExists(to)
        }
        guard code == ENOTSUP || code == EINVAL else {
            throw CryptError.io(L("cannot rename %@ to %@: %@", from, to, reason(code)))
        }
        // a file system without RENAME_EXCL: link fails if the target exists
        if link(from, to) == 0 {
            unlink(from)
            return
        }
        if errno == EEXIST {
            throw CryptError.alreadyExists(to)
        }
        if exists(to) {
            throw CryptError.alreadyExists(to)
        }
        try rename(from, to)
    }

    static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    static func directory(of path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }
}
