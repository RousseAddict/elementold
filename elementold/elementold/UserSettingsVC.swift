import UIKit

// User settings screen, pushed from the account (user-circle) menu on the room
// list. For now it exposes the media cache: how much disk it's using and a way
// to clear it. A grouped table keeps room to grow (notifications, about, etc.).
class UserSettingsVC: UIViewController {

    private var tableView: UITableView!
    private let cellId = "SettingsCell"

    // Latest computed disk usage, shown in the "Cache" row's detail text.
    private var cacheBytes: UInt64 = 0
    private var cacheFiles: Int = 0
    private var cacheLoading = true

    // Same, for downloaded attachments (Documents/elementold-files), which are
    // kept outside the media cache so they survive its automatic trimming.
    private var filesBytes: UInt64 = 0
    private var filesCount: Int = 0
    private var filesLoading = true

    // Tags distinguishing the two confirmation sheets on the iOS 6 path, where
    // a single UIActionSheetDelegate handles both.
    private let cacheSheetTag = 81
    private let filesSheetTag = 82

    // Matrix client for the profile API, plus the current profile once fetched.
    private let client = MatrixSession.makeAPIClient()
    private var displayName: String?
    private var avatarMxc: String?
    private var profileLoading = true
    // Strongly held: UIImagePickerController's delegate is weak, so a picker
    // helper created as a local would be gone before the user picks anything.
    private var avatarPicker: AvatarPicker?

    // Whether the recorded crash log is expanded in the Diagnostics section.
    // Collapsed by default so it never dominates the screen; the crash text is
    // only rendered in the footer while this is true.
    private var crashExpanded = false

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
        view.backgroundColor = .white

        tableView = UITableView(frame: view.bounds, style: .grouped)
        tableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tableView.dataSource = self
        tableView.delegate = self
        view.addSubview(tableView)

        refreshUsage()
        fetchProfile()
    }

    private func refreshUsage() {
        cacheLoading = true
        reloadCacheRow()
        MediaCache.shared.diskUsage { [weak self] bytes, files in
            guard let self = self else { return }
            self.cacheBytes = bytes
            self.cacheFiles = files
            self.cacheLoading = false
            self.reloadCacheRow()
        }
        filesLoading = true
        reloadFilesRow()
        MediaCache.shared.filesUsage { [weak self] bytes, files in
            guard let self = self else { return }
            self.filesBytes = bytes
            self.filesCount = files
            self.filesLoading = false
            self.reloadFilesRow()
        }
    }

    private func reloadCacheRow() {
        guard isViewLoaded else { return }
        // Storage is section 2 (0 = Account, 1 = Notifications). Reloading the
        // wrong row here previously left "Cache used" stuck showing "…".
        tableView.reloadRows(at: [IndexPath(row: 0, section: 2)], with: .none)
    }

    private func reloadFilesRow() {
        guard isViewLoaded else { return }
        tableView.reloadRows(at: [IndexPath(row: 1, section: 2)], with: .none)
    }

    @objc private func notificationsToggled(_ sw: UISwitch) {
        NotificationManager.shared.setEnabled(sw.isOn)
    }

    // Bytes -> "1.2 MB" / "834 KB". Hand-rolled (no ByteCountFormatter, whose
    // behaviour on the swapped 5.1.5 runtime is unverified) using only arithmetic.
    private func humanSize(_ bytes: UInt64) -> String {
        if bytes >= 1024 * 1024 {
            let mb = Double(bytes) / (1024.0 * 1024.0)
            return String(format: "%.1f MB", mb)
        }
        if bytes >= 1024 {
            let kb = Double(bytes) / 1024.0
            return String(format: "%.0f KB", kb)
        }
        return "\(bytes) B"
    }

    private func confirmClearCache() {
        let title = "Reset cache?"
        let message = "This deletes all downloaded images and the saved room list. Everything is fetched again when needed."
#if IOS6_TARGET
        let sheet = UIActionSheet()
        sheet.title = message
        sheet.addButton(withTitle: "Reset Cache")   // index 0 (destructive)
        sheet.addButton(withTitle: "Cancel")         // index 1
        sheet.destructiveButtonIndex = 0
        sheet.cancelButtonIndex = 1
        sheet.tag = cacheSheetTag
        sheet.delegate = self
        sheet.show(in: view)
        _ = title
#else
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Reset Cache", style: .destructive) { [weak self] _ in
            self?.performClearCache()
        })
        present(alert, animated: true)
#endif
    }

    private func performClearCache() {
        // Also forget the persisted room list, so "Reset Cache" means one thing.
        // Harmless mid-session: the live list and the in-memory delta token are
        // untouched, so nothing on screen changes — the next cold start just pays
        // for a full sync again.
        RoomStore.shared.discard()
        // Restored message keys are deliberately kept. They are re-fetchable in
        // principle, but only by re-entering the recovery key — too high a price
        // for the few KB they occupy, and losing them silently turns every
        // encrypted message back into a placeholder. The hard logout still wipes
        // them, which is the case that actually matters.
        MediaCache.shared.clear { [weak self] in
            self?.refreshUsage()
        }
    }

    private func confirmClearDownloads() {
        let title = "Delete downloads?"
        let message = "This deletes every attachment you've downloaded. They can be downloaded again."
#if IOS6_TARGET
        let sheet = UIActionSheet()
        sheet.title = message
        sheet.addButton(withTitle: "Delete Downloads")   // index 0 (destructive)
        sheet.addButton(withTitle: "Cancel")             // index 1
        sheet.destructiveButtonIndex = 0
        sheet.cancelButtonIndex = 1
        sheet.tag = filesSheetTag
        sheet.delegate = self
        sheet.show(in: view)
        _ = title
#else
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete Downloads", style: .destructive) { [weak self] _ in
            self?.performClearDownloads()
        })
        present(alert, animated: true)
