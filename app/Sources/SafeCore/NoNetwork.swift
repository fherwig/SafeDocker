import CSandbox
import Darwin

/// The app denies itself the network when it starts.
public enum NoNetwork {
    /// Calls safe_deny_network(); the restriction lasts until the process ends.
    public static func enforce() throws {
        var error: UnsafeMutablePointer<CChar>?
        if safe_deny_network(&error) != 0 {
            let message = error.map { String(cString: $0) } ?? "unknown error"
            safe_free_error(error)
            var text = "cannot deny network access: \(message)"
            if message.contains("Operation not permitted") {
                // sandbox_init fails so inside another sandbox, such as an agent's
                // command sandbox; the app itself is fine
                text += ". Safe cannot run inside another sandbox (for example an agent's or a "
                    + "tool's command sandbox); start it normally"
            }
            throw CryptError.io(text)
        }
    }

    /// True if connect() fails with EPERM.
    ///
    /// Connects a TCP socket to port 9 of 127.0.0.1, so that nothing leaves
    /// the Mac even when the network is allowed: then the connection is
    /// refused (or accepted, if something listens there). Under the sandbox
    /// profile connect() fails with EPERM; EACCES and a socket() that is
    /// refused the same way count as blocked too.
    public static func probeBlocked() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 {
            return errno == EPERM || errno == EACCES
        }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(9).bigEndian)
        address.sin_addr.s_addr = in_addr_t(UInt32(0x7F00_0001).bigEndian)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 {
            return false
        }
        return errno == EPERM || errno == EACCES
    }
}
