import UIKit
import AVFoundation
import CoreMedia
import AudioToolbox
import MediaPlayer

// One reaction chip: an emoji, how many people sent it, and — when we're one of
// them — the event id of our own m.reaction, which a redaction needs to take it
// back. File scope rather than nested so ReactionsCell can see it too.
private struct ReactionItem {
    let key: String
    let count: Int
    let mineEventId: String?
}

// Room timeline: renders m.room.message + membership events, backfills older
// history on scroll-up, sends new messages via PUT .../send/m.room.message/{txnId}.
// No optimistic local echo: a sent message appears once the next /sync response
// includes it (foreground sync is fast enough for v1, and this avoids having to
// de-dupe our own echoed event against the locally-inserted placeholder).
class RoomTimelineVC: UIViewController {

    // `var` (not `let`): Room Settings edits the name/topic/avatar and hands the
    // updated Room back so the nav title refreshes without waiting for /sync.
    private var room: Room
    private let client: MatrixAPIClient
    private let syncEngine: SyncEngine

    private var tableView: UITableView!
    private var inputBar: UIView!
    private var messageField: UITextView!
    private var placeholderLabel: UILabel!
    private var sendButton: UIButton!
    private var attachButton: UIButton!
    private var statusLabel: UILabel!

    // Auto-growing input geometry. The field grows from one line up to
    // `inputMaxHeight` (then scrolls internally); the bar height tracks it, with
    // `inputVPad` above/below. Buttons stay pinned to the bar's bottom edge as it
    // grows, iMessage-style. `keyboardHeight` is tracked so the bar's bottom edge
    // sits just above the keyboard (or the screen bottom when dismissed).
    private let inputVPad: CGFloat = 9
    private let inputMinHeight: CGFloat = 36
    private let inputMaxHeight: CGFloat = 120
    private let attachWidth: CGFloat = 34
    private let sendWidth: CGFloat = 56
    private let hMargin: CGFloat = 12
    private let hSpacing: CGFloat = 8
    private var currentFieldHeight: CGFloat = 36
    private var keyboardHeight: CGFloat = 0
    // One-shot latch: the first scroll-to-bottom must wait for the table's FINAL
    // height. seedInitialEvents() (in viewDidLoad) scrolls with the pre-layout
    // bounds, before layoutInputBar() shrinks the table to leave room for the
    // input bar — so that early scroll lands short by the bar's height, leaving a
    // visible empty gap. Redo it once in viewDidLayoutSubviews once geometry has
    // settled.
    private var didInitialScroll = false

    // Floating "X is typing…" strip docked just above the input bar. Shown only
    // while at least one OTHER member is typing (m.typing ephemeral event); the
    // table shrinks by its height so it never covers the last message.
    private var typingLabel: UILabel!
    private let typingBarHeight: CGFloat = 22

    // "Replying to Alice: …" strip, docked between the typing strip and the input
    // bar while a reply is queued. Like the typing strip, the table shrinks by
    // its height so it never covers the newest message.
    private var replyBar: UIView!
    private var replyLabel: UILabel!
    private var replyCancelButton: UIButton!
    private let replyBarHeight: CGFloat = 30
    private var typingUsers: [String] = []
    // Throttle for our own outbound typing notices (PUT .../typing/{userId}) so
    // each keystroke doesn't fire a request — resent at most every few seconds
    // while typing, and cancelled on send / leaving the screen.
    private var lastTypingSent: TimeInterval = 0

    // Per-user display name / avatar mxc, seeded from the Room struct and kept
    // current from every /sync member event, so sender avatars/names in the
    // timeline don't need a separate profile fetch.
    private var memberNames: [String: String] = [:]
    private var memberAvatars: [String: String] = [:]

    // Event IDs that at least one OTHER user has sent an m.read receipt for.
    // Used to place a "Seen" marker under the most recent of our own messages
    // that a peer has read.
    private var othersReadEventIds = Set<String>()

    private var events: [RoomEvent] = []
    private var seenEventIds = Set<String>()
    private var isLoadingBackfill = false
    private var hasLoadedInitial = false
    private var isSending = false
    // Backfill pagination: `backfillFrom` starts at the room's prev_batch and
    // then advances to each /messages response's `end` token, so repeated
    // scroll-ups fetch successively older pages instead of re-fetching the same
    // first page forever. `reachedHistoryStart` latches once the server returns
    // no further token / an empty chunk, so we stop asking.
    private var backfillFrom: String?
    private var reachedHistoryStart = false
    // Top-of-table "loading older messages" spinner (shown during backfill).
    private var backfillHeader: UIView?
    private var backfillSpinner: UIActivityIndicatorView?

    // Text queued for copying by the long-press → UIMenuController "Copy" action.
    private var pendingCopyText: String?
    // Event the long-press → "React" action will annotate (nil for rows that
    // can't carry a reaction: date separators, receipts, membership notices).
    private var pendingReactionEventId: String?
    // Event the long-press → "Delete" action will redact. Only ever our own
    // messages: redacting someone else's needs a moderator power level, which
    // we neither check nor expose.
    private var pendingDeleteEventId: String?
    // Event the long-press → "Reply" action will answer. Any message, from
    // anyone — unlike Delete, which is our own messages only.
    private var pendingReplyTargetId: String?

    // The reply the composer currently has queued (set by a rightward swipe or
    // the long-press "Reply" item, cleared on send / cancel). The sender and
    // one-line preview are kept alongside it because the outbound reply fallback
    // quotes them, and the strip above the input bar displays them.
    private var replyingToEventId: String?
    private var replyingToSender: String?
    private var replyingToPreview: String?

    // Voice-message recording. The input bar swaps between a text mode and a
    // voice mode (Cancel / Record-Stop / Send). AVAudioRecorder + AVAudioSession
    // are iOS 3+; recording an AAC .m4a needs no Info.plist mic key on this
    // project's iOS 6-9 targets (that's an iOS 10+ requirement).
    private enum InputMode { case text, voice }
    private var inputMode: InputMode = .text
    private var voiceCancelButton: UIButton!
    private var voiceRecordButton: UIButton!
    private var audioRecorder: AVAudioRecorder?
    private var voiceRecordingURL: URL?
    private var voiceRecordTimer: Timer?
    private var voiceRecordSeconds: Int = 0
    private var voiceHasRecording = false
    private var voiceIsRecording = false
    // Playback of received/sent voice messages. One shared AVAudioPlayer plays at
    // a time; `playingAudioMxc` identifies which bubble is active so the (recycled)
    // visible cell can render its play/pause + progress. A 0.2s timer advances the
    // on-screen progress while playing.
    private var audioPlayer: AVAudioPlayer?
    private var playingAudioMxc: String?
    private var audioProgressTimer: Timer?
    private let audioCellId = "AudioEventCell"
    private let fileCellId = "FileEventCell"
    private let videoCellId = "VideoEventCell"
    // In-flight attachment downloads (mxc -> 0...1), so a recycled or scrolled-in
    // cell can show the current progress.
    private var fileProgress: [String: Float] = [:]
    // Retained for the duration of a preview / open-in menu: UIDocumentInteractionController
    // is not held by the system while it presents, so a local `let` would be
    // deallocated before the preview appears. Same for the movie player.
    private var docController: UIDocumentInteractionController?
    private var moviePlayerVC: MPMoviePlayerViewController?
    // mxc URIs we've already kicked a thumbnail prefetch for, so we prime each
    // image exactly once (on first appearance in `events`) rather than re-hitting
    // the cache — and re-logging a diagnostic line — on every table reload.
    private var prefetchedMxcs = Set<String>()
    // Token for our /sync listener so deinit can unregister it — otherwise every
    // conversation opened this session would leave a dead listener that /sync
    // still calls on each response.
    private var syncListenerToken: Int?

    // Per-message timestamps are hidden by default (Messenger-style); a
    // horizontal swipe slides every bubble left to reveal a time label docked at
    // the right edge. This holds the current reveal amount so cells scrolled into
    // view mid-swipe match, and it animates back to 0 when the swipe ends.
    private var revealOffset: CGFloat = 0

    // A rightward drag on that same pan gesture pulls the bubbles the other way
    // and, once it passes `replyTriggerDistance`, queues a reply to the row the
    // drag started on. The target event is captured at .began (the touch point
    // travels during the drag, and a /sync reload could reshuffle the rows
    // underneath it), and `replySwipeArmed` latches so releasing anywhere fires.
    private static let maxReplyPull: CGFloat = 56
    private static let replyTriggerDistance: CGFloat = 44
    private var replySwipeEventId: String?
    private var replySwipeArmed = false

    // A message row that knows whether it's the first of a same-sender group
    // (and therefore shows a meta header). Precomputed in rebuildRows().
    private struct EventRow {
        let event: RoomEvent
        let showMeta: Bool
        // Set when an m.replace edit targets this event: the replacement text,
        // resolved once in rebuildRows so the height calculation and the cell
        // can never disagree about what's being displayed.
        let editedBody: String?
    }

    // The flat list actually rendered: message/membership events interleaved
    // with full-date separator rows inserted at each calendar-day boundary.
    private enum Row {
        case date(String)
        case event(EventRow)
        // A right-aligned "Seen" marker placed under the latest own message a
        // peer has read.
        case receipt(String)
        // A strip of reaction chips under the message they annotate.
        case reactions(ReactionRow)
    }
    private struct ReactionRow {
        let targetEventId: String
        let items: [ReactionItem]
        let isOwn: Bool
    }
    private var rows: [Row] = []

    // target event id -> reaction key -> OUR reaction's event id, rebuilt with
    // the rows. Lets a tap tell "add" from "take back" (which needs the event
    // id to redact) without re-scanning `events`.
    private var myReactions: [String: [String: String]] = [:]

    // Every loaded event by id, rebuilt with the rows. Lets a reply resolve the
    // message it answers without a linear scan of `events` per row.
    private var eventsById: [String: RoomEvent] = [:]

    private let cellId = "EventCell"
    private let imageCellId = "ImageEventCell"
    private let membershipCellId = "MembershipCell"
    private let dateCellId = "DateCell"
    private let reactionsCellId = "ReactionsCell"

    // Tags the emoji picker and the delete confirmation on the iOS 6 path, where
    // one UIActionSheetDelegate serves them and the "+" attach sheet.
    private let reactionSheetTag = 93
    private let deleteSheetTag = 94

    // Offered by the long-press "React" menu item. All Unicode 6.0, so they
    // exist in the Apple Color Emoji font shipped with iOS 6.
    fileprivate static let quickReactions = ["\u{1F44D}", "\u{2764}\u{FE0F}", "\u{1F602}",
                                             "\u{1F62E}", "\u{1F622}", "\u{1F389}"]

    init(room: Room, client: MatrixAPIClient, syncEngine: SyncEngine) {
        self.room = room
        self.client = client
        self.syncEngine = syncEngine
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = room.name
        // A pure-white canvas (.white) left the "other" bubble color below
        // (0.92 white) almost indistinguishable from the background — no
        // visible bubble edge, just a flat white screen. A slightly off-white
        // canvas gives every bubble real contrast to sit on top of.
        view.backgroundColor = UIColor(white: 0.95, alpha: 1.0)

        // Seed the member directory from what the room already knew, so sender
        // avatars/names render on first paint (updated live from /sync after).
        memberNames = room.memberNames
        memberAvatars = room.memberAvatars

        setupTitleView()
        buildInputBar()
        buildReplyBar()
        buildTypingLabel()
        buildTableView()
        buildStatusLabel()
        registerKeyboardObservers()

        seedInitialEvents()

        syncListenerToken = syncEngine.addUpdateListener { [weak self] json, _ in
            self?.handleSync(json)
        }

        // Only kick off the initial history fetch here if we truly have
        // nothing to show yet (brand new room, or opened before any /sync
        // response arrived). Otherwise let the normal `willDisplay` hook for
        // row 0 load older history lazily on scroll-up, like a normal
        // messaging app — firing it unconditionally here used to compete
        // with seedInitialEvents()'s scroll-to-bottom and could visibly
        // yank the viewport back up while the initial backfill landed.
        if events.isEmpty {
            loadBackfill()
        } else {
            markInitialLoadDone()
            // Also pull ONE page of immediately-older history on open. A dormant
            // room's recent images often sit just beyond the /sync-buffered
            // window that seeded this view (that buffer only captures events
            // that arrived in a /sync while the session was running), so without
            // this they'd never load until the user manually scrolled to the top.
            // The non-empty backfill branch compensates contentOffset by the
            // prepended height, so the viewport stays pinned at the bottom where
            // seedInitialEvents() just left it — no visible jump.
            loadBackfill()
        }
    }