#endif
    }

    private func performClearDownloads() {
        MediaCache.shared.clearFiles { [weak self] in
            self?.refreshUsage()
        }
    }

    private func copyCrashLog() {
        guard let crash = CrashLogger.lastCrash else { return }
        UIPasteboard.general.string = crash
        let title = "Copied"
        let message = "Crash log copied to the clipboard."
#if IOS6_TARGET
        UIAlertView(title: title, message: message, delegate: nil, cancelButtonTitle: "OK").show()
#else
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
#endif
    }

    // MARK: - Account (photo + display name)

    private func fetchProfile() {
        guard let userId = MatrixSession.userId else { profileLoading = false; return }
        // Matrix IDs (@user:server) go UNENCODED in the path — percent-encoding
        // via Foundation crashes on this iOS 6 runtime, and curl accepts the raw
        // path fine (same as every other room/user path in this project).
        // The bare /profile/{userId} endpoint returns both fields in one request.
        client.get("/_matrix/client/v3/profile/\(userId)") { [weak self] json, _ in
            guard let self = self else { return }
            self.displayName = json?["displayname"] as? String
            self.avatarMxc = json?["avatar_url"] as? String
            self.profileLoading = false
            self.reloadAccountSection()
        }
    }

    private func reloadAccountSection() {
        guard isViewLoaded else { return }
        tableView.reloadSections(IndexSet(integer: 0), with: .none)
    }

    private func pickAvatar() {
        let picker = AvatarPicker(client: client)
        avatarPicker = picker
        picker.start(from: self, anchor: view) { [weak self] mxc, _, error in
            guard let self = self else { return }
            self.avatarPicker = nil
            guard let mxc = mxc else {
                if let error = error { self.showError(error) }
                return
            }
            self.saveAvatar(mxc)
        }
    }

    private func saveAvatar(_ mxc: String) {
        guard let userId = MatrixSession.userId else { return }
        let path = "/_matrix/client/v3/profile/\(userId)/avatar_url"
        client.put(path, body: ["avatar_url": mxc]) { [weak self] _, error in
            guard let self = self else { return }
            if let error = error { self.showError(error); return }
            self.avatarMxc = mxc
            self.reloadAccountSection()
        }
    }

    private func openRecoveryKey() {
        let vc = RecoveryKeyVC(client: client)
        // The key count is only known after a restore, and the user is still on
        // the recovery screen when it lands — refresh so the row is right when
        // they come back.
        vc.onRestored = { [weak self] in self?.reloadEncryptionSection() }
        navigationController?.pushViewController(vc, animated: true)
    }

    private func reloadEncryptionSection() {
        tableView.reloadSections(IndexSet(integer: 3), with: .none)
    }

    private func showError(_ error: Error) {
        let title = "Couldn't update"
        let message = error.localizedDescription
#if IOS6_TARGET
        UIAlertView(title: title, message: message, delegate: nil, cancelButtonTitle: "OK").show()
#else
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
#endif
    }

    private func promptEditDisplayName() {
        // A dedicated pushed editor rather than a UIAlertView text-input alert:
        // UIAlertView's `.plainTextInput` style froze the app on the iOS 6
        // runtime. A plain pushed VC with a UITextField + Save bar button uses
        // only rock-solid iOS 6 primitives.
        let editor = TextEditVC(screenTitle: "Display name", placeholder: "Display name",
                                current: displayName ?? "", multiline: false)
        editor.onSave = { [weak self] name in self?.saveDisplayName(name) }
        navigationController?.pushViewController(editor, animated: true)
    }

    fileprivate func saveDisplayName(_ raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != displayName, let userId = MatrixSession.userId else { return }
        let path = "/_matrix/client/v3/profile/\(userId)/displayname"
        client.put(path, body: ["displayname": name]) { [weak self] _, error in
            guard let self = self else { return }
            if let error = error { self.showError(error); return }
            self.displayName = name
            self.reloadAccountSection()
        }
    }
}

