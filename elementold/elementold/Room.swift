import Foundation

// A joined room, built/merged from successive `rooms.join[roomId]` entries
// returned by /sync. Later (incremental) sync responses often omit `state`
// entirely and only carry new timeline events, so `parse` merges into
// `existing` rather than rebuilding from scratch each time.
struct Room {
    let roomId: String
    var name: String
    var lastMessage: String
    var lastMessageTimestamp: Double   // ms since epoch (origin_server_ts), for sorting
    var prevBatch: String?             // pagination token for backfill (Phase 5)
    // Parsed events captured from /sync timeline chunks, so RoomTimelineVC can seed its
    // initial view with them. Without this, every message that arrived in a /sync
    // response before the room was opened (not just the newest one reflected in
    // lastMessage above) was silently dropped: RoomTimelineVC only had backfill
    // (older than prevBatch) and live syncs (after the screen opened) as sources,
    // leaving a gap for exactly the messages that produced the room-list preview.
    // Bounded so a room sitting unopened for a long session doesn't grow unbounded.
    var timelineEvents: [RoomEvent] = []
    // Room avatar mxc:// URI, from m.room.avatar state (or, for a DM with no
    // explicit room avatar, a fallback to the other member's avatar — see below).
    var avatarMxc: String?
    // Per-user display names and avatar mxc URIs harvested from m.room.member
    // state/timeline events, so the timeline can show sender avatars/names
    // without a separate profile fetch. Merged across syncs (incremental syncs
    // only carry changed members).
    var memberNames: [String: String] = [:]
    var memberAvatars: [String: String] = [:]
    // Larger of: (a) the homeserver's own `unread_notifications.notification_count`
    // (present on every /sync room entry) — server-computed against push rules
    // and read receipts, correct across all of the user's devices — and (b) a
    // simple client-side count of messages from others seen while this room
    // wasn't open. (a) alone should be sufficient on a normally-configured
    // homeserver, but push-rule semantics for what counts as a "notification"
    // vary enough by server/room config that (b) is kept as a floor so the
    // badge still reflects reality even if (a) doesn't. Forced to 0 while
    // `isOpen` so the badge clears immediately on open rather than waiting on
    // our own read-receipt call (see RoomTimelineVC) to land and the *next*
    // /sync to reflect it.
    var unreadCount: Int = 0

    // Room type from m.room.create `content.type` (e.g. "m.space"). nil for an
    // ordinary room. Spaces are grouping containers with no timeline — they
    // should be hidden from the room list and used as filter buckets instead.
    // Set once from state on join; carried across incremental syncs (which omit
    // state) via `existing`.
    var roomType: String?
    // For a space room (roomType == "m.space"): the set of child room IDs it
    // groups, from `m.space.child` state events (state_key = child room id). Per
    // spec a child link is "present" only while its content is non-empty, so an
    // `m.space.child` with empty content removes the child. Merged across syncs.
    var spaceChildren: Set<String> = []
    // Bridge info (uk.half-shot.bridge / MSC2346): the bridged network's label +
    // icon when this room is a bridge portal, used to group/label rooms by their
    // origin network (Discord/WhatsApp/…). nil for a native Matrix room.
    var bridgeNetwork: String?      // protocol.displayname ?? protocol.id
    var bridgeAvatarMxc: String?    // protocol.avatar_url (mxc://)
    // Room topic from m.room.topic state. Shown/edited in Room Settings. Empty
    // string is a legitimate value (a topic that was cleared), so this stays nil
    // only while we've never seen the state event.
    var topic: String?

    // Convenience: this room is a Matrix space (grouping container, no timeline).
    var isSpace: Bool { return roomType == "m.space" }

    private static let maxBufferedEvents = 50

