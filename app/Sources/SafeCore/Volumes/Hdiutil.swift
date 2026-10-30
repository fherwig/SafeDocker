import Foundation

// Runs /usr/bin/hdiutil. Passwords go to its stdin, each followed by a NUL
// byte, straight from the SecureBytes; they never appear on a command line,
// in an error message or in a log.

enum Hdiutil {
    static let path = "/usr/bin/hdiutil"

    struct Result {
        let status: Int32
        let stdout: Data
        let stderr: Data

        /// What hdiutil said about a failure, for CryptError.io.
        var message: String {
            for data in [stderr, stdout] {
                let text = String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    return text
                }
            }
            return L("hdiutil failed with status %ld", Int(status))
        }

        /// The plist that -plist printed on stdout.
        func plist() throws -> [String: Any] {
            guard let object = try? PropertyListSerialization.propertyList(from: stdout, format: nil),
                  let dict = object as? [String: Any] else {
                throw CryptError.io(L("hdiutil printed no readable property list"))
            }
            return dict
        }
    }

    /// Runs hdiutil with `arguments` and waits for it.
    static func run(_ arguments: [String], passwords: [SecureBytes] = []) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let inPipe = passwords.isEmpty ? nil : Pipe()
        process.standardInput = inPipe ?? FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw CryptError.io(L("cannot run hdiutil: %@", error.localizedDescription))
        }

        // read both outputs while writing the passwords, so that no pipe fills up
        final class Box { var data = Data() }
        let out = Box(), err = Box()
        let group = DispatchGroup()
        DispatchQueue.global().async(group: group) {
            out.data = outPipe.fileHandleForReading.readDataToEndOfFile()
        }
        DispatchQueue.global().async(group: group) {
            err.data = errPipe.fileHandleForReading.readDataToEndOfFile()
        }
        if let inPipe = inPipe {
            let fd = inPipe.fileHandleForWriting.fileDescriptor
            // if hdiutil quits early, write fails with EPIPE instead of killing us
            _ = fcntl(fd, F_SETNOSIGPIPE, 1)
            for password in passwords {
                let written = password.withUnsafeBytes { writeAll(fd, $0) }
                    && withUnsafeBytes(of: UInt8(0)) { writeAll(fd, $0) }
                if !written {
                    break
                }
            }
            try? inPipe.fileHandleForWriting.close()
        }
        process.waitUntilExit()
        group.wait()
        return Result(status: process.terminationStatus, stdout: out.data, stderr: err.data)
    }

    /// Runs hdiutil and throws if it fails: a wrong password as .wrongPassword,
    /// anything else as .io with hdiutil's message.
    @discardableResult
    static func check(_ arguments: [String], passwords: [SecureBytes] = []) throws -> Result {
        let result = try run(arguments, passwords: passwords)
        if result.status != 0 {
            throw error(for: result)
        }
        return result
    }

    static func error(for result: Result) -> CryptError {
        let message = result.message
        // the text of EAUTH, which strerror does not translate
        if message.contains("Authentication error") {
            return .wrongPassword
        }
        return .io(message)
    }

    private static func writeAll(_ fd: Int32, _ buffer: UnsafeRawBufferPointer) -> Bool {
        guard let base = buffer.baseAddress else {
            return true
        }
        var offset = 0
        while offset < buffer.count {
            let n = write(fd, base + offset, buffer.count - offset)
            if n < 0 {
                if errno == EINTR {
                    continue
                }
                return false
            }
            offset += n
        }
        return true
    }
}
