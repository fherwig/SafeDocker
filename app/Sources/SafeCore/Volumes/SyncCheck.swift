import Darwin
import Foundation

// WP2. Today's safe_load.sh checks the sync app with pgrep -x; this does the
// same without a child process, and also matches names longer than the 16
// characters pgrep sees.

/// Checks that the app syncing a volume's folder is running (R4).
public enum SyncCheck {
    /// True if the folder at `folder`, or one above it, is probably uploaded by a
    /// sync service: under ~/Library/CloudStorage (Dropbox, OneDrive, Google Drive
    /// and others on current macOS) or ~/Library/Mobile Documents (iCloud Drive),
    /// or a folder whose name contains Nextcloud, ownCloud, Dropbox, OneDrive,
    /// Google Drive, Seafile or Syncthing. The service then keeps a plain copy of
    /// a file encrypted or deleted there in its trash and version history, which
    /// Safe tells the user (review round 4).
    public static func isInSyncedFolder(_ folder: String, home: String) -> Bool {
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        let standard = (folder as NSString).standardizingPath + "/"
        for root in ["/Library/CloudStorage/", "/Library/Mobile Documents/"]
            where standard.hasPrefix(home + root) {
            return true
        }
        let names = ["nextcloud", "owncloud", "dropbox", "onedrive", "google drive", "seafile", "syncthing"]
        return standard.split(separator: "/").contains { component in
            let lower = component.lowercased()
            return names.contains { lower.contains($0) }
        }
    }

    /// True if a process with exactly this name runs: its process name or the
    /// file name of its program, for example "Nextcloud".
    public static func isRunning(processName: String) -> Bool {
        guard !processName.isEmpty else {
            return false
        }
        for pid in allProcesses() {
            if name(of: pid) == processName || programName(of: pid) == processName {
                return true
            }
        }
        return false
    }

    private static func allProcesses() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else {
            return []
        }
        // room for processes started in between
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let found = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard found > 0 else {
            return []
        }
        return pids.prefix(Int(found)).filter { $0 > 0 }
    }

    /// The process name; empty for processes of other users.
    private static func name(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else {
            return ""
        }
        return String(cString: buffer)
    }

    private static func programName(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else {
            return ""
        }
        return (String(cString: buffer) as NSString).lastPathComponent
    }
}