    // The input bar is manually positioned (no autoresizingMask), so re-run its
    // layout whenever the view's bounds settle — the bounds in viewDidLoad can
    // still be the pre-nav-bar/full-window size, and a one-time layout there
    // would leave the bar pinned off-screen (just the white canvas showing).
    // layoutInputBar() reuses the current field height + keyboard height, so this
    // only corrects position/width, never the grow state.
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutInputBar()
        // The initial scroll in seedInitialEvents() ran before layoutInputBar()
        // gave the table its final (bar-adjusted) height, so it stopped short by
        // the input bar's height. Redo it once now that geometry has settled so
        // the newest message sits flush above the input bar.
        if !didInitialScroll, !rows.isEmpty {
            didInitialScroll = true
            scrollToBottom(animated: false)
        }
    }

    // Seeds from whatever this room's Room struct already buffered from /sync
    // responses received before this screen existed (see Room.timelineEvents).
    // Without this, only backfill (older than prevBatch) and future live syncs
    // populated `events`, leaving a gap for exactly the messages that arrived
    // in the sync(s) before the room was opened — which is what produced the
    // "last message" preview in the room list, hence it looking "missing" here.

    private func seedInitialEvents() {
        guard !room.timelineEvents.isEmpty else { return }
        for event in room.timelineEvents where !seenEventIds.contains(event.eventId) {
            seenEventIds.insert(event.eventId)
            events.append(event)
        }
        reloadTable()
        updateStatusLabel()
        scrollToBottom(animated: false)
        if let latest = events.last {
            sendReadReceipt(for: latest.eventId)
        }
    }

    // Tells the homeserver we've read up to this event, so its own
    // `unread_notifications.notification_count` (which RoomListVC's badge is
    // driven by) drops on the next /sync — for everyone's clients, not just
    // this app. Fire-and-forget: a dropped receipt just means the badge stays
    // stale until the next message is read, not a crash or blocked UI.
    private func sendReadReceipt(for eventId: String) {
        let path = "/_matrix/client/v3/rooms/\(room.roomId)/receipt/m.read/\(eventId)"
        client.post(path, body: [:]) { _, _ in }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Clear our typing state on the way out so peers don't see us stuck
        // "typing…" after we've left (the server would otherwise wait out the
        // 8s timeout).
        sendTypingStop()
        // Stop any voice-message playback so audio doesn't keep going after the
        // screen is dismissed.
        stopAudioPlayback()
        refreshAudioCells()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let token = syncListenerToken { syncEngine.removeUpdateListener(token) }
        cleanUpRecording(deleteFile: true)
        stopAudioPlayback()
    }

    private func buildTableView() {
        let frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: view.bounds.height - inputBar.frame.height)
        tableView = UITableView(frame: frame, style: .plain)
        tableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tableView.dataSource = self
        tableView.delegate = self
        tableView.separatorStyle = .none
        // UITableView's own default backgroundColor is opaque white regardless
        // of the view behind it — without clearing this, view.backgroundColor's
        // off-white canvas above never actually shows through the table.
        tableView.backgroundColor = .clear

        // Swipe-to-reveal timestamps. Recognized simultaneously with the table's
        // own scroll pan (see the delegate below); the handler only acts on
        // clearly-horizontal drags, so vertical scrolling is unaffected.
        let reveal = UIPanGestureRecognizer(target: self, action: #selector(handleReveal(_:)))
        reveal.delegate = self
        tableView.addGestureRecognizer(reveal)

        // Long-press a message to bring up a "Copy" menu (UIMenuController).
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        tableView.addGestureRecognizer(longPress)

        // "Loading older messages" spinner, docked at the very top of the table
        // (i.e. above the oldest row, where backfill prepends). It's shown only
        // while a backfill request is in flight and removed for good once we hit
        // the start of history — so no empty gap lingers at the top.
        let header = UIView(frame: CGRect(x: 0, y: 0, width: view.bounds.width, height: 44))
        header.autoresizingMask = [.flexibleWidth]
        let spinner = UIActivityIndicatorView(style: .gray)
        spinner.hidesWhenStopped = true
        spinner.center = CGPoint(x: header.bounds.midX, y: header.bounds.midY)
        spinner.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin]
        header.addSubview(spinner)
        backfillSpinner = spinner
        backfillHeader = header

        view.insertSubview(tableView, belowSubview: inputBar)
    }

    // Shows/hides the top backfill spinner. When history-start is reached the
    // header is detached entirely so it doesn't leave a blank strip.
    private func setBackfillSpinner(active: Bool) {
        guard let header = backfillHeader, let spinner = backfillSpinner else { return }
        if reachedHistoryStart {
            spinner.stopAnimating()
            if tableView.tableHeaderView != nil { tableView.tableHeaderView = nil }
            return
        }
        if active {
            spinner.startAnimating()
            if tableView.tableHeaderView == nil { tableView.tableHeaderView = header }
        } else {
            spinner.stopAnimating()
        }
    }

    // MARK: - Long-press menu (Reply / Copy / React / Delete)

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        let point = gesture.location(in: tableView)
        guard let indexPath = tableView.indexPathForRow(at: point) else { return }
        guard indexPath.row < rows.count else { return }
        let row = rows[indexPath.row]
        pendingCopyText = copyText(for: row)
        pendingReactionEventId = reactableEventId(for: row)
        pendingDeleteEventId = deletableEventId(for: row)
        pendingReplyTargetId = replyableEventId(for: row)
        // Nothing to offer for a date/receipt separator.
        guard pendingCopyText != nil || pendingReactionEventId != nil else { return }

        // A UIMenuController needs a first responder to route its actions to.
        becomeFirstResponder()
        let menu = UIMenuController.shared
        // menuItems is global state, so set it every time rather than once —
        // otherwise "React"/"Delete" linger on a row that can't take them.
        var items: [UIMenuItem] = []
        if pendingReplyTargetId != nil {
            items.append(UIMenuItem(title: "Reply", action: #selector(replyMenuTapped(_:))))
        }
        if pendingReactionEventId != nil {
            items.append(UIMenuItem(title: "React", action: #selector(reactMenuTapped(_:))))
        }
        if pendingDeleteEventId != nil {
            items.append(UIMenuItem(title: "Delete", action: #selector(deleteMenuTapped(_:))))
        }
        menu.menuItems = items.isEmpty ? nil : items
        let cellRect = tableView.rectForRow(at: indexPath)
        menu.setTargetRect(tableView.convert(cellRect, to: view), in: view)
        menu.setMenuVisible(true, animated: true)
    }

    // Reactions attach to real messages only — not to membership lines or the
    // date/receipt separators.
    private func reactableEventId(for row: Row) -> String? {
        guard case .event(let eventRow) = row else { return nil }
        switch eventRow.event.kind {
        case .message, .image, .audio, .file, .video: return eventRow.event.eventId
        case .membership, .reaction, .redaction, .edit: return nil
        }
    }

    // Our own message in this row, if any — the only thing we offer to delete.
    // Redacting anyone else's message requires a moderator power level; rather
    // than fetch and interpret m.room.power_levels, we simply don't offer it.
    private func deletableEventId(for row: Row) -> String? {
        guard case .event(let eventRow) = row,
              RoomTimelineVC.senderOf(eventRow.event) == MatrixSession.userId else { return nil }
        return eventRow.event.eventId
    }

    // Replies attach to real messages, from anyone — not to membership notices
    // or the date/receipt/reaction separator rows.
    private func replyableEventId(for row: Row) -> String? {
        guard case .event(let eventRow) = row else { return nil }
        switch eventRow.event.kind {
        case .message, .image, .audio, .file, .video: return eventRow.event.eventId
        case .membership, .reaction, .redaction, .edit: return nil
        }
    }

    // Copyable text for a row (message body, image caption, or membership line);
    // nil for date/receipt separators (nothing to copy).
    private func copyText(for row: Row) -> String? {
        guard case .event(let eventRow) = row else { return nil }
        switch eventRow.event.kind {
        // Copy what's actually on screen, which for an edited message is the
        // replacement text rather than the original.
        case .message(_, let body, _): return eventRow.editedBody ?? body
        case .image(_, let caption, _, _, _): return caption.isEmpty ? nil : caption
        case .audio(_, _, _, let caption): return caption.isEmpty ? nil : caption
        case .file(_, _, let filename, _, _): return filename
        case .video(_, let video): return video.filename
        case .membership(let description): return description
        case .reaction, .redaction, .edit: return nil
        }
    }

    override var canBecomeFirstResponder: Bool { return true }

    override func copy(_ sender: Any?) {
        if let text = pendingCopyText { UIPasteboard.general.string = text }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        // Only Reply / Copy / React / Delete — no cut/paste/etc. in this menu,
        // and each only when the long-pressed row actually supports it.
        if action == #selector(replyMenuTapped(_:)) { return pendingReplyTargetId != nil }
        if action == #selector(UIResponder.copy(_:)) { return pendingCopyText != nil }
        if action == #selector(reactMenuTapped(_:)) { return pendingReactionEventId != nil }
        if action == #selector(deleteMenuTapped(_:)) { return pendingDeleteEventId != nil }
        return false
    }

    // MARK: - Reply composer

    @objc private func replyMenuTapped(_ sender: Any?) {
        guard let eventId = pendingReplyTargetId else { return }
        UIMenuController.shared.setMenuVisible(false, animated: true)
        beginReply(to: eventId)
    }

    // Queues a reply to `eventId`: shows the "Replying to …" strip above the
    // input bar and remembers the target's sender + one-line preview, which the
    // outbound reply fallback quotes (see sendTapped).
    private func beginReply(to eventId: String) {
        // Voice mode has its own controls and send path, and replying is a text
        // action — drop out of it first.
        if inputMode == .voice { exitVoiceMode() }
        replyingToEventId = eventId
        // Normally loaded (the row is on screen), but a reply carrying only the
        // relation and no quote is still perfectly valid, so don't refuse.
        let source = eventsById[eventId]
        replyingToSender = source.flatMap { RoomTimelineVC.senderOf($0) }
        replyingToPreview = source.flatMap { RoomTimelineVC.previewText(for: $0) }
        if let sender = replyingToSender {
            let name = memberNames[sender] ?? shortName(sender)
            let quote = RoomTimelineVC.oneLine(replyingToPreview ?? "", limit: 80)
            replyLabel.text = "Replying to \(name): \(quote)"
        } else {
            replyLabel.text = "Replying to a message"
        }
        replyBar.isHidden = false
        layoutInputBar()
        messageField.becomeFirstResponder()
    }

    private func endReply() {
        guard replyingToEventId != nil else { return }
        replyingToEventId = nil
        replyingToSender = nil
        replyingToPreview = nil
        replyBar.isHidden = true
        layoutInputBar()
    }

    @objc private func replyCancelTapped() { endReply() }

    // Collapses runs of whitespace/newlines into single spaces and truncates,
    // for the one-line reply strip. Pure Swift
    // stdlib on purpose (no Foundation trimming/replacing convenience APIs,
    // which can bridge to iOS 7+ NSString selectors on this runtime).
    private static func oneLine(_ text: String, limit: Int) -> String {
        var out = ""
        var lastWasSpace = true   // also drops any leading whitespace
        for scalar in text.unicodeScalars {
            if out.count >= limit { return out + "\u{2026}" }
            if scalar == " " || scalar == "\n" || scalar == "\r" || scalar == "\t" {
                if !lastWasSpace { out.append(" ") }
                lastWasSpace = true
            } else {
                out.unicodeScalars.append(scalar)
                lastWasSpace = false
            }
        }
        return out
    }

    // MARK: - Delete own message

    @objc private func deleteMenuTapped(_ sender: Any?) {
        guard pendingDeleteEventId != nil else { return }
        UIMenuController.shared.setMenuVisible(false, animated: true)
        #if IOS6_TARGET
        let sheet = UIActionSheet()
        sheet.title = "Delete this message?"
        sheet.delegate = self
        sheet.tag = deleteSheetTag
        sheet.destructiveButtonIndex = sheet.addButton(withTitle: "Delete")
        sheet.cancelButtonIndex = sheet.addButton(withTitle: "Cancel")
        sheet.show(in: view)
        #else
        let sheet = UIAlertController(title: "Delete this message?", message: nil,
                                      preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            self?.deleteConfirmed()
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        sheet.popoverPresentationController?.sourceView = view
        sheet.popoverPresentationController?.sourceRect = view.bounds
        present(sheet, animated: true, completion: nil)
        #endif
    }

    // Deleting a message in Matrix means redacting it: the server strips the
    // content and echoes an m.room.redaction back through /sync, which
    // rebuildRows() then drops from the timeline. No local echo here either —
    // the message disappears once that redaction arrives.
    private func deleteConfirmed() {
        guard let eventId = pendingDeleteEventId else { return }
        let path = "/_matrix/client/v3/rooms/\(room.roomId)/redact/\(eventId)/\(newTxnId())"
        client.put(path, body: [:]) { [weak self] _, error in
            if let error = error {
                self?.showAlert(title: "Delete failed", message: "\(error)")
            }
        }
    }

    // MARK: - Reactions

    @objc private func reactMenuTapped(_ sender: Any?) {
        guard let target = pendingReactionEventId else { return }
        UIMenuController.shared.setMenuVisible(false, animated: true)
        #if IOS6_TARGET
        let sheet = UIActionSheet()
        sheet.title = "React"
        sheet.delegate = self
        sheet.tag = reactionSheetTag
        for key in RoomTimelineVC.quickReactions { sheet.addButton(withTitle: key) }
        sheet.cancelButtonIndex = sheet.addButton(withTitle: "Cancel")
        sheet.show(in: view)
        #else
        let sheet = UIAlertController(title: "React", message: nil, preferredStyle: .actionSheet)
        for key in RoomTimelineVC.quickReactions {
            sheet.addAction(UIAlertAction(title: key, style: .default) { [weak self] _ in
                self?.toggleReaction(target: target, key: key)
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        sheet.popoverPresentationController?.sourceView = view
        sheet.popoverPresentationController?.sourceRect = view.bounds
        present(sheet, animated: true, completion: nil)
        #endif
    }

    // Add the reaction, or take ours back if we already sent this one. Matrix has
    // no "unreact" event: removing a reaction means redacting the m.reaction we
    // sent. As everywhere else here there's no local echo — the chip updates when
    // the next /sync carries the event back.
    private func toggleReaction(target: String, key: String) {
        if let mine = myReactions[target]?[key] {
            let path = "/_matrix/client/v3/rooms/\(room.roomId)/redact/\(mine)/\(newTxnId())"
            client.put(path, body: [:]) { _, _ in }
        } else {
            let path = "/_matrix/client/v3/rooms/\(room.roomId)/send/m.reaction/\(newTxnId())"
            let body: [String: Any] = ["m.relates_to": ["rel_type": "m.annotation",
                                                        "event_id": target,
                                                        "key": key]]
            client.put(path, body: body) { _, _ in }
        }
    }

    // MARK: - Horizontal swipe: timestamps (left) / reply (right)

    @objc private func handleReveal(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            // Note the row the drag starts on: the touch point moves as the
            // finger travels, but a reply belongs to where it began.
            let point = gesture.location(in: tableView)
            if let indexPath = tableView.indexPathForRow(at: point), indexPath.row < rows.count {
                replySwipeEventId = replyableEventId(for: rows[indexPath.row])
            } else {
                replySwipeEventId = nil
            }
            replySwipeArmed = false
        case .changed:
            let t = gesture.translation(in: tableView)
            // Only a predominantly-horizontal drag moves the bubbles; otherwise
            // let the table scroll normally.
            guard abs(t.x) > abs(t.y) else { return }
            if t.x > 0 {
                // Rightward: pull the bubbles aside to reply. A NEGATIVE reveal
                // offset reuses the very same per-cell translation as the
                // timestamp reveal, and every cell hides its time label at
                // offsets <= 0, so no timestamp shows on this side.
                guard replySwipeEventId != nil else { return }
                setRevealOffset(-min(RoomTimelineVC.maxReplyPull, t.x))
                // Tracks the CURRENT distance rather than latching, so dragging
                // back short of the threshold cancels the reply.
                replySwipeArmed = t.x >= RoomTimelineVC.replyTriggerDistance
            } else {
                replySwipeArmed = false
                setRevealOffset(min(EventCell.maxReveal, -t.x))
            }
        case .ended, .cancelled, .failed:
            let target = (gesture.state == .ended && replySwipeArmed) ? replySwipeEventId : nil
            replySwipeArmed = false
            replySwipeEventId = nil
            UIView.animate(withDuration: 0.2) { self.setRevealOffset(0) }
            if let target = target { beginReply(to: target) }
        default:
            break
        }
    }

    private func setRevealOffset(_ offset: CGFloat) {
        revealOffset = offset
        for cell in tableView.visibleCells {
            (cell as? EventCell)?.setRevealOffset(offset)
            (cell as? ImageEventCell)?.setRevealOffset(offset)
            (cell as? AudioEventCell)?.setRevealOffset(offset)
            (cell as? FileEventCell)?.setRevealOffset(offset)
            (cell as? VideoEventCell)?.setRevealOffset(offset)
            (cell as? ReactionsCell)?.setRevealOffset(offset)
        }
    }

    private func buildStatusLabel() {
        statusLabel = UILabel(frame: tableView.bounds.insetBy(dx: 24, dy: 24))
        statusLabel.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.textColor = .gray
        statusLabel.text = "Loading messages\u{2026}"
        view.insertSubview(statusLabel, aboveSubview: tableView)
    }

    // Nav-bar title: a small circular room avatar next to the room name, instead
    // of the plain text title. Sized to fit so the nav bar centres it.
    private func setupTitleView() {
        let avatarSize: CGFloat = 30
        let gap: CGFloat = 8
        let label = UILabel()
        label.backgroundColor = .clear
        label.text = room.name
        label.font = UIFont.boldSystemFont(ofSize: 17)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        label.sizeToFit()
        // Cap the title width well short of the nav bar's edges so a long room
        // name ellipsises rather than running under the back button (left) or the
        // members icon (right). The centred titleView grows symmetrically, so we
        // reserve ~90pt on each side for those buttons plus the avatar/gap.
        let maxLabelWidth = max(60, UIScreen.main.bounds.width - 180)
        let labelWidth = min(label.frame.width, maxLabelWidth)
        let height: CGFloat = 36
        let container = UIView(frame: CGRect(x: 0, y: 0,
                                             width: avatarSize + gap + labelWidth, height: height))
        let avatar = AvatarView(frame: CGRect(x: 0, y: (height - avatarSize) / 2,
                                              width: avatarSize, height: avatarSize))
        avatar.setAvatar(mxc: room.avatarMxc, name: room.name)
        container.addSubview(avatar)
        label.frame = CGRect(x: avatarSize + gap, y: (height - label.frame.height) / 2,
                             width: labelWidth, height: label.frame.height)
        container.addSubview(label)
        // Tapping the title (avatar + name) opens Room Settings — the same
        // affordance Element/WhatsApp/Telegram use, and it needs no new icon
        // asset (hence no project.pbxproj round-trip).
        container.isUserInteractionEnabled = true
        container.addGestureRecognizer(UITapGestureRecognizer(target: self,
                                                              action: #selector(openRoomSettings)))
        navigationItem.titleView = container

        // Right-hand button (users icon) opens the member list for this room.
        // The loose PNG (not asset catalog) is drawn by iOS 6/7 as an alpha-mask
        // template, so the white glyph auto-tints to the nav bar's tint colour.
        let membersItem: UIBarButtonItem
        if let icon = UIImage(named: "Users") {
            membersItem = UIBarButtonItem(image: icon, style: .plain,
                                          target: self, action: #selector(openMemberList))
        } else {
            membersItem = UIBarButtonItem(title: "Members", style: .plain,
                                          target: self, action: #selector(openMemberList))
        }
        navigationItem.rightBarButtonItem = membersItem
    }

    @objc private func openMemberList() {
        let vc = MemberListVC(room: room, client: client,
                              memberNames: memberNames, memberAvatars: memberAvatars)
        navigationController?.pushViewController(vc, animated: true)
    }

    @objc private func openRoomSettings() {
        let vc = RoomSettingsVC(room: room, client: client)
        vc.onRoomUpdated = { [weak self] updated in
            guard let self = self else { return }
            self.room = updated
            self.setupTitleView()
        }
        navigationController?.pushViewController(vc, animated: true)
    }

    // "Replying to …" strip; hidden unless a reply is queued. Sits directly above
    // the input bar, positioned in layoutInputBar() like the typing strip. Added
    // after the input bar so the table (inserted below the bar) can't cover it.
    private func buildReplyBar() {
        replyBar = UIView(frame: .zero)
        replyBar.backgroundColor = UIColor(white: 0.90, alpha: 1.0)
        replyBar.isHidden = true

        replyLabel = UILabel(frame: .zero)
        replyLabel.backgroundColor = .clear   // iOS 6: labels default to white bg
        replyLabel.font = UIFont.systemFont(ofSize: 12)
        replyLabel.textColor = UIColor(white: 0.3, alpha: 1.0)
        replyLabel.lineBreakMode = .byTruncatingTail
        replyBar.addSubview(replyLabel)

        replyCancelButton = UIButton(type: .system)
        replyCancelButton.setTitle("\u{2715} Cancel", for: .normal)
        replyCancelButton.titleLabel?.font = UIFont.systemFont(ofSize: 12)
        replyCancelButton.addTarget(self, action: #selector(replyCancelTapped), for: .touchUpInside)
        replyBar.addSubview(replyCancelButton)

        view.addSubview(replyBar)
    }

    // Typing strip lives above the input bar; positioned in layoutInputBar().
    private func buildTypingLabel() {
        typingLabel = UILabel(frame: .zero)
        typingLabel.backgroundColor = .clear   // iOS 6: labels default to white bg
        typingLabel.font = UIFont.italicSystemFont(ofSize: 12)
        typingLabel.textColor = .gray
        typingLabel.isHidden = true
        view.addSubview(typingLabel)
    }

    private func buildInputBar() {
        // We fully manage every frame in layoutInputBar() (it repositions on
        // grow + on keyboard show/hide), so autoresizing is left off to avoid it
        // fighting the manual layout.
        inputBar = UIView(frame: .zero)
        inputBar.backgroundColor = UIColor(white: 0.97, alpha: 1.0)

        // Attach (photo) button, docked at the far left of the bar.
        attachButton = UIButton(type: .system)
        attachButton.setTitle("+", for: .normal)
        attachButton.titleLabel?.font = UIFont.systemFont(ofSize: 30)
        // The "+" glyph's optical centre sits low inside the font's line box, so
        // the button looks bottom-heavy. Lift the title a few points to centre it.
        attachButton.titleEdgeInsets = UIEdgeInsets(top: -3, left: 0, bottom: 0, right: 0)
        attachButton.addTarget(self, action: #selector(attachTapped), for: .touchUpInside)
        inputBar.addSubview(attachButton)

        // A UITextView (not UITextField) so the input can hold multiple lines and
        // grow. The Return key inserts a newline (UITextView's default); sending
        // is the explicit "Send" button only. Kept white with a hairline border +
        // rounded corners so it reads as a field against the light bar.
        messageField = UITextView(frame: .zero)
        messageField.backgroundColor = .white
        messageField.layer.cornerRadius = 8
        messageField.layer.masksToBounds = true
        messageField.layer.borderWidth = 0.5
        messageField.layer.borderColor = UIColor(white: 0.8, alpha: 1.0).cgColor
        messageField.font = UIFont.systemFont(ofSize: 16)
        messageField.delegate = self
        // Scrolling stays off while growing; it's flipped on only once the content
        // exceeds inputMaxHeight (see adjustInputHeight).
        messageField.isScrollEnabled = false
        // Normalise the text inset so the placeholder can line up with the real
        // text. textContainerInset / textContainer are TextKit (iOS 7+) — guard
        // them so this doesn't crash on the iOS 6 runtime, where the default inset
        // is used instead.
        if messageField.responds(to: NSSelectorFromString("setTextContainerInset:")) {
            messageField.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        }
        if messageField.responds(to: NSSelectorFromString("textContainer")) {
            messageField.textContainer.lineFragmentPadding = 4
        }
        inputBar.addSubview(messageField)

        // Placeholder overlay: a plain label inside the field, hidden as soon as
        // there's any text (UITextView has no built-in placeholder).
        placeholderLabel = UILabel(frame: .zero)
        placeholderLabel.text = "Message"
        placeholderLabel.font = messageField.font
        placeholderLabel.textColor = UIColor(white: 0.7, alpha: 1.0)
        placeholderLabel.isUserInteractionEnabled = false
        messageField.addSubview(placeholderLabel)

        sendButton = UIButton(type: .system)
        sendButton.setTitle("Send", for: .normal)
        sendButton.titleLabel?.font = UIFont.boldSystemFont(ofSize: 15)
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        inputBar.addSubview(sendButton)

        // Voice-mode controls (hidden until the user picks "Voice Message" from
        // the + sheet). They replace the attach button + text field; Send is
        // shared with text mode.
        voiceCancelButton = UIButton(type: .system)
        voiceCancelButton.setTitle("Cancel", for: .normal)
        voiceCancelButton.titleLabel?.font = UIFont.systemFont(ofSize: 15)
        voiceCancelButton.addTarget(self, action: #selector(voiceCancelTapped), for: .touchUpInside)
        voiceCancelButton.isHidden = true
        inputBar.addSubview(voiceCancelButton)

        voiceRecordButton = UIButton(type: .system)
        voiceRecordButton.setTitle("\u{25CF} Record", for: .normal)
        voiceRecordButton.setTitleColor(UIColor(red: 0.85, green: 0.15, blue: 0.15, alpha: 1.0), for: .normal)
        voiceRecordButton.titleLabel?.font = UIFont.systemFont(ofSize: 15)
        voiceRecordButton.addTarget(self, action: #selector(voiceRecordTapped), for: .touchUpInside)
        voiceRecordButton.isHidden = true
        inputBar.addSubview(voiceRecordButton)

        view.addSubview(inputBar)
        currentFieldHeight = inputMinHeight
        layoutInputBar()
    }

    // Lays out the bar and its subviews for the current field height + keyboard
    // position. The bar's bottom edge sits just above the keyboard (or the screen
    // bottom when dismissed) and it grows upward; the table fills the space above.
    private func layoutInputBar() {
        let barWidth = view.bounds.width
        let barHeight = currentFieldHeight + inputVPad * 2
        let barY = view.bounds.height - keyboardHeight - barHeight
        inputBar.frame = CGRect(x: 0, y: barY, width: barWidth, height: barHeight)

        // Buttons keep a fixed 36pt box pinned to the bar's bottom edge, so they
        // stay put while the field grows above them.
        let buttonH = inputMinHeight
        let buttonY = barHeight - inputVPad - buttonH
        sendButton.frame = CGRect(x: barWidth - hMargin - sendWidth, y: buttonY,
                                  width: sendWidth, height: buttonH)

        if inputMode == .voice {
            attachButton.isHidden = true
            messageField.isHidden = true
            placeholderLabel.isHidden = true
            voiceCancelButton.isHidden = false
            voiceRecordButton.isHidden = false
            let cancelW: CGFloat = 64
            voiceCancelButton.frame = CGRect(x: hMargin, y: buttonY, width: cancelW, height: buttonH)
            let recX = hMargin + cancelW + hSpacing
            let recW = (barWidth - hMargin - sendWidth - hSpacing) - recX
            voiceRecordButton.frame = CGRect(x: recX, y: buttonY, width: max(0, recW), height: buttonH)
        } else {
            attachButton.isHidden = false
            messageField.isHidden = false
            if voiceCancelButton != nil { voiceCancelButton.isHidden = true }
            if voiceRecordButton != nil { voiceRecordButton.isHidden = true }
            attachButton.frame = CGRect(x: hMargin, y: buttonY, width: attachWidth, height: buttonH)

            let fieldX = hMargin + attachWidth + hSpacing
            let fieldWidth = barWidth - fieldX - hMargin - sendWidth - hSpacing
            messageField.frame = CGRect(x: fieldX, y: inputVPad, width: fieldWidth, height: currentFieldHeight)

            // Placeholder sits at the field's text origin (matches the 4pt inset set
            // above, or ~8pt default on iOS 6 — close enough either way).
            let phInset: CGFloat = 8
            placeholderLabel.frame = CGRect(x: phInset, y: phInset,
                                            width: fieldWidth - phInset * 2,
                                            height: messageField.font!.lineHeight + 2)
        }

        // Reply strip (if a reply is queued) sits directly above the bar, and the
        // typing strip above that; the table shrinks by both so neither ever
        // overlaps the newest message.
        let replyVisible = replyBar != nil && !replyBar.isHidden
        let replyH: CGFloat = replyVisible ? replyBarHeight : 0
        if replyVisible {
            replyBar.frame = CGRect(x: 0, y: barY - replyH, width: barWidth, height: replyH)
            let cancelW: CGFloat = 76
            replyLabel.frame = CGRect(x: hMargin, y: 0,
                                      width: max(0, barWidth - hMargin * 2 - cancelW), height: replyH)
            replyCancelButton.frame = CGRect(x: barWidth - hMargin - cancelW, y: 0,
                                             width: cancelW, height: replyH)
        }

        let typingVisible = !typingUsers.isEmpty
        let typingH: CGFloat = typingVisible ? typingBarHeight : 0
        if typingLabel != nil {
            typingLabel.isHidden = !typingVisible
            typingLabel.frame = CGRect(x: hMargin, y: barY - replyH - typingH,
                                       width: barWidth - hMargin * 2, height: typingH)
        }

        if isViewLoaded, tableView != nil {
            tableView.frame.size.height = barY - replyH - typingH
        }
    }

    // Recomputes the field height from its content and grows/shrinks the bar,
    // clamped to [inputMinHeight, inputMaxHeight]; past the max the field scrolls.
    private func adjustInputHeight() {
        let fitWidth = messageField.bounds.width
        let content = messageField.sizeThatFits(CGSize(width: fitWidth, height: .greatestFiniteMagnitude)).height
        let target = min(max(content, inputMinHeight), inputMaxHeight)
        messageField.isScrollEnabled = content > inputMaxHeight
        guard abs(target - currentFieldHeight) > 0.5 else { return }
        currentFieldHeight = target
        layoutInputBar()
        scrollToBottom(animated: false)
    }

    // MARK: - Data

    private func loadBackfill() {
        guard !reachedHistoryStart, !isLoadingBackfill else {
            markInitialLoadDone()
            return
        }
        // First page starts at the room's prev_batch; later pages continue from
        // the previous response's `end` token (see below).
        guard let from = backfillFrom ?? room.prevBatch else {
            markInitialLoadDone()
            return
        }
        isLoadingBackfill = true
        setBackfillSpinner(active: true)
        let path = "/_matrix/client/v3/rooms/\(room.roomId)/messages?dir=b&from=\(from)&limit=30"
        client.get(path) { [weak self] json, error in
            guard let self = self else { return }
            self.isLoadingBackfill = false
            defer { self.setBackfillSpinner(active: false) }
            defer { self.markInitialLoadDone() }
            guard let json = json else { return }
            // Advance the pagination cursor so the next scroll-up fetches an
            // older page. No `end` token (or an empty chunk below) means the
            // server has no more history — latch so we stop asking.
            if let end = json["end"] as? String {
                self.backfillFrom = end
            } else {
                self.reachedHistoryStart = true
            }
            guard let chunk = json["chunk"] as? [[String: Any]] else { return }
            if chunk.isEmpty { self.reachedHistoryStart = true; return }
            // dir=b returns newest-first; reverse to chronological order and prepend.
            let parsed = chunk.reversed().compactMap { RoomEvent.parse($0) }
            let newOnes = parsed.filter { !self.seenEventIds.contains($0.eventId) }
            guard !newOnes.isEmpty else { return }
            newOnes.forEach { self.seenEventIds.insert($0.eventId) }
            let wasEmpty = self.events.isEmpty
            self.events.insert(contentsOf: newOnes, at: 0)
            DispatchQueue.main.async {
                if wasEmpty {
                    self.reloadTable()
                    self.scrollToBottom(animated: false)
                } else {
                    // Prepending rows changes contentSize, which by default
                    // yanks the viewport back to the same *offset* (now
                    // pointing at different content, visually a jump toward
                    // the top). Compensate contentOffset by the height delta
                    // so the rows the user was looking at stay in place.
                    let oldContentHeight = self.tableView.contentSize.height
                    let oldOffsetY = self.tableView.contentOffset.y
                    self.reloadTable()
                    self.tableView.layoutIfNeeded()
                    let newContentHeight = self.tableView.contentSize.height
                    self.tableView.contentOffset = CGPoint(x: 0, y: oldOffsetY + (newContentHeight - oldContentHeight))
                }
            }
        }
    }

    // Shows a "Loading messages…" label until the initial backfill request
    // completes (success, error, or no-prevBatch no-op), then either hides it
    // (messages present) or switches to "No messages yet." — previously the
    // screen just sat blank with no feedback while the first request was in flight.
    private func markInitialLoadDone() {
        guard !hasLoadedInitial else { return }
        hasLoadedInitial = true
        DispatchQueue.main.async { [weak self] in
            self?.updateStatusLabel()
        }
    }

    private func updateStatusLabel() {
        if !events.isEmpty {
            statusLabel.isHidden = true
        } else if hasLoadedInitial {
            statusLabel.text = "No messages yet."
            statusLabel.isHidden = false
        }
    }

    private func handleSync(_ json: [String: Any]) {
        // Note: no early return on "no timeline events" any more — a /sync
        // response can carry ONLY ephemeral data (someone typing, a read
        // receipt) or member-profile updates with no new messages, and those
        // still need to update the UI.
        guard let rooms = json["rooms"] as? [String: Any],
              let join = rooms["join"] as? [String: Any],
              let roomJSON = join[room.roomId] as? [String: Any] else { return }

        // Member profiles (display name / avatar) from state + timeline.
        if let state = roomJSON["state"] as? [String: Any],
           let stateEvents = state["events"] as? [[String: Any]] {
            updateMembers(from: stateEvents)
        }

        var newOnes: [RoomEvent] = []
        if let timeline = roomJSON["timeline"] as? [String: Any],
           let rawEvents = timeline["events"] as? [[String: Any]] {
            updateMembers(from: rawEvents)
            let parsed = rawEvents.compactMap { RoomEvent.parse($0) }
            newOnes = parsed.filter { !seenEventIds.contains($0.eventId) }
            newOnes.forEach { seenEventIds.insert($0.eventId) }
            events.append(contentsOf: newOnes)
        }

        // Ephemeral: typing notices + read receipts.
        var typingChanged = false
        var receiptsChanged = false
        if let ephemeral = roomJSON["ephemeral"] as? [String: Any],
           let ephEvents = ephemeral["events"] as? [[String: Any]] {
            for ev in ephEvents {
                guard let type = ev["type"] as? String,
                      let content = ev["content"] as? [String: Any] else { continue }
                if type == "m.typing" {
                    let ids = (content["user_ids"] as? [String]) ?? []
                    let others = ids.filter { $0 != MatrixSession.userId }
                    if others != typingUsers { typingUsers = others; typingChanged = true }
                } else if type == "m.receipt" {
                    if applyReceipts(content) { receiptsChanged = true }
                }
            }
        }

        let tableChanged = !newOnes.isEmpty || receiptsChanged
        // Annotations and edits redraw existing rows but shouldn't yank the view
        // to the bottom or move our read marker onto a non-message event.
        let hasNewMessages = newOnes.contains { event in
            switch event.kind {
            case .reaction, .redaction, .edit: return false
            default: return true
            }
        }
        if tableChanged || typingChanged {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if tableChanged {
                    self.reloadTable()
                    self.updateStatusLabel()
                    if hasNewMessages { self.scrollToBottom(animated: true) }
                }
                if typingChanged { self.updateTypingIndicator() }
            }
        }
        if hasNewMessages, let latest = events.last(where: { event in
            switch event.kind {
            case .reaction, .redaction, .edit: return false
            default: return true
            }
        }) {
            sendReadReceipt(for: latest.eventId)
        }
    }

    // Merges join-member display name / avatar into the local member directory.
    // Keyed on state_key (the member the event is about) rather than sender.
    private func updateMembers(from events: [[String: Any]]) {
        for ev in events where ev["type"] as? String == "m.room.member" {
            guard let content = ev["content"] as? [String: Any],
                  content["membership"] as? String == "join" else { continue }
            let userId = (ev["state_key"] as? String) ?? (ev["sender"] as? String)
            guard let userId = userId else { continue }
            if let dn = content["displayname"] as? String, !dn.isEmpty {
                memberNames[userId] = dn
            }
            if let av = content["avatar_url"] as? String, av.hasPrefix("mxc://") {
                memberAvatars[userId] = av
            }
        }
    }

    // Records which of our own events peers have read. m.receipt content is
    // { eventId: { "m.read": { userId: { ts } } } }. Returns true if a new
    // (event, other-user) pair was seen, so the "Seen" marker can be recomputed.
    private func applyReceipts(_ content: [String: Any]) -> Bool {
        var changed = false
        for (eventId, raw) in content {
            guard let data = raw as? [String: Any],
                  let read = data["m.read"] as? [String: Any] else { continue }
            for userId in read.keys where userId != MatrixSession.userId {
                if othersReadEventIds.insert(eventId).inserted { changed = true }
            }
        }
        return changed
    }

    // Rebuilds the flat `rows` list from `events`: inserts a full-date separator
    // whenever the calendar day changes, and marks each message row with whether
    // it starts a new same-sender group (which resets after a day change or a
    // gap longer than the grouping window) so it shows a meta header.
    private func rebuildRows() {
        var result: [Row] = []
        var lastDayKey: String?
        var prevEvent: RoomEvent?

        // Everything a redaction took back — a deleted message as much as an
        // un-done reaction. (A message already redacted before we fetched it
        // arrives with empty content and is dropped at ingestion by
        // RoomEvent.parse; this covers the ones redacted while we're watching.)
        var redacted = Set<String>()
        for event in events {
            if case .redaction(let target) = event.kind { redacted.insert(target) }
        }

        var byId: [String: RoomEvent] = [:]
        for event in events { byId[event.eventId] = event }
        eventsById = byId

        // Edits rewrite an existing bubble rather than adding one. Keep only the
        // newest edit per target, and only from the target's own sender — the
        // spec says an edit from anyone else is to be ignored.
        var edits: [String: (timestamp: Double, body: String)] = [:]
        for event in events {
            guard case .edit(let sender, let target, let body) = event.kind,
                  !redacted.contains(event.eventId),
                  let original = byId[target],
                  RoomTimelineVC.senderOf(original) == sender else { continue }
            if let existing = edits[target], existing.timestamp >= event.timestamp { continue }
            edits[target] = (event.timestamp, body)
        }

        // Reactions annotate other events rather than occupying a row, so fold
        // them up front: which keys were used on each target, in first-seen
        // order, how many people used each, and which one is ours.
        var keyOrder: [String: [String]] = [:]
        var keyCounts: [String: [String: Int]] = [:]
        var mine: [String: [String: String]] = [:]
        // Reactions we know were taken back, so the server's bundled totals
        // (which may predate the redaction) can be corrected below.
        var redactedCounts: [String: [String: Int]] = [:]
        for event in events {
            guard case .reaction(let sender, let target, let key) = event.kind else { continue }
            if redacted.contains(event.eventId) {
                redactedCounts[target, default: [:]][key, default: 0] += 1
                continue
            }
            if keyCounts[target]?[key] == nil {
                keyOrder[target] = (keyOrder[target] ?? []) + [key]
            }
            keyCounts[target, default: [:]][key, default: 0] += 1
            if sender == MatrixSession.userId {
                mine[target, default: [:]][key] = event.eventId
            }
        }
        myReactions = mine

        // Fold in the totals the server bundled onto each event. This is the
        // only way reactions to a message older than our loaded history show up
        // at all — its m.reaction events are outside the timeline we fetched.
        // The bundle carries no event ids, so it can never tell us that one of
        // the reactions is ours: a chip added this way always renders as
        // someone else's until the room is reopened.
        for event in events where !event.bundledReactions.isEmpty {
            let target = event.eventId
            for bundled in event.bundledReactions {
                let live = keyCounts[target]?[bundled.key] ?? 0
                let adjusted = max(0, bundled.count - (redactedCounts[target]?[bundled.key] ?? 0))
                let merged = max(live, adjusted)
                guard merged > 0 else { continue }
                if keyCounts[target]?[bundled.key] == nil {
                    keyOrder[target] = (keyOrder[target] ?? []) + [bundled.key]
                }
                keyCounts[target, default: [:]][bundled.key] = merged
            }
        }

        // The most recent of OUR own messages that a peer has read — a single
        // "Seen" marker goes under it.
        var seenEventId: String?
        for event in events where othersReadEventIds.contains(event.eventId)
            && RoomTimelineVC.senderOf(event) == MatrixSession.userId {
            seenEventId = event.eventId
        }
        for event in events {
            // (Content-less/blank messages are already dropped at ingestion in
            // RoomEvent.parse, so they never reach here to create empty-bubble
            // gaps or break same-sender grouping.)
            //
            // Annotations were folded above; skipping them before any of the
            // day-separator / grouping bookkeeping keeps them from splitting a
            // same-sender run or emitting a stray date header.
            switch event.kind {
            case .reaction, .redaction, .edit: continue
            default: break
            }
            // A message deleted (redacted) since we loaded it leaves the
            // timeline entirely, along with any reactions that hung off it.
            if redacted.contains(event.eventId) { continue }
            var dayChanged = false
            if event.timestamp > 0 {
                let key = TimeFormat.dayKey(msSinceEpoch: event.timestamp)
                if key != lastDayKey {
                    result.append(.date(TimeFormat.dateHeader(msSinceEpoch: event.timestamp)))
                    lastDayKey = key
                    dayChanged = true
                }
            }
            var showMeta = false
            if let sender = RoomTimelineVC.senderOf(event) {
                if dayChanged {
                    showMeta = true
                } else if let prev = prevEvent, let prevSender = RoomTimelineVC.senderOf(prev) {
                    showMeta = sender != prevSender
                        || (event.timestamp - prev.timestamp) > EventCell.groupingWindowMs
                } else {
                    showMeta = true
                }
            }
            result.append(.event(EventRow(event: event, showMeta: showMeta,
                                          editedBody: edits[event.eventId]?.body)))
            if let keys = keyOrder[event.eventId] {
                let items = keys.map {
                    ReactionItem(key: $0,
                                 count: keyCounts[event.eventId]?[$0] ?? 0,
                                 mineEventId: mine[event.eventId]?[$0])
                }
                result.append(.reactions(ReactionRow(targetEventId: event.eventId, items: items,
                                                     isOwn: RoomTimelineVC.senderOf(event) == MatrixSession.userId)))
            }
            if event.eventId == seenEventId {
                result.append(.receipt("Seen"))
            }
            prevEvent = event
        }
        rows = result
    }

    // Sender of a message/image event (nil for membership rows), used for
    // same-sender grouping across both text and image bubbles.
    private static func senderOf(_ event: RoomEvent) -> String? {
        switch event.kind {
        case .message(let sender, _, _): return sender
        case .image(let sender, _, _, _, _): return sender
        case .audio(let sender, _, _, _): return sender
        case .file(let sender, _, _, _, _): return sender
        case .video(let sender, _): return sender
        // Annotations and edits never become rows, so they have no grouping
        // sender. (An edit's own sender is checked separately in rebuildRows.)
        case .membership, .reaction, .redaction, .edit: return nil
        }
    }

    private func reloadTable() {
        rebuildRows()
        tableView.reloadData()
        prefetchImageThumbnails()
    }

    // Updates the typing strip text + shows/hides it (animating the table resize).
    private func updateTypingIndicator() {
        typingLabel.text = typingText()
        UIView.animate(withDuration: 0.2) { self.layoutInputBar() }
    }

    private func typingText() -> String {
        let names = typingUsers.map { memberNames[$0] ?? shortName($0) }
        switch names.count {
        case 0: return ""
        case 1: return "\(names[0]) is typing\u{2026}"
        case 2: return "\(names[0]) and \(names[1]) are typing\u{2026}"
        default: return "Several people are typing\u{2026}"
        }
    }

    // "@alice:example.org" → "alice" for a readable fallback when we have no
    // display name for a member.
    private func shortName(_ userId: String) -> String {
        var s = userId
        if s.hasPrefix("@") { s = String(s.dropFirst()) }
        if let colon = s.firstIndex(of: ":") { s = String(s[..<colon]) }
        return s.isEmpty ? userId : s
    }

    // Prime the thumbnail cache for every image in `events`, not just the ones
    // currently on screen. UITableView only builds cells for visible rows, so
    // without this an image scrolled off the top (or below the fold on open)
    // never issues its download until the user scrolls it exactly into view —
    // which read as "images above the fold never load". Coalescing in MediaCache
    // dedups against the cell's own later request; `prefetchedMxcs` ensures we
    // fire once per image rather than on every reload.
    private func prefetchImageThumbnails() {
        for event in events {
            // Videos are prefetched too: their poster frame is an ordinary
            // thumbnail request, keyed on the thumbnail's own mxc.
            var request: (mxc: String, w: Int, h: Int)?
            switch event.kind {
            case .image(_, _, let mxc, let w, let h):
                request = (mxc, w, h)
            case .video(_, let video):
                if let thumb = video.thumbnailMxc { request = (thumb, video.width, video.height) }
            default:
                break
            }
            guard let req = request, !prefetchedMxcs.contains(req.mxc) else { continue }
            prefetchedMxcs.insert(req.mxc)
            let (reqW, reqH) = ImageEventCell.thumbnailRequestSize(imageWidth: req.w, imageHeight: req.h)
            MediaCache.shared.loadThumbnail(mxc: req.mxc, width: reqW, height: reqH) { _ in }
        }
    }

    private func scrollToBottom(animated: Bool) {
        guard !rows.isEmpty else { return }
        // scrollToRow(at:.bottom) leaves the last row pinned to the visible
        // bottom but can stop a few points short (row-height estimate vs. the
        // laid-out height), leaving a visible gap. Compute the exact maximum
        // offset from contentSize instead so the last bubble sits flush against
        // the input bar with no margin.
        tableView.layoutIfNeeded()
        let maxOffsetY = tableView.contentSize.height - tableView.bounds.height + tableView.contentInset.bottom
        let y = max(-tableView.contentInset.top, maxOffsetY)
        tableView.setContentOffset(CGPoint(x: 0, y: y), animated: animated)
    }

    // MARK: - Sending

    @objc private func sendTapped() {
        if inputMode == .voice { sendVoiceMessage(); return }
        guard let text = messageField.text, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        // Give immediate feedback and prevent double-sends: a failure here used
        // to only `print()` (invisible with no attached Xcode console on the
        // ad-hoc-installed IPA), so the send button looked "stuck" with no
        // indication anything happened, whether it succeeded, failed, or was
        // still in flight.
        guard !isSending else { return }
        messageField.text = ""
        // Programmatic text changes don't fire textViewDidChange, so restore the
        // placeholder and collapse the grown field back to one line by hand.
        placeholderLabel.isHidden = false
        adjustInputHeight()
        sendTypingStop()
        setSending(true)

        let path = "/_matrix/client/v3/rooms/\(room.roomId)/send/m.room.message/\(newTxnId())"
        var body: [String: Any] = ["msgtype": "m.text", "body": text]
        let replyTarget = replyingToEventId
        if let replyTarget = replyTarget {
            // m.relates_to alone, with NO legacy "> <@alice:server> …" fallback
            // prepended to the body. MSC2781 removed reply fallbacks from the
            // spec (Matrix 1.13) and Element stopped sending them; bridges built
            // on mautrix bridgev2 (Messenger, current WhatsApp) consequently no
            // longer strip one, so a fallback we send arrives on the far side as
            // literal message text. Older bridges (mautrix-discord) still strip
            // it, which is why the leak only showed up on some networks.
            body["m.relates_to"] = ["m.in_reply_to": ["event_id": replyTarget]]
            endReply()
        }
        client.put(path, body: body) { [weak self] _, error in
            guard let self = self else { return }
            self.setSending(false)
            if let error = error {
                self.messageField.text = text  // don't lose what the user typed
                self.placeholderLabel.isHidden = true
                self.adjustInputHeight()
                // Restore the reply context too, so retrying still answers the
                // message the user picked.
                if let replyTarget = replyTarget { self.beginReply(to: replyTarget) }
                self.showSendError(error)
            }
        }
    }

    // Toggles the "a send is in flight" UI state across the whole input bar so
    // text sends and image uploads share one consistent lock (double-send guard
    // + disabled controls + spinner-ish "…" on the send button).
    private func setSending(_ sending: Bool) {
        isSending = sending
        messageField.isEditable = !sending
        sendButton.isEnabled = !sending
        attachButton.isEnabled = !sending
        if voiceCancelButton != nil { voiceCancelButton.isEnabled = !sending }
        if voiceRecordButton != nil { voiceRecordButton.isEnabled = !sending }
        sendButton.setTitle(sending ? "\u{2026}" : "Send", for: .normal)
    }

    // Int64, not Int: on the armv7 (32-bit) build for iPhone 4S/5, `Int` is
    // 32-bit (max ~2.1 billion) but epoch-milliseconds is ~1.7 trillion —
    // `Int(Double)` traps (SIGTRAP, precondition failure) when the value doesn't
    // fit. Int64 is always 64-bit regardless of platform word size.
    private func newTxnId() -> String {
        return "elementold-\(Int64(Date().timeIntervalSince1970 * 1000))-\(Int.random(in: 0..<1_000_000))"
    }

    // MARK: - Outbound typing notices

    // Notifies the homeserver we're typing (PUT .../typing/{userId}, throttled to
    // at most once every few seconds while the field is non-empty). Room/user IDs
    // are sent unencoded in the path, matching every other room-scoped request in
    // this app (percent-encoding via Foundation crashes on the iOS 6 runtime).
    private func sendTypingIfNeeded() {
        guard let userId = MatrixSession.userId else { return }
        guard let text = messageField.text, !text.isEmpty else { sendTypingStop(); return }
        let now = Date().timeIntervalSince1970
        guard now - lastTypingSent > 4 else { return }
        lastTypingSent = now
        let path = "/_matrix/client/v3/rooms/\(room.roomId)/typing/\(userId)"
        client.put(path, body: ["typing": true, "timeout": 8000]) { _, _ in }
    }

    private func sendTypingStop() {
        guard lastTypingSent > 0, let userId = MatrixSession.userId else { return }
        lastTypingSent = 0
        let path = "/_matrix/client/v3/rooms/\(room.roomId)/typing/\(userId)"
        client.put(path, body: ["typing": false]) { _, _ in }
    }

    // MARK: - Image attach / upload / send

    @objc private func attachTapped() {
        messageField.resignFirstResponder()
        let hasCamera = UIImagePickerController.isSourceTypeAvailable(.camera)
#if IOS6_TARGET
        let sheet = UIActionSheet()
        sheet.delegate = self
        sheet.title = "Attach"
        if hasCamera { sheet.addButton(withTitle: "Take Photo") }
        sheet.addButton(withTitle: "Choose from Library")
        sheet.addButton(withTitle: "Voice Message")
        let cancelIndex = sheet.addButton(withTitle: "Cancel")
        sheet.cancelButtonIndex = cancelIndex
        sheet.show(in: view)
#else
        let sheet = UIAlertController(title: "Attach", message: nil, preferredStyle: .actionSheet)
        if hasCamera {
            sheet.addAction(UIAlertAction(title: "Take Photo", style: .default) { [weak self] _ in
                self?.presentPicker(source: .camera)
            })
        }
        sheet.addAction(UIAlertAction(title: "Choose from Library", style: .default) { [weak self] _ in
            self?.presentPicker(source: .photoLibrary)
        })
        sheet.addAction(UIAlertAction(title: "Voice Message", style: .default) { [weak self] _ in
            self?.enterVoiceMode()
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(sheet, animated: true)
#endif
    }

    private func presentPicker(source: UIImagePickerController.SourceType) {
        let picker = UIImagePickerController()
        picker.sourceType = source
        // "public.image"/"public.movie" are the literal values of kUTTypeImage and
        // kUTTypeMovie, used directly so this file doesn't need MobileCoreServices.
        // Asking for a media type the source can't provide raises an exception, so
        // movies are only offered when the source actually supports them.
        let available = UIImagePickerController.availableMediaTypes(for: source) ?? []
        var types = ["public.image"]
        if available.contains("public.movie") { types.append("public.movie") }
        picker.mediaTypes = types
        // The upload path buffers the whole file in memory (see
        // maxVideoUploadBytes), so lean on the picker to shrink it: it transcodes
        // both recorded and library movies to this quality on export, which keeps a
        // minute of video in the same size range as the photos we already send.
        picker.videoQuality = .typeMedium
        picker.videoMaximumDuration = 60
        picker.delegate = self
        present(picker, animated: true)
    }

    private func uploadAndSendImage(_ image: UIImage) {
        guard !isSending else { return }
        // Downscale large photos before upload — full 8-12MP camera images are
        // needlessly heavy to encode/upload/decode on A5/A6 hardware and slow
        // for other clients to fetch; 1600px on the long edge is plenty for chat.
        let resized = downscale(image, maxDimension: 1600)
        guard let data = resized.jpegData(compressionQuality: 0.8) else { return }
        // Image replies aren't supported yet, so clear any queued reply instead
        // of leaving the strip up over a photo that won't carry the relation.
        endReply()
        setSending(true)
        let filename = "elementold-\(Int64(Date().timeIntervalSince1970 * 1000)).jpg"
        client.uploadMedia(data: data, filename: filename, mimeType: "image/jpeg") { [weak self] json, error in
            guard let self = self else { return }
            guard let mxc = json?["content_uri"] as? String else {
                self.setSending(false)
                self.showSendError(error ?? MatrixAPIClient.MatrixError(errcode: "M_UNKNOWN",
                                                                        error: "Upload returned no content_uri"))
                return
            }
            self.sendImageMessage(mxc: mxc, image: resized, size: data.count, filename: filename)
        }
    }

    private func sendImageMessage(mxc: String, image: UIImage, size: Int, filename: String) {
        let path = "/_matrix/client/v3/rooms/\(room.roomId)/send/m.room.message/\(newTxnId())"
        let info: [String: Any] = ["mimetype": "image/jpeg",
                                    "w": Int(image.size.width),
                                    "h": Int(image.size.height),
                                    "size": size]
        let body: [String: Any] = ["msgtype": "m.image", "body": filename, "url": mxc, "info": info]

        // Prime the cache with our own image under the exact keys the timeline
        // cell + full-screen viewer will request. A freshly-uploaded mxc often
        // 404s on the thumbnail endpoint for a moment, so without this our own
        // sent photo shows as a blank bubble until the server catches up. Now it
        // renders instantly and never triggers a redundant download.
        let (reqW, reqH) = ImageEventCell.thumbnailRequestSize(imageWidth: Int(image.size.width),
                                                               imageHeight: Int(image.size.height))
        MediaCache.shared.storeThumbnail(image, mxc: mxc, width: reqW, height: reqH)
        MediaCache.shared.storeFull(image, mxc: mxc)

        client.put(path, body: body) { [weak self] _, error in
            guard let self = self else { return }
            self.setSending(false)
            if let error = error { self.showSendError(error) }
        }
    }

    // MARK: - Video attach / upload / send

    // Dimensions and duration pulled off the picked file for the event's `info`.
    private struct VideoMeta {
        let width: Int
        let height: Int
        let durationMs: Int
    }

    // The upload path holds the whole file in memory, and libcurl copies the body
    // again (CURLOPT_COPYPOSTFIELDS), so peak use is roughly twice the file size.
    // Past this cap a 4S risks a low-memory kill, which is worse than refusing —
    // so oversized clips get an alert. A streaming upload would lift the limit.
    private static let maxVideoUploadBytes = 16 * 1024 * 1024

    // DIAGNOSTIC: video send/render is invisible on device (no console), and the
    // remux falls back silently by design, so leave a breadcrumb trail in
    // UserDefaults for Settings → Diagnostics to show. Remove once confirmed.
    static let videoTraceKey = "elementold.videoTrace"
    private static var tracedVideoRows = Set<String>()
    static func videoTrace(_ line: String) {
        let defaults = UserDefaults.standard
        var lines = defaults.stringArray(forKey: videoTraceKey) ?? []
        lines.append(line)
        if lines.count > 10 { lines.removeFirst(lines.count - 10) }
        defaults.set(lines, forKey: videoTraceKey)
        defaults.synchronize()
    }

    private func uploadAndSendVideo(atPath path: String) {
        guard !isSending else { return }
        // Video replies aren't supported yet, so clear any queued reply rather than
        // leaving the strip up over a send that won't carry the relation.
        endReply()
        // Locked before the export starts, so a second pick can't race it.
        setSending(true)
        remuxToMP4(path: path) { [weak self] preparedPath, isTemporary in
            self?.uploadPreparedVideo(atPath: preparedPath, temporary: isTemporary)
        }
    }

    // The camera and library hand us QuickTime (.mov). mautrix-whatsapp re-encodes
    // whatever it gets, but mautrix-meta passes the bytes through untouched, and
    // Messenger then won't play a .mov — so rewrap into MP4 first. Passthrough means
    // no re-encode: the tracks are copied, so it's fast and lossless. When it isn't
    // available for this asset we send the original unchanged rather than fail.
    private func remuxToMP4(path: String, completion: @escaping (String, Bool) -> Void) {
        RoomTimelineVC.videoTrace("pick .\(RoomTimelineVC.videoExtension(of: path))")
        guard RoomTimelineVC.videoExtension(of: path) != "mp4" else {
            RoomTimelineVC.videoTrace("remux skip: already mp4")
            completion(path, false)
            return
        }
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        // Deliberately NOT gated on exportPresets(compatibleWith:) — that call never
        // lists passthrough, so gating on it skipped the remux every time. The real
        // test is whether the session can write MP4: a passthrough session only
        // rewraps into containers its tracks already fit, and setting an unsupported
        // outputFileType raises, so this must be checked before assigning it.
        guard let session = AVAssetExportSession(asset: asset,
                                                 presetName: AVAssetExportPresetPassthrough),
              session.supportedFileTypes.contains(.mp4) else {
            RoomTimelineVC.videoTrace("remux skip: mp4 unsupported")
            completion(path, false)
            return
        }
        // Unique name: the export refuses to write over an existing file. NSString
        // path append — URL.appendingPathComponent hangs on this runtime.
        let name = "elementold-remux-\(Int64(Date().timeIntervalSince1970 * 1000)).mp4"
        let outPath = (NSTemporaryDirectory() as NSString).appendingPathComponent(name)
        session.outputURL = URL(fileURLWithPath: outPath)
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        session.exportAsynchronously {
            // AVFoundation calls back off the main thread, unlike CurlFetcher.
            DispatchQueue.main.async {
                guard session.status == .completed else {
                    let reason = (session.error as NSError?).map { "\($0.domain) \($0.code)" } ?? "none"
                    RoomTimelineVC.videoTrace("remux failed: status=\(session.status.rawValue) err=\(reason)")
                    try? FileManager.default.removeItem(atPath: outPath)
                    completion(path, false)
                    return
                }
                RoomTimelineVC.videoTrace("remux ok -> mp4")
                completion(outPath, true)
            }
        }
    }

    private func uploadPreparedVideo(atPath path: String, temporary: Bool) {
        // Stat before reading: an oversized file must never be loaded at all. This
        // checks the prepared file, which is the one that actually lands in memory.
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let sizeBytes = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        guard sizeBytes > 0 else {
            failVideoSend(title: "Couldn't read video",
                          message: "The picked video couldn't be opened.",
                          temporaryPath: temporary ? path : nil)
            return
        }
        let cap = RoomTimelineVC.maxVideoUploadBytes
        guard sizeBytes <= cap else {
            failVideoSend(title: "Video too large",
                          message: String(format: "That video is %.1f MB. The limit is %d MB — try a shorter clip.",
                                          Double(sizeBytes) / (1024 * 1024), cap / (1024 * 1024)),
                          temporaryPath: temporary ? path : nil)
            return
        }

        let meta = videoMeta(path: path)
        let ext = RoomTimelineVC.videoExtension(of: path)
        let mime = RoomTimelineVC.videoMimeType(extension: ext)
        let filename = "elementold-\(Int64(Date().timeIntervalSince1970 * 1000)).\(ext)"
        RoomTimelineVC.videoTrace("send \(mime) \(sizeBytes / 1024)KB \(meta.width)x\(meta.height)")

        // Poster frame first: it goes out before the video so the big Data isn't
        // resident while a second request is in flight, and the event can then
        // carry thumbnail_url (without it other clients show a bare filename).
        uploadVideoThumbnail(path: path) { [weak self] thumbMxc, thumbInfo, thumbImage in
            guard let self = self else { return }
            let data = FileManager.default.contents(atPath: path)
            // Earliest safe point to drop the remux output: the bytes are in memory
            // now, so no later path has to remember to clean up.
            if temporary { try? FileManager.default.removeItem(atPath: path) }
            guard let data = data else {
                self.failVideoSend(title: "Couldn't read video",
                                   message: "The picked video couldn't be opened.",
                                   temporaryPath: nil)
                return
            }
            self.client.uploadMedia(data: data, filename: filename, mimeType: mime) { json, error in
                guard let mxc = json?["content_uri"] as? String else {
                    self.setSending(false)
                    self.showSendError(error ?? MatrixAPIClient.MatrixError(errcode: "M_UNKNOWN",
                                                                            error: "Upload returned no content_uri"))
                    return
                }
                self.sendVideoMessage(mxc: mxc, filename: filename, mimeType: mime,
                                      size: data.count, meta: meta,
                                      thumbMxc: thumbMxc, thumbInfo: thumbInfo, thumbImage: thumbImage)
            }
        }
    }

    private func failVideoSend(title: String, message: String, temporaryPath: String?) {
        if let temporaryPath = temporaryPath { try? FileManager.default.removeItem(atPath: temporaryPath) }
        setSending(false)
        showAlert(title: title, message: message)
    }

    private func sendVideoMessage(mxc: String, filename: String, mimeType: String, size: Int,
                                  meta: VideoMeta, thumbMxc: String?, thumbInfo: [String: Any]?,
                                  thumbImage: UIImage?) {
        let path = "/_matrix/client/v3/rooms/\(room.roomId)/send/m.room.message/\(newTxnId())"
        // Only send fields we actually resolved — a zero width or duration is worse
        // than an absent one, since receivers lay out from whatever we advertise.
        var info: [String: Any] = ["mimetype": mimeType, "size": size]
        if meta.width > 0 { info["w"] = meta.width }
        if meta.height > 0 { info["h"] = meta.height }
        if meta.durationMs > 0 { info["duration"] = meta.durationMs }
        if let thumbMxc = thumbMxc {
            info["thumbnail_url"] = thumbMxc
            if let thumbInfo = thumbInfo { info["thumbnail_info"] = thumbInfo }
        }
        let body: [String: Any] = ["msgtype": "m.video", "body": filename, "url": mxc, "info": info]
        // Prime the cache with the poster we already have, under the exact key our
        // own row will ask for: a just-uploaded mxc 404s on the thumbnail endpoint
        // for a moment, which would otherwise leave our bubble grey (same fix as
        // sendImageMessage).
        if let thumbMxc = thumbMxc, let thumbImage = thumbImage {
            let (reqW, reqH) = ImageEventCell.thumbnailRequestSize(imageWidth: meta.width,
                                                                  imageHeight: meta.height)
            MediaCache.shared.storeThumbnail(thumbImage, mxc: thumbMxc, width: reqW, height: reqH)
        }
        client.put(path, body: body) { [weak self] _, error in
            guard let self = self else { return }
            self.setSending(false)
            if let error = error { self.showSendError(error) }
        }
    }

    // Always calls back: a nil mxc just means the video sends without a preview,
    // which is much better than failing the whole send over a poster frame. The
    // image comes back too, so the caller can prime the cache with it.
    private func uploadVideoThumbnail(path: String,
                                      completion: @escaping (String?, [String: Any]?, UIImage?) -> Void) {
        guard let thumb = videoThumbnail(path: path),
              let data = thumb.jpegData(compressionQuality: 0.7) else {
            completion(nil, nil, nil)
            return
        }
        let filename = "elementold-thumb-\(Int64(Date().timeIntervalSince1970 * 1000)).jpg"
        client.uploadMedia(data: data, filename: filename, mimeType: "image/jpeg") { json, _ in
            guard let mxc = json?["content_uri"] as? String, !mxc.isEmpty else {
                completion(nil, nil, nil)
                return
            }
            completion(mxc, ["mimetype": "image/jpeg",
                             "w": Int(thumb.size.width),
                             "h": Int(thumb.size.height),
                             "size": data.count], thumb)
        }
    }

    private func videoThumbnail(path: String) -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: path)))
        // Without this a clip recorded in portrait comes out sideways.
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 800, height: 800)
        // Half a second in: the first frame of a recording is often black.
        let time = CMTimeMakeWithSeconds(0.5, preferredTimescale: 600)
        guard let cg = try? generator.copyCGImage(at: time, actualTime: nil) else { return nil }
        return UIImage(cgImage: cg)
    }

    private func videoMeta(path: String) -> VideoMeta {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let seconds = CMTimeGetSeconds(asset.duration)
        let durationMs = (seconds.isFinite && seconds > 0) ? Int(seconds * 1000) : 0
        var width = 0
        var height = 0
        if let track = asset.tracks(withMediaType: .video).first {
            // naturalSize ignores the rotation held in the track transform, so a
            // portrait clip would otherwise be advertised as landscape.
            let size = track.naturalSize.applying(track.preferredTransform)
            width = Int(abs(size.width))
            height = Int(abs(size.height))
        }
        return VideoMeta(width: width, height: height, durationMs: durationMs)
    }

    // The picker hands back .MOV on iOS 6-9; keep the real extension so receivers
    // can infer the type from the filename when they ignore `info.mimetype`.
    private static func videoExtension(of path: String) -> String {
        let ext = fileExtension(of: path)
        return ["mov", "mp4", "m4v", "3gp"].contains(ext) ? ext : "mov"
    }

    private static func videoMimeType(extension ext: String) -> String {
        switch ext {
        case "mp4", "m4v": return "video/mp4"
        case "3gp": return "video/3gpp"
        default: return "video/quicktime"
        }
    }

    // MARK: - Voice message record / upload / send

    // Swaps the input bar into voice mode: field/attach hidden, Cancel + Record
    // shown alongside the existing Send button (Send stays disabled until a
    // recording exists). No mic-permission prompt here on purpose —
    // `requestRecordPermission` is an iOS 7+ selector (crash risk on the iOS 6
    // runtime); iOS 7-9 auto-prompt on record start and iOS 6 needs no prompt.
    private func enterVoiceMode() {
        guard inputMode == .text else { return }
        // Replying is a text-mode action, so drop any queued reply rather than
        // leave the strip claiming a voice note will answer it.
        endReply()
        inputMode = .voice
        messageField.resignFirstResponder()
        voiceHasRecording = false
        voiceIsRecording = false
        voiceRecordSeconds = 0
        updateVoiceRecordButton()
        sendButton.isEnabled = false
        currentFieldHeight = inputMinHeight
        layoutInputBar()
    }

    private func exitVoiceMode() {
        cleanUpRecording(deleteFile: true)
        inputMode = .text
        sendButton.isEnabled = true
        sendButton.setTitle("Send", for: .normal)
        placeholderLabel.isHidden = !(messageField.text ?? "").isEmpty
        layoutInputBar()
    }

    @objc private func voiceCancelTapped() {
        exitVoiceMode()
    }

    @objc private func voiceRecordTapped() {
        if voiceIsRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        // `requestRecordPermission:` is an iOS 7+ selector — guarded by
        // responds(to:) so it's never sent on iOS 6 (which has no microphone
        // permission system and needs none; we just begin directly there).
        let session = AVAudioSession.sharedInstance()
        let permSel = NSSelectorFromString("requestRecordPermission:")
        if session.responds(to: permSel) {
            session.requestRecordPermission { [weak self] granted in
                // The callback may arrive off the main thread — hop back before
                // touching AVAudioRecorder / UIKit.
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if granted {
                        self.beginRecording()
                    } else {
                        self.showSendError(MatrixAPIClient.MatrixError(errcode: "M_FORBIDDEN",
                            error: "Microphone access denied. Enable it in Settings > Privacy."))
                    }
                }
            }
        } else {
            beginRecording()
        }
    }

    private func beginRecording() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord)
            try session.setActive(true)
        } catch {
            showSendError(MatrixAPIClient.MatrixError(errcode: "M_UNKNOWN",
                                                      error: "Could not start audio session"))
            return
        }
        // AAC .m4a — plays back on other Matrix clients, needs no Info.plist
        // mic-usage key on iOS 6-9 (that requirement is iOS 10+). Int64 for the
        // epoch-ms filename (32-bit Int would trap on armv7).
        let name = "elementold-voice-\(Int64(Date().timeIntervalSince1970 * 1000)).m4a"
        // Build the path with the pure ObjC NSString method, NOT
        // URL(fileURLWithPath:).appendingPathComponent(_:): the URL variant does a
        // filesystem stat to decide the trailing slash, which wedges (hangs) on the
        // swapped 5.1.5 runtime (same hanging-URL-API class as Data.write(to:)).
        // NSString's appendingPathComponent is a plain string op — no stat, safe.
        let dir = NSTemporaryDirectory() as NSString
        let url = URL(fileURLWithPath: dir.appendingPathComponent(name))
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 22050.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]
        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            recorder.record()
            audioRecorder = recorder
            voiceRecordingURL = url
            voiceIsRecording = true
            voiceRecordSeconds = 0
            voiceRecordTimer = Timer.scheduledTimer(timeInterval: 1.0, target: self,
                                                    selector: #selector(voiceRecordTick),
                                                    userInfo: nil, repeats: true)
            updateVoiceRecordButton()
        } catch {
            showSendError(MatrixAPIClient.MatrixError(errcode: "M_UNKNOWN",
                                                      error: "Could not start recording"))
        }
    }

    private func stopRecording() {
        audioRecorder?.stop()
        voiceRecordTimer?.invalidate()
        voiceRecordTimer = nil
        voiceIsRecording = false
        try? AVAudioSession.sharedInstance().setActive(false)
        voiceHasRecording = voiceRecordSeconds > 0
        sendButton.isEnabled = voiceHasRecording
        updateVoiceRecordButton()
    }

    @objc private func voiceRecordTick() {
        voiceRecordSeconds += 1
        updateVoiceRecordButton()
    }

    private func updateVoiceRecordButton() {
        guard voiceRecordButton != nil else { return }
        let title: String
        if voiceIsRecording {
            title = "\u{25A0} Stop \u{00B7} \(voiceDurationString(voiceRecordSeconds))"
        } else if voiceHasRecording {
            title = "\u{25CF} Re-record \u{00B7} \(voiceDurationString(voiceRecordSeconds))"
        } else {
            title = "\u{25CF} Record"
        }
        voiceRecordButton.setTitle(title, for: .normal)
    }

    private func voiceDurationString(_ seconds: Int) -> String {
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    // Stops any active recording, kills the timer, deactivates the audio session,
    // optionally deletes the temp file, and resets voice state.
    private func cleanUpRecording(deleteFile: Bool) {
        if voiceIsRecording {
            audioRecorder?.stop()
        }
        voiceRecordTimer?.invalidate()
        voiceRecordTimer = nil
        try? AVAudioSession.sharedInstance().setActive(false)
        if deleteFile, let url = voiceRecordingURL {
            try? FileManager.default.removeItem(atPath: url.path)
        }
        audioRecorder = nil
        voiceRecordingURL = nil
        voiceIsRecording = false
        voiceHasRecording = false
        voiceRecordSeconds = 0
    }

    private func sendVoiceMessage() {
        guard voiceHasRecording, !voiceIsRecording, !isSending,
              let url = voiceRecordingURL,
              // Path-based read, NOT Data(contentsOf:) — the URL-based Data API
              // hangs on the swapped 5.1.5 runtime (same rule as MediaCache).
              let data = FileManager.default.contents(atPath: url.path) else { return }
        let seconds = voiceRecordSeconds
        let filename = url.lastPathComponent
        setSending(true)
        client.uploadMedia(data: data, filename: filename, mimeType: "audio/mp4") { [weak self] json, error in
            guard let self = self else { return }
            guard let mxc = json?["content_uri"] as? String else {
                self.setSending(false)
                self.showSendError(error ?? MatrixAPIClient.MatrixError(errcode: "M_UNKNOWN",
                                                                        error: "Upload returned no content_uri"))
                return
            }
            // Prime the cache with our own recording so it plays instantly and
            // never re-downloads (a fresh mxc can 404 on download briefly).
            MediaCache.shared.storeAudioFile(fromPath: url.path, mxc: mxc)
            self.sendAudioEvent(mxc: mxc, size: data.count, seconds: seconds, filename: filename)
        }
    }

    private func sendAudioEvent(mxc: String, size: Int, seconds: Int, filename: String) {
        let path = "/_matrix/client/v3/rooms/\(room.roomId)/send/m.room.message/\(newTxnId())"
        let info: [String: Any] = ["mimetype": "audio/mp4",
                                    "size": size,
                                    "duration": seconds * 1000]
        let body: [String: Any] = ["msgtype": "m.audio",
                                    "body": "Voice message \u{00B7} \(voiceDurationString(seconds))",
                                    "url": mxc,
                                    "info": info]
        client.put(path, body: body) { [weak self] _, error in
            guard let self = self else { return }
            self.setSending(false)
            if let error = error {
                self.showSendError(error)
            } else {
                self.exitVoiceMode()
            }
        }
    }

    // MARK: - Voice message playback

    // Play/pause the voice message for `mxc`. Tapping the currently-playing bubble
    // pauses it; tapping any bubble starts it (stopping whatever was playing).
    private func toggleAudio(mxc: String, durationMs: Int) {
        if playingAudioMxc == mxc, let player = audioPlayer {
            if player.isPlaying {
                player.pause()
                stopAudioProgressTimer()
            } else {
                startPlaybackSession()
                player.play()
                startAudioProgressTimer()
            }
            refreshAudioCells()
            return
        }
        // Different (or first) bubble: tear down any current player, then load.
        stopAudioPlayback()
        MediaCache.shared.loadAudioPath(mxc: mxc) { [weak self] path in
            guard let self = self else { return }
            guard let path = path else {
                self.showSendError(MatrixAPIClient.MatrixError(errcode: "M_UNKNOWN",
                    error: "Could not load voice message"))
                return
            }
            self.startPlaybackSession()
            do {
                let player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
                player.delegate = self
                player.prepareToPlay()
                self.audioPlayer = player
                self.playingAudioMxc = mxc
                player.play()
                self.startAudioProgressTimer()
                self.refreshAudioCells()
            } catch {
                self.showSendError(MatrixAPIClient.MatrixError(errcode: "M_UNKNOWN",
                    error: "Could not play voice message"))
            }
        }
    }

    // Playback needs an audible category (the default respects the silent switch);
    // wrapped in try? — a failure here shouldn't block playback attempts.
    private func startPlaybackSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback)
        try? session.setActive(true)
    }

    private func stopAudioPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        playingAudioMxc = nil
        stopAudioProgressTimer()
    }

    private func startAudioProgressTimer() {
        stopAudioProgressTimer()
        audioProgressTimer = Timer.scheduledTimer(timeInterval: 0.2, target: self,
                                                  selector: #selector(audioProgressTick),
                                                  userInfo: nil, repeats: true)
    }

    private func stopAudioProgressTimer() {
        audioProgressTimer?.invalidate()
        audioProgressTimer = nil
    }

    @objc private func audioProgressTick() {
        refreshAudioCells()
    }

    // Pushes the current playback state onto whichever visible audio cell matches
    // the playing mxc (and clears state on all others).
    private func refreshAudioCells() {
        let current = audioPlayer?.currentTime ?? 0
        let duration = audioPlayer?.duration ?? 0
        let playing = audioPlayer?.isPlaying ?? false
        for cell in tableView.visibleCells {
            guard let audioCell = cell as? AudioEventCell else { continue }
            if audioCell.mxc == playingAudioMxc {
                audioCell.setPlaybackState(playing: playing, currentTime: current, duration: duration)
            } else {
                audioCell.setPlaybackState(playing: false, currentTime: 0, duration: audioCell.declaredDuration)
            }
        }
    }

    private func downscale(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxDimension else { return image }
        let scale = maxDimension / longest
        let newSize = CGSize(width: floor(image.size.width * scale), height: floor(image.size.height * scale))
        UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
        image.draw(in: CGRect(origin: .zero, size: newSize))
        let result = UIGraphicsGetImageFromCurrentImageContext() ?? image
        UIGraphicsEndImageContext()
        return result
    }

    // MARK: - Attachment downloads

    private func handleFileTap(mxc: String, filename: String, mimeType: String) {
        if let path = MediaCache.shared.downloadedFilePath(mxc: mxc, filename: filename, mimeType: mimeType) {
            openDownloadedFile(path: path, filename: filename, mimeType: mimeType)
            return
        }
        guard fileProgress[mxc] == nil else { return }   // already downloading

        fileProgress[mxc] = 0
        visibleAttachmentCell(for: mxc)?.setProgress(0)
        MediaCache.shared.downloadFile(mxc: mxc, filename: filename, mimeType: mimeType,
                                       progress: { [weak self] fraction in
            guard let self = self else { return }
            // Only repaint on a whole-percent change — curl reports progress far
            // more often than the label can meaningfully change.
            let previous = self.fileProgress[mxc] ?? -1
            guard Int(fraction * 100) != Int(previous * 100) else { return }
            self.fileProgress[mxc] = fraction
            self.visibleAttachmentCell(for: mxc)?.setProgress(fraction)
        }) { [weak self] path in
            guard let self = self else { return }
            self.fileProgress.removeValue(forKey: mxc)
            let cell = self.visibleAttachmentCell(for: mxc)
            if let path = path {
                cell?.markDownloaded()
                // The download was started by an explicit tap, so open it right
                // away — unless the timeline has since been dismissed, in which
                // case presenting anything would be presenting off-screen.
                if self.view.window != nil {
                    self.openDownloadedFile(path: path, filename: filename, mimeType: mimeType)
                }
            } else {
                cell?.setProgress(nil)
                self.showAlert(title: "Download failed", message: filename)
            }
        }
    }

    // MARK: - Opening a downloaded attachment

    private func openDownloadedFile(path: String, filename: String, mimeType: String) {
        if isVideo(filename: filename, mimeType: mimeType) {
            playVideo(path: path)
            return
        }
        // Quick Look renders plain text unreliably on this OS — it can sit on a
        // spinner forever instead of failing — so show text ourselves.
        if isText(filename: filename, mimeType: mimeType) {
            let viewer = TextFileViewerVC(path: path, filename: filename)
            navigationController?.pushViewController(viewer, animated: true)
            return
        }
        // UIDocumentInteractionController (iOS 3.2+) gives us Quick Look preview
        // for the formats iOS knows (PDF, images, text, iWork/Office docs) and an
        // "Open in…" hand-off to another app for everything else.
        let controller = UIDocumentInteractionController(url: URL(fileURLWithPath: path))
        controller.delegate = self
        controller.name = filename          // preview title shows the real filename
        docController = controller
        if controller.presentPreview(animated: true) { return }
        if controller.presentOpenInMenu(from: view.bounds, in: view, animated: true) { return }
        docController = nil
        showAlert(title: "Can't open",
                      message: "No app on this device can open \(filename). It's saved at:\n\n\(path)")
    }

    private func playVideo(path: String) {
        // MPMoviePlayerViewController is the only full-screen player available on
        // iOS 6 (AVPlayerViewController is iOS 8+).
        guard let player = MPMoviePlayerViewController(contentURL: URL(fileURLWithPath: path)) else { return }
        moviePlayerVC = player
        present(player, animated: true, completion: nil)
    }

    // Quick Look can stumble on video, and a movie is better served by a real
    // player anyway, so route it away from the preview path. Falls back to the
    // filename extension when the sender omitted `info.mimetype`.
    private func isVideo(filename: String, mimeType: String) -> Bool {
        if mimeType.hasPrefix("video/") { return true }
        guard mimeType.isEmpty else { return false }
        let ext = RoomTimelineVC.fileExtension(of: filename)
        return ext == "mp4" || ext == "mov" || ext == "m4v" || ext == "3gp" || ext == "avi"
    }

    private func isText(filename: String, mimeType: String) -> Bool {
        // text/html is deliberately excluded: Quick Look renders it as a page,
        // which is more useful than showing the markup.
        if mimeType.hasPrefix("text/") && mimeType != "text/html" { return true }
        if mimeType == "application/json" || mimeType == "application/xml" { return true }
        guard mimeType.isEmpty else { return false }
        let ext = RoomTimelineVC.fileExtension(of: filename)
        return ext == "txt" || ext == "log" || ext == "md" || ext == "csv"
            || ext == "json" || ext == "xml"
    }

    private static func fileExtension(of filename: String) -> String {
        guard let dot = filename.lastIndex(of: "."),
              dot < filename.index(before: filename.endIndex) else { return "" }
        return String(filename[filename.index(after: dot)...]).lowercased()
    }

    private func visibleAttachmentCell(for mxc: String) -> AttachmentProgressCell? {
        for cell in tableView.visibleCells {
            if let attachment = cell as? AttachmentProgressCell, attachment.mxc == mxc { return attachment }
        }
        return nil
    }

    private func showAlert(title: String, message: String) {
#if IOS6_TARGET
        let alert = UIAlertView()
        alert.title = title
        alert.message = message
        alert.addButton(withTitle: "OK")
        alert.show()
#else
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        present(alert, animated: true)
#endif
    }

    private func openImageViewer(mxc: String, placeholder: UIImage?) {
        let viewer = ImageViewerVC(mxc: mxc, placeholder: placeholder)
        navigationController?.pushViewController(viewer, animated: true)
    }

    private func showSendError(_ error: Error) {
#if IOS6_TARGET
        let alert = UIAlertView()
        alert.title = "Send failed"
        alert.message = "\(error)"
        alert.addButton(withTitle: "OK")
        alert.show()
#else
        let alert = UIAlertController(title: "Send failed", message: "\(error)", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
#endif
    }

    // MARK: - Keyboard avoidance

    private func registerKeyboardObservers() {
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillShow(_:)),
            name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    @objc private func keyboardWillShow(_ notification: Notification) {
        guard let keyboardFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        keyboardHeight = keyboardFrame.height
        UIView.animate(withDuration: duration) {
            self.layoutInputBar()
        }
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        keyboardHeight = 0
        UIView.animate(withDuration: duration) {
            self.layoutInputBar()
        }
    }
}

extension RoomTimelineVC: UITableViewDataSource, UITableViewDelegate, UIGestureRecognizerDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return rows.count
    }

    // Manual row-height calculation for multi-line message bodies.
    // UITableView.automaticDimension is iOS 8+ only; without this, the default
    // fixed row height clipped wrapped text, which both rendered messages
    // outside their cell (overlapping neighboring rows) and threw off the
    // table's computed contentSize, making scrolling look "blocked" (there was
    // more rendered content on screen than the table thought existed).
    // Uses UILabel.sizeThatFits (a core UIView method, present since iOS 2)
    // rather than any Foundation string-measuring API, since those have
    // repeatedly turned out to be iOS 7+-only selectors on this legacy runtime.
    // Numbers here must stay in sync with EventCell's own layoutSubviews (kept
    // as EventCell.* static constants for exactly that reason).
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return rowHeight(rows[indexPath.row], width: tableView.bounds.width)
    }

    private func rowHeight(_ row: Row, width: CGFloat) -> CGFloat {
        switch row {
        case .date:
            return EventCell.dateRowHeight
        case .receipt:
            return 18
        case .reactions(let reactionRow):
            return ReactionsCell.height(items: reactionRow.items, width: width)
        case .event(let eventRow):
            switch eventRow.event.kind {
            case .message:
                let text = bodyText(for: eventRow)
                let maxBubbleWidth = width * EventCell.bubbleWidthFraction
                let bodyWidth = maxBubbleWidth - EventCell.innerPadding * 2
                let bodyHeight = textHeight(text, font: UIFont.systemFont(ofSize: 15), width: bodyWidth)
                let quoteBlock: CGFloat = replyPreview(for: eventRow.event) != nil
                    ? EventCell.quoteHeight + EventCell.quoteGap : 0
                let bubbleHeight = quoteBlock + bodyHeight + EventCell.innerPadding * 2
                let hasMeta = hasMetaHeader(eventRow)
                let metaBlock: CGFloat = hasMeta ? EventCell.metaHeight + EventCell.metaGap : 0
                let topMargin = hasMeta ? EventCell.topMargin : EventCell.groupedTopMargin
                return topMargin + metaBlock + bubbleHeight + EventCell.bottomMargin
            case .image(_, _, _, let w, let h):
                let maxBubbleWidth = width * EventCell.bubbleWidthFraction
                let imageSize = ImageEventCell.displaySize(imageWidth: w, imageHeight: h, maxWidth: maxBubbleWidth)
                let hasMeta = hasMetaHeader(eventRow)
                let metaBlock: CGFloat = hasMeta ? EventCell.metaHeight + EventCell.metaGap : 0
                let topMargin = hasMeta ? EventCell.topMargin : EventCell.groupedTopMargin
                return topMargin + metaBlock + imageSize.height + EventCell.bottomMargin
            case .audio:
                let hasMeta = hasMetaHeader(eventRow)
                let metaBlock: CGFloat = hasMeta ? EventCell.metaHeight + EventCell.metaGap : 0
                let topMargin = hasMeta ? EventCell.topMargin : EventCell.groupedTopMargin
                return topMargin + metaBlock + AudioEventCell.bubbleHeight + EventCell.bottomMargin
            case .file:
                let hasMeta = hasMetaHeader(eventRow)
                let metaBlock: CGFloat = hasMeta ? EventCell.metaHeight + EventCell.metaGap : 0
                let topMargin = hasMeta ? EventCell.topMargin : EventCell.groupedTopMargin
                return topMargin + metaBlock + FileEventCell.bubbleHeight + EventCell.bottomMargin
            case .video(_, let video):
                let maxBubbleWidth = width * EventCell.bubbleWidthFraction
                let posterSize = ImageEventCell.displaySize(imageWidth: video.width,
                                                            imageHeight: video.height,
                                                            maxWidth: maxBubbleWidth)
                let hasMeta = hasMetaHeader(eventRow)
                let metaBlock: CGFloat = hasMeta ? EventCell.metaHeight + EventCell.metaGap : 0
                let topMargin = hasMeta ? EventCell.topMargin : EventCell.groupedTopMargin
                return topMargin + metaBlock + posterSize.height + EventCell.bottomMargin
            case .membership:
                return 30
            case .reaction, .redaction, .edit:
                // Folded into the event they relate to / consumed by
                // rebuildRows; never reaches the table as an event row.
                return 0
            }
        }
    }

    // The meta header shown above the first bubble of a group is just the
    // sender name now — the per-message timestamp is hidden by default and
    // revealed on swipe (see EventCell). Own messages and emotes get no header
    // (the former are obviously the local user's; the latter name the sender
    // inline in the body).
    private func metaText(sender: String, isOwn: Bool, isEmote: Bool) -> String? {
        if isOwn || isEmote { return nil }
        // Show the member's display name (from m.room.member state/timeline,
        // seeded into memberNames), falling back to the localpart of the Matrix
        // ID ("@alice:server" -> "alice") when we have no display name yet —
        // never the raw Matrix identifier.
        return memberNames[sender] ?? shortName(sender)
    }

    // Whether the row actually draws a meta header. The cells lay themselves out
    // from `meta != nil`, not from showMeta, and metaText returns nil for own
    // messages and emotes — so a height computed off showMeta alone reserved
    // metaHeight + metaGap (plus the taller group-start top margin) for a header
    // that never got drawn, leaving an empty gap above every own group-start.
    private func hasMetaHeader(_ eventRow: EventRow) -> Bool {
        guard eventRow.showMeta else { return false }
        switch eventRow.event.kind {
        case .message(let sender, _, let isEmote):
            return metaText(sender: sender, isOwn: sender == MatrixSession.userId,
                            isEmote: isEmote) != nil
        case .image(let sender, _, _, _, _),
             .audio(let sender, _, _, _),
             .file(let sender, _, _, _, _),
             .video(let sender, _):
            return metaText(sender: sender, isOwn: sender == MatrixSession.userId,
                            isEmote: false) != nil
        case .membership, .reaction, .redaction, .edit:
            return false
        }
    }

    // The text a message bubble actually shows: the replacement when the message
    // has been edited (plus an "(edited)" marker), with the sender's display
    // name folded into an emote. Shared by rowHeight and cellForRowAt so the
    // measured height and the drawn text can never disagree.
    private func bodyText(for eventRow: EventRow) -> String {
        guard case .message(let sender, let body, let isEmote) = eventRow.event.kind else { return "" }
        var text = eventRow.editedBody ?? body
        if isEmote { text = "* \(memberNames[sender] ?? shortName(sender)) \(text)" }
        if eventRow.editedBody != nil { text += " (edited)" }
        return text
    }

    // The one-line "Alice: original message" quote drawn inside the bubble above
    // a reply. Prefers the real target event when we've loaded it; otherwise
    // falls back to the quote the sender embedded in the reply fallback, which
    // is all we have when the target is older than our loaded history.
    private func replyPreview(for event: RoomEvent) -> String? {
        guard let target = event.replyTo else { return nil }
        if let source = eventsById[target], let sender = RoomTimelineVC.senderOf(source),
           let text = RoomTimelineVC.previewText(for: source) {
            let name = memberNames[sender] ?? shortName(sender)
            return "\(name): \(text)"
        }
        guard let quote = event.replyQuote else { return nil }
        if let author = event.replyAuthor {
            return "\(memberNames[author] ?? shortName(author)): \(quote)"
        }
        return quote
    }

    // One-line description of a message for a reply quote: its own text, or a
    // short label standing in for a non-text attachment. Shared by the in-bubble
    // quote line and the composer's "Replying to …" strip so they always agree.
    private static func previewText(for event: RoomEvent) -> String? {
        switch event.kind {
        case .message(_, let body, _): return body
        case .image: return "Photo"
        case .audio: return "Voice message"
        case .file(_, _, let filename, _, _): return filename
        case .video: return "Video"
        default: return nil
        }
    }

    private func textHeight(_ text: String, font: UIFont, width: CGFloat) -> CGFloat {
        let label = UILabel()
        label.font = font
        label.numberOfLines = 0
        label.text = text
        let size = label.sizeThatFits(CGSize(width: max(1, width), height: .greatestFiniteMagnitude))
        return ceil(size.height)
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch rows[indexPath.row] {
        case .date(let text):
            let cell = tableView.dequeueReusableCell(withIdentifier: dateCellId) ??
                UITableViewCell(style: .default, reuseIdentifier: dateCellId)
            cell.backgroundColor = .clear
            cell.contentView.backgroundColor = .clear
            cell.textLabel?.backgroundColor = .clear   // iOS 6: labels default to white bg
            cell.selectionStyle = .none
            cell.textLabel?.font = UIFont.boldSystemFont(ofSize: 12)
            cell.textLabel?.textColor = .gray
            cell.textLabel?.textAlignment = .center
            cell.textLabel?.text = text
            return cell

        case .receipt(let text):
            let cell = tableView.dequeueReusableCell(withIdentifier: "ReceiptCell") ??
                UITableViewCell(style: .default, reuseIdentifier: "ReceiptCell")
            cell.backgroundColor = .clear
            cell.contentView.backgroundColor = .clear
            cell.textLabel?.backgroundColor = .clear   // iOS 6: labels default to white bg
            cell.selectionStyle = .none
            cell.textLabel?.font = UIFont.systemFont(ofSize: 11)
            cell.textLabel?.textColor = .gray
            cell.textLabel?.textAlignment = .right
            // Sit clear of the swipe-reveal timestamp gutter on the right edge.
            cell.textLabel?.text = text + "   "
            return cell

        case .reactions(let reactionRow):
            let cell = (tableView.dequeueReusableCell(withIdentifier: reactionsCellId) as? ReactionsCell) ??
                ReactionsCell(style: .default, reuseIdentifier: reactionsCellId)
            cell.configure(items: reactionRow.items, isOwn: reactionRow.isOwn)
            cell.setRevealOffset(revealOffset)
            let target = reactionRow.targetEventId
            cell.onTapKey = { [weak self] key in self?.toggleReaction(target: target, key: key) }
            return cell

        case .event(let eventRow):
            switch eventRow.event.kind {
            case .message(let sender, _, let isEmote):
                let cell = (tableView.dequeueReusableCell(withIdentifier: cellId) as? EventCell) ??
                    EventCell(style: .default, reuseIdentifier: cellId)
                let isOwn = sender == MatrixSession.userId
                let time = TimeFormat.shortTime(msSinceEpoch: eventRow.event.timestamp)
                let meta = eventRow.showMeta
                    ? metaText(sender: sender, isOwn: isOwn, isEmote: isEmote)
                    : nil
                cell.configure(meta: meta, quote: replyPreview(for: eventRow.event),
                               body: bodyText(for: eventRow), time: time, isOwn: isOwn,
                               avatarMxc: memberAvatars[sender], senderName: memberNames[sender] ?? sender)
                cell.setRevealOffset(revealOffset)
                return cell

            case .image(let sender, _, let mxc, let w, let h):
                let cell = (tableView.dequeueReusableCell(withIdentifier: imageCellId) as? ImageEventCell) ??
                    ImageEventCell(style: .default, reuseIdentifier: imageCellId)
                let isOwn = sender == MatrixSession.userId
                let time = TimeFormat.shortTime(msSinceEpoch: eventRow.event.timestamp)
                let meta = eventRow.showMeta ? metaText(sender: sender, isOwn: isOwn, isEmote: false) : nil
                cell.configure(meta: meta, mxc: mxc, imageWidth: w, imageHeight: h, time: time, isOwn: isOwn,
                               avatarMxc: memberAvatars[sender], senderName: memberNames[sender] ?? sender)
                cell.setRevealOffset(revealOffset)
                cell.onTap = { [weak self, weak cell] in
                    self?.openImageViewer(mxc: mxc, placeholder: cell?.displayedImage)
                }
                return cell

            case .audio(let sender, let mxc, let durationMs, _):
                let cell = (tableView.dequeueReusableCell(withIdentifier: audioCellId) as? AudioEventCell) ??
                    AudioEventCell(style: .default, reuseIdentifier: audioCellId)
                let isOwn = sender == MatrixSession.userId
                let time = TimeFormat.shortTime(msSinceEpoch: eventRow.event.timestamp)
                let meta = eventRow.showMeta ? metaText(sender: sender, isOwn: isOwn, isEmote: false) : nil
                cell.configure(meta: meta, mxc: mxc, durationMs: durationMs, time: time, isOwn: isOwn,
                               avatarMxc: memberAvatars[sender], senderName: memberNames[sender] ?? sender)
                cell.setRevealOffset(revealOffset)
                cell.onPlayTap = { [weak self] in self?.toggleAudio(mxc: mxc, durationMs: durationMs) }
                // Reflect current playback state onto this (possibly recycled) cell.
                let playing = (playingAudioMxc == mxc) && (audioPlayer?.isPlaying ?? false)
                cell.setPlaybackState(playing: playing,
                                      currentTime: playing ? (audioPlayer?.currentTime ?? 0) : 0,
                                      duration: audioPlayer?.duration ?? (Double(durationMs) / 1000.0))
                return cell

            case .file(let sender, let mxc, let filename, let mimeType, let sizeBytes):
                let cell = (tableView.dequeueReusableCell(withIdentifier: fileCellId) as? FileEventCell) ??
                    FileEventCell(style: .default, reuseIdentifier: fileCellId)
                let isOwn = sender == MatrixSession.userId
                let time = TimeFormat.shortTime(msSinceEpoch: eventRow.event.timestamp)
                let meta = eventRow.showMeta ? metaText(sender: sender, isOwn: isOwn, isEmote: false) : nil
                let downloaded = MediaCache.shared.downloadedFilePath(mxc: mxc, filename: filename,
                                                                      mimeType: mimeType) != nil
                cell.configure(meta: meta, mxc: mxc, filename: filename, mimeType: mimeType,
                               sizeBytes: sizeBytes, downloaded: downloaded, time: time, isOwn: isOwn,
                               avatarMxc: memberAvatars[sender], senderName: memberNames[sender] ?? sender)
                // Reflect an in-flight download onto this (possibly recycled) cell.
                cell.setProgress(fileProgress[mxc])
                cell.setRevealOffset(revealOffset)
                cell.onTap = { [weak self] in
                    self?.handleFileTap(mxc: mxc, filename: filename, mimeType: mimeType)
                }
                return cell

            case .video(let sender, let video):
                let cell = (tableView.dequeueReusableCell(withIdentifier: videoCellId) as? VideoEventCell) ??
                    VideoEventCell(style: .default, reuseIdentifier: videoCellId)
                let isOwn = sender == MatrixSession.userId
                let time = TimeFormat.shortTime(msSinceEpoch: eventRow.event.timestamp)
                let meta = eventRow.showMeta ? metaText(sender: sender, isOwn: isOwn, isEmote: false) : nil
                let downloaded = MediaCache.shared.downloadedFilePath(mxc: video.mxc, filename: video.filename,
                                                                      mimeType: video.mimeType) != nil
                // DIAGNOSTIC: distinguishes "no video cell at all" from "video cell
                // with no poster to draw". Once per mxc — cellForRowAt runs on every
                // scroll and reload, and each trace writes UserDefaults. Remove once
                // confirmed.
                if RoomTimelineVC.tracedVideoRows.insert(video.mxc).inserted {
                    RoomTimelineVC.videoTrace("row \(video.mimeType) thumb="
                                              + (video.thumbnailMxc != nil ? "yes" : "no"))
                }
                cell.configure(meta: meta, video: video, downloaded: downloaded, time: time, isOwn: isOwn,
                               avatarMxc: memberAvatars[sender], senderName: memberNames[sender] ?? sender)
                // Reflect an in-flight download onto this (possibly recycled) cell.
                cell.setProgress(fileProgress[video.mxc])
                cell.setRevealOffset(revealOffset)
                cell.onTap = { [weak self] in
                    self?.handleFileTap(mxc: video.mxc, filename: video.filename, mimeType: video.mimeType)
                }
                return cell

            case .membership(let description):
                let cell = tableView.dequeueReusableCell(withIdentifier: membershipCellId) ??
                    UITableViewCell(style: .default, reuseIdentifier: membershipCellId)
                cell.backgroundColor = .clear
                cell.contentView.backgroundColor = .clear
                cell.textLabel?.backgroundColor = .clear   // iOS 6: labels default to white bg
                cell.selectionStyle = .none
                cell.textLabel?.font = UIFont.italicSystemFont(ofSize: 13)
                cell.textLabel?.textColor = .gray
                cell.textLabel?.textAlignment = .center
                cell.textLabel?.text = description
                return cell

            case .reaction, .redaction, .edit:
                // Never emitted as an event row (see rebuildRows) — satisfy the
                // switch without inventing a cell for it.
                return UITableViewCell(style: .default, reuseIdentifier: nil)
            }
        }
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        if indexPath.row == 0 {
            loadBackfill()
        }
    }

    // Let the reveal pan run alongside the table's own scroll pan; the handler
    // gates on horizontal movement so the two don't actually fight.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        return true
    }
}

