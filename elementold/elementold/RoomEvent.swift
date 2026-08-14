import Foundation

// Shared clock-time formatter for message/room-list timestamps (localized short
// time, e.g. "2:34 PM" / "14:34" — no date). Cached as a static let: creating an
// NSDateFormatter is relatively expensive, and both RoomListVC and RoomTimelineVC
// format many rows per reload. NSDateFormatter + .dateStyle/.timeStyle are core
// Foundation API present since iOS 2 — safe on this target (unlike some of the
// newer CharacterSet/String convenience APIs found elsewhere in this project).
enum TimeFormat {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    // Stable per-calendar-day key (local time zone) used only to detect when two
    // timestamps fall on different days — string comparison avoids any NSCalendar
    // component API (some of which are iOS 8+ and unsafe on this legacy runtime).
    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let yearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy"
        return f
    }()

    // Explicit dateFormat strings (not .dateStyle) so the day-separator labels
    // read as a plain full date; DateFormatter/dateFormat is Foundation core
    // since iOS 2, safe on this target.
    private static let sameYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d"
        return f
    }()

    private static let otherYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM d, yyyy"
        return f
    }()

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE"
        return f
    }()

    static func shortTime(msSinceEpoch: Double) -> String {
        guard msSinceEpoch > 0 else { return "" }
        return formatter.string(from: Date(timeIntervalSince1970: msSinceEpoch / 1000))
    }

    static func dayKey(msSinceEpoch: Double) -> String {
        guard msSinceEpoch > 0 else { return "" }
        return dayKeyFormatter.string(from: Date(timeIntervalSince1970: msSinceEpoch / 1000))
    }

    // A full-date header for a day-separator row between messages: "Today" /
    // "Yesterday" for the two most recent days, a weekday + month/day within the
    // current year, and a month/day/year for anything older.
    static func dateHeader(msSinceEpoch: Double) -> String {
        guard msSinceEpoch > 0 else { return "" }
        let date = Date(timeIntervalSince1970: msSinceEpoch / 1000)
        let now = Date()
        let key = dayKeyFormatter.string(from: date)
        if key == dayKeyFormatter.string(from: now) { return "Today" }
        if key == dayKeyFormatter.string(from: Date(timeIntervalSinceNow: -86400)) { return "Yesterday" }
        let sameYear = yearFormatter.string(from: date) == yearFormatter.string(from: now)
        return (sameYear ? sameYearFormatter : otherYearFormatter).string(from: date)
    }

    // The room list's per-row stamp: a clock time only while a conversation is
    // still today's, the day's own name for the rest of the past week, and a
    // plain numeric date beyond that — so a row's age reads at a glance instead
    // of every row showing an hour that means a different day on each line.
    //
    // Days are matched by comparing day-key strings against fixed 24h steps back
    // from now, which keeps this free of any NSCalendar component API. A daylight
    // saving change can make one of those steps land on a day already matched,
    // in which case the oldest weekday falls through to the numeric date — a day
    // early, twice a year, on a label that is only ever a rough marker.
    static func listStamp(msSinceEpoch: Double) -> String {
        guard msSinceEpoch > 0 else { return "" }
        let date = Date(timeIntervalSince1970: msSinceEpoch / 1000)
        let key = dayKeyFormatter.string(from: date)
        if key == dayKeyFormatter.string(from: Date()) {
            return shortTime(msSinceEpoch: msSinceEpoch)
        }
        for daysAgo in 1...6 {
            let past = Date(timeIntervalSinceNow: -86400 * Double(daysAgo))
            if key == dayKeyFormatter.string(from: past) {
                return weekdayFormatter.string(from: date)
            }
        }
        // dayKeyFormatter is already yyyy-MM-dd, which is the wanted short date.
        return key
    }
}

// A single timeline row: either a chat message or an inline membership event.
// Unsupported event types (reactions, redactions, etc.) are dropped for v1 —
// per plan.md Phase 5, only m.room.message + membership rows are rendered.
// Everything an m.video bubble needs. `thumbnailMxc` is info.thumbnail_url when
// the sender supplied a poster frame — nil means we draw a placeholder instead,
// since fetching a frame out of the video would mean downloading all of it.
struct VideoAttachment {
    let mxc: String
    let thumbnailMxc: String?
    let filename: String
    let mimeType: String
    let sizeBytes: Int
    let width: Int
    let height: Int
    let durationMs: Int
}