    static func parse(roomId: String, json: [String: Any], existing: Room?, selfUserId: String?,
                       isOpen: Bool = false, isInitialSync: Bool = false) -> Room {
        var name = existing?.name ?? roomId
        var lastMessage = existing?.lastMessage ?? ""
        var lastTimestamp = existing?.lastMessageTimestamp ?? 0
        var prevBatch = existing?.prevBatch
        var timelineEvents = existing?.timelineEvents ?? []
        var unreadCount = existing?.unreadCount ?? 0
        var avatarMxc = existing?.avatarMxc
        var memberNames = existing?.memberNames ?? [:]
        var memberAvatars = existing?.memberAvatars ?? [:]
        var roomType = existing?.roomType
        var spaceChildren = existing?.spaceChildren ?? []
        var bridgeNetwork = existing?.bridgeNetwork
        var bridgeAvatarMxc = existing?.bridgeAvatarMxc
        var topic = existing?.topic
        var explicitAvatarFound = existing?.avatarMxc != nil
        var fallbackMemberName: String?
        var fallbackMemberAvatar: String?
        var explicitNameFound = existing != nil && existing?.name != roomId

        func considerStateEvent(_ event: [String: Any]) {
            guard let type = event["type"] as? String,
                  let content = event["content"] as? [String: Any] else { return }
            if type == "m.room.name", let roomName = content["name"] as? String, !roomName.isEmpty {
                name = roomName
                explicitNameFound = true
            } else if type == "m.room.avatar", let url = content["url"] as? String, url.hasPrefix("mxc://") {
                avatarMxc = url
                explicitAvatarFound = true
            } else if type == "m.room.topic", let t = content["topic"] as? String {
                topic = t
            } else if type == "m.room.create" {
                // Space detection: m.room.create carries the room's type.
                if let t = content["type"] as? String, !t.isEmpty { roomType = t }
            } else if type == "m.space.child" {
                // state_key = the child room id. Non-empty content = link present;
                // empty content = link removed.
                if let childId = event["state_key"] as? String, !childId.isEmpty {
                    if content.isEmpty { spaceChildren.remove(childId) }
                    else { spaceChildren.insert(childId) }
                }
            } else if type == "uk.half-shot.bridge" {
                // Bridge portal metadata. Take the protocol network label + icon.
                if let proto = content["protocol"] as? [String: Any] {
                    bridgeNetwork = (proto["displayname"] as? String)
                        ?? (proto["id"] as? String) ?? bridgeNetwork
                    if let av = proto["avatar_url"] as? String, av.hasPrefix("mxc://") {
                        bridgeAvatarMxc = av
                    }
                }
            } else if type == "m.room.member",
                      content["membership"] as? String == "join",
                      let sender = event["sender"] as? String {
                // Record display name / avatar for every joined member so the
                // timeline can render sender avatars without a profile fetch.
                if let displayname = content["displayname"] as? String, !displayname.isEmpty {
                    memberNames[sender] = displayname
                }
                if let avatar = content["avatar_url"] as? String, avatar.hasPrefix("mxc://") {
                    memberAvatars[sender] = avatar
                }
                // First non-self joined member drives the DM name/avatar fallback.
                if sender != selfUserId, fallbackMemberName == nil {
                    fallbackMemberName = (content["displayname"] as? String) ?? sender
                    fallbackMemberAvatar = content["avatar_url"] as? String
                }
            }
        }

        if let state = json["state"] as? [String: Any],
           let stateEvents = state["events"] as? [[String: Any]] {
            stateEvents.forEach(considerStateEvent)
        }

        if let timeline = json["timeline"] as? [String: Any] {
            if prevBatch == nil, let batch = timeline["prev_batch"] as? String {
                prevBatch = batch
            }
            if let events = timeline["events"] as? [[String: Any]] {
                events.forEach(considerStateEvent)
                for event in events where event["type"] as? String == "m.room.message" {
                    if let content = event["content"] as? [String: Any],
                       let body = content["body"] as? String {
                        lastMessage = body
                    }
                    if let ts = (event["origin_server_ts"] as? NSNumber)?.doubleValue {
                        lastTimestamp = ts
                    }
                    // Client-side unread floor: only meaningful for *live*
                    // (incremental) messages arriving while this room isn't
                    // open. On the cold-start initial sync the timeline replays
                    // recent history the user may have already read, so counting
                    // it here would inflate the badge and make it "repop" with a
                    // stale count on every app restart — skip it and trust the
                    // server's read-receipt-aware notification_count below.
                    if !isOpen, !isInitialSync,
                       let sender = event["sender"] as? String, sender != selfUserId {
                        unreadCount += 1
                    }
                }
                timelineEvents.append(contentsOf: events.compactMap { RoomEvent.parse($0) })
                if timelineEvents.count > maxBufferedEvents {
                    timelineEvents.removeFirst(timelineEvents.count - maxBufferedEvents)
                }
            }
        }

        if !explicitNameFound, let fallbackMemberName = fallbackMemberName {
            name = fallbackMemberName
        }
        // DM fallback: no explicit m.room.avatar, so use the other member's avatar.
        if !explicitAvatarFound, let fallbackMemberAvatar = fallbackMemberAvatar,
           fallbackMemberAvatar.hasPrefix("mxc://") {
            avatarMxc = fallbackMemberAvatar
        }

        if let unreadNotifications = json["unread_notifications"] as? [String: Any],
           let count = (unreadNotifications["notification_count"] as? NSNumber)?.intValue {
            unreadCount = max(unreadCount, count)
        }
        // Being open always wins over both sources above (e.g. the server
        // hasn't caught up to our read receipt yet, or a message arrived in
        // the same /sync batch that opened the room).
        if isOpen { unreadCount = 0 }

        return Room(roomId: roomId, name: name, lastMessage: lastMessage,
                    lastMessageTimestamp: lastTimestamp, prevBatch: prevBatch,
                    timelineEvents: timelineEvents,
                    avatarMxc: avatarMxc, memberNames: memberNames, memberAvatars: memberAvatars,
                    unreadCount: unreadCount,
                    roomType: roomType, spaceChildren: spaceChildren,
                    bridgeNetwork: bridgeNetwork, bridgeAvatarMxc: bridgeAvatarMxc,
                    topic: topic)
    }
}