// Chat-bubble cell (stoatold-style meta grouping): a colored, rounded rect
// message body, aligned right/blue for the local user's own messages and
// left/gray for everyone else's. A meta header line (sender name + time) sits
// *above* the bubble, but only on the first message of a consecutive same-
// sender group — subsequent messages in the run drop the header and hug the
// one above with a tighter top margin. The bubble is sized to its content
// (capped at bubbleWidthFraction of the row).
private class EventCell: UITableViewCell {
    static let outerMargin: CGFloat = 12
    static let innerPadding: CGFloat = 10
    static let bubbleWidthFraction: CGFloat = 0.75
    static let metaHeight: CGFloat = 15         // height of the meta header line
    static let metaGap: CGFloat = 2             // meta-header-to-bubble spacing
    static let quoteHeight: CGFloat = 14        // quoted-reply line inside the bubble
    static let quoteGap: CGFloat = 4            // quote-to-body spacing
    static let topMargin: CGFloat = 8           // above a group's meta header
    static let groupedTopMargin: CGFloat = 2    // above a grouped (headerless) bubble
    static let bottomMargin: CGFloat = 2        // below every bubble
    static let dateRowHeight: CGFloat = 28      // full-date separator row
    static let maxReveal: CGFloat = 62          // swipe distance that fully reveals the time
    static let avatarSize: CGFloat = 28         // sender avatar (others' group-start rows)
    static let avatarGap: CGFloat = 6           // avatar-to-bubble spacing
    // Left gutter reserved for others' messages so grouped (headerless) bubbles
    // line up under the group-start bubble that shows the avatar.
    static var senderGutter: CGFloat { return avatarSize + avatarGap }
    // Consecutive same-sender messages closer than this are grouped under one
    // meta header (5 minutes, in ms — timestamps are origin_server_ts).
    static let groupingWindowMs: Double = 5 * 60 * 1000

