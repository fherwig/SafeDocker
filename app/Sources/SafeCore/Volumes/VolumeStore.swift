import Foundation

// WP2. The app's list of volumes (building plan 3, 4.8), kept as JSON:
//   { "version": 1, "volumes": [ { "id": ..., "name": ..., "path": "~/...", "syncApp": ... } ] }
// Paths under the home folder are kept with a leading "~/", so the list still
// fits after the home folder moves. The file is replaced atomically, mode 0600.

/// One volume in the app's list.
public struct VolumeRecord: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    /// Stored with a leading "~/" when under the home folder.
    public var path: String
    /// Process name to check before opening, or nil.
    public var syncApp: String?

    /// Makes a record; the app needs this because the memberwise init is internal.
    public init(id: UUID = UUID(), name: String, path: String, syncApp: String? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.syncApp = syncApp
    }

    /// The image's location, with "~/" expanded.
    public var url: URL {
        URL(fileURLWithPath: VolumeStore.expandingHome(path))
    }
}

/// The list of volumes, kept in a JSON file (R4). Use it from one thread.
public final class VolumeStore {
    /// The JSON file.
    public let file: URL

    /// Set when the file exists but could not be read. The list then starts
    /// empty, and the next change first renames the unreadable file to
    /// NAME.broken-DATE, so that it is never overwritten.
    public private(set) var loadError: String?

    /// Loads the list from `file`; a missing file is an empty list.
    public init(file: URL = VolumeStore.defaultFile) {
        self.file = file
        load()
    }

    /// ~/Library/Application Support/SafeDocker/volumes.json
    public static var defaultFile: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("SafeDocker", isDirectory: true)
            .appendingPathComponent("volumes.json")
    }

    /// The volumes in the list.
    public private(set) var volumes: [VolumeRecord] = []

    /// Adds a volume and saves the list; its path is kept with "~/" when under
    /// the home folder. Throws .alreadyExists if its id or path is in the list.
    public func add(_ v: VolumeRecord) throws {
        let record = Self.normalized(v)
        if volumes.contains(where: { $0.id == record.id }) {
            throw CryptError.alreadyExists(record.name)
        }
        if volumes.contains(where: { $0.path == record.path }) {
            throw CryptError.alreadyExists(record.path)
        }
        try save(volumes + [record])
    }

    /// Replaces the volume with the same id and saves the list.
    public func update(_ v: VolumeRecord) throws {
        let record = Self.normalized(v)
        guard let index = volumes.firstIndex(where: { $0.id == record.id }) else {
            throw CryptError.io(L("%@ is not in the list of volumes.", record.name))
        }
        if volumes.contains(where: { $0.id != record.id && $0.path == record.path }) {
            throw CryptError.alreadyExists(record.path)
        }
        var list = volumes
        list[index] = record
        try save(list)
    }

    /// Forgets a volume; never deletes the image. An unknown id changes nothing.
    public func remove(id: UUID) throws {
        guard volumes.contains(where: { $0.id == id }) else {
            return
        }
        try save(volumes.filter { $0.id != id })
    }

    /// "/Users/NAME/x" becomes "~/x"; other paths stay as they are.
    public static func abbreviatingHome(_ path: String) -> String {
        let home = homePath
        if path == home {
            return "~"
        }
        if path.hasPrefix(home + "/") {
            return "~/" + path.dropFirst(home.count + 1)
        }
        return path
    }

    /// "~/x" becomes "/Users/NAME/x"; other paths stay as they are.
    public static func expandingHome(_ path: String) -> String {
        if path == "~" {
            return homePath
        }
        if path.hasPrefix("~/") {
            return homePath + "/" + path.dropFirst(2)
        }
        return path
    }

    // MARK: file

    private struct Contents: Codable {
        var version: Int
        var volumes: [VolumeRecord]
    }

    private static var homePath: String {
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
        return home == "/" ? "" : home
    }

    /// The path made absolute and tidy (no "..", no trailing "/"), then with "~/".
    private static func normalized(_ v: VolumeRecord) -> VolumeRecord {
        var record = v
        let full = URL(fileURLWithPath: expandingHome(v.path)).standardizedFileURL.path
        record.path = abbreviatingHome(full)
        return record
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: file.path) else {
            return
        }
        do {
            let data = try Data(contentsOf: file)
            volumes = try JSONDecoder().decode(Contents.self, from: data).volumes
        } catch {
            volumes = []
            loadError = L("Cannot read %@: %@", file.path, error.localizedDescription)
        }
    }

    /// Writes `list` to a new file next to the old one and renames it over the
    /// old one, then takes it as the list.
    private func save(_ list: [VolumeRecord]) throws {
        let fm = FileManager.default
        let folder = file.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        } catch {
            throw CryptError.io(L("Cannot make the folder %@: %@", folder.path, error.localizedDescription))
        }
        if loadError != nil && fm.fileExists(atPath: file.path) {
            let stamp = Self.stampFormatter.string(from: Date())
            let kept = folder.appendingPathComponent(file.lastPathComponent + ".broken-" + stamp)
            do {
                try fm.moveItem(at: file, to: kept)
            } catch {
                throw CryptError.io(L("Cannot keep the unreadable %@: %@", file.path, error.localizedDescription))
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(Contents(version: 1, volumes: list))
        } catch {
            throw CryptError.io(L("Cannot encode the list of volumes: %@", error.localizedDescription))
        }

        let temp = folder.appendingPathComponent("." + file.lastPathComponent + "." + UUID().uuidString + ".tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else {
            throw CryptError.io(L("Cannot write %@: %@", temp.path, Self.lastError()))
        }
        var failure: String?
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else {
                return
            }
            var offset = 0
            while offset < buffer.count && failure == nil {
                let n = write(fd, base + offset, buffer.count - offset)
                if n >= 0 {
                    offset += n
                } else if errno != EINTR {
                    failure = Self.lastError()
                }
            }
        }
        if failure == nil && fsync(fd) != 0 {
            failure = Self.lastError()
        }
        close(fd)
        if failure == nil && rename(temp.path, file.path) != 0 {
            failure = Self.lastError()
        }
        if let failure = failure {
            unlink(temp.path)
            throw CryptError.io(L("Cannot write %@: %@", file.path, failure))
        }
        // make the rename itself durable
        let dirfd = open(folder.path, O_RDONLY)
        if dirfd >= 0 {
            fsync(dirfd)
            close(dirfd)
        }
        loadError = nil
        volumes = list
    }

    private static func lastError() -> String {
        String(cString: strerror(errno))
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}
