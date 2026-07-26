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

    // How a message should be labelled: the sender's display name within the
    // room, and the room's own name. Set by RoomListVC so we reuse the very
    // state the room list and timeline already hold (Room.memberNames /
    // Room.name, merged across syncs) instead of re-parsing membership here — an
    // incremental sync usually carries no member state at all, so parsing only
    // the current response would leave us with nothing to resolve. Both come
    // from one Room lookup.
    //
    // Called on the /sync thread, right after RoomListVC has merged this
    // response into its rooms: its update listener is registered before ours and
    // they run in order on the same thread, so the names are already current.
    var contextResolver: ((_ roomId: String, _ userId: String) -> (sender: String?, room: String?))?

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

        var pending: [(name: String, room: String?, body: String)] = []
        for (roomId, rawRoom) in join {
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
                // Display name when we know one, the Matrix ID's localpart
                // otherwise — never the raw "@alice:server.tld".
                var name = NotificationManager.localpart(sender)
                var roomName: String?
                if let sender = sender {
                    let context = contextResolver?(roomId, sender)
                    if let resolved = context?.sender, !resolved.isEmpty { name = resolved }
                    roomName = context?.room
                }
                pending.append((name, roomName, body))
            }
        }
        guard !pending.isEmpty else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self = self, NotificationManager.isEnabled, self.isBackground else { return }
            guard UIApplication.shared.applicationState != .active else { return }
            for msg in pending {
                self.postNotification(name: msg.name, room: msg.room, body: msg.body)
            }
        }
    }

    // Must be called on the main thread only (see handleSync).
    private func postNotification(name: String, room: String?, body: String) {
        let note = UILocalNotification()
        note.alertBody = NotificationManager.alertBody(name: name, room: room, body: body)
        note.soundName = UILocalNotificationDefaultSoundName
        UIApplication.shared.presentLocalNotificationNow(note)
    }

    // "Alice · Standup: on my way" in a named room, plain "Alice: on my way" in a
    // DM. The room name is dropped when it just repeats the sender (Room.parse
    // names a DM after the other member, so it would read "Alice · Alice") and
    // when it's still the fallback room id (an unnamed room we've seen no
    // m.room.name for), which would be noise. A banner only shows about a line
    // before truncating, so anything that doesn't disambiguate is worth omitting.
    private static func alertBody(name: String, room: String?, body: String) -> String {
        var title = name
        if let room = room, !room.isEmpty, room != name, !room.hasPrefix("!") {
            title = title.isEmpty ? room : "\(name) \u{00B7} \(room)"
        }
        return title.isEmpty ? body : "\(title): \(body)"
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