    private let bubble = UIView()
    private let metaLabel = UILabel()
    private let bodyLabel = UILabel()
    // The message being replied to, drawn as one truncated line at the top of
    // the bubble. Hidden unless this message is a reply.
    private let quoteLabel = UILabel()
    // Small circular sender avatar, shown at the group-start of others' messages.
    private let avatarView = AvatarView()
    // Timestamp docked at the right edge, hidden until a swipe slides the bubble
    // left to expose it (Messenger-style).
    private let revealTimeLabel = UILabel()
    private var isOwnMessage = false
    private var hasMeta = false
    private var revealOffset: CGFloat = 0

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        // UITableViewCell's contentView carries its own opaque white background
        // by default, independent of the cell's own backgroundColor — leaving
        // it unset painted a solid white rectangle behind/around the bubble
        // (visible whenever the row height is taller than the bubble itself),
        // clashing with the rounded corners instead of letting the table's
        // own background show through.
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        // On this project's iOS 6 runtime, UILabel defaults to an OPAQUE WHITE
        // background (not clear) — leaving it unset painted a white rectangle
        // over the colored bubble behind each label, which is the "white content
        // inside the bubble" bug. (Same gotcha noted in cAI's MessageCell.)
        // The meta label sits on the table's off-white canvas, above the bubble.
        metaLabel.backgroundColor = .clear
        metaLabel.font = UIFont.systemFont(ofSize: 11)
        metaLabel.textColor = .gray
        contentView.addSubview(metaLabel)

