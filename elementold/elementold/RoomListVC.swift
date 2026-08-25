import UIKit

// Root screen after login: joined rooms, driven by SyncEngine updates.
// Owns the shared MatrixAPIClient/SyncEngine instances for the session, passed
// down to RoomTimelineVC on row selection.
class RoomListVC: UIViewController {

    private var tableView: UITableView!
    private var statusLabel: UILabel!
    private var roomsById: [String: Room] = [:]
    // Room *ids* in display order, not the rooms themselves. `Room` is a large
    // value type (three dictionaries, an array and a set), so an array of them
    // costs a full structural copy per element every time it's sorted or
    // filtered — and, worse, holds stale copies of anything that changed since,
    // which markRoomRead used to have to hand-patch. Ids keep roomsById the one
    // source of truth and make these lists cheap to rebuild.
    private var sortedRoomIds: [String] = []
    // Pending invites, keyed by roomId. Kept as a running map (not replaced per
    // sync) because incremental syncs only report *changed* invites; an invite
    // is cleared when the room later shows up under join (accepted) or leave
    // (declined/left). `invitations` is the sorted view rendered in the banner.
    private var invitesById: [String: Invitation] = [:]
    private var invitations: [Invitation] = []
    // The rooms actually rendered, after the space/bucket/search filters. Kept as
    // stored state and refreshed via rebuildDisplayedRoomIds() — see there for why.
    private var displayedRoomIds: [String] = []
    private var hasSyncedOnce = false
    private var loadingTimer: Timer?
    private var loadingSeconds = 0
    private var lastErrorText: String?
    // Latched once the re-authentication screen is on its way in, so a late
    // error listener firing for the same rejected token can't push a second one.
    private var isSoftLoggingOut = false
    // The room currently pushed on screen, if any — Room.parse uses this to
    // avoid counting messages as unread while the user is already looking at
    // that room's timeline, and markRoomRead zeroes the badge on selection.
    private var openRoomId: String?

    // Search bar (table header) + current filter text. The search bar sits in a
    // header container alongside a real funnel button (see filterButton) so the
    // funnel doesn't overlap the search field.
    private var searchBar: UISearchBar!
    private var searchText: String = ""
    private var listHeaderContainer: UIView!
    private var filterButton: UIButton!
    private let filterButtonWidth: CGFloat = 44
    // The header starts scrolled just out of sight, Mail-style: it stays part of
    // the table's content, so pulling the list down brings it back and no scroll
    // observing is needed. One-shot — once we've had a go at hiding it, it is
    // never hidden again, so the list can't shuffle itself under the user later.
    private var didHideListHeader = false

    // Pull-to-refresh. UIRefreshControl exists on iOS 6, but UIScrollView's
    // `refreshControl` property is iOS 10+, so on a plain UIViewController it has
    // to be added as a subview of the table.
    private var refreshControl: UIRefreshControl!
    private var refreshTimeoutTimer: Timer?

    // Bridge/space grouping. A "bucket" is one space (its child rooms) or one
    // bridged network (its portal rooms). Built after each /sync from roomsById;
    // `selectedFilterId == nil` means "All conversations". The filter is applied
    // on top of the space-room exclusion + search text in `displayedRoomIds`.
    private struct RoomFilter { let id: String; let label: String; let roomIds: Set<String> }
    private var filters: [RoomFilter] = []
    private var selectedFilterId: String?
    // Options captured for the iOS 6 UIActionSheet delegate (index -> filter id).
    private var pendingFilterOptions: [(label: String, id: String?)] = []
    private let filterSheetTag = 91

    private let client: MatrixAPIClient
    private let syncEngine: SyncEngine

    // The delta token matching the room list as it currently stands, persisted
    // alongside it (see RoomStore) so the next cold start resumes incrementally.
    private var lastSyncToken: String?
    // True from the moment we render a snapshot from disk until the first /sync
    // response of this launch lands. It CANNOT be driven off "a request is in
    // flight" — the long-poll always is, so the indicator would never turn off.
    private var isCatchingUp = false

    private let cellId = "RoomCell"
    private let inviteCellId = "InviteBannerCell"

    // Two sections: an "Invitations" banner (0 or 1 row) above the room list.
    private let inviteSection = 0
    private let roomSection = 1

