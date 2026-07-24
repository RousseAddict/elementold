import UIKit

// Root screen after login: joined rooms, driven by SyncEngine updates.
// Owns the shared MatrixAPIClient/SyncEngine instances for the session, passed
// down to RoomTimelineVC on row selection.
class RoomListVC: UIViewController {

    private var tableView: UITableView!
    private var statusLabel: UILabel!
    private var roomsById: [String: Room] = [:]
    private var sortedRooms: [Room] = []
    // Pending invites, keyed by roomId. Kept as a running map (not replaced per
    // sync) because incremental syncs only report *changed* invites; an invite
    // is cleared when the room later shows up under join (accepted) or leave
    // (declined/left). `invitations` is the sorted view rendered in the banner.
    private var invitesById: [String: Invitation] = [:]
    private var invitations: [Invitation] = []
    private var hasSyncedOnce = false
    private var loadingTimer: Timer?
    private var loadingSeconds = 0
    private var lastErrorText: String?
    // The room currently pushed on screen, if any — Room.parse uses this to
    // avoid counting messages as unread while the user is already looking at
    // that room's timeline, and markRoomRead zeroes the badge on selection.
    private var openRoomId: String?

    // Search bar (table header) + current filter text.
    private var searchBar: UISearchBar!
    private var searchText: String = ""

    // Bridge/space grouping. A "bucket" is one space (its child rooms) or one
    // bridged network (its portal rooms). Built after each /sync from roomsById;
    // `selectedFilterId == nil` means "All conversations". The filter is applied
    // on top of the space-room exclusion + search text in `displayedRooms`.
    private struct RoomFilter { let id: String; let label: String; let roomIds: Set<String> }
    private var filters: [RoomFilter] = []
    private var selectedFilterId: String?
    private var filterItem: UIBarButtonItem!
    // Options captured for the iOS 6 UIActionSheet delegate (index -> filter id).
    private var pendingFilterOptions: [(label: String, id: String?)] = []
    private let filterSheetTag = 91

    private let client: MatrixAPIClient
    private let syncEngine: SyncEngine

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