struct RoomEvent {
    enum Kind {
        case message(sender: String, body: String, isEmote: Bool)
        // An m.image message: `mxc` is the mxc:// content URI, `caption` is the
        // body (usually the original filename), width/height come from `info`
        // (0 if the server omitted them — the cell falls back to a default box).
        case image(sender: String, caption: String, mxc: String, width: Int, height: Int)
        // An m.audio message (voice message): `mxc` is the content URI,
        // `durationMs` is info.duration in milliseconds (0 if the sender omitted
        // it), `caption` is the body text ("Voice message · m:ss").
        case audio(sender: String, mxc: String, durationMs: Int, caption: String)
        // An m.file attachment: `mxc` is the content URI, `filename` is the body
        // (the original filename), `mimeType`/`sizeBytes` come from `info`
        // (empty/0 when the sender omitted them).
        case file(sender: String, mxc: String, filename: String, mimeType: String, sizeBytes: Int)
        // An m.video attachment. Carried as a struct rather than eight more
        // associated values, so the switch sites that only want the sender stay
        // readable. Renders as a poster-frame bubble with a play badge.
        case video(sender: String, video: VideoAttachment)
        case membership(description: String)
        // An m.reaction annotation. Never a row of its own — the timeline folds
        // these into a chip strip under the message they target.
        case reaction(sender: String, targetEventId: String, key: String)
        // An m.room.redaction. Also not a row: it's only consulted to drop a
        // reaction that was taken back. Redacted *messages* arrive with empty
        // content and are already dropped by the blank-body check below.
        case redaction(targetEventId: String)
        // An edit (m.replace): a whole new message event whose content replaces
        // an earlier one's. Not a row either — the timeline swaps the new text
        // into the original bubble. Rendering it as its own event is exactly the
        // bug this closes: an edited message used to appear twice.
        case edit(sender: String, targetEventId: String, body: String)
    }

    let eventId: String
    let kind: Kind
    let timestamp: Double

    // Set when this message is a reply (m.in_reply_to). `replyTo` is the event
    // it answers; the other two come from the reply *fallback* — the quoted
    // "> <@alice:server> text" block senders prepend to the body for clients
    // that don't understand replies — and are the only context we have when the
    // quoted message is older than the history we've loaded.
    var replyTo: String? = nil
    var replyQuote: String? = nil
    var replyAuthor: String? = nil

    // Reaction totals the server bundled onto this event (unsigned.m.relations),
    // which is how reactions to messages older than our loaded history become
    // visible at all: we'd otherwise only know about reactions whose m.reaction
    // events happen to sit in the timeline we fetched. Counts only — the chunk
    // carries no event ids, so we can't tell whether one of them is ours.
    var bundledReactions: [(key: String, count: Int)] = []

    // The transaction id we generated when sending this event, echoed back by the
    // homeserver in unsigned.transaction_id — present only on our own events, and
    // only for the device that sent them. It's how a queued message recognises its
    // own arrival and retires its placeholder row.
    var transactionId: String? = nil

    static func parse(_ json: [String: Any]) -> RoomEvent? {
        guard var event = parseEvent(json) else { return nil }
        event.bundledReactions = parseBundledReactions(json)
        event.transactionId = (json["unsigned"] as? [String: Any])?["transaction_id"] as? String
        return event
    }