// MARK: - Persisted room list

// The room list plus the /sync delta token it corresponds to, kept on disk so a
// cold start can resume with an *incremental* sync instead of paying for a full
// initial one. That cost is not small: the initial sync builds full state and a
// timeline for every joined room, which is why it needs its own 180s budget (see
// SyncEngine) and why a large room list made the first load take minutes.
//
// Only the room LIST is persisted, no timeline events — opening a room still
// backfills, exactly as it already does for any room that wasn't opened this
// session. But every *other* field of Room is kept, including the ones the list
// never draws: an incremental sync returns only the rooms that CHANGED, and
// name / avatar / members / space / bridge / topic all come from *state*, which
// the server sends once. Drop them and a quiet room would come back nameless,
// avatar-less and outside its filter bucket, permanently.
//
// Known gap: `prevBatch` is persisted at whatever position it had, so if a room
// received so much while the app was closed that the catch-up sync truncates its
// timeline (`limited: true`), scrollback can skip the slice between the two.
// Nothing is lost that we had before — this is the same shape of gap a limited
// timeline already produces mid-session — and no cached event is discarded.
final class RoomStore {

    static let shared = RoomStore()

    struct Snapshot {
        let since: String
        let rooms: [Room]
        let invites: [Invitation]
    }

    // Bumped whenever the encoding below changes. A file written by a different
    // version is discarded whole rather than half-read; the only cost is one
    // full sync.
    private static let version = 1

    // Documents, not Caches: iOS evicts Caches at will and MediaCache's own
    // 100MB oldest-first trim lives there. Losing the file is *safe* — it just
    // forces a full sync — but it isn't free, so it goes somewhere durable.
    private let path: String

    // Encoding and writing happen here, never on the main thread: save() is
    // called after every /sync, and a main-thread JSON encode over every joined
    // room per sync is precisely the class of cost the last three rounds of
    // audits removed.
    private let queue = DispatchQueue(label: "com.jellyold.roomstore")

    // Debounce, same shape as MediaCache.scheduleTrim. A long-poll returns
    // instantly on any event — including a typing notice — so /sync can complete
    // several times a second, and each one would otherwise be a full re-encode
    // plus a disk write. `pending`/`writeScheduled` are touched only from the
    // main thread (handleSync and the background/terminate notifications both
    // run there).
    private var pending: Snapshot?
    private var writeScheduled = false
    private let writeDelay: TimeInterval = 4

    private init() {
        let documents = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first
            ?? NSTemporaryDirectory()
        path = (documents as NSString).appendingPathComponent("elementold-roomlist.json")
    }

    // MARK: reading