extension UserSettingsVC: UITableViewDataSource, UITableViewDelegate {
    // 0 = Account (display name), 1 = Notifications (kill switch), 2 = Storage
    // (cache), 3 = Encryption (recovery key), 4 = Diagnostics.
    func numberOfSections(in tableView: UITableView) -> Int { return 5 }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0: return "Account"
        case 1: return "Notifications"
        case 2: return "Storage"
        case 3: return "Encryption"
        default: return "Diagnostics"
        }
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if section == 1 {
            return "Keeps syncing in the background to alert you of new messages. "
                 + "Off by default; turning it off stops all background activity."
        }
        if section == 3 {
            return "Your recovery key unlocks the message keys stored on the server, "
                 + "so encrypted messages can be read here. It cannot be used to sign in."
        }
        guard section == 4 else { return nil }
        // Build time comes off the executable's mtime, so it can't drift out of sync
        // with what's actually installed — the reliable way to spot a stale install.
        var parts = ["Build: \(UserSettingsVC.buildStamp)"]
        // Surfaces the last recorded crash (if any) here rather than as a
        // launch-time popup — inspectable on demand without interrupting startup.
        if crashExpanded, let crash = CrashLogger.lastCrash { parts.append("Last crash:\n\(crash)") }
        return parts.joined(separator: "\n\n")
    }

    // `let`, not a function: UIKit asks for a section's footer text repeatedly
    // (every reload, every rotation), and this stats the executable and builds a
    // DateFormatter. The executable's mtime can't change while we're running it,
    // so resolve it once on first use.
    private static let buildStamp: String = {
        guard let path = Bundle.main.executablePath,
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let date = attrs[.modificationDate] as? Date else { return "unknown" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d HH:mm"
        return formatter.string(from: date)
    }()

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0: return 2                     // photo, display name
        case 1: return 1                     // notifications toggle
        case 2: return 4                     // cache usage, downloads usage, reset, delete
        case 3: return 2                     // enter recovery key, restored key count
        default:
            // Diagnostics: crash-log toggle row (+ a copy row when expanded),
            // only when a crash was actually recorded.
            guard CrashLogger.lastCrash != nil else { return 0 }
            return crashExpanded ? 2 : 1
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        // Section 0: Account — photo, then display name (both tap to edit).
        if indexPath.section == 0 {
            if indexPath.row == 0 {
                let cell = tableView.dequeueReusableCell(withIdentifier: cellId + "AV") ??
                    UITableViewCell(style: .default, reuseIdentifier: cellId + "AV")
                cell.textLabel?.text = "Photo"
                cell.textLabel?.textColor = .black
                cell.textLabel?.textAlignment = .left
                let avatar = AvatarView(frame: CGRect(x: 0, y: 0, width: 34, height: 34))
                avatar.setAvatar(mxc: avatarMxc, name: displayName ?? MatrixSession.userId ?? "?")
                cell.accessoryView = avatar
                cell.selectionStyle = .default
                return cell
            }
            let cell = tableView.dequeueReusableCell(withIdentifier: cellId + "V") ??
                UITableViewCell(style: .value1, reuseIdentifier: cellId + "V")
            cell.textLabel?.text = "Display name"
            cell.textLabel?.textColor = .black
            cell.textLabel?.textAlignment = .left
            cell.detailTextLabel?.text = profileLoading
                ? "\u{2026}"
                : (displayName ?? "Not set")
            cell.selectionStyle = .default
            cell.accessoryType = .disclosureIndicator
            return cell
        }

        // Section 1: Notifications — the master kill switch (UISwitch, iOS 5+).
        if indexPath.section == 1 {
            let cell = tableView.dequeueReusableCell(withIdentifier: cellId + "SW") ??
                UITableViewCell(style: .default, reuseIdentifier: cellId + "SW")
            cell.textLabel?.text = "Background notifications"
            cell.textLabel?.textColor = .black
            cell.textLabel?.textAlignment = .left
            cell.selectionStyle = .none
            let sw = UISwitch()
            sw.isOn = NotificationManager.isEnabled
            sw.addTarget(self, action: #selector(notificationsToggled(_:)), for: .valueChanged)
            cell.accessoryView = sw
            return cell
        }

        // Section 2: Storage — cache usage, downloads usage, then their actions.
        if indexPath.section == 2 {
            if indexPath.row <= 1 {
                let isCache = indexPath.row == 0
                let cell = tableView.dequeueReusableCell(withIdentifier: cellId + "V") ??
                    UITableViewCell(style: .value1, reuseIdentifier: cellId + "V")
                cell.textLabel?.text = isCache ? "Cache used" : "Downloads"
                cell.textLabel?.textColor = .black
                cell.textLabel?.textAlignment = .left
                let loading = isCache ? cacheLoading : filesLoading
                let bytes = isCache ? cacheBytes : filesBytes
                let count = isCache ? cacheFiles : filesCount
                cell.detailTextLabel?.text = loading
                    ? "\u{2026}"
                    : "\(humanSize(bytes)) (\(count) file\(count == 1 ? "" : "s"))"
                cell.selectionStyle = .none
                cell.accessoryType = .none
                return cell
            }
            let cell = tableView.dequeueReusableCell(withIdentifier: cellId) ??
                UITableViewCell(style: .default, reuseIdentifier: cellId)
            cell.textLabel?.text = indexPath.row == 2 ? "Reset Cache" : "Delete Downloads"
            cell.textLabel?.textColor = UIColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 1.0)
            cell.textLabel?.textAlignment = .center
            cell.selectionStyle = .default
            cell.accessoryType = .none
            return cell
        }

        // Section 3: Encryption — recovery key entry, then what it recovered.
        if indexPath.section == 3 {
            if indexPath.row == 0 {
                let cell = tableView.dequeueReusableCell(withIdentifier: cellId) ??
                    UITableViewCell(style: .default, reuseIdentifier: cellId)
                cell.textLabel?.text = "Enter Recovery Key"
                cell.textLabel?.textColor = .black
                cell.textLabel?.textAlignment = .left
                cell.selectionStyle = .default
                cell.accessoryType = .disclosureIndicator
                return cell
            }
            let cell = tableView.dequeueReusableCell(withIdentifier: cellId + "V") ??
                UITableViewCell(style: .value1, reuseIdentifier: cellId + "V")
            let count = MegolmKeyStore.shared.count
            cell.textLabel?.text = "Message keys"
            cell.textLabel?.textColor = .black
            cell.textLabel?.textAlignment = .left
            cell.detailTextLabel?.text = count == 0 ? "None" : "\(count) restored"
            cell.selectionStyle = .none
            cell.accessoryType = .none
            return cell
        }

        // Section 4: Diagnostics — crash-log toggle + copy.
        if indexPath.row == 0 {
            let cell = tableView.dequeueReusableCell(withIdentifier: cellId + "V") ??
                UITableViewCell(style: .value1, reuseIdentifier: cellId + "V")
            cell.textLabel?.text = "Last crash"
            cell.textLabel?.textColor = .black
            cell.textLabel?.textAlignment = .left
            cell.detailTextLabel?.text = crashExpanded ? "Hide" : "Show"
            cell.selectionStyle = .default
            cell.accessoryType = .none
            return cell
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: cellId) ??
            UITableViewCell(style: .default, reuseIdentifier: cellId)
        cell.textLabel?.text = "Copy crash log"
        cell.textLabel?.textColor = UIColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 1.0)
        cell.textLabel?.textAlignment = .center
        cell.selectionStyle = .default
        cell.accessoryType = .none
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch indexPath.section {
        case 0:
            if indexPath.row == 0 { pickAvatar() } else { promptEditDisplayName() }
        case 1:
            break                                   // toggle handled by the switch
        case 2:
            if indexPath.row == 2 { confirmClearCache() }
            if indexPath.row == 3 { confirmClearDownloads() }
        case 3:
            if indexPath.row == 0 { openRecoveryKey() }
        default:
            if indexPath.row == 0 {
                crashExpanded.toggle()
                tableView.reloadSections(IndexSet(integer: 4), with: .automatic)
            } else {
                copyCrashLog()
            }
        }
    }
}

