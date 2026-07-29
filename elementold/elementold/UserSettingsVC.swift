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
        let message = "This deletes all downloaded images. They'll be fetched again when needed."
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
    // (cache), 3 = Diagnostics.
    func numberOfSections(in tableView: UITableView) -> Int { return 4 }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0: return "Account"
        case 1: return "Notifications"
        case 2: return "Storage"
        default: return "Diagnostics"
        }
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if section == 1 {
            return "Keeps syncing in the background to alert you of new messages. "
                 + "Off by default; turning it off stops all background activity."
        }
        // Surfaces the last recorded crash (if any) here rather than as a
        // launch-time popup — inspectable on demand without interrupting startup.
        guard section == 3, crashExpanded, let crash = CrashLogger.lastCrash else { return nil }
        return "Last crash:\n\(crash)"
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0: return 2                     // photo, display name
        case 1: return 1                     // notifications toggle
        case 2: return 4                     // cache usage, downloads usage, reset, delete
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

        // Section 3: Diagnostics — crash-log toggle + copy.
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
        default:
            if indexPath.row == 0 {
                crashExpanded.toggle()
                tableView.reloadSections(IndexSet(integer: 3), with: .automatic)
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