        avatarView.isHidden = true
        contentView.addSubview(avatarView)

        bubble.layer.cornerRadius = 12
        bubble.layer.masksToBounds = true   // actually clip content to the rounded rect
        contentView.addSubview(bubble)

        quoteLabel.backgroundColor = .clear
        quoteLabel.font = UIFont.systemFont(ofSize: 11)
        quoteLabel.numberOfLines = 1
        quoteLabel.lineBreakMode = .byTruncatingTail
        quoteLabel.isHidden = true
        bubble.addSubview(quoteLabel)

        bodyLabel.backgroundColor = .clear
        bodyLabel.font = UIFont.systemFont(ofSize: 15)
        bodyLabel.numberOfLines = 0
        bubble.addSubview(bodyLabel)

        revealTimeLabel.backgroundColor = .clear
        revealTimeLabel.font = UIFont.systemFont(ofSize: 11)
        revealTimeLabel.textColor = .gray
        revealTimeLabel.textAlignment = .right
        revealTimeLabel.isHidden = true
        contentView.addSubview(revealTimeLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(meta: String?, quote: String?, body: String, time: String, isOwn: Bool,
                   avatarMxc: String?, senderName: String) {
        isOwnMessage = isOwn
        hasMeta = meta != nil
        metaLabel.isHidden = !hasMeta
        metaLabel.text = meta
        metaLabel.textAlignment = isOwn ? .right : .left
        quoteLabel.isHidden = quote == nil
        quoteLabel.text = quote
        // Dimmed against whichever bubble colour it sits on, so the quote reads
        // as context rather than as part of the message.
        quoteLabel.textColor = isOwn ? UIColor(white: 1.0, alpha: 0.75)
                                     : UIColor(white: 0.35, alpha: 1.0)
        bodyLabel.text = body
        bodyLabel.textColor = isOwn ? .white : .black
        bubble.backgroundColor = isOwn ? UIColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 1.0)
                                        : UIColor(white: 0.85, alpha: 1.0)
        revealTimeLabel.text = time
        // Avatar only on others' group-start rows (own messages need no avatar;
        // grouped continuations align under the group-start bubble via the gutter).
        let showAvatar = !isOwn && hasMeta
        avatarView.isHidden = !showAvatar
        if showAvatar { avatarView.setAvatar(mxc: avatarMxc, name: senderName) }
        setNeedsLayout()
    }