#if IOS6_TARGET
extension UserSettingsVC: UIActionSheetDelegate {
    func actionSheet(_ actionSheet: UIActionSheet, clickedButtonAt buttonIndex: Int) {
        guard buttonIndex == actionSheet.destructiveButtonIndex else { return }
        if actionSheet.tag == filesSheetTag {
            performClearDownloads()
        } else {
            performClearCache()
        }
    }
}

#endif

// Simple pushed editor for a single text value — the account display name, and
// (from Room Settings) a room's name or topic. Deliberately built from the most
// basic iOS 6 primitives — a UITextField/UITextView and a Save bar button —
// because the UIAlertView `.plainTextInput` approach froze the app on the iOS 6
// runtime. `multiline` swaps the field for a UITextView (topics are free text).
class TextEditVC: UIViewController, UITextFieldDelegate {
    var onSave: ((String) -> Void)?
    private let current: String
    private let placeholder: String
    private let multiline: Bool
    private var field: UITextField?
    private var textView: UITextView?

    init(screenTitle: String, placeholder: String, current: String, multiline: Bool) {
        self.current = current
        self.placeholder = placeholder
        self.multiline = multiline
        super.init(nibName: nil, bundle: nil)
        title = screenTitle
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.95, alpha: 1.0)

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Save", style: .done, target: self, action: #selector(saveTapped))

        if multiline {
            let tv = UITextView(frame: .zero)
            tv.backgroundColor = .white
            tv.textColor = .black
            tv.text = current
            tv.font = UIFont.systemFont(ofSize: 15)
            tv.autocorrectionType = .no
            view.addSubview(tv)
            textView = tv
            return
        }

        let f = UITextField(frame: .zero)
        f.borderStyle = .none
        f.backgroundColor = .white
        f.textColor = .black
        f.text = current
        f.placeholder = placeholder
        f.clearButtonMode = .whileEditing
        f.autocorrectionType = .no
        f.returnKeyType = .done
        f.delegate = self
        // Symmetric inset padding (roundedRect bezel looks misaligned at custom
        // heights on this runtime — see the input-bar note).
        let pad = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 1))
        f.leftView = pad
        f.leftViewMode = .always
        f.rightView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 1))
        f.rightViewMode = .always
        view.addSubview(f)
        field = f
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Fixed top offset that clears the nav bar on both iOS 6 (bar not
        // extended under content) and iOS 7+ (translucent bar). Deliberately
        // NOT using `#available` / `topLayoutGuide` — those are used nowhere
        // else in this project and are unsafe on the swapped iOS 6 runtime
        // (this VC froze because of them).
        field?.frame = CGRect(x: 0, y: 76, width: view.bounds.width, height: 44)
        textView?.frame = CGRect(x: 0, y: 76, width: view.bounds.width, height: 132)
    }

    @objc private func saveTapped() {
        onSave?(textView?.text ?? field?.text ?? "")
        navigationController?.popViewController(animated: true)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        saveTapped()
        return true
    }
}

// Shared "pick a photo and upload it" helper, used for both the account avatar
// (User Settings) and the room avatar (Room Settings). Lifts the flow already
// proven in RoomTimelineVC's image sending: source sheet -> UIImagePickerController
// -> downscale -> JPEG -> POST /media/v3/upload -> content_uri.
//
// The caller MUST hold a strong reference for the whole flow: both
// UIImagePickerController's and UIActionSheet's delegates are weak, so a helper
// created as a local would be deallocated before the user picks anything.
final class AvatarPicker: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {

    // (mxc, uploaded image, error) — mxc is nil when the user cancelled (error
    // nil too) or the upload failed (error set).
    typealias Completion = (String?, UIImage?, Error?) -> Void

    private let client: MatrixAPIClient
    private weak var presenter: UIViewController?
    private var completion: Completion?

    // Avatars are displayed small; 800px is plenty and keeps the upload quick on
    // a 3G-era connection.
    private static let maxDimension: CGFloat = 800

    init(client: MatrixAPIClient) {
        self.client = client
        super.init()
    }