        // Filter button (bridge/space buckets). Hidden until at least one bucket
        // is discovered from /sync (updateFilterButton).
        filterItem = UIBarButtonItem(title: "Filter", style: .plain,
                                     target: self, action: #selector(filterTapped))
        updateFilterButton()

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
        tableView.tableHeaderView = searchBar

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

        // Background notifications (gated by the Settings kill switch; off by
        // default → this listener is a no-op and no background work is taken).
        NotificationManager.shared.syncEngine = syncEngine
        syncEngine.addUpdateListener { json, isInitial in
            NotificationManager.shared.handleSync(json, isInitial: isInitial)
        }

        syncEngine.start()

        // Diagnostic: if this ticker itself stalls, the main thread is deadlocked
        // (not just waiting on the network). If it keeps ticking with no sync
        // response ever arriving, the request itself is what's stuck.
        // (Selector-based Timer, not the block-based iOS10+ API — iOS 6/7 target.)
        loadingTimer = Timer.scheduledTimer(timeInterval: 1, target: self,
                                             selector: #selector(loadingTick), userInfo: nil, repeats: true)
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
        updateInvitations(from: rooms)

        if let join = rooms?["join"] as? [String: Any] {
            for (roomId, rawRoom) in join {
                guard let roomJSON = rawRoom as? [String: Any] else { continue }
                let existing = roomsById[roomId]
                roomsById[roomId] = Room.parse(roomId: roomId, json: roomJSON, existing: existing,
                                                selfUserId: MatrixSession.userId, isOpen: roomId == openRoomId,
                                                isInitialSync: isInitial)
            }
            sortedRooms = roomsById.values.sorted { $0.lastMessageTimestamp > $1.lastMessageTimestamp }
        }

        // Rebuild the bridge/space filter buckets from the (just-updated) rooms.
        rebuildFilters()

        hasSyncedOnce = true
        // Total unread across all joined rooms, mirrored on the app icon badge.
        // Computed here (off-main, right after the roomsById mutation) so the
        // main-thread block below only reads a captured Int, never roomsById.
        let totalUnread = totalUnreadCount()
        DispatchQueue.main.async { [weak self] in
            self?.tableView.reloadData()
            self?.updateStatusLabel()
            self?.updateFilterButton()
            UIApplication.shared.applicationIconBadgeNumber = totalUnread
        }
    }

    // Sum of every joined room's unread count — drives the app icon badge.
    private func totalUnreadCount() -> Int {
        return roomsById.values.reduce(0) { $0 + $1.unreadCount }
    }

    // Maintains the pending-invite map from a /sync `rooms` object: upserts
    // anything under `invite`, and clears anything that has since moved to
    // `join` (accepted) or `leave` (declined/left).
    private func updateInvitations(from rooms: [String: Any]?) {
        guard let rooms = rooms else { return }
        if let invite = rooms["invite"] as? [String: Any] {
            for (roomId, raw) in invite {
                guard let inviteJSON = raw as? [String: Any] else { continue }
                invitesById[roomId] = Invitation.parse(roomId: roomId, json: inviteJSON,
                                                        selfUserId: MatrixSession.userId)
            }
        }
        for key in ["join", "leave"] {
            if let section = rooms[key] as? [String: Any] {
                for roomId in section.keys { invitesById[roomId] = nil }
            }
        }
        invitations = invitesById.values.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    private func handleSyncError(_ error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // Only surface this if we've never synced successfully — once rooms
            // are showing, a transient retry-loop error shouldn't blank the screen.
            guard self.sortedRooms.isEmpty else { return }
            let tokenState = self.client.accessToken.map { token in "present, \(token.count) chars" } ?? "MISSING (nil)"
            self.lastErrorText = "Sync error:\n\(error)\n\n[debug] token: \(tokenState)"
            self.statusLabel.text = self.lastErrorText
            self.statusLabel.isHidden = false
        }
    }

    private func updateStatusLabel() {
        loadingTimer?.invalidate()
        loadingTimer = nil
        if !sortedRooms.isEmpty {
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
        // Clear the app icon badge so the next account doesn't inherit a stale count.
        UIApplication.shared.applicationIconBadgeNumber = 0
        MatrixSession.clear()
        // Drop cached media too, so a different account signing in on this
        // device doesn't inherit the previous user's downloaded images.
        MediaCache.shared.clear {}
        navigationController?.setViewControllers([LoginVC()], animated: true)
    }

    // MARK: - Search / filter

    // Rooms shown in the list. Three filters stacked, in order:
    //   1. Space rooms (isSpace) are never shown — they're grouping containers
    //      with no timeline, surfaced only as filter buckets.
    //   2. The selected bridge/space bucket, if any (selectedFilterId != nil).
    //   3. The search bar text (client-side: Matrix has no "search my joined
    //      rooms" endpoint, so filtering the synced list by name is correct).
    private var displayedRooms: [Room] {
        var rooms = sortedRooms.filter { !$0.isSpace }
        if let id = selectedFilterId,
           let bucket = filters.first(where: { $0.id == id }) {
            rooms = rooms.filter { bucket.roomIds.contains($0.roomId) }
        }
        if !searchText.isEmpty {
            rooms = rooms.filter { RoomListVC.nameMatches($0.name, query: searchText) }
        }
        return rooms
    }

    // Rebuilds the filter buckets from roomsById. Called off-main after every
    // /sync (only mutates our own filter state, never UIKit).
    //   Spaces first: one bucket per joined space room, containing the joined,
    //   non-space rooms it lists via m.space.child (spaceChildren).
    //   Bridges second: for every bridged room (bridgeNetwork != nil) not already
    //   claimed by a space bucket, one bucket per distinct network label.
    // Buckets with no currently-joined member rooms are dropped.
    private func rebuildFilters() {
        let joinedNonSpace = Set(roomsById.values.filter { !$0.isSpace }.map { $0.roomId })
        var built: [RoomFilter] = []
        var claimed = Set<String>()

        // 1. Spaces.
        let spaces = roomsById.values.filter { $0.isSpace }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
        for space in spaces {
            let members = space.spaceChildren.intersection(joinedNonSpace)
            guard !members.isEmpty else { continue }
            built.append(RoomFilter(id: "space:\(space.roomId)", label: space.name, roomIds: members))
            claimed.formUnion(members)
        }

        // 2. Bridged rooms not already in a space bucket, grouped by network label.
        var byNetwork: [String: Set<String>] = [:]
        for room in roomsById.values where !room.isSpace {
            guard let net = room.bridgeNetwork, !claimed.contains(room.roomId) else { continue }
            byNetwork[net, default: []].insert(room.roomId)
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
        sheet.show(from: filterItem, animated: true)
#else
        let sheet = UIAlertController(title: "Filter conversations", message: nil, preferredStyle: .actionSheet)
        for opt in options {
            sheet.addAction(UIAlertAction(title: opt.label, style: .default) { [weak self] _ in
                self?.applyFilter(opt.id)
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.barButtonItem = filterItem
        present(sheet, animated: true)
#endif
    }

    private func applyFilter(_ id: String?) {
        selectedFilterId = id
        updateFilterButton()
        tableView.reloadData()
    }

    // Shows the filter button only when at least one bucket exists; its title
    // reflects the current selection ("Filter" when showing all).
    private func updateFilterButton() {
        guard filterItem != nil else { return }
        if filters.isEmpty {
            navigationItem.rightBarButtonItem = nil
            return
        }
        navigationItem.rightBarButtonItem = filterItem
        if let sel = selectedFilterId,
           let f = filters.first(where: { $0.id == sel }) {
            filterItem.title = f.label
        } else {
            filterItem.title = "Filter"
        }
    }

    // Pure-Swift case-insensitive substring test. Avoids Foundation's
    // `range(of:)`/`contains(_:)` (whose underlying NSString selectors are a
    // crash risk on this iOS 6 runtime) — only Character comparison + lowercased()
    // (already proven safe elsewhere in this file).
    private static func nameMatches(_ name: String, query: String) -> Bool {
        let n = Array(name.lowercased())
        let q = Array(query.lowercased())
        if q.isEmpty { return true }
        if q.count > n.count { return false }
        for start in 0...(n.count - q.count) {
            var ok = true
            for j in 0..<q.count where n[start + j] != q[j] { ok = false; break }
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
        return displayedRooms.count
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
        let room = displayedRooms[indexPath.row]
        cell.textLabel?.text = room.name
        cell.detailTextLabel?.text = room.lastMessage
        cell.detailTextLabel?.textColor = .gray
        cell.accessoryType = .disclosureIndicator
        cell.timeLabel.text = TimeFormat.shortTime(msSinceEpoch: room.lastMessageTimestamp)
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
        let room = displayedRooms[indexPath.row]
        openRoomId = room.roomId
        markRoomRead(room.roomId)
        let vc = RoomTimelineVC(room: roomsById[room.roomId] ?? room, client: client, syncEngine: syncEngine)
        navigationController?.pushViewController(vc, animated: true)
    }

    private func markRoomRead(_ roomId: String) {
        guard var room = roomsById[roomId], room.unreadCount > 0 else { return }
        room.unreadCount = 0
        roomsById[roomId] = room
        if let sIdx = sortedRooms.firstIndex(where: { $0.roomId == roomId }) {
            sortedRooms[sIdx].unreadCount = 0
        }
        // Reload against the currently DISPLAYED (possibly filtered) index.
        if let idx = displayedRooms.firstIndex(where: { $0.roomId == roomId }) {
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
