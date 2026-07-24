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
                    bridgeNetwork: bridgeNetwork, bridgeAvatarMxc: bridgeAvatarMxc)
    }
}
