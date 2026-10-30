import Foundation

// WP2. Encrypted disk images through /usr/bin/hdiutil (building plan 3, 4.8).
// Passwords go to hdiutil's stdin, see Hdiutil.swift. Every call waits for
// hdiutil, which can take a while: call these off the main thread.

/// A disk image that hdiutil reports as attached.
public struct AttachedImage {
    /// The image file or sparse bundle, as hdiutil reports it.
    public let imagePath: URL
    /// Where its volume is mounted, if it is.
    public let mountPoint: URL?
}

/// Encrypted disk images through hdiutil, passwords on stdin (R4).
public enum DiskImage {
    /// Makes an empty encrypted sparse bundle (AES-256, APFS) that can grow to
    /// `maxSizeMB`. The name must end in .sparsebundle and must not exist yet.
    public static func createEmpty(at image: URL, maxSizeMB: Int, volumeName: String,
                                   password: SecureBytes) throws {
        guard maxSizeMB > 0 else {
            throw CryptError.io(L("The maximum size must be at least 1 MB."))
        }
        try checkNewImage(image, volumeName: volumeName, password: password)
        try Hdiutil.check(["create", "-size", "\(maxSizeMB)m", "-type", "SPARSEBUNDLE",
                           "-fs", "APFS", "-encryption", "AES-256", "-stdinpass",
                           "-volname", volumeName, image.path],
                          passwords: [password])
        try checkMade(image)
    }

