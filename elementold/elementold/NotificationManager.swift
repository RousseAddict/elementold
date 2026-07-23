import UIKit

// Background message notifications, gated by a master kill switch in Settings
// (see push-notifications-research.md, "Tier 1"). The switch is OFF by default.
//
// When OFF: NONE of this runs. SyncEngine stops on background exactly as the
// original foreground-only build, no background task is taken, no VoIP keep-alive
// is registered, and no local notification is ever posted. Turning the switch off
// is therefore a true kill switch — zero new behaviour, zero new crash surface.
//
// When ON: we keep the /sync long-poll alive after the app is backgrounded via a
// UIBackgroundTask plus the legacy VoIP keep-alive timer (setKeepAliveTimeout,
// present on iOS 4-9 — perfect for our 6/7 target, removed only in iOS 10) and
// post a UILocalNotification for each incoming message from another user.
//
// Every API used here is iOS 4+ / iOS 6-safe on purpose: beginBackgroundTask
// WITHOUT the withName: variant (that selector is iOS 7+), presentLocalNotificationNow,
// UILocalNotification, setKeepAliveTimeout/clearKeepAliveTimeout. The iOS 8+
// registerUserNotificationSettings requirement is handled under #if IOS8_TARGET
// only, so it's compiled out of the iOS 6/7 build entirely.
final class NotificationManager {
    static let shared = NotificationManager()

    private static let enabledKey = "elementold.notificationsEnabled"

    // The kill switch. Defaults to false (UserDefaults.bool default) → OFF.
    static var isEnabled: Bool {
        get { return UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    // Set by RoomListVC. Lets us stop the poll loop when our background window
    // expires, so the OS doesn't kill us for overrunning.
    weak var syncEngine: SyncEngine?

    private var bgTask: UIBackgroundTaskIdentifier = UIBackgroundTaskIdentifier.invalid
    private var isBackground = false

    // Cap notifications posted per sync response so a large catch-up batch can't
    // flood Notification Center.
    private let maxPerSync = 5

    private init() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    // Called at launch (harmless when OFF / on the iOS 6 build).
    func registerSettingsIfNeeded() {
#if IOS8_TARGET
        let types: UIUserNotificationType = [.alert, .sound, .badge]
        let settings = UIUserNotificationSettings(types: types, categories: nil)
        UIApplication.shared.registerUserNotificationSettings(settings)
#endif
    }

    // Called from the Settings toggle. Turning OFF immediately tears down any
    // live background machinery.
    func setEnabled(_ on: Bool) {
        NotificationManager.isEnabled = on
        if on {
            registerSettingsIfNeeded()
            // If we're somehow already backgrounded (e.g. toggled from a sheet),
            // spin up the background window now.
            if isBackground { beginBackgroundTask(); registerKeepAlive() }
        } else {
            clearKeepAlive()
            endBackgroundTask()
        }
    }

    // MARK: - Background lifecycle

    @objc private func appDidEnterBackground() {
        isBackground = true
        guard NotificationManager.isEnabled else { return }
        beginBackgroundTask()
        registerKeepAlive()
    }

    @objc private func appDidBecomeActive() {
        isBackground = false
        endBackgroundTask()
        clearKeepAlive()
    }

    private func beginBackgroundTask() {
        guard bgTask == UIBackgroundTaskIdentifier.invalid else { return }
        // NOTE: the no-name variant only — beginBackgroundTask(withName:...) is an
        // iOS 7+ selector and would crash on a genuine iOS 6 device.
        bgTask = UIApplication.shared.beginBackgroundTask(expirationHandler: { [weak self] in
            self?.syncEngine?.stop()
            self?.endBackgroundTask()
        })
    }

    private func endBackgroundTask() {
        guard bgTask != UIBackgroundTaskIdentifier.invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTask)
        bgTask = UIBackgroundTaskIdentifier.invalid
    }

    // Legacy VoIP keep-alive: iOS re-wakes us (min 600s) so we can re-open a
    // fresh background window and make sure the sync loop is running. Returns
    // false (no-op) if the app lacks the `voip` UIBackgroundMode — safe either way.
    private func registerKeepAlive() {
        UIApplication.shared.setKeepAliveTimeout(600) { [weak self] in
            guard let self = self, NotificationManager.isEnabled else { return }
            self.beginBackgroundTask()
            self.syncEngine?.start()
        }
    }

    private func clearKeepAlive() {
        UIApplication.shared.clearKeepAliveTimeout()
    }

    // MARK: - Notification posting

    // Called for every /sync response via a listener RoomListVC registers.
    // Posts only while enabled AND backgrounded, and never on the cold-start
    // initial sync (which replays already-read history — see Room.parse).
    //
    // ⚠️ This runs on CurlFetcher's BACKGROUND queue (the /sync completion thread),
    // NOT the main thread. Parsing the [String: Any] dictionaries here is fine, but
    // EVERY UIApplication / UILocalNotification call must be marshalled to the main
    // thread: doing UIKit work off-main on this iOS 6 runtime crashed SpringBoard
    // (device respring / boot-logo, no app crash log). Collect first, post on main.
    func handleSync(_ json: [String: Any], isInitial: Bool) {
        guard NotificationManager.isEnabled, isBackground, !isInitial else { return }
        let selfId = MatrixSession.userId
        guard let rooms = json["rooms"] as? [String: Any],
              let join = rooms["join"] as? [String: Any] else { return }

        var pending: [(name: String, body: String)] = []
        for (_, rawRoom) in join {
            if pending.count >= maxPerSync { break }
            guard let roomJSON = rawRoom as? [String: Any],
                  let timeline = roomJSON["timeline"] as? [String: Any],
                  let events = timeline["events"] as? [[String: Any]] else { continue }
            for ev in events {
                if pending.count >= maxPerSync { break }
                guard (ev["type"] as? String) == "m.room.message" else { continue }
                let sender = ev["sender"] as? String
                if let selfId = selfId, sender == selfId { continue }   // skip own messages
                let content = ev["content"] as? [String: Any]
                let body = (content?["body"] as? String) ?? "New message"
                pending.append((NotificationManager.localpart(sender), body))
            }
        }
        guard !pending.isEmpty else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self = self, NotificationManager.isEnabled, self.isBackground else { return }
            guard UIApplication.shared.applicationState != .active else { return }
            for msg in pending { self.postNotification(name: msg.name, body: msg.body) }
        }
    }

    // Must be called on the main thread only (see handleSync).
    private func postNotification(name: String, body: String) {
        let note = UILocalNotification()
        note.alertBody = name.isEmpty ? body : "\(name): \(body)"
        note.soundName = UILocalNotificationDefaultSoundName
        UIApplication.shared.presentLocalNotificationNow(note)
    }

    // "@alice:server.tld" -> "alice". Pure Swift (no NSString range selectors,
    // which are a crash risk on this runtime).
    private static func localpart(_ userId: String?) -> String {
        guard var s = userId else { return "" }
        if s.hasPrefix("@") { s.removeFirst() }
        if let colon = s.firstIndex(of: ":") { s = String(s[..<colon]) }
        return s
    }
}
