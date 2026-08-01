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

    // A `since` restored from disk (see RoomStore) has never been shown to the
    // homeserver by this process, so unlike a token we obtained ourselves it may
    // simply not be accepted — the server may have forgotten it, or the session
    // may have been invalidated while the app was closed. That failure repeats
    // identically every retry, which would leave the app permanently stuck, so
    // the FIRST failure with such a token drops it and falls back to a full sync.
    private var isUnvalidatedResumeToken = false

    // The first poll of a launch needs the generous budget even when it is
    // technically incremental: resuming after hours away means the server has a
    // large delta to assemble, and `timeout` doesn't bound that work (it only
    // bounds how long the server WAITS for new events). Cleared on first success.
    private var isFirstPoll = true

    // Server-requested long-poll duration (ms) passed to /sync?timeout=...
    // The client-side curl timeout (seconds) must stay comfortably above this
    // so our own timeout never races the server's long-poll response.
    private let serverTimeoutMs = 30000
    private var clientTimeoutSeconds: Int { (serverTimeoutMs / 1000) + 10 }

    // The INITIAL sync needs its own, much larger allowance. `timeout` above only
    // bounds how long the server waits for new events, which applies to an
    // incremental sync; the first sync has nothing to wait for and instead spends
    // however long it takes to build full state plus a timeline for every joined
    // room. That cost grows with the size of the room list, and past a few dozen
    // rooms it comfortably exceeded the 40s budget — the curl handle's timeout is
    // a TOTAL transfer deadline, so it fired while the server was still working
    // and surfaced as "Connection failed", every 40 seconds, forever: `since` is
    // only assigned from a successful response, so each retry started another
    // full initial sync and the app could never reach the cheap incremental path.
    //
    // NOTE: a stall detector (CURLOPT_LOW_SPEED_*) is NOT usable as a substitute
    // here. The server sends nothing at all while it computes, so a low-speed
    // abort would kill the request for exactly the same wrong reason.
    private let initialSyncTimeoutSeconds = 180

    // Delay before retrying after a failed poll, so an unreachable/erroring
    // server doesn't get hammered in a tight loop.
    private let retryDelaySeconds: TimeInterval = 5

    // Floor between two successful polls. A long-poll normally blocks for the
    // full serverTimeoutMs, but any event at all — including a typing notice,
    // which fires every few keystrokes on the other end — returns it instantly.
    // Since CurlFetcher delivers completions on the main thread, the listeners
    // (Room.parse for every room, RoomEvent.parse, rebuildRows, reloadData) run
    // there too, so a burst of fast returns is a burst of main-thread work that
    // competes with typing and scrolling. This caps that at ~4 rounds/second at
    // no cost to perceived latency.
    private let minPollIntervalSeconds: TimeInterval = 0.25

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

    // Bumped whenever a poll is forced (refreshNow). The delayed re-poll blocks
    // capture the value current when they were scheduled and bail if it moved,
    // which is the only way to cancel them — DispatchQueue.asyncAfter has no
    // cancel, so without this a forced poll would be followed by the original
    // delayed one firing too, and pollOnce's in-flight guard would silently
    // swallow it rather than reschedule, stalling the loop until the next event.
    private var pollGeneration = 0

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

    // Seed the delta token from a persisted snapshot so the first /sync of this
    // launch is a cheap incremental one instead of a full initial sync. Must be
    // called BEFORE start(), and only makes sense once — a token acquired during
    // this session is always the better one.
    //
    // Note the first response then reports `isInitial == false`, which is correct:
    // it is not an initial sync, and RoomListVC's client-side unread heuristic
    // SHOULD count what arrived while the app was closed.
    func resume(since token: String) {
        guard !isRunning, since == nil, !token.isEmpty else { return }
        since = token
        isUnvalidatedResumeToken = true
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        pollOnce()
    }

    func stop() {
        isRunning = false
    }

    // Ask for a poll right now, skipping whatever delay the loop is sitting in.
    // Returns whether that actually changed anything: when a long-poll is already
    // open there is nothing to force — the server is holding that request open
    // precisely so it can answer the instant something happens, and we have no
    // way to cancel it (CurlFetcher has no cancellation), so a "refresh" then
    // means the list is already as current as it can be.
    @discardableResult
    func refreshNow() -> Bool {
        guard isRunning else {
            start()
            return true
        }
        guard !isRequestInFlight else { return false }
        pollGeneration += 1
        pollOnce()
        return true
    }

    private func pollOnce() {
        guard isRunning, !isRequestInFlight else { return }
        isRequestInFlight = true
        let generation = pollGeneration

        // Captured before the response updates `since`: a nil `since` here means
        // this is the cold-start full sync (no incremental delta token yet).
        let isInitial = since == nil

        var path = "/_matrix/client/v3/sync?timeout=\(serverTimeoutMs)"
        if let since = since {
            let encoded = SyncEngine.percentEncode(since)
            path += "&since=\(encoded)"
        }

        let timeout = (isInitial || isFirstPoll) ? initialSyncTimeoutSeconds : clientTimeoutSeconds
        api.get(path, timeout: timeout) { [weak self] json, error in
            guard let self = self else { return }
            self.isRequestInFlight = false

            if let error = error {
                if self.isUnvalidatedResumeToken {
                    // Deliberately shape-agnostic: a rejected token can surface as
                    // M_UNKNOWN_TOKEN, as some other errcode, or as a transport
                    // failure, and guessing wrong here means an app that never
                    // recovers. Throwing the token away costs one full sync.
                    self.isUnvalidatedResumeToken = false
                    self.since = nil
                    RoomStore.shared.discard()
                }
                self.errorListeners.forEach { $0.fn(error) }
                guard self.isRunning else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + self.retryDelaySeconds) { [weak self] in
                    guard let self = self, self.pollGeneration == generation else { return }
                    self.pollOnce()
                }
                return
            }

            if let json = json {
                self.isUnvalidatedResumeToken = false
                self.isFirstPoll = false
                if let nextBatch = json["next_batch"] as? String {
                    self.since = nextBatch
                }
                self.updateListeners.forEach { $0.fn(json, isInitial) }
            }

            guard self.isRunning else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + self.minPollIntervalSeconds) { [weak self] in
                guard let self = self, self.pollGeneration == generation else { return }
                self.pollOnce()
            }
        }
    }
}