    /// Makes an encrypted sparse bundle (AES-256, APFS) holding a copy of what is
    /// in `folder`; the folder's contents become the volume's top level. The name
    /// must end in .sparsebundle, must not exist yet and must not be inside the
    /// folder. The volume can grow to twice the folder's size, at least 1 GB.
    /// Files the user cannot read are left out rather than asking for an
    /// administrator. The folder is left as it is; compare it with
    /// FolderVerifier before deleting it.
    public static func createFromFolder(_ folder: URL, at image: URL, volumeName: String,
                                        password: SecureBytes) throws {
        try checkNewImage(image, volumeName: volumeName, password: password)
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder),
              isFolder.boolValue else {
            throw CryptError.io(L("%@ is not a folder.", folder.path))
        }
        let source = realPath(folder.path)
        let target = realPath(image.deletingLastPathComponent().path)
        if target == source || target.hasPrefix(source.hasSuffix("/") ? source : source + "/") {
            throw CryptError.io(L("The volume cannot be saved inside the folder it is made from."))
        }
        // without -size, hdiutil makes the volume just big enough for the folder;
        // without -anyowners -skipunreadable, it can ask for an administrator
        try Hdiutil.check(["create", "-srcfolder", source, "-size", "\(sizeMB(for: folder))m",
                           "-anyowners", "-skipunreadable",
                           "-format", "UDSB", "-fs", "APFS", "-encryption", "AES-256",
                           "-stdinpass", "-volname", volumeName, image.path],
                          passwords: [password])
        try checkMade(image)
    }

    /// Attaches the image and returns the mount point of its volume, as hdiutil
    /// reports it (/private/var/... for a folder under /var). With `mountPoint`,
    /// the volume is mounted there; give a path that does not exist yet, then
    /// hdiutil makes the folder and removes it at detach (privateMountPoint()
    /// gives one), or an empty folder; a folder with files in it is refused.
    /// Without, it goes to /Volumes. `hidden` keeps it out of the Finder
    /// (-nobrowse). Throws .wrongPassword for a wrong password.
    public static func attach(_ image: URL, password: SecureBytes, readOnly: Bool,
                              mountPoint: URL?, hidden: Bool) throws -> URL {
        try checkPassword(password, isNew: false)
        try checkExists(image)
        var arguments = ["attach", "-stdinpass", "-plist", "-noautoopen"]
        if readOnly {
            arguments.append("-readonly")
        }
        if hidden {
            arguments.append("-nobrowse")
        }
        if let mountPoint = mountPoint {
            let path = mountPoint.standardizedFileURL.path
            // a volume mounted on a folder hides what is in it
            var isFolder: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) {
                let names = isFolder.boolValue ? try? FileManager.default.contentsOfDirectory(atPath: path) : nil
                if names?.isEmpty != true {
                    throw CryptError.io(L("%@ is in use; the volume needs a new or empty folder.", path))
                }
            }
            arguments += ["-mountpoint", path]
        }
        arguments.append(image.path)

        let result = try Hdiutil.run(arguments, passwords: [password])
        if result.status != 0 {
            // hdiutil says "Resource busy" when the image is attached already
            if result.message.contains("Resource busy"), let open = try? attachment(of: image) {
                if let mountPoint = open.mountPoint {
                    throw CryptError.io(L("%@ is already open at %@.", image.lastPathComponent, mountPoint.path))
                }
                throw CryptError.io(L("%@ is already open.", image.lastPathComponent))
            }
            throw Hdiutil.error(for: result)
        }
        let entities = try result.plist()["system-entities"] as? [[String: Any]] ?? []
        if let mounted = entities.compactMap({ $0["mount-point"] as? String }).first {
            return URL(fileURLWithPath: mounted, isDirectory: true)
        }
        // attached, but no volume was mounted: let go of the image again
        if let device = entities.compactMap({ $0["dev-entry"] as? String }).first {
            _ = try? Hdiutil.run(["detach", device])
        }
        throw CryptError.io(L("%@ holds no volume that macOS can mount.", image.lastPathComponent))
    }

    /// Detaches the volume mounted at `mountPoint`. A busy volume is tried again
    /// for a moment; then, only if `force` is true, detached with -force, which can
    /// lose other apps' unsaved work on it. Throws .io with hdiutil's message,
    /// also if nothing is mounted there.
    public static func detach(_ mountPoint: URL, force: Bool) throws {
        let path = mountPoint.standardizedFileURL.path
        // the image's disk rather than the folder: a detach can unmount the
        // volume and then fail to eject the disk, and the next try would not
        // find the folder, which macOS removes at the unmount
        let target = (try? disk(mountedAt: path)) ?? path
        var result = try Hdiutil.run(["detach", target])
        var tries = 1
        // Spotlight or fseventsd can hold a volume for a moment
        while result.status != 0 && isBusy(result) && tries < 3 {
            Thread.sleep(forTimeInterval: 0.5 * Double(tries))
            result = try Hdiutil.run(["detach", target])
            tries += 1
        }
        if result.status != 0 && force {
            result = try Hdiutil.run(["detach", target, "-force"])
        }
        if result.status != 0 {
            throw Hdiutil.error(for: result)
        }
    }

    /// Changes the image's password; the image must not be attached. Throws
    /// .wrongPassword if `old` is wrong.
    public static func changePassword(_ image: URL, old: SecureBytes, new: SecureBytes) throws {
        try checkPassword(old, isNew: false)
        try checkPassword(new, isNew: true)
        try checkExists(image)
        if try attachment(of: image) != nil {
            throw CryptError.io(L("%@ is open. Close it before changing its password.", image.lastPathComponent))
        }
        try Hdiutil.check(["chpass", "-oldstdinpass", "-newstdinpass", image.path],
                          passwords: [old, new])
    }

    /// Tells whether the image is encrypted. A file that is not a disk image
    /// counts as not encrypted.
    public static func isEncrypted(_ image: URL) throws -> Bool {
        try checkExists(image)
        let info = try Hdiutil.check(["isencrypted", "-plist", image.path]).plist()
        guard let encrypted = info["encrypted"] as? Bool else {
            throw CryptError.io(L("hdiutil isencrypted gave no answer for %@.", image.lastPathComponent))
        }
        return encrypted
    }

    /// The images attached now, from hdiutil info -plist.
    public static func attached() throws -> [AttachedImage] {
        let info = try Hdiutil.check(["info", "-plist"]).plist()
        let images = info["images"] as? [[String: Any]] ?? []
        return images.compactMap { image in
            guard let path = image["image-path"] as? String else {
                return nil
            }
            let entities = image["system-entities"] as? [[String: Any]] ?? []
            let mounted = entities.compactMap { $0["mount-point"] as? String }.first
            return AttachedImage(imagePath: URL(fileURLWithPath: path),
                                 mountPoint: mounted.map { URL(fileURLWithPath: $0, isDirectory: true) })
        }
    }

    /// The disk (/dev/diskN) of the attached image that has a volume mounted
    /// at `path`, or nil if no disk image is mounted there.
    static func disk(mountedAt path: String) throws -> String? {
        let wanted = realPath(path)
        let info = try Hdiutil.check(["info", "-plist"]).plist()
        for image in info["images"] as? [[String: Any]] ?? [] {
            let entities = image["system-entities"] as? [[String: Any]] ?? []
            guard entities.contains(where: { ($0["mount-point"] as? String).map(realPath) == wanted }) else {
                continue
            }
            // hdiutil lists the image's own disk first, before its partitions
            // and the disk APFS makes for its container
            return entities.compactMap { $0["dev-entry"] as? String }.first
        }
        return nil
    }

    /// The attached image at this path, or nil if it is not attached.
    public static func attachment(of image: URL) throws -> AttachedImage? {
        let wanted = realPath(image.path)
        return try attached().first { realPath($0.imagePath.path) == wanted }
    }

    /// A path for attach(mountPoint:) that does not exist yet, in the user's own
    /// temporary folder; hdiutil makes the folder and removes it at detach.
    public static func privateMountPoint() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("safe-mount-" + UUID().uuidString, isDirectory: true)
    }

    // MARK: helpers

    private static func checkNewImage(_ image: URL, volumeName: String, password: SecureBytes) throws {
        guard image.isFileURL, image.pathExtension.lowercased() == "sparsebundle" else {
            throw CryptError.io(L("The name of the volume's file must end in .sparsebundle."))
        }
        var st = stat()
        if lstat(image.path, &st) == 0 {
            throw CryptError.alreadyExists(image.path)
        }
        var isFolder: ObjCBool = false
        let parent = image.deletingLastPathComponent().path
        guard FileManager.default.fileExists(atPath: parent, isDirectory: &isFolder),
              isFolder.boolValue else {
            throw CryptError.io(L("The folder %@ does not exist.", parent))
        }
        if volumeName.trimmingCharacters(in: .whitespaces).isEmpty {
            throw CryptError.io(L("The volume needs a name."))
        }
        try checkPassword(password, isNew: true)
    }

    private static func checkPassword(_ password: SecureBytes, isNew: Bool) throws {
        if isNew && password.count == 0 {
            throw CryptError.io(L("The password must not be empty."))
        }
        // hdiutil reads a password up to the first NUL byte
        if password.withUnsafeBytes({ $0.contains(0) }) {
            throw CryptError.io(L("The password must not contain a NUL character."))
        }
    }

    private static func checkExists(_ image: URL) throws {
        guard image.isFileURL, FileManager.default.fileExists(atPath: image.path) else {
            throw CryptError.io(L("There is no disk image at %@.", image.path))
        }
    }

    private static func checkMade(_ image: URL) throws {
        guard FileManager.default.fileExists(atPath: image.path) else {
            throw CryptError.io(L("hdiutil reported no error, but %@ was not made.", image.path))
        }
    }

    private static func isBusy(_ result: Hdiutil.Result) -> Bool {
        result.status == EBUSY || result.message.contains("Resource busy")
    }

    /// Twice the folder's size, at least 1 GB; a sparse bundle only takes the
    /// space its files need.
    static func sizeMB(for folder: URL) -> Int {
        var bytes: Int64 = 0
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        if let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                     options: [], errorHandler: { _, _ in true }) {
            for case let url as URL in walk {
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true else {
                    continue
                }
                // round up to whole 4 KB blocks
                bytes += (Int64(values.fileSize ?? 0) + 4095) / 4096 * 4096
            }
        }
        let mb = Int(bytes / (1024 * 1024)) + 1
        return max(1024, 2 * mb + 64)
    }

    /// The path with symbolic links resolved (/var becomes /private/var), or the
    /// standardized path if it does not exist.
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else {
            return URL(fileURLWithPath: path).standardizedFileURL.path
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