    // Called during a horizontal swipe (and when a cell is (re)configured while
    // a swipe is in progress) to slide the bubble/meta left by `offset`,
    // exposing the timestamp docked at the right edge.
    func setRevealOffset(_ offset: CGFloat) {
        guard offset != revealOffset else { return }
        revealOffset = offset
        setNeedsLayout()
        layoutIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let maxBubbleWidth = contentView.bounds.width * EventCell.bubbleWidthFraction
        let maxInnerWidth = maxBubbleWidth - EventCell.innerPadding * 2
        // Measure body at the widest allowed width; sizeThatFits returns the
        // tightest width that yields the same wrapping, so the bubble can shrink
        // to fit short messages while long ones cap out.
        let bodySize = bodyLabel.sizeThatFits(CGSize(width: maxInnerWidth, height: .greatestFiniteMagnitude))
        // A quoted reply gets to widen the bubble (it truncates to one line, so
        // it can't change the height) — otherwise a one-word reply to a long
        // message would cut the quote down to nothing.
        var contentWidth = ceil(bodySize.width)
        let quoteBlock: CGFloat = quoteLabel.isHidden ? 0 : EventCell.quoteHeight + EventCell.quoteGap
        if !quoteLabel.isHidden {
            let quoteSize = quoteLabel.sizeThatFits(CGSize(width: maxInnerWidth,
                                                           height: EventCell.quoteHeight))
            contentWidth = max(contentWidth, ceil(quoteSize.width))
        }
        let innerWidth = min(contentWidth, maxInnerWidth)
        let bubbleWidth = innerWidth + EventCell.innerPadding * 2
        let bubbleHeight = quoteBlock + ceil(bodySize.height) + EventCell.innerPadding * 2

        // Others' messages are indented by the avatar gutter so grouped
        // continuations line up under the group-start bubble (which shows the
        // avatar); own messages hug the right edge with no gutter.
        let leftEdge = EventCell.outerMargin + (isOwnMessage ? 0 : EventCell.senderGutter)

        var y: CGFloat = hasMeta ? EventCell.topMargin : EventCell.groupedTopMargin
        if hasMeta {
            // Meta header spans the bubble's max width, aligned to the bubble's
            // side (right-aligned text for own messages, left for others).
            let metaX = isOwnMessage ? contentView.bounds.width - EventCell.outerMargin - maxBubbleWidth
                                     : leftEdge
            metaLabel.frame = CGRect(x: metaX - revealOffset, y: y,
                                      width: maxBubbleWidth, height: EventCell.metaHeight)
            y += EventCell.metaHeight + EventCell.metaGap
        }

        let bubbleX = isOwnMessage ? contentView.bounds.width - bubbleWidth - EventCell.outerMargin
                                    : leftEdge
        bubble.frame = CGRect(x: bubbleX - revealOffset, y: y, width: bubbleWidth, height: bubbleHeight)
        if !quoteLabel.isHidden {
            quoteLabel.frame = CGRect(x: EventCell.innerPadding, y: EventCell.innerPadding,
                                       width: innerWidth, height: EventCell.quoteHeight)
        }
        bodyLabel.frame = CGRect(x: EventCell.innerPadding,
                                  y: EventCell.innerPadding + quoteBlock,
                                  width: innerWidth, height: ceil(bodySize.height))

        // Avatar bottom-aligned with the bubble, in the left gutter.
        if !avatarView.isHidden {
            let ax = EventCell.outerMargin - revealOffset
            let ay = bubble.frame.maxY - EventCell.avatarSize
            avatarView.frame = CGRect(x: ax, y: ay, width: EventCell.avatarSize, height: EventCell.avatarSize)
        }

        // Timestamp sits in the right margin, vertically aligned with the bubble,
        // and only becomes visible once the swipe has slid content off of it.
        revealTimeLabel.frame = CGRect(x: contentView.bounds.width - EventCell.maxReveal + 2,
                                        y: bubble.frame.minY, width: EventCell.maxReveal - 8,
                                        height: bubble.frame.height)
        revealTimeLabel.isHidden = revealOffset <= 0.5
    }
}

// Image-bubble cell: an inline m.image rendered as a rounded, aspect-fit
// UIImageView sized like a text bubble (same meta header + swipe-to-reveal
// timestamp + own/other alignment as EventCell). The thumbnail is fetched
// asynchronously through MediaCache; a light-gray placeholder shows until it
// arrives. Reuse-safe: each configure() stores the mxc it's loading and the
// async completion drops any image whose mxc no longer matches (the cell was
// recycled for a different row before the download finished).
private class ImageEventCell: UITableViewCell {
    // Aspect-fit box: images scale down to fit within maxWidth x maxHeight, never
    // up (a tiny image stays tiny rather than blowing up blurry). Unknown
    // dimensions (server omitted info.w/h) fall back to a 3:2 box at maxWidth.
    static let maxHeight: CGFloat = 260
    static func displaySize(imageWidth: Int, imageHeight: Int, maxWidth: CGFloat) -> CGSize {
        var w = CGFloat(imageWidth)
        var h = CGFloat(imageHeight)
        if w <= 0 || h <= 0 {
            w = maxWidth
            h = maxWidth * 2.0 / 3.0
        }
        let scale = min(maxWidth / w, maxHeight / h, 1.0)
        return CGSize(width: max(1, floor(w * scale)), height: max(1, floor(h * scale)))
    }

    // The (width, height) a cell asks MediaCache for: ~2x the on-screen box for
    // Retina crispness. Shared so the sender can prime the cache under the exact
    // same key its own row will later request (see sendImageMessage).
    static func thumbnailRequestSize(imageWidth: Int, imageHeight: Int) -> (Int, Int) {
        let box = displaySize(imageWidth: imageWidth, imageHeight: imageHeight,
                              maxWidth: UIScreen.main.bounds.width * EventCell.bubbleWidthFraction)
        return (Int(box.width * 2), Int(box.height * 2))
    }

    private let bubble = UIView()
    private let imageView2 = UIImageView()
    private let metaLabel = UILabel()
    private let avatarView = AvatarView()
    private let revealTimeLabel = UILabel()
    private var isOwnMessage = false
    private var hasMeta = false
    private var imageWidth = 0
    private var imageHeight = 0
    private var revealOffset: CGFloat = 0
    // The mxc currently being displayed/loaded — guards against a stale async
    // download landing on a recycled cell.
    private var currentMxc: String?
    // Invoked when the image bubble is tapped (opens the full-screen viewer).
    var onTap: (() -> Void)?
    // The thumbnail currently shown, handed to the viewer as an instant
    // placeholder while the full-res download is in flight.
    var displayedImage: UIImage? { return imageView2.image }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        metaLabel.backgroundColor = .clear
        metaLabel.font = UIFont.systemFont(ofSize: 11)
        metaLabel.textColor = .gray
        contentView.addSubview(metaLabel)

        avatarView.isHidden = true
        contentView.addSubview(avatarView)

        bubble.layer.cornerRadius = 12
        bubble.layer.masksToBounds = true
        bubble.backgroundColor = UIColor(white: 0.85, alpha: 1.0)   // placeholder tint
        contentView.addSubview(bubble)

        imageView2.contentMode = .scaleAspectFill
        imageView2.clipsToBounds = true
        bubble.addSubview(imageView2)

        // Tap the bubble to open the full-screen viewer. Coexists with the
        // table's reveal-pan (a tap and a pan don't conflict).
        bubble.isUserInteractionEnabled = true
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        bubble.addGestureRecognizer(tap)

        revealTimeLabel.backgroundColor = .clear
        revealTimeLabel.font = UIFont.systemFont(ofSize: 11)
        revealTimeLabel.textColor = .gray
        revealTimeLabel.textAlignment = .right
        revealTimeLabel.isHidden = true
        contentView.addSubview(revealTimeLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func handleTap() { onTap?() }

    func configure(meta: String?, mxc: String, imageWidth: Int, imageHeight: Int, time: String, isOwn: Bool,
                   avatarMxc: String?, senderName: String) {
        isOwnMessage = isOwn
        hasMeta = meta != nil
        metaLabel.isHidden = !hasMeta
        metaLabel.text = meta
        metaLabel.textAlignment = isOwn ? .right : .left
        revealTimeLabel.text = time
        let showAvatar = !isOwn && hasMeta
        avatarView.isHidden = !showAvatar
        if showAvatar { avatarView.setAvatar(mxc: avatarMxc, name: senderName) }
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        currentMxc = mxc
        imageView2.image = nil

        // Request a thumbnail at ~2x the on-screen box so it stays crisp on a
        // Retina display; the server clamps to its own allowed sizes anyway.
        let (reqW, reqH) = ImageEventCell.thumbnailRequestSize(imageWidth: imageWidth, imageHeight: imageHeight)
        MediaCache.shared.loadThumbnail(mxc: mxc, width: reqW, height: reqH) { [weak self] image in
            guard let self = self else { return }
            // The cell may have been recycled onto another row before the async
            // load returned — only apply if this is still the same image.
            guard self.currentMxc == mxc, let image = image else { return }
            self.imageView2.image = image
            self.setNeedsLayout()
            self.layoutIfNeeded()
        }
        setNeedsLayout()
    }

    func setRevealOffset(_ offset: CGFloat) {
        guard offset != revealOffset else { return }
        revealOffset = offset
        setNeedsLayout()
        layoutIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let maxBubbleWidth = contentView.bounds.width * EventCell.bubbleWidthFraction
        let box = ImageEventCell.displaySize(imageWidth: imageWidth, imageHeight: imageHeight, maxWidth: maxBubbleWidth)

        let leftEdge = EventCell.outerMargin + (isOwnMessage ? 0 : EventCell.senderGutter)

        var y: CGFloat = hasMeta ? EventCell.topMargin : EventCell.groupedTopMargin
        if hasMeta {
            let metaX = isOwnMessage ? contentView.bounds.width - EventCell.outerMargin - maxBubbleWidth
                                     : leftEdge
            metaLabel.frame = CGRect(x: metaX - revealOffset, y: y,
                                      width: maxBubbleWidth, height: EventCell.metaHeight)
            y += EventCell.metaHeight + EventCell.metaGap
        }

        let bubbleX = isOwnMessage ? contentView.bounds.width - box.width - EventCell.outerMargin
                                    : leftEdge
        bubble.frame = CGRect(x: bubbleX - revealOffset, y: y, width: box.width, height: box.height)
        imageView2.frame = bubble.bounds

        if !avatarView.isHidden {
            let ax = EventCell.outerMargin - revealOffset
            let ay = bubble.frame.maxY - EventCell.avatarSize
            avatarView.frame = CGRect(x: ax, y: ay, width: EventCell.avatarSize, height: EventCell.avatarSize)
        }

        revealTimeLabel.frame = CGRect(x: contentView.bounds.width - EventCell.maxReveal + 2,
                                        y: bubble.frame.minY, width: EventCell.maxReveal - 8,
                                        height: bubble.frame.height)
        revealTimeLabel.isHidden = revealOffset <= 0.5
    }
}

// Voice-message bubble: a play/pause button + a duration (and, while playing,
// elapsed) label in a fixed-size rounded bubble. Same meta header + avatar +
// swipe-to-reveal timestamp + own/other alignment as the other cells. Playback
// itself is driven by the VC (one shared AVAudioPlayer); the cell just renders
// the state pushed to it via setPlaybackState and reports taps via onPlayTap.
private class AudioEventCell: UITableViewCell {
    static let bubbleHeight: CGFloat = 46
    static let bubbleMaxWidth: CGFloat = 210

    private let bubble = UIView()
    private let metaLabel = UILabel()
    private let avatarView = AvatarView()
    private let revealTimeLabel = UILabel()
    private let playButton = UIButton(type: .custom)
    private let durationLabel = UILabel()
    private var isOwnMessage = false
    private var hasMeta = false
    private var revealOffset: CGFloat = 0

    // Which voice message this cell shows, and its declared length (seconds) —
    // read by the VC to match the playing bubble and to render the idle time.
    var mxc: String?
    var declaredDuration: TimeInterval = 0
    var onPlayTap: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        metaLabel.backgroundColor = .clear
        metaLabel.font = UIFont.systemFont(ofSize: 11)
        metaLabel.textColor = .gray
        contentView.addSubview(metaLabel)

        avatarView.isHidden = true
        contentView.addSubview(avatarView)

        bubble.layer.cornerRadius = 12
        bubble.layer.masksToBounds = true
        contentView.addSubview(bubble)

