import Darwin

/// A password or key in locked memory, wiped on deinit.
///
/// The bytes live in pages of their own, from mmap, locked with mlock so they
/// are not written to swap, and overwritten with memset_s, which the compiler
/// may not leave out. Each instance has its own pages because munlock unlocks
/// a whole page, whoever else uses it.
public final class SecureBytes {
    private let pointer: UnsafeMutableRawPointer
    private let capacity: Int
    private let locked: Bool
    private var length: Int

    /// Copies the bytes into locked memory.
    public init(_ bytes: [UInt8]) {
        let (memory, capacity, locked) = SecureBytes.allocate(bytes.count)
        bytes.withUnsafeBytes { source in
            if let base = source.baseAddress, source.count > 0 {
                memory.copyMemory(from: base, byteCount: source.count)
            }
        }
        (self.pointer, self.capacity, self.locked) = (memory, capacity, locked)
        length = bytes.count
    }

    /// The exact UTF-8 bytes of the string, copied without a temporary array.
    public convenience init(string: String) {
        var text = string
        self.init(zeros: text.utf8.count)
        text.withUTF8 { source in
            withUnsafeMutableBytes { $0.copyMemory(from: UnsafeRawBufferPointer(source)) }
        }
    }

    /// `count` zero bytes, to be filled with withUnsafeMutableBytes, for keys.
    init(zeros count: Int) {
        (pointer, capacity, locked) = SecureBytes.allocate(count)
        length = count
    }

    /// The number of bytes.
    public var count: Int {
        length
    }

    /// Lends the bytes to `body` without copying them.
    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try body(UnsafeRawBufferPointer(start: pointer, count: length))
    }

    /// Lends the bytes to `body` for writing.
    func withUnsafeMutableBytes<R>(_ body: (UnsafeMutableRawBufferPointer) throws -> R) rethrows -> R {
        try body(UnsafeMutableRawBufferPointer(start: pointer, count: length))
    }

    /// Overwrites the bytes with zeros; afterwards count is 0.
    public func wipe() {
        _ = memset_s(pointer, capacity, 0, capacity)
        length = 0
    }

    deinit {
        wipe()
        if locked {
            munlock(pointer, capacity)
        }
        munmap(pointer, capacity)
    }

    private static func allocate(_ count: Int) -> (UnsafeMutableRawPointer, Int, Bool) {
        let page = Int(getpagesize())
        let capacity = (max(count, 1) + page - 1) / page * page
        let memory = mmap(nil, capacity, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0)
        guard let memory = memory, memory != MAP_FAILED else {
            fatalError("SecureBytes: cannot allocate \(capacity) bytes")
        }
        // a lock can fail if the limit for locked memory is reached; the
        // bytes are still wiped then
        let locked = mlock(memory, capacity) == 0
        return (memory, capacity, locked)
    }
}