    // nil whenever there's nothing usable: no file, a file from another account
    // or another encoding version, or anything unreadable. Every one of those
    // just means "do a full sync", i.e. the behaviour before any of this existed.
    func load() -> Snapshot? {
        guard let userId = MatrixSession.userId else { return nil }
        // FileManager, not Data(contentsOf:) — the URL-based reader hangs on this
        // runtime.
        guard let data = FileManager.default.contents(atPath: path),
              let json = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any],
              (json["version"] as? NSNumber)?.intValue == RoomStore.version,
              json["userId"] as? String == userId,
              let since = json["since"] as? String, !since.isEmpty else { return nil }
        let rooms = (json["rooms"] as? [[String: Any]] ?? []).compactMap { RoomStore.decodeRoom($0) }
        let invites = (json["invites"] as? [[String: Any]] ?? []).compactMap { RoomStore.decodeInvite($0) }
        guard !rooms.isEmpty else { return nil }
        return Snapshot(since: since, rooms: rooms, invites: invites)
    }

    // MARK: writing

    // Debounced — safe to call after every /sync.
    func save(since: String, rooms: [Room], invites: [Invitation]) {
        pending = Snapshot(since: since, rooms: rooms, invites: invites)
        guard !writeScheduled else { return }
        writeScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + writeDelay) { [weak self] in
            guard let self = self else { return }
            self.writeScheduled = false
            guard let snapshot = self.pending else { return }
            self.pending = nil
            self.queue.async { self.write(snapshot) }
        }
    }

    // Immediate and synchronous, for backgrounding and termination where a
    // queued write may never get to run. The file is tens of KB, so paying for
    // it on the caller's thread at that one moment is the right trade for
    // actually landing on disk.
    func flush(since: String, rooms: [Room], invites: [Invitation]) {
        pending = nil
        writeScheduled = false
        write(Snapshot(since: since, rooms: rooms, invites: invites))
    }

    // Forget the snapshot, so the next cold start does a full sync. Used by
    // Reset Cache and by logout, and as the recovery path when the homeserver
    // won't accept our stored token.
    func discard() {
        pending = nil
        writeScheduled = false
        let path = self.path
        queue.async { try? FileManager.default.removeItem(atPath: path) }
    }

    private func write(_ snapshot: Snapshot) {
        guard let userId = MatrixSession.userId else { return }
        let json: [String: Any] = [
            "version": RoomStore.version,
            "userId": userId,
            "since": snapshot.since,
            "rooms": snapshot.rooms.map { RoomStore.encodeRoom($0) },
            "invites": snapshot.invites.map { RoomStore.encodeInvite($0) },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: []) else { return }
        // Path-based NSData write: Data.write(to:) hangs on this runtime. The
        // `atomically` is what keeps the token and the rooms inseparable —
        // storing `since = T` without the state derived from the batch ending at
        // T would lose those messages for good, since the server treats
        // everything up to T as delivered and no retry replays it. A kill
        // mid-write leaves the previous snapshot intact, never a torn one.
        (data as NSData).write(toFile: path, atomically: true)
    }

    // MARK: encoding
    //
    // Hand-rolled [String: Any] both ways, like every other model here: no
    // Codable, and numbers read back through NSNumber because `as? Int` /
    // `as? Double` silently fail on this runtime. Keys are short because they
    // repeat once per room. nil/empty fields are omitted rather than encoded as
    // null, which JSONSerialization would reject anyway.

    private static func encodeRoom(_ room: Room) -> [String: Any] {
        var d: [String: Any] = [
            "id": room.roomId,
            "name": room.name,
            "last": room.lastMessage,
            "ts": room.lastMessageTimestamp,
            "unread": room.unreadCount,
        ]
        if let v = room.prevBatch { d["prev"] = v }
        if let v = room.avatarMxc { d["avatar"] = v }
        if !room.memberNames.isEmpty { d["names"] = room.memberNames }
        if !room.memberAvatars.isEmpty { d["avatars"] = room.memberAvatars }
        if let v = room.roomType { d["type"] = v }
        if !room.spaceChildren.isEmpty { d["children"] = Array(room.spaceChildren) }
        if let v = room.bridgeNetwork { d["bridge"] = v }
        if let v = room.bridgeAvatarMxc { d["bridgeAvatar"] = v }
        if let v = room.topic { d["topic"] = v }
        return d
    }

    private static func decodeRoom(_ d: [String: Any]) -> Room? {
        guard let roomId = d["id"] as? String, !roomId.isEmpty else { return nil }
        return Room(roomId: roomId,
                    name: d["name"] as? String ?? roomId,
                    lastMessage: d["last"] as? String ?? "",
                    lastMessageTimestamp: (d["ts"] as? NSNumber)?.doubleValue ?? 0,
                    prevBatch: d["prev"] as? String,
                    timelineEvents: [],
                    avatarMxc: d["avatar"] as? String,
                    memberNames: stringMap(d["names"]),
                    memberAvatars: stringMap(d["avatars"]),
                    unreadCount: (d["unread"] as? NSNumber)?.intValue ?? 0,
                    roomType: d["type"] as? String,
                    spaceChildren: Set(stringArray(d["children"])),
                    bridgeNetwork: d["bridge"] as? String,
                    bridgeAvatarMxc: d["bridgeAvatar"] as? String,
                    topic: d["topic"] as? String)
    }

    private static func encodeInvite(_ invite: Invitation) -> [String: Any] {
        var d: [String: Any] = ["id": invite.roomId, "name": invite.name]
        if let v = invite.inviter { d["by"] = v }
        return d
    }

    private static func decodeInvite(_ d: [String: Any]) -> Invitation? {
        guard let roomId = d["id"] as? String, !roomId.isEmpty else { return nil }
        return Invitation(roomId: roomId, name: d["name"] as? String ?? roomId,
                          inviter: d["by"] as? String)
    }

    // Element-wise rather than a straight `as? [String: String]` / `as? [String]`:
    // those collection casts have to bridge-check every value, and this project
    // has a history of Foundation convenience casts behaving differently here
    // than they read. Cheap insurance on a path that runs once per launch.
    private static func stringMap(_ any: Any?) -> [String: String] {
        guard let raw = any as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (key, value) in raw {
            if let s = value as? String { out[key] = s }
        }
        return out
    }

    private static func stringArray(_ any: Any?) -> [String] {
        guard let raw = any as? [Any] else { return [] }
        return raw.compactMap { $0 as? String }
    }
}