        playButton.imageView?.contentMode = .scaleAspectFit
        playButton.addTarget(self, action: #selector(playTapped), for: .touchUpInside)
        bubble.addSubview(playButton)

        // iOS 6: UILabel defaults to opaque white — clear it or it paints over
        // the bubble colour.
        durationLabel.backgroundColor = .clear
        durationLabel.font = UIFont.systemFont(ofSize: 13)
        bubble.addSubview(durationLabel)

        revealTimeLabel.backgroundColor = .clear
        revealTimeLabel.font = UIFont.systemFont(ofSize: 11)
        revealTimeLabel.textColor = .gray
        revealTimeLabel.textAlignment = .right
        revealTimeLabel.isHidden = true
        contentView.addSubview(revealTimeLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func playTapped() { onPlayTap?() }

    func configure(meta: String?, mxc: String, durationMs: Int, time: String, isOwn: Bool,
                   avatarMxc: String?, senderName: String) {
        isOwnMessage = isOwn
        hasMeta = meta != nil
        metaLabel.isHidden = !hasMeta
        metaLabel.text = meta
        metaLabel.textAlignment = isOwn ? .right : .left
        revealTimeLabel.text = time
        self.mxc = mxc
        declaredDuration = Double(durationMs) / 1000.0

        bubble.backgroundColor = isOwn ? UIColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 1.0)
                                        : UIColor(white: 0.85, alpha: 1.0)
        let fg: UIColor = isOwn ? .white : .black
        durationLabel.textColor = fg

        let showAvatar = !isOwn && hasMeta
        avatarView.isHidden = !showAvatar
        if showAvatar { avatarView.setAvatar(mxc: avatarMxc, name: senderName) }

        setPlaybackState(playing: false, currentTime: 0, duration: declaredDuration)
        setNeedsLayout()
    }

    // Updates the play/pause glyph + the time label. Called by the VC on tap,
    // on the 0.2s progress tick, and when the player finishes.
    func setPlaybackState(playing: Bool, currentTime: TimeInterval, duration: TimeInterval) {
        let iconName: String
        if playing { iconName = isOwnMessage ? "PauseWhite" : "PauseDark" }
        else { iconName = isOwnMessage ? "PlayWhite" : "PlayDark" }
        playButton.setImage(UIImage(named: iconName), for: .normal)
        let total = duration > 0 ? duration : declaredDuration
        if playing {
            durationLabel.text = "\(AudioEventCell.fmt(currentTime)) / \(AudioEventCell.fmt(total))"
        } else {
            durationLabel.text = "Voice \u{00B7} \(AudioEventCell.fmt(total))"
        }
    }

    private static func fmt(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    func setRevealOffset(_ offset: CGFloat) {
        guard offset != revealOffset else { return }
        revealOffset = offset
        setNeedsLayout()
        layoutIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let maxBubbleWidth = contentView.bounds.width * EventCell.bubbleWidthFraction
        let bw = min(AudioEventCell.bubbleMaxWidth, maxBubbleWidth)
        let bh = AudioEventCell.bubbleHeight

        let leftEdge = EventCell.outerMargin + (isOwnMessage ? 0 : EventCell.senderGutter)

        var y: CGFloat = hasMeta ? EventCell.topMargin : EventCell.groupedTopMargin
        if hasMeta {
            let metaX = isOwnMessage ? contentView.bounds.width - EventCell.outerMargin - maxBubbleWidth
                                     : leftEdge
            metaLabel.frame = CGRect(x: metaX - revealOffset, y: y,
                                      width: maxBubbleWidth, height: EventCell.metaHeight)
            y += EventCell.metaHeight + EventCell.metaGap
        }

        let bubbleX = isOwnMessage ? contentView.bounds.width - bw - EventCell.outerMargin
                                    : leftEdge
        bubble.frame = CGRect(x: bubbleX - revealOffset, y: y, width: bw, height: bh)

        let pad: CGFloat = 8
        let btn: CGFloat = 30
        playButton.frame = CGRect(x: pad, y: (bh - btn) / 2, width: btn, height: btn)
        let labelX = pad + btn + 8
        durationLabel.frame = CGRect(x: labelX, y: 0, width: max(0, bw - labelX - pad), height: bh)

        if !avatarView.isHidden {
            let ax = EventCell.outerMargin - revealOffset
            let ay = bubble.frame.maxY - EventCell.avatarSize
            avatarView.frame = CGRect(x: ax, y: ay, width: EventCell.avatarSize, height: EventCell.avatarSize)
        }

        revealTimeLabel.frame = CGRect(x: contentView.bounds.width - EventCell.maxReveal + 2,
                                        y: bubble.frame.minY, width: EventCell.maxReveal - 8,
                                        height: bubble.frame.height)
        revealTimeLabel.isHidden = revealOffset <= 0.5
    }
}

// Both attachment bubbles (the generic file chip and the video poster) show
// download progress the same way, so the tap/progress plumbing in the VC drives
// them through this instead of naming a concrete cell class.
fileprivate protocol AttachmentProgressCell: AnyObject {
    var mxc: String? { get }
    func setProgress(_ progress: Float?)
    func markDownloaded()
}

// An m.file attachment bubble: a file-type "chip" (the uppercase extension) next
// to the filename and a "PDF · 2.4 MB" subtitle. Tapping downloads it (progress
// shown inline) and then opens it.
private class FileEventCell: UITableViewCell, AttachmentProgressCell {
    static let bubbleHeight: CGFloat = 58
    static let bubbleMaxWidth: CGFloat = 250

    private let bubble = UIView()
    private let metaLabel = UILabel()
    private let avatarView = AvatarView()
    private let revealTimeLabel = UILabel()
    private let chip = UIView()
    private let chipLabel = UILabel()
    private let nameLabel = UILabel()
    private let detailLabel = UILabel()
    private let progressView = UIProgressView(progressViewStyle: .default)
    private var isOwnMessage = false
    private var hasMeta = false
    private var revealOffset: CGFloat = 0

    // Download state, kept on the cell so a progress tick doesn't have to re-stat
    // the disk. `sizeText` is the pre-formatted attachment size (empty if the
    // sender omitted it).
    private var isDownloaded = false
    private var sizeText = ""

    // Which attachment this cell shows — the VC matches progress updates against it.
    var mxc: String?
    var onTap: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        // iOS 6: UILabel defaults to an opaque white background — every label
        // over the bubble must be cleared explicitly.
        metaLabel.backgroundColor = .clear
        metaLabel.font = UIFont.systemFont(ofSize: 11)
        metaLabel.textColor = .gray
        contentView.addSubview(metaLabel)

        avatarView.isHidden = true
        contentView.addSubview(avatarView)

        bubble.layer.cornerRadius = 12
        bubble.layer.masksToBounds = true
        contentView.addSubview(bubble)

        chip.layer.cornerRadius = 6
        chip.layer.masksToBounds = true
        bubble.addSubview(chip)

        chipLabel.backgroundColor = .clear
        chipLabel.font = UIFont.boldSystemFont(ofSize: 11)
        chipLabel.textAlignment = .center
        chipLabel.adjustsFontSizeToFitWidth = true
        chip.addSubview(chipLabel)

        nameLabel.backgroundColor = .clear
        nameLabel.font = UIFont.boldSystemFont(ofSize: 14)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        bubble.addSubview(nameLabel)

        detailLabel.backgroundColor = .clear
        detailLabel.font = UIFont.systemFont(ofSize: 11)
        bubble.addSubview(detailLabel)

        progressView.isHidden = true
        bubble.addSubview(progressView)

        revealTimeLabel.backgroundColor = .clear
        revealTimeLabel.font = UIFont.systemFont(ofSize: 11)
        revealTimeLabel.textColor = .gray
        revealTimeLabel.textAlignment = .right
        revealTimeLabel.isHidden = true
        contentView.addSubview(revealTimeLabel)

        bubble.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(bubbleTapped)))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func bubbleTapped() { onTap?() }

    func configure(meta: String?, mxc: String, filename: String, mimeType: String, sizeBytes: Int,
                   downloaded: Bool, time: String, isOwn: Bool, avatarMxc: String?, senderName: String) {
        isOwnMessage = isOwn
        hasMeta = meta != nil
        metaLabel.isHidden = !hasMeta
        metaLabel.text = meta
        metaLabel.textAlignment = isOwn ? .right : .left
        revealTimeLabel.text = time

        self.mxc = mxc
        isDownloaded = downloaded
        sizeText = sizeBytes > 0 ? FileEventCell.humanSize(sizeBytes) : ""
        nameLabel.text = filename
        chipLabel.text = FileEventCell.typeTag(filename: filename, mimeType: mimeType)
        setProgress(nil)

        bubble.backgroundColor = isOwn ? UIColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 1.0)
                                        : UIColor(white: 0.85, alpha: 1.0)
        nameLabel.textColor = isOwn ? .white : .black
        detailLabel.textColor = isOwn ? UIColor(white: 1.0, alpha: 0.75) : .darkGray
        chip.backgroundColor = isOwn ? UIColor(white: 1.0, alpha: 0.22) : .white
        chipLabel.textColor = isOwn ? .white : UIColor(white: 0.3, alpha: 1.0)
        progressView.progressTintColor = isOwn ? .white : UIColor(white: 0.35, alpha: 1.0)

        let showAvatar = !isOwn && hasMeta
        avatarView.isHidden = !showAvatar
        if showAvatar { avatarView.setAvatar(mxc: avatarMxc, name: senderName) }

        setNeedsLayout()
    }

    // `progress` nil means "not downloading" — the subtitle then reflects whether
    // the attachment is already on disk.
    func setProgress(_ progress: Float?) {
        if let progress = progress {
            progressView.isHidden = false
            progressView.progress = progress
            detailLabel.text = "Downloading\u{2026} \(Int(progress * 100))%"
            return
        }
        progressView.isHidden = true
        let lead = isDownloaded ? "Saved" : "Tap to download"
        detailLabel.text = sizeText.isEmpty ? lead : "\(lead) \u{00B7} \(sizeText)"
    }

    func markDownloaded() {
        isDownloaded = true
        setProgress(nil)
    }

    // Uppercase file-type tag: the filename's extension when it has one, else
    // the mime subtype, else "FILE". Pure Swift scalar work — no Foundation
    // string convenience APIs (several are unsafe on this legacy runtime).
    private static func typeTag(filename: String, mimeType: String) -> String {
        var candidate = ""
        if let dot = filename.lastIndex(of: "."), dot < filename.index(before: filename.endIndex) {
            candidate = String(filename[filename.index(after: dot)...])
        }
        if candidate.isEmpty, let slash = mimeType.lastIndex(of: "/"),
           slash < mimeType.index(before: mimeType.endIndex) {
            candidate = String(mimeType[mimeType.index(after: slash)...])
        }
        if candidate.isEmpty { return "FILE" }
        return asciiUppercased(String(candidate.prefix(4)))
    }

    private static func asciiUppercased(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in s.unicodeScalars {
            if scalar.value >= 97, scalar.value <= 122, let up = UnicodeScalar(scalar.value - 32) {
                out.append(up)
            } else {
                out.append(scalar)
            }
        }
        return String(out)
    }

    // Hand-rolled byte formatting (ByteCountFormatter is avoided project-wide).
    private static func humanSize(_ bytes: Int) -> String {
        let b = Double(bytes)
        if b >= 1024 * 1024 * 1024 { return String(format: "%.1f GB", b / (1024 * 1024 * 1024)) }
        if b >= 1024 * 1024 { return String(format: "%.1f MB", b / (1024 * 1024)) }
        if b >= 1024 { return String(format: "%.0f KB", b / 1024) }
        return "\(bytes) B"
    }

    func setRevealOffset(_ offset: CGFloat) {
        guard offset != revealOffset else { return }
        revealOffset = offset
        setNeedsLayout()
        layoutIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let maxBubbleWidth = contentView.bounds.width * EventCell.bubbleWidthFraction
        let bw = min(FileEventCell.bubbleMaxWidth, maxBubbleWidth)
        let bh = FileEventCell.bubbleHeight

        let leftEdge = EventCell.outerMargin + (isOwnMessage ? 0 : EventCell.senderGutter)

        var y: CGFloat = hasMeta ? EventCell.topMargin : EventCell.groupedTopMargin
        if hasMeta {
            let metaX = isOwnMessage ? contentView.bounds.width - EventCell.outerMargin - maxBubbleWidth
                                     : leftEdge
            metaLabel.frame = CGRect(x: metaX - revealOffset, y: y,
                                      width: maxBubbleWidth, height: EventCell.metaHeight)
            y += EventCell.metaHeight + EventCell.metaGap
        }

        let bubbleX = isOwnMessage ? contentView.bounds.width - bw - EventCell.outerMargin
                                    : leftEdge
        bubble.frame = CGRect(x: bubbleX - revealOffset, y: y, width: bw, height: bh)

        let pad: CGFloat = 8
        let chipSize: CGFloat = 38
        chip.frame = CGRect(x: pad, y: (bh - chipSize) / 2, width: chipSize, height: chipSize)
        chipLabel.frame = chip.bounds.insetBy(dx: 2, dy: 0)

        let textX = pad + chipSize + 8
        let textW = max(0, bw - textX - pad)
        nameLabel.frame = CGRect(x: textX, y: 9, width: textW, height: 18)
        detailLabel.frame = CGRect(x: textX, y: 28, width: textW, height: 14)
        progressView.frame = CGRect(x: textX, y: 46, width: textW, height: 2)

        if !avatarView.isHidden {
            let ax = EventCell.outerMargin - revealOffset
            let ay = bubble.frame.maxY - EventCell.avatarSize
            avatarView.frame = CGRect(x: ax, y: ay, width: EventCell.avatarSize, height: EventCell.avatarSize)
        }

        revealTimeLabel.frame = CGRect(x: contentView.bounds.width - EventCell.maxReveal + 2,
                                        y: bubble.frame.minY, width: EventCell.maxReveal - 8,
                                        height: bubble.frame.height)
        revealTimeLabel.isHidden = revealOffset <= 0.5
    }
}

// An m.video attachment bubble: the sender's poster frame with a play badge and
// a duration pill, sized like an image bubble. Falls back to the plain grey
// placeholder when the sender supplied no thumbnail — pulling a frame out of the
// video itself would mean downloading the whole thing first. Tapping downloads
// and plays, sharing the VC's file-download plumbing.
private class VideoEventCell: UITableViewCell, AttachmentProgressCell {
    private let bubble = UIView()
    private let posterView = UIImageView()
    private let playBadge = UIView()
    private let playIcon = UIImageView()
    private let durationLabel = UILabel()
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let metaLabel = UILabel()
    private let avatarView = AvatarView()
    private let revealTimeLabel = UILabel()
    private var isOwnMessage = false
    private var hasMeta = false
    private var revealOffset: CGFloat = 0
    private var posterWidth = 0
    private var posterHeight = 0

    // Download state and the idle subtitle ("0:23", or the size when the sender
    // omitted a duration), kept so a progress tick needn't re-derive them.
    private var isDownloaded = false
    private var idleText = ""

    // The thumbnail mxc currently being loaded — guards a stale async load from
    // landing on a recycled cell. Separate from `mxc`, which is the video itself
    // (what the VC matches download progress against).
    private var currentThumbnailMxc: String?
    var mxc: String?
    var onTap: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        // iOS 6: UILabel defaults to an opaque white background — every label
        // over the bubble must be cleared explicitly.
        metaLabel.backgroundColor = .clear
        metaLabel.font = UIFont.systemFont(ofSize: 11)
        metaLabel.textColor = .gray
        contentView.addSubview(metaLabel)

        avatarView.isHidden = true
        contentView.addSubview(avatarView)

        bubble.layer.cornerRadius = 12
        bubble.layer.masksToBounds = true
        bubble.backgroundColor = UIColor(white: 0.85, alpha: 1.0)   // placeholder tint
        contentView.addSubview(bubble)

        posterView.contentMode = .scaleAspectFill
        posterView.clipsToBounds = true
        bubble.addSubview(posterView)

        // Dark scrim behind the glyph so the badge reads over a light frame.
        playBadge.backgroundColor = UIColor(white: 0, alpha: 0.45)
        playBadge.layer.cornerRadius = VideoEventCell.badgeSize / 2
        playBadge.layer.masksToBounds = true
        bubble.addSubview(playBadge)

        // The white variant, since the badge behind it is always dark.
        playIcon.image = UIImage(named: "PlayWhite")
        playIcon.contentMode = .scaleAspectFit
        playBadge.addSubview(playIcon)

        // This one keeps a background on purpose: it's a pill over the poster.
        durationLabel.backgroundColor = UIColor(white: 0, alpha: 0.45)
        durationLabel.font = UIFont.boldSystemFont(ofSize: 11)
        durationLabel.textColor = .white
        durationLabel.textAlignment = .center
        durationLabel.layer.cornerRadius = 4
        durationLabel.layer.masksToBounds = true
        bubble.addSubview(durationLabel)

        progressView.isHidden = true
        progressView.progressTintColor = .white
        bubble.addSubview(progressView)

        revealTimeLabel.backgroundColor = .clear
        revealTimeLabel.font = UIFont.systemFont(ofSize: 11)
        revealTimeLabel.textColor = .gray
        revealTimeLabel.textAlignment = .right
        revealTimeLabel.isHidden = true
        contentView.addSubview(revealTimeLabel)

        bubble.isUserInteractionEnabled = true
        bubble.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(bubbleTapped)))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func bubbleTapped() { onTap?() }

    func configure(meta: String?, video: VideoAttachment, downloaded: Bool, time: String, isOwn: Bool,
                   avatarMxc: String?, senderName: String) {
        isOwnMessage = isOwn
        hasMeta = meta != nil
        metaLabel.isHidden = !hasMeta
        metaLabel.text = meta
        metaLabel.textAlignment = isOwn ? .right : .left
        revealTimeLabel.text = time
        let showAvatar = !isOwn && hasMeta
        avatarView.isHidden = !showAvatar
        if showAvatar { avatarView.setAvatar(mxc: avatarMxc, name: senderName) }

        mxc = video.mxc
        isDownloaded = downloaded
        posterWidth = video.width
        posterHeight = video.height
        idleText = VideoEventCell.idleText(video: video)
        setProgress(nil)

        // The poster is an ordinary thumbnail request keyed on the thumbnail's own
        // mxc, but sized from the video's dimensions so the box matches rowHeight.
        posterView.image = nil
        currentThumbnailMxc = video.thumbnailMxc
        if let thumb = video.thumbnailMxc {
            let (reqW, reqH) = ImageEventCell.thumbnailRequestSize(imageWidth: video.width,
                                                                   imageHeight: video.height)
            MediaCache.shared.loadThumbnail(mxc: thumb, width: reqW, height: reqH) { [weak self] image in
                guard let self = self, self.currentThumbnailMxc == thumb, let image = image else { return }
                self.posterView.image = image
            }
        }

        setNeedsLayout()
    }

    // `progress` nil means "not downloading" — the pill then shows the duration.
    func setProgress(_ progress: Float?) {
        if let progress = progress {
            progressView.isHidden = false
            progressView.progress = progress
            playBadge.isHidden = true
            durationLabel.text = " \(Int(progress * 100))% "
            return
        }
        progressView.isHidden = true
        playBadge.isHidden = false
        durationLabel.text = " \(idleText) "
        setNeedsLayout()
    }

    func markDownloaded() {
        isDownloaded = true
        setProgress(nil)
    }

    func setRevealOffset(_ offset: CGFloat) {
        guard offset != revealOffset else { return }
        revealOffset = offset
        setNeedsLayout()
        layoutIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let maxBubbleWidth = contentView.bounds.width * EventCell.bubbleWidthFraction
        let box = ImageEventCell.displaySize(imageWidth: posterWidth, imageHeight: posterHeight,
                                             maxWidth: maxBubbleWidth)

        let leftEdge = EventCell.outerMargin + (isOwnMessage ? 0 : EventCell.senderGutter)

        var y: CGFloat = hasMeta ? EventCell.topMargin : EventCell.groupedTopMargin
        if hasMeta {
            let metaX = isOwnMessage ? contentView.bounds.width - EventCell.outerMargin - maxBubbleWidth
                                     : leftEdge
            metaLabel.frame = CGRect(x: metaX - revealOffset, y: y,
                                      width: maxBubbleWidth, height: EventCell.metaHeight)
            y += EventCell.metaHeight + EventCell.metaGap
        }

        let bubbleX = isOwnMessage ? contentView.bounds.width - box.width - EventCell.outerMargin
                                    : leftEdge
        bubble.frame = CGRect(x: bubbleX - revealOffset, y: y, width: box.width, height: box.height)
        posterView.frame = bubble.bounds

        let badge = VideoEventCell.badgeSize
        playBadge.frame = CGRect(x: (box.width - badge) / 2, y: (box.height - badge) / 2,
                                  width: badge, height: badge)
        // Inset the glyph, and nudge it right: a triangle's visual centre sits
        // left of its bounding box.
        playIcon.frame = playBadge.bounds.insetBy(dx: 10, dy: 10).offsetBy(dx: 1, dy: 0)

        let pillWidth = min(box.width - 12, durationLabel.sizeThatFits(CGSize(width: box.width,
                                                                             height: 16)).width + 8)
        durationLabel.frame = CGRect(x: 6, y: box.height - 22, width: max(28, pillWidth), height: 16)
        progressView.frame = CGRect(x: 6, y: box.height - 4, width: box.width - 12, height: 2)

        if !avatarView.isHidden {
            let ax = EventCell.outerMargin - revealOffset
            let ay = bubble.frame.maxY - EventCell.avatarSize
            avatarView.frame = CGRect(x: ax, y: ay, width: EventCell.avatarSize, height: EventCell.avatarSize)
        }

        revealTimeLabel.frame = CGRect(x: contentView.bounds.width - EventCell.maxReveal + 2,
                                        y: bubble.frame.minY, width: EventCell.maxReveal - 8,
                                        height: bubble.frame.height)
        revealTimeLabel.isHidden = revealOffset <= 0.5
    }

    private static let badgeSize: CGFloat = 44

    // "0:23" when the sender gave a duration, else the size, else just "Video" —
    // the pill doubles as the only affordance saying this is a playable clip.
    private static func idleText(video: VideoAttachment) -> String {
        if video.durationMs > 0 {
            let total = video.durationMs / 1000
            return String(format: "%d:%02d", total / 60, total % 60)
        }
        if video.sizeBytes > 0 { return humanSize(video.sizeBytes) }
        return "Video"
    }

    private static func humanSize(_ bytes: Int) -> String {
        let b = Double(bytes)
        if b >= 1024 * 1024 { return String(format: "%.1f MB", b / (1024 * 1024)) }
        if b >= 1024 { return String(format: "%.0f KB", b / 1024) }
        return "\(bytes) B"
    }
}

extension RoomTimelineVC: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        placeholderLabel.isHidden = !textView.text.isEmpty
        adjustInputHeight()
        sendTypingIfNeeded()
    }
}

extension RoomTimelineVC: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    func imagePickerController(_ picker: UIImagePickerController,
                               didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        picker.dismiss(animated: true)
        // A movie pick carries .mediaURL, a photo carries .originalImage. Check the
        // movie key first, since some sources hand back both.
        if let url = info[.mediaURL] as? URL {
            uploadAndSendVideo(atPath: url.path)
            return
        }
        guard let image = info[.originalImage] as? UIImage else { return }
        uploadAndSendImage(image)
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
    }
}

