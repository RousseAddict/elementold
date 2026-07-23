import Foundation
import UIKit

// Foreground-only Matrix /sync long-poll loop (v1 scope, per plan.md Phase 2/7:
// no background modes, no push). The loop runs only while the app is active;
// it stops when backgrounded and does a fresh poll when the app comes back.
//
// Supports multiple listeners (RoomListVC needs every update to refresh the room
// list; RoomTimelineVC additionally needs updates while a room is open) via
// addUpdateListener/addErrorListener rather than a single closure.
class SyncEngine {

    private let api: MatrixAPIClient
    private var since: String?
    private var isRunning = false
    private var isRequestInFlight = false

    // Server-requested long-poll duration (ms) passed to /sync?timeout=...
    // The client-side curl timeout (seconds) must stay comfortably above this
    // so our own timeout never races the server's long-poll response.
    private let serverTimeoutMs = 30000
    private var clientTimeoutSeconds: Int { (serverTimeoutMs / 1000) + 10 }

    // Delay before retrying after a failed poll, so an unreachable/erroring
    // server doesn't get hammered in a tight loop.
    private let retryDelaySeconds: TimeInterval = 5

    // The Bool is `isInitial`: true only for the very first /sync of this
    // engine's lifetime (the cold-start full sync, when `since` was still nil).
    // RoomListVC uses it to skip its client-side unread heuristic on that batch,
    // since the initial timeline replays already-read messages (see Room.parse).
    // Keyed by an opaque token so a listener can be removed again — a screen
    // that comes and goes (RoomTimelineVC, opened once per conversation) must
    // remove its listener when it closes, otherwise every conversation ever
    // opened this session leaves a dead closure here that /sync still calls on
    // each response. (RoomListVC lives for the whole session and never removes.)
    private var updateListeners: [(token: Int, fn: ([String: Any], Bool) -> Void)] = []
    private var errorListeners: [(token: Int, fn: (Error) -> Void)] = []
    private var nextListenerToken = 0

    // Percent-encode a query value using pure Swift stdlib only — no Foundation/ObjC calls.
    // `String.addingPercentEncoding(withAllowedCharacters:)` itself (the whole method, not
    // just the .urlQueryAllowed constant) bridges to an NSString method that doesn't exist
    // on real iOS 6 ("unrecognized selector sent to instance"), so any Foundation-based
    // percent-encoding API is off the table here — hand-roll it instead.
    private static let unreservedBytes: Set<UInt8> = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8)
    private static let hexDigits = Array("0123456789ABCDEF")

    private static func percentEncode(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            if unreservedBytes.contains(byte) {
                result.unicodeScalars.append(UnicodeScalar(byte))
            } else {
                result.append("%")
                result.append(hexDigits[Int(byte >> 4)])
                result.append(hexDigits[Int(byte & 0x0F)])
            }
        }
        return result
    }

    init(api: MatrixAPIClient) {
        self.api = api
        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive),
                                                name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground),
                                                name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @discardableResult
    func addUpdateListener(_ listener: @escaping ([String: Any], Bool) -> Void) -> Int {
        let token = nextListenerToken
        nextListenerToken += 1
        updateListeners.append((token, listener))
        return token
    }

    @discardableResult
    func addErrorListener(_ listener: @escaping (Error) -> Void) -> Int {
        let token = nextListenerToken
        nextListenerToken += 1
        errorListeners.append((token, listener))
        return token
    }

    func removeUpdateListener(_ token: Int) {
        updateListeners.removeAll { $0.token == token }
    }

    func removeErrorListener(_ token: Int) {
        errorListeners.removeAll { $0.token == token }
    }

    @objc private func appDidBecomeActive() {
        start()
    }

    @objc private func appDidEnterBackground() {
        // Keep the long-poll running in the background ONLY when background
        // notifications are switched on; the NotificationManager holds a
        // UIBackgroundTask + VoIP keep-alive to keep the process alive to
        // service it. When the switch is OFF this stops exactly as before.
        if !NotificationManager.isEnabled { stop() }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        pollOnce()
    }

    func stop() {
        isRunning = false
    }

    private func pollOnce() {
        guard isRunning, !isRequestInFlight else { return }
        isRequestInFlight = true

        // Captured before the response updates `since`: a nil `since` here means
        // this is the cold-start full sync (no incremental delta token yet).
        let isInitial = since == nil

        var path = "/_matrix/client/v3/sync?timeout=\(serverTimeoutMs)"
        if let since = since {
            let encoded = SyncEngine.percentEncode(since)
            path += "&since=\(encoded)"
        }

        api.get(path, timeout: clientTimeoutSeconds) { [weak self] json, error in
            guard let self = self else { return }
            self.isRequestInFlight = false

            if let error = error {
                self.errorListeners.forEach { $0.fn(error) }
                guard self.isRunning else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + self.retryDelaySeconds) { [weak self] in
                    self?.pollOnce()
                }
                return
            }

            if let json = json {
                if let nextBatch = json["next_batch"] as? String {
                    self.since = nextBatch
                }
                self.updateListeners.forEach { $0.fn(json, isInitial) }
            }

            guard self.isRunning else { return }
            self.pollOnce()
        }
    }
}
