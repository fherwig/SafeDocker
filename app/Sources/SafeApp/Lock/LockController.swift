import AppKit
import SafeCore
import CoreGraphics

// WP3. The interface is fixed by the building plan, section 3.1.

/// Something that hides or closes its decrypted content when the app locks (G4).
protocol Lockable: AnyObject {
    /// Hides or closes the decrypted content.
    func lock()
}

/// Locks after 10 minutes without input (read every 10 s), on sleep and on screen
/// lock (G4, section 4.9).
final class LockController {
    /// The one lock controller of the app.
    static let shared = LockController()

    /// kCGAnyInputEventType. The plan's .null (kCGEventNull) does not work: tested on
    /// macOS 26.3, it reports the time since start-up, not since the last input.
    static let anyInputEvent = CGEventType(rawValue: ~0) ?? .null

    /// Seconds since the last keyboard, mouse or tablet input anywhere on the Mac.
    /// The checks replace it.
    var idleSeconds: () -> TimeInterval = {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: LockController.anyInputEvent)
    }

    /// A clock that only goes forward, for the time between two idle checks
    /// (IdleLockDecider); the checks replace it.
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    /// True while a volume that Safe opened is open; AppDelegate sets it. With
    /// the editors and viewers it decides whether the idle check must not be
    /// delayed (keepChecking).
    var hasOpenVolumes: () -> Bool = { false }

    /// Begins and ends the activity that keeps App Nap from holding back the idle
    /// check; the checks replace them.
    var beginActivity: () -> NSObjectProtocol = {
        ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                              reason: "Safe hides decrypted files and closes volumes after 10 minutes without use")
    }
    var endActivity: (NSObjectProtocol) -> Void = { ProcessInfo.processInfo.endActivity($0) }
    private var activity: NSObjectProtocol?

    private struct WeakItem {
        weak var item: Lockable?
    }

    private var items: [WeakItem] = []
    private var actions: [() -> Void] = []
    private var decider = IdleLockDecider()
    private var timer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var screenLockObserver: ScreenLockObserver?
    private var locking = false
    private var awaitingReturn = false
    private var lockingForSleep = false

    /// How often the app has locked since it started. A flow that waits in a
    /// dialog with decrypted data reads it before and after, and shows nothing
    /// if it changed (G4).
    private(set) var lockCount = 0

    /// Called once after a lock, at the first idle check that finds input again
    /// (the user is back); AppDelegate also calls it on com.apple.screenIsUnlocked.
    /// Volumes left open on lock are reported then (G4).
    var onUserBack: (() -> Void)?

    /// Starts watching; called once by AppDelegate.
    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: LockPolicy.checkInterval, repeats: true) { [weak self] _ in
            self?.checkIdle()
        }
        timer.tolerance = 2
        // common modes, so that it also fires while a dialog is open
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification,
                     NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            // before sleep the lock actions finish before the handler returns, so
            // that the Mac does not sleep with volumes still open
            let sleep = name != NSWorkspace.sessionDidResignActiveNotification
            let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.lockNow(beforeSleep: sleep)
            }
            observers.append((workspace, token))
        }

        // AppKit holds back distributed notifications while the app is not active,
        // unless they are asked for with deliverImmediately.
        let screenLock = ScreenLockObserver { [weak self] in self?.lockNow() }
        DistributedNotificationCenter.default().addObserver(
            screenLock, selector: #selector(ScreenLockObserver.screenLocked(_:)),
            name: NSNotification.Name("com.apple.screenIsLocked"), object: nil,
            suspensionBehavior: .deliverImmediately)
        screenLockObserver = screenLock
    }

    /// Reads the idle time and locks once it passes 10 minutes; the timer calls it.
    /// After a lock, the first check with recent input calls onUserBack: an app
    /// that is in front when it locks never becomes active again, so its report
    /// cannot wait for that.
    func checkIdle() {
        let idle = idleSeconds()
        if decider.shouldLock(idleSeconds: idle, at: now()) {
            lockNow()
        } else if awaitingReturn && idle < LockPolicy.idleLimit {
            userIsBack()
        }
        keepChecking()
    }

    /// While an editor, a viewer or a volume that Safe opened is open, holds an
    /// activity, so that App Nap does not hold back the idle check of a Safe in
    /// the background (finding of review round 4); otherwise lets it go. Called
    /// at every check, when an item is registered, and when a volume opens or closes.
    func keepChecking() {
        let needed = !registeredItems.isEmpty || hasOpenVolumes()
        if needed && activity == nil {
            activity = beginActivity()
        } else if !needed, let token = activity {
            endActivity(token)
            activity = nil
        }
    }

    /// True while the activity of keepChecking is held; for the checks.
    var isKeepingChecking: Bool {
        activity != nil
    }

    /// True from a lock until the user is back.
    var isAwaitingReturn: Bool {
        awaitingReturn
    }

    /// The user is back after a lock; calls onUserBack once per lock.
    func userIsBack() {
        guard awaitingReturn else { return }
        awaitingReturn = false
        onUserBack?()
    }

    /// Adds an item to lock; held weakly.
    func register(_ item: Lockable) {
        items.removeAll { $0.item == nil || $0.item === item }
        items.append(WeakItem(item: item))
        keepChecking()
    }

    /// Adds an action to run on lock; WP4 adds "close volumes".
    func addLockAction(_ action: @escaping () -> Void) {
        actions.append(action)
    }

    /// The registered items that still exist.
    var registeredItems: [Lockable] {
        items.compactMap { $0.item }
    }

    /// True while the lock actions run for a lock before the Mac sleeps (or its
    /// screens do): they should then finish their work before they return.
    var isLockingForSleep: Bool {
        lockingForSleep
    }

    /// Locks everything now: editors and viewers, then the clipboard, then the
    /// lock actions. The user counts as away before the actions run, so that an
    /// action that finishes at once never reports to the user during the lock.
    func lockNow(beforeSleep: Bool = false) {
        // an item that closes its window must not start a second round
        guard !locking else { return }
        locking = true
        lockingForSleep = beforeSleep
        defer {
            locking = false
            lockingForSleep = false
        }
        lockCount += 1
        let live = registeredItems
        items = live.map { WeakItem(item: $0) }
        for item in live {
            item.lock()
        }
        ClipboardGuard.clearIfOurs()
        awaitingReturn = true
        for action in actions {
            action()
        }
    }
}

/// Receives com.apple.screenIsLocked; distributed notifications need an Objective-C selector.
private final class ScreenLockObserver: NSObject {
    private let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    @objc func screenLocked(_ notification: Notification) {
        if Thread.isMainThread {
            action()
        } else {
            DispatchQueue.main.async(execute: action)
        }
    }
}