    private static func parseEvent(_ json: [String: Any]) -> RoomEvent? {
        guard let eventId = json["event_id"] as? String,
              let type = json["type"] as? String,
              let sender = json["sender"] as? String else { return nil }
        let timestamp = (json["origin_server_ts"] as? NSNumber)?.doubleValue ?? 0

        switch type {
        case "m.room.message":
            guard let content = json["content"] as? [String: Any] else { return nil }
            let relates = content["m.relates_to"] as? [String: Any]

            // An edit is a whole new event that REPLACES an earlier one. It must
            // not become a row of its own (that's the double-message bug) — the
            // timeline folds it into the original bubble.
            if let relates = relates,
               relates["rel_type"] as? String == "m.replace",
               let target = relates["event_id"] as? String {
                // m.new_content holds the real replacement. The top-level body is
                // only the "* new text" fallback for clients that don't
                // understand edits, so strip that marker when we have to use it.
                var newBody = (content["m.new_content"] as? [String: Any])?["body"] as? String ?? ""
                if newBody.isEmpty {
                    newBody = content["body"] as? String ?? ""
                    if newBody.hasPrefix("* ") { newBody.removeFirst(2) }
                }
                if RoomEvent.isBlank(newBody) { return nil }
                return RoomEvent(eventId: eventId,
                                  kind: .edit(sender: sender, targetEventId: target, body: newBody),
                                  timestamp: timestamp)
            }

            var body = content["body"] as? String ?? ""
            var replyTo: String?
            var replyQuote: String?
            var replyAuthor: String?
            // A reply carries the quoted message inline at the top of its body
            // ("> <@alice:server> hi") for clients that don't understand replies.
            // We render the quote ourselves, so strip the fallback out of the
            // body — leaving it in is what makes replies look like markup today.
            if let inReplyTo = relates?["m.in_reply_to"] as? [String: Any],
               let target = inReplyTo["event_id"] as? String {
                replyTo = target
                let split = RoomEvent.splitReplyFallback(body)
                replyAuthor = split.author
                replyQuote = split.quote
                body = split.rest
            }

            guard let kind = RoomEvent.messageKind(content: content, sender: sender, body: body) else {
                return nil
            }
            return RoomEvent(eventId: eventId, kind: kind, timestamp: timestamp,
                              replyTo: replyTo, replyQuote: replyQuote, replyAuthor: replyAuthor)

        case "m.room.encrypted":
            // E2EE is out of scope for v1, but silently dropping these events
            // leaves an encrypted room looking like an empty timeline. Render a
            // plain text bubble instead so it's obvious why nothing is readable.
            // Reusing .message keeps every exhaustive switch untouched. The lock
            // is Unicode 6.0, so it exists in iOS 6's Apple Color Emoji.
            return RoomEvent(eventId: eventId,
                              kind: .message(sender: sender,
                                             body: "\u{1F512} Encrypted message (not supported)",
                                             isEmote: false),
                              timestamp: timestamp)

        case "m.reaction":
            guard let content = json["content"] as? [String: Any],
                  let relates = content["m.relates_to"] as? [String: Any],
                  relates["rel_type"] as? String == "m.annotation",
                  let target = relates["event_id"] as? String,
                  let key = relates["key"] as? String, !key.isEmpty else { return nil }
            return RoomEvent(eventId: eventId,
                              kind: .reaction(sender: sender, targetEventId: target, key: key),
                              timestamp: timestamp)

        case "m.room.redaction":
            // `redacts` sits at the top level up to room version 10 and moved
            // into content in v11 — accept either.
            let target = (json["redacts"] as? String)
                ?? ((json["content"] as? [String: Any])?["redacts"] as? String)
            guard let redacted = target else { return nil }
            return RoomEvent(eventId: eventId, kind: .redaction(targetEventId: redacted),
                              timestamp: timestamp)

        case "m.room.member":
            guard let content = json["content"] as? [String: Any],
                  let membership = content["membership"] as? String else { return nil }
            let name = (content["displayname"] as? String) ?? sender
            let description: String
            switch membership {
            case "join": description = "\(name) joined the room"
            case "leave": description = "\(name) left the room"
            case "invite": description = "\(name) was invited"
            case "ban": description = "\(name) was banned"
            default: description = "\(name): \(membership)"
            }
            return RoomEvent(eventId: eventId, kind: .membership(description: description), timestamp: timestamp)

        default:
            return nil
        }
    }

    // The row an m.room.message renders as, once edits and the reply fallback
    // have been peeled off. Split out so replies keep working for every message
    // type instead of only plain text.
    private static func messageKind(content: [String: Any], sender: String, body: String) -> Kind? {
        let msgtype = content["msgtype"] as? String ?? "m.text"
        // m.image with a plaintext `url` (mxc://) renders as an inline image.
        // Encrypted images (E2EE out of scope for v1) carry a `file` object
        // instead of `url` — those fall through to the text branch below and
        // show their filename body, which is the best we can do unencrypted.
        if msgtype == "m.image", let mxc = content["url"] as? String, mxc.hasPrefix("mxc://") {
            let info = content["info"] as? [String: Any]
            let w = (info?["w"] as? NSNumber)?.intValue ?? 0
            let h = (info?["h"] as? NSNumber)?.intValue ?? 0
            return .image(sender: sender, caption: body, mxc: mxc, width: w, height: h)
        }
        // m.audio with a plaintext `url` renders as an inline voice message
        // (play button + duration). Encrypted audio (E2EE out of scope)
        // carries a `file` object instead and falls through to the text branch.
        if msgtype == "m.audio", let mxc = content["url"] as? String, mxc.hasPrefix("mxc://") {
            let info = content["info"] as? [String: Any]
            let dur = (info?["duration"] as? NSNumber)?.intValue ?? 0
            return .audio(sender: sender, mxc: mxc, durationMs: dur, caption: body)
        }
        // m.file renders as an attachment bubble (filename, type, size), m.video
        // as a poster-frame bubble. Encrypted attachments carry a `file` object
        // instead of `url` and fall through to the text branch, as with images.
        if msgtype == "m.file" || msgtype == "m.video",
           let mxc = content["url"] as? String, mxc.hasPrefix("mxc://") {
            let info = content["info"] as? [String: Any]
            let mime = info?["mimetype"] as? String ?? ""
            let size = (info?["size"] as? NSNumber)?.intValue ?? 0
            let name = RoomEvent.isBlank(body) ? "Attachment" : body
            if msgtype == "m.video" {
                // Only accept a plaintext mxc thumbnail: an encrypted one arrives
                // as thumbnail_file, which we can't fetch.
                var thumb = info?["thumbnail_url"] as? String
                if thumb?.hasPrefix("mxc://") != true { thumb = nil }
                let video = VideoAttachment(mxc: mxc, thumbnailMxc: thumb, filename: name,
                                            mimeType: mime, sizeBytes: size,
                                            width: (info?["w"] as? NSNumber)?.intValue ?? 0,
                                            height: (info?["h"] as? NSNumber)?.intValue ?? 0,
                                            durationMs: (info?["duration"] as? NSNumber)?.intValue ?? 0)
                return .video(sender: sender, video: video)
            }
            return .file(sender: sender, mxc: mxc, filename: name, mimeType: mime, sizeBytes: size)
        }
        let isEmote = msgtype == "m.emote"
        // Drop content-less messages (redacted events whose content is now
        // `{}`, or bot/bridge messages carrying only invisible/format
        // characters). They'd otherwise render as an empty bubble — a blank
        // vertical gap between real messages with no text. Emotes are exempt:
        // their visible text is the sender name, prepended at render time.
        if !isEmote, RoomEvent.isBlank(body) { return nil }
        return .message(sender: sender, body: body, isEmote: isEmote)
    }