    func start(from presenter: UIViewController, anchor: UIView, completion: @escaping Completion) {
        self.presenter = presenter
        self.completion = completion

        let hasCamera = UIImagePickerController.isSourceTypeAvailable(.camera)
#if IOS6_TARGET
        let sheet = UIActionSheet()
        sheet.title = "Photo"
        if hasCamera { sheet.addButton(withTitle: "Take Photo") }
        sheet.addButton(withTitle: "Choose from Library")
        sheet.addButton(withTitle: "Cancel")
        sheet.cancelButtonIndex = sheet.numberOfButtons - 1
        sheet.delegate = self
        sheet.show(in: anchor)
#else
        let sheet = UIAlertController(title: "Photo", message: nil, preferredStyle: .actionSheet)
        if hasCamera {
            sheet.addAction(UIAlertAction(title: "Take Photo", style: .default) { [weak self] _ in
                self?.presentPicker(source: .camera)
            })
        }
        sheet.addAction(UIAlertAction(title: "Choose from Library", style: .default) { [weak self] _ in
            self?.presentPicker(source: .photoLibrary)
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            self?.finish(nil, nil, nil)
        })
        sheet.popoverPresentationController?.sourceView = anchor
        presenter.present(sheet, animated: true)
#endif
    }

    fileprivate func presentPicker(source: UIImagePickerController.SourceType) {
        let picker = UIImagePickerController()
        picker.sourceType = source
        picker.delegate = self
        presenter?.present(picker, animated: true)
    }

    fileprivate func finish(_ mxc: String?, _ image: UIImage?, _ error: Error?) {
        let done = completion
        completion = nil
        done?(mxc, image, error)
    }

    // MARK: - Picker delegate

    func imagePickerController(_ picker: UIImagePickerController,
                               didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        picker.dismiss(animated: true)
        guard let image = info[.originalImage] as? UIImage else { finish(nil, nil, nil); return }
        upload(image)
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
        finish(nil, nil, nil)
    }

    // MARK: - Upload

    private func upload(_ image: UIImage) {
        let scaled = AvatarPicker.downscale(image, maxDimension: AvatarPicker.maxDimension)
        guard let data = scaled.jpegData(compressionQuality: 0.8) else { finish(nil, nil, nil); return }
        // Generated ASCII filename, so no percent-encoding is needed in the
        // upload query string (percent-encoding crashes on this iOS 6 runtime).
        let filename = "elementold-avatar-\(Int64(Date().timeIntervalSince1970 * 1000)).jpg"
        client.uploadMedia(data: data, filename: filename, mimeType: "image/jpeg") { [weak self] json, error in
            guard let self = self else { return }
            guard let mxc = json?["content_uri"] as? String, !mxc.isEmpty else {
                self.finish(nil, nil, error)
                return
            }
            // Prime the cache under the exact key AvatarView will request: a
            // just-uploaded mxc 404s on the thumbnail endpoint for a moment, and
            // without this the new avatar would stay a blank/initials circle.
            MediaCache.shared.storeThumbnail(scaled, mxc: mxc,
                                             width: AvatarView.thumbPx, height: AvatarView.thumbPx)
            MediaCache.shared.storeFull(scaled, mxc: mxc)
            self.finish(mxc, scaled, nil)
        }
    }

    // Aspect-preserving downscale so the long edge is at most `maxDimension`.
    // Never upscales.
    private static func downscale(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let longEdge = max(image.size.width, image.size.height)
        guard longEdge > maxDimension, longEdge > 0 else { return image }
        let scale = maxDimension / longEdge
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
        image.draw(in: CGRect(origin: .zero, size: newSize))
        let result = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return result ?? image
    }
}

#if IOS6_TARGET
extension AvatarPicker: UIActionSheetDelegate {
    func actionSheet(_ actionSheet: UIActionSheet, clickedButtonAt buttonIndex: Int) {
        if buttonIndex == actionSheet.cancelButtonIndex { finish(nil, nil, nil); return }
        // Button 0 is "Take Photo" only when a camera exists; otherwise the first
        // button is the library.
        let hasCamera = UIImagePickerController.isSourceTypeAvailable(.camera)
        if hasCamera && buttonIndex == 0 { presentPicker(source: .camera) }
        else { presentPicker(source: .photoLibrary) }
    }
}
#endif

// Recovery key entry, and the first half of the E2EE recovery chain:
//
//     recovery key -> 4S secret storage -> (later) megolm key backup -> decrypt
//
// It decodes the key the user typed and checks it against the key description
// the homeserver stores in account data — which is what turns "wrong recovery
// key" into a clean error instead of garbage several steps further down — then
// walks the rest of the chain: unlock the backup's private key out of secret
// storage, fetch the backed-up megolm sessions, and hand them to
// MegolmKeyStore.
//
// A recovery key CANNOT be used to sign in; it has nothing to do with the
// access token. That distinction is spelled out in the section footer.
final class RecoveryKeyVC: UIViewController {

    private let client: MatrixAPIClient

    // Fired once message keys have landed in the store, so the settings screen
    // behind us can refresh its count.
    var onRestored: (() -> Void)?

    private var promptLabel: UILabel!
    private var keyView: UITextView!
    private var statusLabel: UILabel!
    private var verifyItem: UIBarButtonItem!

    // Guards against a second tap while the two account-data requests are in
    // flight. Both completions run on main (CurlFetcher marshals them), so a
    // plain Bool is enough.
    private var busy = false