#if IOS6_TARGET
extension RoomTimelineVC: UIActionSheetDelegate {
    func actionSheet(_ actionSheet: UIActionSheet, clickedButtonAt buttonIndex: Int) {
        if actionSheet.tag == reactionSheetTag {
            guard buttonIndex != actionSheet.cancelButtonIndex,
                  let key = actionSheet.buttonTitle(at: buttonIndex),
                  let target = pendingReactionEventId else { return }
            toggleReaction(target: target, key: key)
            return
        }
        if actionSheet.tag == deleteSheetTag {
            if buttonIndex == actionSheet.destructiveButtonIndex { deleteConfirmed() }
            return
        }
        // Map by title, not index: the button set is dynamic (camera row is
        // conditional) so a fixed index would break when Voice Message shifted it.
        switch actionSheet.buttonTitle(at: buttonIndex) {
        case "Take Photo": presentPicker(source: .camera)
        case "Choose from Library": presentPicker(source: .photoLibrary)
        case "Voice Message": enterVoiceMode()
        default: break
        }
    }
}
#endif

extension RoomTimelineVC: AVAudioRecorderDelegate {
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if !flag {
            voiceHasRecording = false
            sendButton.isEnabled = false
            updateVoiceRecordButton()
        }
    }
}

extension RoomTimelineVC: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        stopAudioPlayback()
        refreshAudioCells()
    }
}

extension RoomTimelineVC: UIDocumentInteractionControllerDelegate {
    func documentInteractionControllerViewControllerForPreview(
        _ controller: UIDocumentInteractionController) -> UIViewController {
        return self
    }

    func documentInteractionControllerDidEndPreview(_ controller: UIDocumentInteractionController) {
        docController = nil
    }

    func documentInteractionControllerDidDismissOpenInMenu(_ controller: UIDocumentInteractionController) {
        docController = nil
    }
}

// MARK: - Reaction chips

// A strip of reaction chips ("👍 3") sitting under the message they annotate,
// aligned with that message's bubble. Tapping a chip adds our reaction, or takes
// it back when we already sent that key.
private class ReactionsCell: UITableViewCell {
    static let chipHeight: CGFloat = 22
    static let chipGap: CGFloat = 4          // between chips on the same line
    static let rowGap: CGFloat = 2           // between wrapped lines
    static let topGap: CGFloat = 1           // above the strip (bubble sits right there)
    static let bottomGap: CGFloat = 4
    static let chipHPadding: CGFloat = 8
    static let font = UIFont.systemFont(ofSize: 13)

    private var chips: [UIButton] = []
    private var items: [ReactionItem] = []
    private var isOwnMessage = false
    private var revealOffset: CGFloat = 0

    var onTapKey: ((String) -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(items: [ReactionItem], isOwn: Bool) {
        self.items = items
        isOwnMessage = isOwn
        // Rebuild the buttons: the chip set changes with every reaction, so
        // recycling individual buttons buys nothing but bookkeeping.
        chips.forEach { $0.removeFromSuperview() }
        chips = items.enumerated().map { index, item in
            let button = UIButton(type: .custom)
            button.tag = index
            button.titleLabel?.font = ReactionsCell.font
            button.setTitle(ReactionsCell.chipTitle(item), for: .normal)
            button.setTitleColor(item.mineEventId != nil
                                    ? UIColor(red: 0.0, green: 0.35, blue: 0.75, alpha: 1.0) : .darkGray,
                                 for: .normal)
            // Ours reads as "selected": tinted fill + matching border.
            button.backgroundColor = item.mineEventId != nil
                ? UIColor(red: 0.85, green: 0.91, blue: 1.0, alpha: 1.0)
                : UIColor(white: 0.90, alpha: 1.0)
            button.layer.cornerRadius = ReactionsCell.chipHeight / 2
            button.layer.borderWidth = 1
            button.layer.borderColor = (item.mineEventId != nil
                ? UIColor(red: 0.35, green: 0.6, blue: 0.95, alpha: 1.0)
                : UIColor(white: 0.78, alpha: 1.0)).cgColor
            button.addTarget(self, action: #selector(chipTapped(_:)), for: .touchUpInside)
            contentView.addSubview(button)
            return button
        }
        setNeedsLayout()
    }

    func setRevealOffset(_ offset: CGFloat) {
        guard offset != revealOffset else { return }
        revealOffset = offset
        setNeedsLayout()
        layoutIfNeeded()
    }

    @objc private func chipTapped(_ sender: UIButton) {
        guard sender.tag >= 0 && sender.tag < items.count else { return }
        onTapKey?(items[sender.tag].key)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = contentView.bounds.width
        let (frames, _) = ReactionsCell.layout(items: items, width: width)
        // Others' chips line up with the bubble (past the avatar gutter); ours
        // are mirrored to the right edge, line by line, so wrapped lines stay
        // flush right the way the bubbles above them do.
        let leftStart = EventCell.outerMargin + EventCell.senderGutter
        for (index, frame) in frames.enumerated() where index < chips.count {
            var f = frame
            if isOwnMessage {
                let lineWidth = ReactionsCell.lineWidth(frames: frames, y: frame.origin.y)
                f.origin.x = width - EventCell.outerMargin - lineWidth + frame.origin.x
            } else {
                f.origin.x = leftStart + frame.origin.x
            }
            f.origin.x -= revealOffset
            chips[index].frame = f
        }
    }

    static func height(items: [ReactionItem], width: CGFloat) -> CGFloat {
        return layout(items: items, width: width).1
    }

    // Shared by height() and layoutSubviews so the two can't drift apart (the
    // same discipline EventCell follows). Frames are laid out from x=0; the
    // caller shifts them to the left gutter or the right edge.
    private static func layout(items: [ReactionItem], width: CGFloat) -> ([CGRect], CGFloat) {
        let available = max(40, width - EventCell.outerMargin * 2 - EventCell.senderGutter)
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = topGap
        for item in items {
            let chipWidth = min(available, textWidth(chipTitle(item)) + chipHPadding * 2)
            if x > 0 && x + chipWidth > available {
                x = 0
                y += chipHeight + rowGap
            }
            frames.append(CGRect(x: x, y: y, width: chipWidth, height: chipHeight))
            x += chipWidth + chipGap
        }
        return (frames, y + chipHeight + bottomGap)
    }

    private static func lineWidth(frames: [CGRect], y: CGFloat) -> CGFloat {
        var maxX: CGFloat = 0
        for frame in frames where frame.origin.y == y { maxX = max(maxX, frame.maxX) }
        return maxX
    }

    private static func chipTitle(_ item: ReactionItem) -> String {
        return item.count > 1 ? "\(item.key) \(item.count)" : item.key
    }

    // UILabel.sizeThatFits rather than any NSString sizing API — those are
    // iOS 7+ selectors on this runtime.
    private static let sizingLabel = UILabel()
    private static func textWidth(_ text: String) -> CGFloat {
        sizingLabel.font = font
        sizingLabel.text = text
        return ceil(sizingLabel.sizeThatFits(CGSize(width: 10000, height: chipHeight)).width)
    }
}

// MARK: - Text attachment viewer

// Shows a downloaded text attachment in a plain read-only UITextView. Exists
// because Quick Look (UIDocumentInteractionController) hangs on a spinner for
// text files on this runtime. Kept in this file to avoid a pbxproj round-trip.
class TextFileViewerVC: UIViewController {

    // Text attachments are usually tiny, but a multi-megabyte log would take a
    // UITextView down with it — read a bounded prefix and say so.
    private static let maxBytes = 512 * 1024

    private let path: String

    init(path: String, filename: String) {
        self.path = path
        super.init(nibName: nil, bundle: nil)
        title = filename
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white

        let textView = UITextView(frame: view.bounds)
        textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        textView.isEditable = false
        textView.font = UIFont.systemFont(ofSize: 14)
        textView.text = TextFileViewerVC.readText(path: path)
        view.addSubview(textView)
    }

    // FileManager.contents(atPath:) rather than Data(contentsOf:) — the URL-based
    // read hangs on the 5.1.5 runtime.
    private static func readText(path: String) -> String {
        guard let data = FileManager.default.contents(atPath: path) else {
            return "Couldn't read this file."
        }
        let truncated = data.count > maxBytes
        let slice = truncated ? data.subdata(in: 0..<maxBytes) : data
        // Latin-1 never fails, so it's a safe last resort for a file that isn't
        // valid UTF-8 (a Windows-authored .txt, say).
        let text = String(data: slice, encoding: .utf8)
            ?? String(data: slice, encoding: .isoLatin1)
            ?? ""
        if text.isEmpty { return "This file has no readable text." }
        return truncated ? text + "\n\n\u{2026} (truncated)" : text
    }
}

// MARK: - Room settings

// Room settings, pushed by tapping the timeline's nav title. Covers the settings
// that are cheap and safe on this target: photo, name, topic, inviting someone,
// and leaving. Kept in this file (not a separate .swift) to avoid a pbxproj
// registration round-trip — same reason MemberListVC lives here.
//
// Everything is written as room state via
//   PUT /_matrix/client/v3/rooms/{roomId}/state/{eventType}
// (the state key is empty for all three, so it's omitted from the path).
// No power-level gating: we never read m.room.power_levels, so a user without
// permission just gets the homeserver's M_FORBIDDEN surfaced in an alert. Room
// IDs travel UNENCODED in the path (percent-encoding crashes on this runtime).
class RoomSettingsVC: UIViewController, UITableViewDataSource, UITableViewDelegate {

    // Handed the updated Room after each successful edit so the timeline can
    // refresh its nav title/avatar without waiting for the change to come back
    // around through /sync.
    var onRoomUpdated: ((Room) -> Void)?

    private var room: Room
    private let client: MatrixAPIClient
    private var tableView: UITableView!
    private let cellId = "RoomSettingCell"
    // Strongly held for the duration of the pick+upload: UIImagePickerController's
    // and UIActionSheet's delegates are both weak.
    private var avatarPicker: AvatarPicker?
    private let leaveSheetTag = 95

    init(room: Room, client: MatrixAPIClient) {
        self.room = room
        self.client = client
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Room Settings"
        view.backgroundColor = .white

        tableView = UITableView(frame: view.bounds, style: .grouped)
        tableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tableView.dataSource = self
        tableView.delegate = self
        view.addSubview(tableView)
    }

    // MARK: - Table

    // 0 = Room (photo, name, topic), 1 = People (invite), 2 = leave.
    func numberOfSections(in tableView: UITableView) -> Int { return 3 }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0: return "Room"
        case 1: return "People"
        default: return nil
        }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0: return 3
        default: return 1
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 0 && indexPath.row == 0 {
            let cell = tableView.dequeueReusableCell(withIdentifier: cellId + "AV") ??
                UITableViewCell(style: .default, reuseIdentifier: cellId + "AV")
            cell.textLabel?.text = "Photo"
            cell.textLabel?.textColor = .black
            cell.textLabel?.textAlignment = .left
            let avatar = AvatarView(frame: CGRect(x: 0, y: 0, width: 34, height: 34))
            avatar.setAvatar(mxc: room.avatarMxc, name: room.name)
            cell.accessoryView = avatar
            cell.selectionStyle = .default
            return cell
        }
        if indexPath.section == 2 {
            let cell = tableView.dequeueReusableCell(withIdentifier: cellId) ??
                UITableViewCell(style: .default, reuseIdentifier: cellId)
            cell.accessoryView = nil
            cell.accessoryType = .none
            cell.textLabel?.text = "Leave Room"
            cell.textLabel?.textColor = UIColor(red: 0.85, green: 0.15, blue: 0.15, alpha: 1.0)
            cell.textLabel?.textAlignment = .center
            cell.selectionStyle = .default
            return cell
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: cellId + "V") ??
            UITableViewCell(style: .value1, reuseIdentifier: cellId + "V")
        cell.accessoryView = nil
        cell.textLabel?.textColor = .black
        cell.textLabel?.textAlignment = .left
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = .default
        if indexPath.section == 1 {
            cell.textLabel?.text = "Invite someone\u{2026}"
            cell.detailTextLabel?.text = nil
            return cell
        }
        if indexPath.row == 1 {
            cell.textLabel?.text = "Name"
            cell.detailTextLabel?.text = room.name
        } else {
            cell.textLabel?.text = "Topic"
            let topic = room.topic ?? ""
            cell.detailTextLabel?.text = topic.isEmpty ? "None" : topic
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch (indexPath.section, indexPath.row) {
        case (0, 0):
            pickPhoto()
        case (0, 1):
            editName()
        case (0, 2):
            editTopic()
        case (1, _):
            navigationController?.pushViewController(
                InviteUserVC(roomId: room.roomId, client: client), animated: true)
        default:
            confirmLeave()
        }
    }

    // MARK: - Edits

    private func editName() {
        let editor = TextEditVC(screenTitle: "Room name", placeholder: "Room name",
                                current: room.name, multiline: false)
        editor.onSave = { [weak self] name in self?.saveName(name) }
        navigationController?.pushViewController(editor, animated: true)
    }

    private func editTopic() {
        let editor = TextEditVC(screenTitle: "Topic", placeholder: "Topic",
                                current: room.topic ?? "", multiline: true)
        editor.onSave = { [weak self] topic in self?.saveTopic(topic) }
        navigationController?.pushViewController(editor, animated: true)
    }

    private func saveName(_ raw: String) {
        let name = raw.roomSettingsTrimmed()
        guard !name.isEmpty, name != room.name else { return }
        putState("m.room.name", body: ["name": name]) { [weak self] in
            guard let self = self else { return }
            self.room.name = name
            self.commit()
        }
    }

    private func saveTopic(_ raw: String) {
        let topic = raw.roomSettingsTrimmed()
        guard topic != (room.topic ?? "") else { return }
        putState("m.room.topic", body: ["topic": topic]) { [weak self] in
            guard let self = self else { return }
            self.room.topic = topic
            self.commit()
        }
    }

    private func pickPhoto() {
        let picker = AvatarPicker(client: client)
        avatarPicker = picker
        picker.start(from: self, anchor: view) { [weak self] mxc, _, error in
            guard let self = self else { return }
            self.avatarPicker = nil
            guard let mxc = mxc else {
                if let error = error { self.showAlert("Couldn't upload", "\(error)") }
                return
            }
            self.putState("m.room.avatar", body: ["url": mxc]) { [weak self] in
                guard let self = self else { return }
                self.room.avatarMxc = mxc
                self.commit()
            }
        }
    }

    private func putState(_ eventType: String, body: [String: Any],
                          onSuccess: @escaping () -> Void) {
        let path = "/_matrix/client/v3/rooms/\(room.roomId)/state/\(eventType)"
        client.put(path, body: body) { [weak self] _, error in
            guard let self = self else { return }
            if let error = error {
                // A homeserver M_FORBIDDEN here means the account lacks the power
                // level for this state event — surfaced as-is rather than
                // pre-checked, since we never read m.room.power_levels.
                self.showAlert("Couldn't update", "\(error)")
                return
            }
            onSuccess()
        }
    }

    // Reflects the locally-applied change in this screen and hands the updated
    // Room back to the timeline.
    private func commit() {
        if isViewLoaded { tableView.reloadData() }
        onRoomUpdated?(room)
    }

    // MARK: - Leave

    private func confirmLeave() {
        let message = "You'll stop receiving messages from this room. You'll need a new invite to rejoin."
#if IOS6_TARGET
        let sheet = UIActionSheet()
        sheet.title = message
        sheet.addButton(withTitle: "Leave Room")   // index 0 (destructive)
        sheet.addButton(withTitle: "Cancel")       // index 1
        sheet.destructiveButtonIndex = 0
        sheet.cancelButtonIndex = 1
        sheet.tag = leaveSheetTag
        sheet.delegate = self
        sheet.show(in: view)
#else
        let alert = UIAlertController(title: "Leave room?", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Leave Room", style: .destructive) { [weak self] _ in
            self?.performLeave()
        })
        present(alert, animated: true)
#endif
    }

    fileprivate func performLeave() {
        client.post("/_matrix/client/v3/rooms/\(room.roomId)/leave", body: [:]) { [weak self] _, error in
            guard let self = self else { return }
            if let error = error {
                self.showAlert("Couldn't leave", "\(error)")
                return
            }
            // Back to the room list. The room itself disappears from the list when
            // the next /sync reports it under `rooms.leave` (RoomListVC.handleSync).
            self.navigationController?.popToRootViewController(animated: true)
        }
    }

    private func showAlert(_ title: String, _ message: String) {
#if IOS6_TARGET
        let alert = UIAlertView()
        alert.title = title
        alert.message = message
        alert.addButton(withTitle: "OK")
        alert.show()
#else
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
#endif
    }
}

#if IOS6_TARGET
extension RoomSettingsVC: UIActionSheetDelegate {
    func actionSheet(_ actionSheet: UIActionSheet, clickedButtonAt buttonIndex: Int) {
        guard actionSheet.tag == leaveSheetTag,
              buttonIndex == actionSheet.destructiveButtonIndex else { return }
        performLeave()
    }
}
#endif

private extension String {
    // Pure-Swift whitespace trim (no Foundation CharacterSet — iOS-6-safe rule).
    // Named distinctly because this file already has other String helpers.
    func roomSettingsTrimmed() -> String {
        let ws: Set<Character> = [" ", "\t", "\n", "\r"]
        var chars = Array(self)
        while let f = chars.first, ws.contains(f) { chars.removeFirst() }
        while let l = chars.last, ws.contains(l) { chars.removeLast() }
        return String(chars)
    }
}

// MARK: - Member list

// Lists the joined members of a room. Fetched via GET .../joined_members so the
// list is complete even for members not yet seen in the timeline; seeds instantly
// from the names/avatars the timeline already knew so there's no blank flash, then
// merges the server response. Kept in this file (not a separate .swift) to avoid a
// pbxproj registration round-trip — same reason AvatarView lives in MediaCache.swift.
class MemberListVC: UIViewController, UITableViewDataSource, UITableViewDelegate {

    private let room: Room
    private let client: MatrixAPIClient
    private var names: [String: String]
    private var avatars: [String: String]
    // Sorted user IDs, display name first then userId.
    private var userIds: [String] = []

    private var tableView: UITableView!
    private let cellId = "MemberCell"
    private var statusLabel: UILabel!

    init(room: Room, client: MatrixAPIClient,
         memberNames: [String: String], memberAvatars: [String: String]) {
        self.room = room
        self.client = client
        self.names = memberNames
        self.avatars = memberAvatars
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Members"
        view.backgroundColor = .white

        tableView = UITableView(frame: view.bounds, style: .plain)
        tableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 56
        view.addSubview(tableView)

        statusLabel = UILabel(frame: CGRect(x: 20, y: 90, width: view.bounds.width - 40, height: 24))
        statusLabel.autoresizingMask = [.flexibleWidth]
        statusLabel.backgroundColor = .clear   // iOS 6: labels default to white bg
        statusLabel.textColor = .gray
        statusLabel.textAlignment = .center
        statusLabel.font = UIFont.systemFont(ofSize: 14)
        statusLabel.text = "Loading members\u{2026}"
        view.addSubview(statusLabel)

        rebuildFromLocal()
        fetchMembers()
    }

    private func rebuildFromLocal() {
        // Order by display name (case-insensitive), then userId as a tiebreak.
        userIds = Array(Set(names.keys).union(avatars.keys)).sorted { a, b in
            let na = (names[a] ?? a).lowercased()
            let nb = (names[b] ?? b).lowercased()
            return na == nb ? a < b : na < nb
        }
        statusLabel.isHidden = !userIds.isEmpty
        tableView.reloadData()
    }

    private func fetchMembers() {
        let path = "/_matrix/client/v3/rooms/\(room.roomId)/joined_members"
        client.get(path) { [weak self] json, error in
            guard let self = self else { return }
            guard let joined = json?["joined"] as? [String: Any] else {
                if self.userIds.isEmpty {
                    self.statusLabel.text = "Couldn't load members."
                    self.statusLabel.isHidden = false
                }
                return
            }
            for (userId, value) in joined {
                guard let info = value as? [String: Any] else { continue }
                if let dn = info["display_name"] as? String, !dn.isEmpty {
                    self.names[userId] = dn
                }
                if let av = info["avatar_url"] as? String, av.hasPrefix("mxc://") {
                    self.avatars[userId] = av
                }
                if self.names[userId] == nil { self.names[userId] = userId }
            }
            self.rebuildFromLocal()
        }
    }

    // MARK: Table

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return userIds.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: cellId) as? MemberCell
            ?? MemberCell(style: .subtitle, reuseIdentifier: cellId)
        let userId = userIds[indexPath.row]
        let name = names[userId] ?? userId
        cell.textLabel?.text = name
        cell.detailTextLabel?.text = userId
        cell.detailTextLabel?.textColor = .gray
        cell.selectionStyle = .none
        cell.setAvatar(mxc: avatars[userId], name: name)
        return cell
    }
}

// Table cell for MemberListVC: circular AvatarView on the left, name + userId
// stacked via the built-in .subtitle style labels.
class MemberCell: UITableViewCell {
    private let avatarView = AvatarView()
    private let avatarSize: CGFloat = 40
    private let avatarMargin: CGFloat = 12

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        contentView.addSubview(avatarView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setAvatar(mxc: String?, name: String) {
        avatarView.setAvatar(mxc: mxc, name: name)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let y = (contentView.bounds.height - avatarSize) / 2
        avatarView.frame = CGRect(x: avatarMargin, y: y, width: avatarSize, height: avatarSize)
        let textLeft = avatarMargin + avatarSize + 12
        if let tl = textLabel {
            tl.frame.origin.x = textLeft
            tl.frame.size.width = contentView.bounds.width - textLeft - avatarMargin
        }
        if let dl = detailTextLabel {
            dl.frame.origin.x = textLeft
            dl.frame.size.width = contentView.bounds.width - textLeft - avatarMargin
        }
    }
}