    init() {
        client = MatrixSession.makeAPIClient()
        syncEngine = SyncEngine(api: client)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Chats"
        view.backgroundColor = .white

        // Account button (user-circle icon). The bundled PNG is now white (iOS 6
        // draws the bar-button image as-is), so no tint override is set — the button
        // otherwise renders exactly as before. Tapping opens the account menu.
        let accountItem = UIBarButtonItem(image: UIImage(named: "UserCircle"),
                                          style: .plain, target: self, action: #selector(accountTapped))
        navigationItem.leftBarButtonItem = accountItem

        // Compose (new conversation) button — same white-icon bar-button style as
        // the account button. Falls back to a "+" title if the image is missing.
        let composeItem: UIBarButtonItem
        if let plus = UIImage(named: "Plus") {
            composeItem = UIBarButtonItem(image: plus, style: .plain,
                                          target: self, action: #selector(composeTapped))
        } else {
            composeItem = UIBarButtonItem(title: "+", style: .plain,
                                          target: self, action: #selector(composeTapped))
        }
        navigationItem.rightBarButtonItem = composeItem

        tableView = UITableView(frame: view.bounds, style: .plain)
        tableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tableView.dataSource = self
        tableView.delegate = self
        view.addSubview(tableView)

        // Search bar as the table header — filters the conversation list by name.
        searchBar = UISearchBar()
        searchBar.delegate = self
        searchBar.placeholder = "Search conversations"
        // Match the (teal) navigation bar. On the iOS 6 runtime `tintColor`
        // colours the bar itself (pre-iOS-7 semantics), same as the nav bar in
        // AppDelegate; `barStyle = .black` keeps the field/glyphs light like the
        // nav bar's white title.
        searchBar.barStyle = .black
        searchBar.tintColor = UIColor(red: 0.13, green: 0.55, blue: 0.60, alpha: 1.0)
        searchBar.sizeToFit()

        // Host the search bar in a header container beside a real funnel button.
        // A UISearchBar bookmark button overlapped the field on this runtime, so
        // the filter gets its own tappable button on a teal background (matching
        // the bar) that keeps the white funnel icon visible.
        let barH = searchBar.frame.height
        let container = UIView(frame: CGRect(x: 0, y: 0, width: view.bounds.width, height: barH))
        container.autoresizingMask = [.flexibleWidth]
        searchBar.frame = container.bounds
        searchBar.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(searchBar)

        filterButton = UIButton(type: .custom)
        filterButton.frame = CGRect(x: container.bounds.width - filterButtonWidth, y: 0,
                                    width: filterButtonWidth, height: barH)
        filterButton.autoresizingMask = [.flexibleLeftMargin, .flexibleHeight]
        filterButton.backgroundColor = UIColor(red: 0.13, green: 0.55, blue: 0.60, alpha: 1.0)
        filterButton.imageView?.contentMode = .scaleAspectFit
        filterButton.addTarget(self, action: #selector(filterButtonTapped), for: .touchUpInside)
        container.addSubview(filterButton)

        listHeaderContainer = container
        tableView.tableHeaderView = container

        refreshControl = UIRefreshControl()
        refreshControl.addTarget(self, action: #selector(refreshPulled), for: .valueChanged)
        tableView.addSubview(refreshControl)

        // The funnel button opens the filter sheet, becoming a funnel-x (clear)
        // while a filter is active. Hidden (search bar full width) until at least
        // one bucket exists.
        updateFilterControl()

        // Compact, centred status label (not a full-bounds one — that read as a
        // big "box" on screen). Fixed size, centred via flexible margins on all
        // sides. Background explicitly cleared (iOS 6 UILabels default to opaque
        // white).
        let sw: CGFloat = 260, sh: CGFloat = 72
        statusLabel = UILabel(frame: CGRect(x: (view.bounds.width - sw) / 2,
                                            y: (view.bounds.height - sh) / 2,
                                            width: sw, height: sh))
        statusLabel.autoresizingMask = [.flexibleTopMargin, .flexibleBottomMargin,
                                        .flexibleLeftMargin, .flexibleRightMargin]
        statusLabel.backgroundColor = .clear
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.font = UIFont.systemFont(ofSize: 14)
        statusLabel.textColor = .gray
        statusLabel.text = "Loading rooms\u{2026}"
        view.addSubview(statusLabel)

        syncEngine.addUpdateListener { [weak self] json, isInitial in
            self?.handleSync(json, isInitial: isInitial)
        }
        syncEngine.addErrorListener { [weak self] error in
            self?.handleSyncError(error)
        }
        // Raised only after the engine has given up, which it does exactly once
        // and only for a rejected access token — nothing a retry could fix.
        syncEngine.onAuthFailure = { [weak self] in
            self?.performSoftLogout()
        }

        // Background notifications (gated by the Settings kill switch; off by
        // default → this listener is a no-op and no background work is taken).
        NotificationManager.shared.syncEngine = syncEngine
        // Let notifications name senders the way the timeline does, and name the
        // room the way this list does, from the state we've already merged. Safe
        // to read here: this listener is registered after ours, so handleSync
        // above has already run for the same response on the same thread.
        NotificationManager.shared.contextResolver = { [weak self] roomId, userId in
            guard let room = self?.roomsById[roomId] else { return (nil, nil) }
            return (room.memberNames[userId], room.name)
        }
        syncEngine.addUpdateListener { json, isInitial in
            NotificationManager.shared.handleSync(json, isInitial: isInitial)
        }

        // Render the last known room list immediately and hand its delta token to
        // the engine, so the first /sync is an incremental catch-up rather than a
        // full initial sync. Must happen before start().
        let seeded = seedFromSnapshot()

        // Persist on the way out as well as on the debounce timer: a queued write
        // may never run once we're suspended, and being killed while backgrounded
        // is the normal way this app ends.
        NotificationCenter.default.addObserver(self, selector: #selector(persistNow),
                                                name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(persistNow),
                                                name: UIApplication.willTerminateNotification, object: nil)

        syncEngine.start()

        // Diagnostic: if this ticker itself stalls, the main thread is deadlocked
        // (not just waiting on the network). If it keeps ticking with no sync
        // response ever arriving, the request itself is what's stuck.
        // (Selector-based Timer, not the block-based iOS10+ API — iOS 6/7 target.)
        // Pointless when we already have a list on screen; the "Updating…" title
        // is the indicator in that case.
        if !seeded {
            loadingTimer = Timer.scheduledTimer(timeInterval: 1, target: self,
                                                 selector: #selector(loadingTick), userInfo: nil, repeats: true)
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Persistence

    // Populates the list from the on-disk snapshot and seeds the engine's delta
    // token. Returns whether anything was restored.
    private func seedFromSnapshot() -> Bool {
        guard let snapshot = RoomStore.shared.load() else { return false }

        for room in snapshot.rooms { roomsById[room.roomId] = room }
        for invite in snapshot.invites { invitesById[invite.roomId] = invite }
        rebuildSortedRoomIds()
        invitations = invitesById.values.sorted { $0.name.lowercased() < $1.name.lowercased() }
        rebuildFilters()
        rebuildDisplayedRoomIds()

        lastSyncToken = snapshot.since
        syncEngine.resume(since: snapshot.since)

        tableView.reloadData()
        statusLabel.isHidden = true
        updateFilterControl()
        UIApplication.shared.applicationIconBadgeNumber = totalUnreadCount()
        setCatchingUp(true)
        return true
    }

    // The catch-up indicator: a title swap plus the status-bar network spinner,
    // shown only between restoring a snapshot and the first /sync of this launch.
    private func setCatchingUp(_ active: Bool) {
        isCatchingUp = active
        title = active ? "Updating\u{2026}" : "Chats"
        UIApplication.shared.isNetworkActivityIndicatorVisible = active
    }

    @objc private func persistNow() {
        guard let token = lastSyncToken else { return }
        let state = snapshotState()
        RoomStore.shared.flush(since: token, rooms: state.rooms, invites: state.invites)
    }

    private func snapshotState() -> (rooms: [Room], invites: [Invitation]) {
        return (Array(roomsById.values), Array(invitesById.values))
    }

    // MARK: - Header reveal / pull to refresh

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        hideListHeaderIfNeeded()
    }

    // Scrolls the search + filter header off the top so the list starts on its
    // first row, the way Mail does it. Deliberately NOT done by removing the
    // header: leaving it in the content means the reveal is just ordinary
    // scrolling, so there is no gesture to recognise and nothing to fight the
    // table's own panning. Pulling further past it reaches the refresh control.
    //
    // Waits for content to exist, because contentOffset can't be pushed beyond
    // contentSize; and latches either way, so a list that grows later (or a
    // /sync-driven reloadData, which preserves contentOffset) never yanks the
    // header away while the user has it open.
    private func hideListHeaderIfNeeded() {
        guard !didHideListHeader, let header = listHeaderContainer else { return }
        let barH = header.frame.height
        guard barH > 0, tableView.contentSize.height > 0 else { return }
        didHideListHeader = true
        if tableView.contentSize.height > tableView.bounds.height {
            tableView.contentOffset = CGPoint(x: 0, y: barH)
        }
    }

    @objc private func refreshPulled() {
        // The room list is push-driven: an open long-poll already delivers changes
        // the moment they happen, so a pull only has work to do when the loop is
        // idling between attempts (after an error) or was stopped. refreshNow()
        // reports which case this is; when there was nothing to force, end the
        // spinner on a short beat rather than leaving it turning for up to the
        // long-poll's 30s while implying we're waiting on something.
        let forced = syncEngine.refreshNow()
        refreshTimeoutTimer?.invalidate()
        refreshTimeoutTimer = Timer.scheduledTimer(timeInterval: forced ? 8 : 0.6, target: self,
                                                   selector: #selector(finishRefresh),
                                                   userInfo: nil, repeats: false)
    }

    @objc private func finishRefresh() {
        refreshTimeoutTimer?.invalidate()
        refreshTimeoutTimer = nil
        guard refreshControl != nil, refreshControl.isRefreshing else { return }
        refreshControl.endRefreshing()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Fires both on first appearance (harmless, already nil) and when
        // popping back from RoomTimelineVC — from that point on, new messages
        // in that room should start counting as unread again.
        openRoomId = nil
    }

    @objc private func loadingTick() {
        guard !hasSyncedOnce else { return }
        loadingSeconds += 1
        let base = lastErrorText ?? "Loading rooms\u{2026}"
        statusLabel.text = "\(base)\n(\(loadingSeconds)s elapsed)"
    }

    private func handleSync(_ json: [String: Any], isInitial: Bool) {
        let rooms = json["rooms"] as? [String: Any]
        let invitesChanged = updateInvitations(from: rooms)

        // A /sync arrives for anything at all — most often a typing notice, which
        // returns the long-poll instantly and so can land several times a second.
        // The list only has work to do when a room actually changed, so each kind
        // of downstream rebuild is gated on the specific fields it depends on.
        var orderChanged = false     // room set, or a sort key (lastMessageTimestamp)
        var contentChanged = false   // anything RoomCell draws
        var filtersChanged = false   // anything rebuildFilters buckets on
        if let join = rooms?["join"] as? [String: Any] {
            for (roomId, rawRoom) in join {
                guard let roomJSON = rawRoom as? [String: Any] else { continue }
                let existing = roomsById[roomId]
                let updated = Room.parse(roomId: roomId, json: roomJSON, existing: existing,
                                          selfUserId: MatrixSession.userId, isOpen: roomId == openRoomId,
                                          isInitialSync: isInitial)
                roomsById[roomId] = updated
                guard let before = existing else {
                    orderChanged = true; contentChanged = true; filtersChanged = true
                    continue
                }
                if before.lastMessageTimestamp != updated.lastMessageTimestamp { orderChanged = true }
                if before.name != updated.name || before.lastMessage != updated.lastMessage
                    || before.unreadCount != updated.unreadCount || before.avatarMxc != updated.avatarMxc
                    || before.lastMessageTimestamp != updated.lastMessageTimestamp {
                    contentChanged = true
                }
                if before.roomType != updated.roomType || before.bridgeNetwork != updated.bridgeNetwork
                    || before.spaceChildren != updated.spaceChildren {
                    filtersChanged = true
                }
            }
        }
        // Rooms we've left (or been kicked from) — including ones we just left
        // from Room Settings. Without this they lingered in the list until the
        // app was restarted, since only `join` was ever read.
        if let leave = rooms?["leave"] as? [String: Any] {
            for roomId in leave.keys where roomsById[roomId] != nil {
                roomsById[roomId] = nil
                orderChanged = true; contentChanged = true; filtersChanged = true
            }
        }
        if orderChanged { rebuildSortedRoomIds() }
        // Rebuild the bridge/space filter buckets from the (just-updated) rooms,
        // then the rendered list, which depends on the order and the buckets.
        // rebuildFilters can also clear a selection whose bucket disappeared.
        if filtersChanged { rebuildFilters() }
        if orderChanged || filtersChanged { rebuildDisplayedRoomIds() }

        let firstSync = !hasSyncedOnce
        hasSyncedOnce = true

        // Persist the list together with the token this exact state corresponds to.
        // Read from the response rather than asking the engine, so the pairing
        // can't drift: storing a token without the state derived from the batch it
        // ends at would silently lose those messages, since the server treats
        // everything up to that token as delivered and nothing replays it.
        if let token = json["next_batch"] as? String, !token.isEmpty {
            lastSyncToken = token
            RoomStore.shared.save(since: token) { [weak self] in
                return self?.snapshotState() ?? (rooms: [], invites: [])
            }
        }

        // Total unread across all joined rooms, mirrored on the app icon badge.
        // Only worth recomputing (a pass over every Room) when a count moved.
        let totalUnread = contentChanged ? totalUnreadCount() : nil
        let needsReload = contentChanged || orderChanged || filtersChanged || invitesChanged || firstSync
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.isCatchingUp { self.setCatchingUp(false) }
            // A previous failure may have left the "Sync error" title up; this
            // response proves it's over. Guarded on the error flag rather than
            // set unconditionally because /sync can land several times a second.
            else if self.lastErrorText != nil { self.title = "Chats" }
            self.lastErrorText = nil
            self.finishRefresh()
            if needsReload {
                self.tableView.reloadData()
                self.hideListHeaderIfNeeded()
                self.updateStatusLabel()
                self.updateFilterControl()
            }
            if let totalUnread = totalUnread {
                UIApplication.shared.applicationIconBadgeNumber = totalUnread
            }
        }
    }

    // Sum of every joined room's unread count — drives the app icon badge.
    private func totalUnreadCount() -> Int {
        return roomsById.values.reduce(0) { $0 + $1.unreadCount }
    }

    // Maintains the pending-invite map from a /sync `rooms` object: upserts
    // anything under `invite`, and clears anything that has since moved to
    // `join` (accepted) or `leave` (declined/left). Returns whether the banner
    // needs redrawing, so an otherwise-idle sync doesn't reload the table.
    @discardableResult
    private func updateInvitations(from rooms: [String: Any]?) -> Bool {
        guard let rooms = rooms else { return false }
        var changed = false
        if let invite = rooms["invite"] as? [String: Any] {
            for (roomId, raw) in invite {
                guard let inviteJSON = raw as? [String: Any] else { continue }
                invitesById[roomId] = Invitation.parse(roomId: roomId, json: inviteJSON,
                                                        selfUserId: MatrixSession.userId)
                changed = true
            }
        }
        for key in ["join", "leave"] {
            if let section = rooms[key] as? [String: Any] {
                for roomId in section.keys where invitesById[roomId] != nil {
                    invitesById[roomId] = nil
                    changed = true
                }
            }
        }
        guard changed else { return false }
        invitations = invitesById.values.sorted { $0.name.lowercased() < $1.name.lowercased() }
        return true
    }

    private func handleSyncError(_ error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // A failed attempt is still an answer for a pull-to-refresh, so stop
            // the spinner before the display guard below bails out.
            self.finishRefresh()
            let tokenState = self.client.accessToken.map { token in "present, \(token.count) chars" } ?? "MISSING (nil)"
            self.lastErrorText = "Sync error:\n\(error)\n\n[debug] token: \(tokenState)"

            // With a list on screen the full-screen status label is the wrong
            // instrument — it would blank a perfectly readable room list over a
            // transient retry. But saying NOTHING was worse: since the list is
            // restored from disk on launch, it is non-empty for any returning
            // user, so a permanent failure (a rejected token, which retries
            // identically forever) showed no indication at all and the app just
            // looked frozen on stale data. Reuse the catch-up title instead.
            if self.sortedRoomIds.isEmpty {
                self.statusLabel.text = self.lastErrorText
                self.statusLabel.isHidden = false
            } else {
                if self.isCatchingUp { self.setCatchingUp(false) }
                self.title = "Sync error"
            }
        }
    }

    private func updateStatusLabel() {
        loadingTimer?.invalidate()
        loadingTimer = nil
        if !sortedRoomIds.isEmpty {
            statusLabel.isHidden = true
        } else if hasSyncedOnce {
            statusLabel.text = "No rooms yet."
            statusLabel.isHidden = false
        }
    }

    // MARK: - Account menu

    @objc private func accountTapped() {
#if IOS6_TARGET
        let sheet = UIActionSheet()
        sheet.addButton(withTitle: "User Settings")   // 0
        sheet.addButton(withTitle: "Log Out")          // 1
        sheet.addButton(withTitle: "Cancel")           // 2
        sheet.cancelButtonIndex = 2
        sheet.delegate = self
        sheet.show(from: navigationItem.leftBarButtonItem!, animated: true)
#else
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "User Settings", style: .default) { [weak self] _ in
            self?.openUserSettings()
        })
        sheet.addAction(UIAlertAction(title: "Log Out", style: .destructive) { [weak self] _ in
            self?.confirmLogout()
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.barButtonItem = navigationItem.leftBarButtonItem
        present(sheet, animated: true)
#endif
    }

    private func openUserSettings() {
        navigationController?.pushViewController(UserSettingsVC(), animated: true)
    }

    private func confirmLogout() {
#if IOS6_TARGET
        let alert = UIAlertView()
        alert.title = "Log Out"
        alert.message = "Are you sure you want to log out?"
        alert.addButton(withTitle: "Cancel")   // 0
        alert.addButton(withTitle: "Log Out")  // 1
        alert.cancelButtonIndex = 0
        alert.delegate = self
        alert.show()
#else
        let alert = UIAlertController(title: "Log Out",
                                      message: "Are you sure you want to log out?", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Log Out", style: .destructive) { [weak self] _ in
            self?.performLogout()
        })
        present(alert, animated: true)
#endif
    }

    private func performLogout() {
        syncEngine.stop()
        // The loading ticker is normally invalidated by the first successful sync
        // (updateStatusLabel). Logging out before that ever happened would leave it
        // running at 1 Hz forever — and since it's a selector-based Timer holding a
        // strong ref to us, it would keep this whole screen alive after LoginVC
        // replaces it.
        loadingTimer?.invalidate()
        loadingTimer = nil
        // Clear the app icon badge so the next account doesn't inherit a stale count.
        UIApplication.shared.applicationIconBadgeNumber = 0
        if isCatchingUp { setCatchingUp(false) }
        // Drop the persisted room list: it belongs to the account signing out.
        // (Also cancels any pending write, so nothing can land after this.)
        RoomStore.shared.discard()
        MatrixSession.clear()
        // Drop cached media too, so a different account signing in on this
        // device doesn't inherit the previous user's downloaded images.
        MediaCache.shared.clear {}
        navigationController?.setViewControllers([LoginVC()], animated: true)
    }

    // The homeserver rejected our access token. The account is still ours and
    // everything we hold for it is still valid, so this is Element's soft
    // logout: drop ONLY the token and send the user back to a login screen
    // pinned to the same server and user. The persisted room list and the media
    // cache deliberately survive, which is what makes re-authenticating instant.
    //
    // Note a recovery key cannot substitute for this. It unlocks secret storage
    // (message keys); an access token comes only from /login.
    private func performSoftLogout() {
        guard !isSoftLoggingOut else { return }
        isSoftLoggingOut = true

        // Same teardown as performLogout — the engine has already stopped itself,
        // but the ticker and the badge would otherwise outlive this screen.
        syncEngine.stop()
        loadingTimer?.invalidate()
        loadingTimer = nil
        UIApplication.shared.applicationIconBadgeNumber = 0
        if isCatchingUp { setCatchingUp(false) }
        // Write the list we have out now: the debounced write would never run
        // once this screen is replaced, and the whole point is that the next
        // sign-in resumes from it.
        persistNow()

        let userId = MatrixSession.userId
        MatrixSession.clearAccessToken()
        navigationController?.setViewControllers([LoginVC(softLogoutUserId: userId)], animated: true)
    }

    // MARK: - Search / filter

    // Newest-first room order. Sorts (id, timestamp) pairs rather than the rooms
    // themselves, so the sort's O(n log n) swaps move two words each instead of a
    // whole Room.
    private func rebuildSortedRoomIds() {
        var keyed: [(id: String, ts: Double)] = []
        keyed.reserveCapacity(roomsById.count)
        for (id, room) in roomsById { keyed.append((id, room.lastMessageTimestamp)) }
        keyed.sort { $0.ts > $1.ts }
        sortedRoomIds = keyed.map { $0.id }
    }

    // Rebuilds `displayedRoomIds` from `sortedRoomIds`. Three filters stacked:
    //   1. Space rooms (isSpace) are never shown — they're grouping containers
    //      with no timeline, surfaced only as filter buckets.
    //   2. The selected bridge/space bucket, if any (selectedFilterId != nil).
    //   3. The search bar text (client-side: Matrix has no "search my joined
    //      rooms" endpoint, so filtering the synced list by name is correct).
    //
    // Stored rather than computed: the table's data source reads it once per row
    // in cellForRowAt, so a computed property ran these filters (V+1) times per
    // reloadData over every joined room, allocating a new array each time. While
    // typing in the search bar that landed on the main thread per keystroke.
    // Call this whenever one of the three inputs above changes.
    private func rebuildDisplayedRoomIds() {
        let bucket = selectedFilterId.flatMap { id in filters.first(where: { $0.id == id }) }
        // Lower-case and unpack the needle ONCE, not once per room compared.
        let query = searchText.isEmpty ? nil : Array(searchText.lowercased())
        var result: [String] = []
        result.reserveCapacity(sortedRoomIds.count)
        for id in sortedRoomIds {
            if let bucket = bucket, !bucket.roomIds.contains(id) { continue }
            guard let room = roomsById[id], !room.isSpace else { continue }
            if let query = query, !RoomListVC.nameMatches(room.name, query: query) { continue }
            result.append(id)
        }
        displayedRoomIds = result
    }

    // Rebuilds the filter buckets from roomsById. Only called when a room's
    // space/bridge state actually changed — the buckets depend on m.room.create,
    // m.space.child and uk.half-shot.bridge, none of which move once a room has
    // been seen, so running this on every /sync was three passes over every room
    // for a result that is the same all session.
    //   Spaces first: one bucket per joined space room, containing the joined,
    //   non-space rooms it lists via m.space.child (spaceChildren).
    //   Bridges second: for every bridged room (bridgeNetwork != nil) not already
    //   claimed by a space bucket, one bucket per distinct network label.
    // Buckets with no currently-joined member rooms are dropped.
    private func rebuildFilters() {
        // One pass, ids only: pulling Rooms out into arrays to filter/map/sort
        // them copied every struct several times over.
        var joinedNonSpace = Set<String>()
        var spaceIds: [String] = []
        for (id, room) in roomsById {
            if room.isSpace { spaceIds.append(id) } else { joinedNonSpace.insert(id) }
        }
        var built: [RoomFilter] = []
        var claimed = Set<String>()

        // 1. Spaces.
        spaceIds.sort { (roomsById[$0]?.name ?? "").lowercased() < (roomsById[$1]?.name ?? "").lowercased() }
        for spaceId in spaceIds {
            guard let space = roomsById[spaceId] else { continue }
            let members = space.spaceChildren.intersection(joinedNonSpace)
            guard !members.isEmpty else { continue }
            built.append(RoomFilter(id: "space:\(spaceId)", label: space.name, roomIds: members))
            claimed.formUnion(members)
        }

        // 2. Bridged rooms not already in a space bucket, grouped by network label.
        var byNetwork: [String: Set<String>] = [:]
        for id in joinedNonSpace where !claimed.contains(id) {
            guard let net = roomsById[id]?.bridgeNetwork else { continue }
            byNetwork[net, default: []].insert(id)
        }
        for net in byNetwork.keys.sorted(by: { $0.lowercased() < $1.lowercased() }) {
            guard let ids = byNetwork[net], !ids.isEmpty else { continue }
            built.append(RoomFilter(id: "bridge:\(net)", label: net, roomIds: ids))
        }

        filters = built
        // Drop a stale selection if its bucket disappeared.
        if let sel = selectedFilterId, !filters.contains(where: { $0.id == sel }) {
            selectedFilterId = nil
        }
    }

    // MARK: - Bridge/space filter UI (main thread only)

    @objc private func filterTapped() {
        // index 0 = "All conversations", then one per bucket.
        var options: [(label: String, id: String?)] = [("All conversations", nil)]
        for f in filters { options.append((f.label, f.id)) }
        pendingFilterOptions = options
#if IOS6_TARGET
        let sheet = UIActionSheet()
        sheet.tag = filterSheetTag
        for opt in options { sheet.addButton(withTitle: opt.label) }
        sheet.addButton(withTitle: "Cancel")
        sheet.cancelButtonIndex = options.count
        sheet.delegate = self
        sheet.show(in: view)
#else
        let sheet = UIAlertController(title: "Filter conversations", message: nil, preferredStyle: .actionSheet)
        for opt in options {
            sheet.addAction(UIAlertAction(title: opt.label, style: .default) { [weak self] _ in
                self?.applyFilter(opt.id)
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = filterButton
        sheet.popoverPresentationController?.sourceRect = filterButton.bounds
        present(sheet, animated: true)
#endif
    }

    private func applyFilter(_ id: String?) {
        selectedFilterId = id
        rebuildDisplayedRoomIds()
        updateFilterControl()
        tableView.reloadData()
    }

    // Filter control = the funnel button beside the search bar. Only shown when
    // at least one bucket exists (otherwise the search bar spans the full width).
    // Icon is the funnel normally; while a filter is active it becomes funnel-x,
    // and tapping then clears the filter (see filterButtonTapped).
    private func updateFilterControl() {
        guard searchBar != nil, filterButton != nil, listHeaderContainer != nil else { return }
        let full = listHeaderContainer.bounds
        if filters.isEmpty {
            filterButton.isHidden = true
            searchBar.frame = full
            return
        }
        filterButton.isHidden = false
        searchBar.frame = CGRect(x: 0, y: 0,
                                 width: full.width - filterButtonWidth, height: full.height)
        let active = selectedFilterId != nil
        if let img = UIImage(named: active ? "FunnelX" : "Funnel") {
            filterButton.setImage(img, for: .normal)
        }
    }

    @objc private func filterButtonTapped() {
        if selectedFilterId != nil {
            applyFilter(nil)
        } else {
            filterTapped()
        }
    }

    // MARK: - New conversation

    @objc private func composeTapped() {
        let vc = NewConversationVC(client: client) { [weak self] roomId, displayName in
            self?.openCreatedRoom(roomId: roomId, displayName: displayName)
        }
        let nav = navigationController
        nav?.pushViewController(vc, animated: true)
    }

    // Called after createRoom succeeds. The room isn't in roomsById yet (it lands
    // on the next /sync), so seed a minimal Room so we can open its timeline right
    // away; /sync fills in the real state/name/members shortly after.
    private func openCreatedRoom(roomId: String, displayName: String) {
        let room = roomsById[roomId] ?? Room(roomId: roomId, name: displayName, lastMessage: "",
                                             lastMessageTimestamp: Date().timeIntervalSince1970 * 1000,
                                             prevBatch: nil, timelineEvents: [],
                                             avatarMxc: nil, memberNames: [:], memberAvatars: [:],
                                             unreadCount: 0, roomType: nil, spaceChildren: [],
                                             bridgeNetwork: nil, bridgeAvatarMxc: nil)
        if roomsById[roomId] == nil {
            roomsById[roomId] = room
            // handleSync only re-sorts when a room's timestamp actually moves, so
            // a locally-seeded room has to enter the id lists here — otherwise it
            // stays out of the list until something in it changes.
            rebuildSortedRoomIds()
            rebuildDisplayedRoomIds()
            tableView.reloadData()
        }
        openRoomId = roomId
        // Pop the compose screen, then push the new room's timeline.
        navigationController?.popToRootViewController(animated: false)
        let vc = RoomTimelineVC(room: room, client: client, syncEngine: syncEngine)
        navigationController?.pushViewController(vc, animated: true)
    }

    // Pure-Swift case-insensitive substring test. Avoids Foundation's
    // `range(of:)`/`contains(_:)` (whose underlying NSString selectors are a
    // crash risk on this iOS 6 runtime) — only Character comparison + lowercased()
    // (already proven safe elsewhere in this file).
    // `query` arrives already lower-cased and unpacked so the caller can hoist
    // that out of its per-room loop.
    private static func nameMatches(_ name: String, query: [Character]) -> Bool {
        if query.isEmpty { return true }
        let n = Array(name.lowercased())
        if query.count > n.count { return false }
        for start in 0...(n.count - query.count) {
            var ok = true
            for j in 0..<query.count where n[start + j] != query[j] { ok = false; break }
            if ok { return true }
        }
        return false
    }
}

#if IOS6_TARGET
extension RoomListVC: UIActionSheetDelegate, UIAlertViewDelegate {
    func actionSheet(_ actionSheet: UIActionSheet, clickedButtonAt buttonIndex: Int) {
        if actionSheet.tag == filterSheetTag {
            // Filter sheet: buttons map 1:1 to pendingFilterOptions; the trailing
            // Cancel button is out of range and ignored.
            if buttonIndex >= 0 && buttonIndex < pendingFilterOptions.count {
                applyFilter(pendingFilterOptions[buttonIndex].id)
            }
            return
        }
        switch buttonIndex {
        case 0: openUserSettings()
        case 1: confirmLogout()
        default: break
        }
    }

    func alertView(_ alertView: UIAlertView, clickedButtonAt buttonIndex: Int) {
        if buttonIndex == 1 { performLogout() }
    }
}
#endif

extension RoomListVC: UITableViewDataSource, UITableViewDelegate {
    func numberOfSections(in tableView: UITableView) -> Int {
        return 2
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section == inviteSection {
            // Hide the invitations banner while filtering — the search bar is for
            // finding an existing conversation.
            return (searchText.isEmpty && !invitations.isEmpty) ? 1 : 0
        }
        return displayedRoomIds.count
    }

    // Taller rows than the stock ~44pt so the avatar + two lines of text aren't
    // cramped and adjacent conversations get some breathing room.
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return indexPath.section == inviteSection ? 44 : 66
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == inviteSection {
            let cell = tableView.dequeueReusableCell(withIdentifier: inviteCellId) ??
                UITableViewCell(style: .value1, reuseIdentifier: inviteCellId)
            cell.textLabel?.text = "Invitations"
            cell.textLabel?.textColor = UIColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 1.0)
            cell.detailTextLabel?.text = "\(invitations.count)"
            cell.accessoryType = .disclosureIndicator
            return cell
        }

        let cell = (tableView.dequeueReusableCell(withIdentifier: cellId) as? RoomCell) ??
            RoomCell(style: .subtitle, reuseIdentifier: cellId)
        guard let room = roomsById[displayedRoomIds[indexPath.row]] else { return cell }
        cell.textLabel?.text = room.name
        cell.detailTextLabel?.text = room.lastMessage
        cell.detailTextLabel?.textColor = .gray
        cell.accessoryType = .disclosureIndicator
        cell.timeLabel.text = TimeFormat.listStamp(msSinceEpoch: room.lastMessageTimestamp)
        cell.setUnreadCount(room.unreadCount)
        cell.setAvatar(mxc: room.avatarMxc, name: room.name)
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == inviteSection {
            let vc = InvitationsVC(invitations: invitations, client: client)
            navigationController?.pushViewController(vc, animated: true)
            return
        }
        let roomId = displayedRoomIds[indexPath.row]
        openRoomId = roomId
        markRoomRead(roomId)
        // Read after markRoomRead so the timeline gets the cleared unread count.
        guard let room = roomsById[roomId] else { return }
        let vc = RoomTimelineVC(room: room, client: client, syncEngine: syncEngine)
        navigationController?.pushViewController(vc, animated: true)
    }

    private func markRoomRead(_ roomId: String) {
        guard var room = roomsById[roomId], room.unreadCount > 0 else { return }
        room.unreadCount = 0
        roomsById[roomId] = room
        // The order and filter lists hold ids, so they still point at the room we
        // just changed — nothing to refresh, just redraw the row against the
        // currently DISPLAYED (possibly filtered) index.
        if let idx = displayedRoomIds.firstIndex(of: roomId) {
            tableView.reloadRows(at: [IndexPath(row: idx, section: roomSection)], with: .none)
        }
        // Opening a room clears its badge locally — reflect that on the icon
        // immediately (already on the main thread here).
        UIApplication.shared.applicationIconBadgeNumber = totalUnreadCount()
    }
}

extension RoomListVC: UISearchBarDelegate {
    func searchBar(_ searchBar: UISearchBar, textDidChange text: String) {
        searchText = text
        rebuildDisplayedRoomIds()
        tableView.reloadData()
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
    }

    func searchBarTextDidBeginEditing(_ searchBar: UISearchBar) {
        searchBar.setShowsCancelButton(true, animated: true)
    }

    func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
        searchBar.text = ""
        searchText = ""
        rebuildDisplayedRoomIds()
        searchBar.setShowsCancelButton(false, animated: true)
        searchBar.resignFirstResponder()
        tableView.reloadData()
    }

    func searchBarTextDidEndEditing(_ searchBar: UISearchBar) {
        searchBar.setShowsCancelButton(false, animated: true)
    }
}

// Custom cell so the time label and unread badge can be positioned reliably in
// layoutSubviews() (relative to the stock textLabel/detailTextLabel frames)
// instead of the previous viewWithTag hack with a hardcoded y-offset, which
// didn't track the actual row layout and looked misaligned.
private class RoomCell: UITableViewCell {
    let timeLabel = UILabel()
    private let badgeBackground = UIView()
    private let badgeLabel = UILabel()
    private let avatarView = AvatarView()
    // Left gutter for the room avatar: margin + circle + gap before the text.
    private let avatarSize: CGFloat = 40
    private let avatarMargin: CGFloat = 12

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        contentView.addSubview(avatarView)

        // iOS 6 runtime: UILabel defaults to an opaque WHITE background. For the
        // badge this was fatal — badgeLabel's white bg filled the blue badge
        // circle with white, and its white text on white was invisible, so the
        // badge looked absent entirely (this, not the count, was why it never
        // showed). Every label here must be explicitly cleared.
        timeLabel.backgroundColor = .clear
        timeLabel.font = UIFont.systemFont(ofSize: 12)
        timeLabel.textColor = .lightGray
        timeLabel.textAlignment = .right
        contentView.addSubview(timeLabel)

        badgeBackground.backgroundColor = UIColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 1.0)
        badgeBackground.isHidden = true
        contentView.addSubview(badgeBackground)

        badgeLabel.backgroundColor = .clear
        badgeLabel.font = UIFont.boldSystemFont(ofSize: 11)
        badgeLabel.textColor = .white
        badgeLabel.textAlignment = .center
        badgeBackground.addSubview(badgeLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setAvatar(mxc: String?, name: String) {
        avatarView.setAvatar(mxc: mxc, name: name)
    }

    func setUnreadCount(_ count: Int) {
        if count > 0 {
            badgeLabel.text = count > 99 ? "99+" : "\(count)"
            badgeBackground.isHidden = false
        } else {
            badgeBackground.isHidden = true
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let margin: CGFloat = 15

        // Circular avatar at the left, vertically centred.
        let avatarY = (contentView.bounds.height - avatarSize) / 2
        avatarView.frame = CGRect(x: avatarMargin, y: avatarY, width: avatarSize, height: avatarSize)

        // Everything to the right of the avatar starts here.
        let textLeft = avatarMargin + avatarSize + 12

        // Time label, right-aligned on the top line.
        timeLabel.sizeToFit()
        let timeY = (textLabel?.frame.midY ?? contentView.bounds.midY / 2) - timeLabel.frame.height / 2
        timeLabel.frame.origin = CGPoint(x: contentView.bounds.width - timeLabel.frame.width - margin, y: timeY)

        // Room name (top line): set its x and width EXPLICITLY rather than
        // nudging the stock frame. In `.subtitle` style, super.layoutSubviews()
        // sizes textLabel to its *content* width, so the earlier "shift right and
        // shrink by the same delta" shrank the title below its content width and
        // truncated it far too early. Give it the full span from the gutter to
        // just before the time label instead.
        if let tl = textLabel {
            tl.frame.origin.x = textLeft
            let right = timeLabel.frame.minX - 8
            tl.frame.size.width = max(0, right - textLeft)
        }

        // Badge (unread count), bottom-right.
        let badgeHeight: CGFloat = 18
        if !badgeBackground.isHidden {
            badgeLabel.sizeToFit()
            let badgeWidth = max(badgeHeight, badgeLabel.frame.width + 10)
            let badgeY = contentView.bounds.height - badgeHeight - 10
            badgeBackground.frame = CGRect(x: contentView.bounds.width - badgeWidth - margin, y: badgeY,
                                            width: badgeWidth, height: badgeHeight)
            badgeBackground.layer.cornerRadius = badgeHeight / 2
            badgeLabel.frame = badgeBackground.bounds
        }

        // Last-message preview (subtitle): same explicit-width treatment, stopping
        // before the badge (or the right margin when there's no badge).
        if let dl = detailTextLabel {
            dl.frame.origin.x = textLeft
            let right = badgeBackground.isHidden ? contentView.bounds.width - margin
                                                 : badgeBackground.frame.minX - 8
            dl.frame.size.width = max(0, right - textLeft)
        }

        if !badgeBackground.isHidden { contentView.bringSubviewToFront(badgeBackground) }
    }
}

// MARK: - New Conversation

// Start a direct message or create a group room. Appended here (not a separate
// file) to avoid a project.pbxproj round-trip — same trick as MemberListVC in
// RoomTimelineVC.swift.
//
// Direct mode: search the user directory (or type a raw @user:server) and tap a
// result to create a DM (createRoom is_direct + trusted_private_chat preset).
// Group mode: enter a room name, tap users to select them, then Create.
//
// iOS 6-safe: no #available / topLayoutGuide (controls live in the table header
// so UIKit positions them under the nav bar automatically); dual-target alerts;
// all inputs travel in JSON request bodies, never in a URL, so no percent-encoding.
class NewConversationVC: UIViewController {

    enum Mode { case direct, group }

    private let client: MatrixAPIClient
    private let onCreated: (_ roomId: String, _ displayName: String) -> Void

    private var mode: Mode = .direct
    private var results: [(userId: String, name: String, avatarMxc: String?)] = []
    private var selected: [String: String] = [:]   // userId -> display name (group mode)
    private var creating = false
    private var searchToken = 0

    private var tableView: UITableView!
    private var headerContainer: UIView!
    private var segmented: UISegmentedControl!
    private var nameField: UITextField!
    private var searchField: UITextField!
    private var createItem: UIBarButtonItem!

    private let cellId = "UserResultCell"

    init(client: MatrixAPIClient, onCreated: @escaping (String, String) -> Void) {
        self.client = client
        self.onCreated = onCreated
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "New Conversation"
        view.backgroundColor = .white

        tableView = UITableView(frame: view.bounds, style: .plain)
        tableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 58
        view.addSubview(tableView)

        buildHeader()

        createItem = UIBarButtonItem(title: "Create", style: .done,
                                     target: self, action: #selector(createGroupTapped))
        updateCreateButton()
    }

    // MARK: header

    private func buildHeader() {
        let width = view.bounds.width
        headerContainer = UIView(frame: CGRect(x: 0, y: 0, width: width, height: 10))
        headerContainer.autoresizingMask = [.flexibleWidth]

        segmented = UISegmentedControl(items: ["Direct", "Group"])
        segmented.selectedSegmentIndex = 0
        segmented.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
        headerContainer.addSubview(segmented)

        nameField = makeField(placeholder: "Group name")
        nameField.addTarget(self, action: #selector(nameEditingChanged), for: .editingChanged)
        headerContainer.addSubview(nameField)

        searchField = makeField(placeholder: "Search users or @user:server")
        searchField.autocapitalizationType = .none
        searchField.autocorrectionType = .no
        searchField.returnKeyType = .search
        searchField.addTarget(self, action: #selector(searchEditingChanged), for: .editingChanged)
        searchField.delegate = self
        headerContainer.addSubview(searchField)

        layoutHeader()
    }

    private func makeField(placeholder: String) -> UITextField {
        return makeRoundedField(placeholder: placeholder)
    }

    // Recomputes the header layout for the current mode and (re)assigns it so the
    // table picks up the new height. The group-name field only exists in group mode.
    private func layoutHeader() {
        let width = view.bounds.width
        let pad: CGFloat = 12
        let fieldH: CGFloat = 34
        segmented.frame = CGRect(x: pad, y: pad, width: width - pad * 2, height: 30)

        var y = segmented.frame.maxY + 10
        if mode == .group {
            nameField.isHidden = false
            nameField.frame = CGRect(x: pad, y: y, width: width - pad * 2, height: fieldH)
            y = nameField.frame.maxY + 8
        } else {
            nameField.isHidden = true
        }
        searchField.frame = CGRect(x: pad, y: y, width: width - pad * 2, height: fieldH)
        y = searchField.frame.maxY + pad

        headerContainer.frame = CGRect(x: 0, y: 0, width: width, height: y)
        tableView.tableHeaderView = headerContainer
    }

    @objc private func modeChanged() {
        mode = segmented.selectedSegmentIndex == 0 ? .direct : .group
        selected.removeAll()
        layoutHeader()
        updateCreateButton()
        tableView.reloadData()
    }

    // Group mode shows a "Create" button, enabled once a name + at least one
    // member are set. Direct mode has no button (tapping a user starts the DM).
    private func updateCreateButton() {
        if mode == .group {
            navigationItem.rightBarButtonItem = createItem
            let name = (nameField.text ?? "").trimmed()
            createItem.isEnabled = !name.isEmpty && !selected.isEmpty && !creating
        } else {
            navigationItem.rightBarButtonItem = nil
        }
    }

    // MARK: search

    @objc private func searchEditingChanged() {
        performSearch()
    }

    @objc private func nameEditingChanged() {
        updateCreateButton()
    }

    private func performSearch() {
        searchToken += 1
        let token = searchToken
        UserDirectory.search(client: client, term: (searchField.text ?? "").trimmed()) { [weak self] found in
            guard let self = self, token == self.searchToken else { return }
            self.results = found
            self.tableView.reloadData()
        }
    }

    // MARK: create

    private func startDirect(userId: String, name: String) {
        guard !creating else { return }
        createRoom(body: ["is_direct": true,
                          "preset": "trusted_private_chat",
                          "invite": [userId]],
                   displayName: name)
    }

    @objc private func createGroupTapped() {
        guard mode == .group, !creating else { return }
        let name = (nameField.text ?? "").trimmed()
        guard !name.isEmpty, !selected.isEmpty else { return }
        let invites = Array(selected.keys)
        createRoom(body: ["preset": "private_chat", "name": name, "invite": invites],
                   displayName: name)
    }

    private func createRoom(body: [String: Any], displayName: String) {
        creating = true
        updateCreateButton()
        view.endEditing(true)
        client.post("/_matrix/client/v3/createRoom", body: body) { [weak self] json, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.creating = false
                self.updateCreateButton()
                if let roomId = json?["room_id"] as? String {
                    self.onCreated(roomId, displayName)
                } else {
                    self.showError("Couldn't create conversation", "\(error.map { "\($0)" } ?? "Unknown error")")
                }
            }
        }
    }

    private func showError(_ title: String, _ message: String) {
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

extension NewConversationVC: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        if textField === searchField { performSearch() }
        return true
    }
}

extension NewConversationVC: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return results.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: cellId)
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: cellId)
        let r = results[indexPath.row]
        cell.textLabel?.text = r.name
        cell.detailTextLabel?.text = r.userId
        cell.detailTextLabel?.textColor = .gray
        if mode == .group {
            cell.accessoryType = (selected[r.userId] != nil) ? .checkmark : .none
        } else {
            cell.accessoryType = .disclosureIndicator
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let r = results[indexPath.row]
        if mode == .group {
            if selected[r.userId] != nil { selected[r.userId] = nil }
            else { selected[r.userId] = r.name }
            tableView.reloadRows(at: [indexPath], with: .none)
            updateCreateButton()
        } else {
            startDirect(userId: r.userId, name: r.name)
        }
    }
}

// MARK: - Shared user-directory search

// User-directory lookup shared by New Conversation and Invite. Always offers a
// raw "@user:server" row when the typed text looks like a Matrix ID, so an exact
// user can be reached even on a homeserver with the directory disabled.
struct UserDirectory {
    typealias Result = (userId: String, name: String, avatarMxc: String?)

    // Completion is always delivered on the main thread.
    static func search(client: MatrixAPIClient, term: String,
                       completion: @escaping ([Result]) -> Void) {
        let mxidRow: [Result] = looksLikeMXID(term) ? [(userId: term, name: term, avatarMxc: nil)] : []
        guard term.count >= 2 else { completion(mxidRow); return }
        client.post("/_matrix/client/v3/user_directory/search",
                    body: ["search_term": term, "limit": 20]) { json, _ in
            DispatchQueue.main.async {
                var found: [Result] = []
                if let arr = json?["results"] as? [[String: Any]] {
                    for r in arr {
                        guard let uid = r["user_id"] as? String else { continue }
                        let dn = (r["display_name"] as? String) ?? uid
                        found.append((userId: uid, name: dn, avatarMxc: r["avatar_url"] as? String))
                    }
                }
                for m in mxidRow where !found.contains(where: { $0.userId == m.userId }) {
                    found.insert(m, at: 0)
                }
                completion(found)
            }
        }
    }

    static func looksLikeMXID(_ s: String) -> Bool {
        return s.hasPrefix("@") && s.firstIndex(of: ":") != nil && s.count >= 4
    }
}

// Rounded white text field matching RoomTimelineVC's chat input: no bezel (the
// roundedRect bezel's fixed insets look misaligned at custom heights on this
// runtime), thin grey border, small left inset spacer.
fileprivate func makeRoundedField(placeholder: String) -> UITextField {
    let f = UITextField()
    f.borderStyle = .none
    f.backgroundColor = .white
    f.layer.cornerRadius = 8
    f.layer.masksToBounds = true
    f.layer.borderWidth = 0.5
    f.layer.borderColor = UIColor(white: 0.8, alpha: 1.0).cgColor
    f.font = UIFont.systemFont(ofSize: 16)
    f.contentVerticalAlignment = .center
    f.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 1))
    f.leftViewMode = .always
    f.placeholder = placeholder
    f.clearButtonMode = .whileEditing
    return f
}

// MARK: - Invite someone

// Invite a user to an existing room, pushed from Room Settings. Lives here (not
// in RoomTimelineVC.swift) so all user-directory UI shares one implementation.
class InviteUserVC: UIViewController {

    private let roomId: String
    private let client: MatrixAPIClient
    private var results: [UserDirectory.Result] = []
    private var searchToken = 0
    private var inviting = false

    private var tableView: UITableView!
    private var headerContainer: UIView!
    private var searchField: UITextField!
    private let cellId = "InviteResultCell"

    init(roomId: String, client: MatrixAPIClient) {
        self.roomId = roomId
        self.client = client
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Invite"
        view.backgroundColor = .white

        tableView = UITableView(frame: view.bounds, style: .plain)
        tableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 58
        view.addSubview(tableView)

        // Controls live in the table header so UIKit positions them under the nav
        // bar with no #available / topLayoutGuide (both unsafe on this runtime).
        let width = view.bounds.width
        headerContainer = UIView(frame: CGRect(x: 0, y: 0, width: width, height: 58))
        headerContainer.autoresizingMask = [.flexibleWidth]
        searchField = makeRoundedField(placeholder: "Search users or @user:server")
        searchField.autocapitalizationType = .none
        searchField.autocorrectionType = .no
        searchField.returnKeyType = .search
        searchField.frame = CGRect(x: 12, y: 12, width: width - 24, height: 34)
        searchField.addTarget(self, action: #selector(searchEditingChanged), for: .editingChanged)
        searchField.delegate = self
        headerContainer.addSubview(searchField)
        tableView.tableHeaderView = headerContainer
    }

    @objc private func searchEditingChanged() { performSearch() }

    private func performSearch() {
        searchToken += 1
        let token = searchToken
        UserDirectory.search(client: client, term: (searchField.text ?? "").trimmed()) { [weak self] found in
            guard let self = self, token == self.searchToken else { return }
            self.results = found
            self.tableView.reloadData()
        }
    }

    private func invite(userId: String, name: String) {
        guard !inviting else { return }
        inviting = true
        view.endEditing(true)
        // Room and user IDs go UNENCODED in the path; the user id travels in the
        // JSON body anyway.
        client.post("/_matrix/client/v3/rooms/\(roomId)/invite",
                    body: ["user_id": userId]) { [weak self] _, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.inviting = false
                if let error = error {
                    self.showAlert("Couldn't invite", "\(error)")
                } else {
                    // No success alert: presenting one from a view controller
                    // that's being popped doesn't reliably show. The invitee
                    // shows up in the member list instead.
                    _ = name
                    self.navigationController?.popViewController(animated: true)
                }
            }
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

extension InviteUserVC: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        performSearch()
        return true
    }
}

extension InviteUserVC: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return results.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: cellId)
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: cellId)
        let r = results[indexPath.row]
        cell.textLabel?.text = r.name
        cell.detailTextLabel?.text = r.userId
        cell.detailTextLabel?.textColor = .gray
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let r = results[indexPath.row]
        invite(userId: r.userId, name: r.name)
    }
}

private extension String {
    // Pure-Swift whitespace trim (no Foundation CharacterSet — iOS-6-safe rule).
    func trimmed() -> String {
        let ws: Set<Character> = [" ", "\t", "\n", "\r"]
        var chars = Array(self)
        while let f = chars.first, ws.contains(f) { chars.removeFirst() }
        while let l = chars.last, ws.contains(l) { chars.removeLast() }
        return String(chars)
    }
}