    init(client: MatrixAPIClient) {
        self.client = client
        super.init(nibName: nil, bundle: nil)
        title = "Recovery Key"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.95, alpha: 1.0)

        verifyItem = UIBarButtonItem(title: "Verify", style: .done,
                                     target: self, action: #selector(verifyTapped))
        navigationItem.rightBarButtonItem = verifyItem

        promptLabel = UILabel(frame: .zero)
        // iOS 6: labels default to an opaque white background.
        promptLabel.backgroundColor = .clear
        promptLabel.textColor = UIColor(white: 0.3, alpha: 1.0)
        promptLabel.font = UIFont.systemFont(ofSize: 13)
        promptLabel.numberOfLines = 0
        promptLabel.text = "Enter the recovery key you saved when you set up encryption. "
                         + "Spaces don't matter, but capitalisation does."
        view.addSubview(promptLabel)

        // A text view rather than a field: a recovery key is 48+ characters and
        // is displayed in groups of four, so it wraps over several lines.
        keyView = UITextView(frame: .zero)
        keyView.backgroundColor = .white
        keyView.textColor = .black
        keyView.font = UIFont.systemFont(ofSize: 15)
        keyView.autocorrectionType = .no
        // Base58 is case-sensitive, so autocapitalisation would silently corrupt
        // the key the user typed.
        keyView.autocapitalizationType = .none
        keyView.spellCheckingType = .no
        view.addSubview(keyView)

        statusLabel = UILabel(frame: .zero)
        statusLabel.backgroundColor = .clear
        statusLabel.textColor = UIColor(white: 0.3, alpha: 1.0)
        statusLabel.font = UIFont.systemFont(ofSize: 13)
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        view.addSubview(statusLabel)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Fixed offsets, no `#available` / `topLayoutGuide` — see TextEditVC.
        let width = view.bounds.width
        promptLabel.frame = CGRect(x: 16, y: 76, width: width - 32, height: 52)
        keyView.frame = CGRect(x: 0, y: 136, width: width, height: 88)
        statusLabel.frame = CGRect(x: 16, y: 236, width: width - 32,
                                   height: max(60, view.bounds.height - 236 - 16))
    }

    // MARK: - Verification

    @objc private func verifyTapped() {
        guard !busy else { return }

        // Decode locally first: a mistyped key fails here without a round trip.
        guard let key = RecoveryKey.decode(keyView.text ?? ""), key.count == 32 else {
            statusLabel.text = "That doesn't look like a recovery key."
            return
        }
        guard let userId = MatrixSession.userId, !userId.isEmpty else {
            statusLabel.text = "Not signed in."
            return
        }

        setBusy(true, status: "Checking…")
        keyView.resignFirstResponder()

        // Matrix IDs go UNENCODED in the path — percent-encoding via Foundation
        // crashes on this iOS 6 runtime, and curl accepts the raw path fine.
        let base = "/_matrix/client/v3/user/\(userId)/account_data/"
        let defaultKeyPath = base + "m.secret_storage.default_key"
        client.get(defaultKeyPath) { [weak self] json, error in
            guard let self = self else { return }
            if let error = error { self.fail(error, path: defaultKeyPath); return }
            guard let keyId = json?["key"] as? String, !keyId.isEmpty else {
                self.setBusy(false, status: "This account has no recovery key set up.")
                return
            }
            // The key id comes from the server and goes into a path SEGMENT, so it
            // has to be encoded: some clients generate plain base64 ids, and a '/'
            // in one breaks the route entirely (Synapse answers M_UNRECOGNIZED,
            // since its account-data pattern matches [^/]* for the type).
            let keyPath = base + "m.secret_storage.key." + RecoveryKeyVC.pathEncode(keyId)
            self.client.get(keyPath) { [weak self] json, error in
                guard let self = self else { return }
                if let error = error { self.fail(error, path: keyPath); return }
                guard let keyInfo = json else {
                    self.setBusy(false, status: "The server didn't return the key description.")
                    return
                }
                if let failure = self.check(key: key, keyInfo: keyInfo) {
                    self.setBusy(false, status: failure)
                    return
                }
                // The key is proven at this point; use it to unlock the backup.
                self.restore(key: key, keyId: keyId, base: base)
            }
        }
    }

    // Validates the entered key against the stored key description, per the
    // m.secret_storage.v1.aes-hmac-sha2 verification procedure: derive an AES
    // key and a MAC key from it, encrypt 32 zero bytes with the stored IV, MAC
    // the result, and compare against the stored MAC.
    //
    // Returns nil on success, or the reason it failed.
    private func check(key: [UInt8], keyInfo: [String: Any]) -> String? {
        let algorithm = keyInfo["algorithm"] as? String ?? ""
        guard algorithm == "m.secret_storage.v1.aes-hmac-sha2" else {
            return "Unsupported key algorithm (\(algorithm.isEmpty ? "none" : algorithm))."
        }
        guard let ivText = keyInfo["iv"] as? String,
              let macText = keyInfo["mac"] as? String,
              let iv = Base64.decode(ivText), iv.count == 16,
              let expectedMAC = Base64.decode(macText), !expectedMAC.isEmpty else {
            return "The stored key description is malformed."
        }

        // The derivation for *verification* uses the empty string as the info,
        // where decrypting a named secret would use that secret's name.
        let zeroes = [UInt8](repeating: 0, count: 32)
        guard let derived = Crypto.hkdfSHA256(ikm: key, salt: zeroes, info: [], length: 64),
              let ciphertext = Crypto.aes256CTR(key: Array(derived[0..<32]), iv: iv, data: zeroes),
              let mac = Crypto.hmacSHA256(key: Array(derived[32..<64]), data: ciphertext) else {
            return "Couldn't derive the keys."
        }
        guard mac == expectedMAC else { return "That recovery key is not valid." }
        return nil
    }