    // Peel the reply fallback off a body: leading "> " lines (the first of which
    // usually starts with "<@alice:server>"), then one blank separator line,
    // then the actual reply. Pure stdlib string work — Foundation's convenience
    // string APIs are a crash risk on this runtime.
    static func splitReplyFallback(_ body: String) -> (author: String?, quote: String?, rest: String) {
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var index = 0
        var quoted: [String] = []
        while index < lines.count, lines[index].hasPrefix(">") {
            var line = String(lines[index].dropFirst())
            if line.hasPrefix(" ") { line.removeFirst() }
            quoted.append(line)
            index += 1
        }
        // No fallback present (some clients omit it) — the body is already clean.
        guard !quoted.isEmpty else { return (nil, nil, body) }
        if index < lines.count, lines[index].isEmpty { index += 1 }
        let rest = lines[index...].joined(separator: "\n")

        var author: String?
        var first = quoted[0]
        if first.hasPrefix("<"), let close = first.firstIndex(of: ">") {
            author = String(first[first.index(after: first.startIndex)..<close])
            first = String(first[first.index(after: close)...])
            if first.hasPrefix(" ") { first.removeFirst() }
            quoted[0] = first
        }
        // The quote is only ever shown on one line, so flatten it.
        let quote = quoted.joined(separator: " ")
        return (author, RoomEvent.isBlank(quote) ? nil : quote, rest)
    }

    // Reaction totals the server aggregated onto the event itself. Present on
    // /sync and /messages events alike, and the only way to see reactions to a
    // message whose m.reaction events fall outside the timeline we fetched.
    private static func parseBundledReactions(_ json: [String: Any]) -> [(key: String, count: Int)] {
        guard let unsigned = json["unsigned"] as? [String: Any],
              let relations = unsigned["m.relations"] as? [String: Any],
              let annotation = relations["m.annotation"] as? [String: Any],
              let chunk = annotation["chunk"] as? [[String: Any]] else { return [] }
        var result: [(key: String, count: Int)] = []
        for entry in chunk {
            guard (entry["type"] as? String) == "m.reaction",
                  let key = entry["key"] as? String, !key.isEmpty,
                  let count = (entry["count"] as? NSNumber)?.intValue, count > 0 else { continue }
            result.append((key: key, count: count))
        }
        return result
    }

    // True when `s` contains no visible characters: ASCII/Unicode whitespace
    // plus common zero-width / formatting code points (ZWSP, ZWNJ, ZWJ, word
    // joiner, BOM) that a plain whitespace trim misses. Pure Swift stdlib (no
    // Foundation CharacterSet) — safe on this project's iOS 6 (5.1.5) runtime,
    // where some Foundation convenience selectors are unexpectedly iOS-7+-only.
    static func isBlank(_ s: String) -> Bool {
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20,      // tab, LF, VT, FF, CR, space
                 0x85, 0xA0,                              // NEL, NBSP
                 0x2000...0x200A, 0x2028, 0x2029,         // Unicode spaces + line/para sep
                 0x202F, 0x205F, 0x3000,                  // narrow/medium/ideographic space
                 0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF:  // ZWSP, ZWNJ, ZWJ, WJ, BOM
                continue
            default:
                return false
            }
        }
        return true
    }
}
