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
}

// A single timeline row: either a chat message or an inline membership event.
// Unsupported event types (reactions, redactions, etc.) are dropped for v1 —
// per plan.md Phase 5, only m.room.message + membership rows are rendered.
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
        // An m.file / m.video attachment: `mxc` is the content URI, `filename`
        // is the body (the original filename), `mimeType`/`sizeBytes` come from
        // `info` (empty/0 when the sender omitted them).
        case file(sender: String, mxc: String, filename: String, mimeType: String, sizeBytes: Int)
        case membership(description: String)
    }

    let eventId: String
    let kind: Kind
    let timestamp: Double

    static func parse(_ json: [String: Any]) -> RoomEvent? {
        guard let eventId = json["event_id"] as? String,
              let type = json["type"] as? String,
              let sender = json["sender"] as? String else { return nil }
        let timestamp = (json["origin_server_ts"] as? NSNumber)?.doubleValue ?? 0

        switch type {
        case "m.room.message":
            guard let content = json["content"] as? [String: Any] else { return nil }
            let body = content["body"] as? String ?? ""
            let msgtype = content["msgtype"] as? String ?? "m.text"
            // m.image with a plaintext `url` (mxc://) renders as an inline image.
            // Encrypted images (E2EE out of scope for v1) carry a `file` object
            // instead of `url` — those fall through to the text branch below and
            // show their filename body, which is the best we can do unencrypted.
            if msgtype == "m.image", let mxc = content["url"] as? String, mxc.hasPrefix("mxc://") {
                let info = content["info"] as? [String: Any]
                let w = (info?["w"] as? NSNumber)?.intValue ?? 0
                let h = (info?["h"] as? NSNumber)?.intValue ?? 0
                return RoomEvent(eventId: eventId,
                                  kind: .image(sender: sender, caption: body, mxc: mxc, width: w, height: h),
                                  timestamp: timestamp)
            }
            // m.audio with a plaintext `url` renders as an inline voice message
            // (play button + duration). Encrypted audio (E2EE out of scope)
            // carries a `file` object instead and falls through to the text branch.
            if msgtype == "m.audio", let mxc = content["url"] as? String, mxc.hasPrefix("mxc://") {
                let info = content["info"] as? [String: Any]
                let dur = (info?["duration"] as? NSNumber)?.intValue ?? 0
                return RoomEvent(eventId: eventId,
                                  kind: .audio(sender: sender, mxc: mxc, durationMs: dur, caption: body),
                                  timestamp: timestamp)
            }
            // m.file / m.video render as an attachment bubble (filename, type,
            // size). Encrypted attachments carry a `file` object instead of
            // `url` and fall through to the text branch, same as images/audio.
            if msgtype == "m.file" || msgtype == "m.video",
               let mxc = content["url"] as? String, mxc.hasPrefix("mxc://") {
                let info = content["info"] as? [String: Any]
                let mime = info?["mimetype"] as? String ?? ""
                let size = (info?["size"] as? NSNumber)?.intValue ?? 0
                let name = RoomEvent.isBlank(body) ? "Attachment" : body
                return RoomEvent(eventId: eventId,
                                  kind: .file(sender: sender, mxc: mxc, filename: name,
                                              mimeType: mime, sizeBytes: size),
                                  timestamp: timestamp)
            }
            let isEmote = msgtype == "m.emote"
            // Drop content-less messages (redacted events whose content is now
            // `{}`, or bot/bridge messages carrying only invisible/format
            // characters). They'd otherwise render as an empty bubble — a blank
            // vertical gap between real messages with no text. Emotes are exempt:
            // their visible text is the sender name, prepended at render time.
            if !isEmote, RoomEvent.isBlank(body) { return nil }
            return RoomEvent(eventId: eventId,
                              kind: .message(sender: sender, body: body, isEmote: isEmote),
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