    // MARK: - Message key restore

    // Recovery key -> the backup's X25519 private key (a 4S secret) -> the
    // server-side megolm backup -> stored sessions. Each step reports its own
    // failure rather than one generic message: the point of walking the chain in
    // stages is being able to see which link is broken.
    private func restore(key: [UInt8], keyId: String, base: String) {
        setBusy(true, status: "Unlocking message keys…")
        let secretPath = base + "m.megolm_backup.v1"
        client.get(secretPath) { [weak self] json, error in
            guard let self = self else { return }
            if let error = error { self.fail(error, path: secretPath); return }
            guard let encrypted = json?["encrypted"] as? [String: Any],
                  let entry = encrypted[keyId] as? [String: Any] else {
                self.setBusy(false, status: "No message key backup is stored on this account.")
                return
            }
            // The secret is the backup's private key, itself base64 inside the
            // decrypted plaintext.
            guard let text = RecoveryKeyVC.decryptSecret(name: "m.megolm_backup.v1", key: key, entry: entry),
                  let privateKey = Base64.decode(text), privateKey.count == 32 else {
                self.setBusy(false, status: "Couldn't unlock the backup key.")
                return
            }
            self.fetchBackupVersion(privateKey: privateKey)
        }
    }

    private func fetchBackupVersion(privateKey: [UInt8]) {
        let path = "/_matrix/client/v3/room_keys/version"
        client.get(path) { [weak self] json, error in
            guard let self = self else { return }
            if let error = error { self.fail(error, path: path); return }
            let algorithm = json?["algorithm"] as? String ?? ""
            guard algorithm == "m.megolm_backup.v1.curve25519-aes-sha2" else {
                self.setBusy(false, status: "Unsupported backup algorithm "
                    + "(\(algorithm.isEmpty ? "none" : algorithm)).")
                return
            }
            guard let version = json?["version"] as? String, !version.isEmpty else {
                self.setBusy(false, status: "The backup has no version.")
                return
            }
            // Cheap early error: if the key we just unlocked doesn't match the
            // public key the backup was made against, nothing below can decrypt.
            guard let auth = json?["auth_data"] as? [String: Any],
                  let publicText = auth["public_key"] as? String,
                  let expected = Base64.decode(publicText),
                  let ours = Crypto.x25519PublicKey(privateKey: privateKey),
                  ours == expected else {
                self.setBusy(false, status: "The unlocked key doesn't match this backup.")
                return
            }
            self.fetchKeys(privateKey: privateKey, version: version)
        }
    }

    private func fetchKeys(privateKey: [UInt8], version: String) {
        setBusy(true, status: "Downloading message keys…")
        let path = "/_matrix/client/v3/room_keys/keys?version=" + RecoveryKeyVC.pathEncode(version)
        client.get(path) { [weak self] json, error in
            guard let self = self else { return }
            if let error = error { self.fail(error, path: path); return }
            guard let rooms = json?["rooms"] as? [String: Any], !rooms.isEmpty else {
                self.setBusy(false, status: "The backup is empty.")
                return
            }
            // One X25519 + AES-CBC per session, on main. This is a one-shot the
            // user asked for and it sits behind the busy state, unlike the
            // per-event work in the timeline.
            var recovered: [MegolmSession] = []
            var unreadable = 0
            // The first failure's reason, shown alongside the count: with a slow
            // build cycle, "could not be read" on its own costs a whole round
            // trip to narrow down.
            var firstReason: String? = nil
            for (roomId, rawRoom) in rooms {
                guard let sessions = (rawRoom as? [String: Any])?["sessions"] as? [String: Any] else { continue }
                for (sessionId, rawSession) in sessions {
                    guard let data = (rawSession as? [String: Any])?["session_data"] as? [String: Any] else {
                        unreadable += 1
                        if firstReason == nil { firstReason = "no session data" }
                        continue
                    }
                    let outcome = RecoveryKeyVC.decodeSession(roomId: roomId, sessionId: sessionId,
                                                             data: data, privateKey: privateKey)
                    if let session = outcome.session {
                        recovered.append(session)
                    } else {
                        unreadable += 1
                        if firstReason == nil { firstReason = outcome.reason }
                    }
                }
            }
            MegolmKeyStore.shared.merge(recovered)
            let total = MegolmKeyStore.shared.count
            self.setBusy(false, status: unreadable > 0
                ? "\(unreadable) key\(unreadable == 1 ? "" : "s") in the backup could not be read"
                  + (firstReason.map { ": \($0)." } ?? ".")
                : "")
            self.onRestored?()
            self.alert(title: "Message keys restored",
                       message: "\(total) message key\(total == 1 ? "" : "s") "
                              + "\(total == 1 ? "is" : "are") available on this device.")
        }
    }

    // Decrypts one named secret out of 4S storage. Same aes-hmac-sha2 scheme as
    // the key check above, except the info is the secret's name and the MAC
    // covers the stored ciphertext.
    private static func decryptSecret(name: String, key: [UInt8], entry: [String: Any]) -> String? {
        guard let ivText = entry["iv"] as? String,
              let cipherText = entry["ciphertext"] as? String,
              let macText = entry["mac"] as? String,
              let iv = Base64.decode(ivText), iv.count == 16,
              let ciphertext = Base64.decode(cipherText), !ciphertext.isEmpty,
              let expectedMAC = Base64.decode(macText), !expectedMAC.isEmpty else { return nil }
        let zeroes = [UInt8](repeating: 0, count: 32)
        guard let derived = Crypto.hkdfSHA256(ikm: key, salt: zeroes,
                                              info: Array(name.utf8), length: 64),
              let mac = Crypto.hmacSHA256(key: Array(derived[32..<64]), data: ciphertext),
              mac == expectedMAC,
              let plain = Crypto.aes256CTR(key: Array(derived[0..<32]), iv: iv, data: ciphertext) else {
            return nil
        }
        return String(bytes: plain, encoding: .utf8)
    }

    // One backed-up session: ECDH against the ephemeral key, then the usual
    // aes-sha2 unwrap, then the exported-megolm-session layout.
    //
    // Returns the session, or the reason it could not be read. One silent nil
    // for the whole chain made every failure look identical, which is the
    // opposite of the staged-so-you-can-see-the-broken-link approach above.
    private static func decodeSession(roomId: String, sessionId: String,
                                      data: [String: Any], privateKey: [UInt8])
        -> (session: MegolmSession?, reason: String?) {
        guard let ephemeralText = data["ephemeral"] as? String,
              let cipherText = data["ciphertext"] as? String,
              let macText = data["mac"] as? String,
              let ephemeral = Base64.decode(ephemeralText), ephemeral.count == 32,
              let ciphertext = Base64.decode(cipherText),
              !ciphertext.isEmpty, ciphertext.count % 16 == 0,
              // The stored MAC is TRUNCATED to 8 bytes here, unlike 4S storage.
              let expectedMAC = Base64.decode(macText), expectedMAC.count >= 8 else {
            return (nil, "malformed session data")
        }
        guard let shared = Crypto.x25519(privateKey: privateKey, peerPublicKey: ephemeral),
              let derived = Crypto.hkdfSHA256(ikm: shared,
                                              salt: [UInt8](repeating: 0, count: 32),
                                              info: [], length: 80) else {
            return (nil, "key agreement failed")
        }
        // ★ The MAC is computed over the EMPTY STRING, not over the ciphertext.
        // That is a bug in the original libolm implementation that is now baked
        // into the format, so it is what every real backup actually contains
        // (matrix-rust-sdk skips this check outright for the same reason). It
        // still confirms we derived the right key, which is worth keeping as an
        // early error. A ciphertext MAC is accepted too, since that is what a
        // spec-literal implementation would have written and it costs nothing.
        let macKey = Array(derived[32..<64])
        let expected = Array(expectedMAC[0..<8])
        let matches: ([UInt8]) -> Bool = { message in
            guard let mac = Crypto.hmacSHA256(key: macKey, data: message) else { return false }
            return Array(mac[0..<8]) == expected
        }
        guard matches([]) || matches(ciphertext) else { return (nil, "MAC mismatch") }
        guard let plain = Crypto.aes256CBCDecrypt(key: Array(derived[0..<32]),
                                                  iv: Array(derived[64..<80]),
                                                  data: ciphertext) else {
            return (nil, "could not decrypt")
        }
        guard let json = (try? JSONSerialization.jsonObject(with: Data(plain),
                                                            options: [])) as? [String: Any] else {
            return (nil, "decrypted data is not JSON")
        }
        let algorithm = json["algorithm"] as? String ?? ""
        guard algorithm == "m.megolm.v1.aes-sha2" else {
            return (nil, "unsupported algorithm (\(algorithm.isEmpty ? "none" : algorithm))")
        }
        // version byte + 4-byte index + 128-byte ratchet + 32-byte Ed25519 key
        guard let sessionKey = json["session_key"] as? String,
              let exported = Base64.decode(sessionKey), exported.count >= 165,
              exported[0] == 0x01 else {
            return (nil, "unexpected session key format")
        }
        let index = (Int(exported[1]) << 24) | (Int(exported[2]) << 16)
                  | (Int(exported[3]) << 8) | Int(exported[4])
        return (MegolmSession(sessionId: sessionId,
                              roomId: roomId,
                              senderKey: json["sender_key"] as? String ?? "",
                              firstKnownIndex: index,
                              ratchet: Array(exported[5..<133]),
                              signingKey: Array(exported[133..<165])), nil)
    }

    // Pure-stdlib percent-encoding for one path segment. Foundation's
    // addingPercentEncoding(withAllowedCharacters:) bridges to an NSString method
    // that does not exist on real iOS 6 — see SyncEngine for the same loop.
    private static let unreservedBytes: Set<UInt8> =
        Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8)
    private static let hexDigits = Array("0123456789ABCDEF")

    private static func pathEncode(_ value: String) -> String {
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

    // The path is included on purpose: both requests share this handler, and an
    // M_UNRECOGNIZED (no route matched) is only diagnosable if we can see which
    // path was asked for.
    private func fail(_ error: Error, path: String) {
        setBusy(false, status: "Request failed.\n\(path)\n\(error)")
    }

    private func setBusy(_ value: Bool, status: String) {
        busy = value
        verifyItem.isEnabled = !value
        keyView.isEditable = !value
        statusLabel.text = status
    }

    private func alert(title: String, message: String) {
#if IOS6_TARGET
        UIAlertView(title: title, message: message, delegate: nil, cancelButtonTitle: "OK").show()
#else
        let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default))
        present(a, animated: true)
#endif
    }
}
