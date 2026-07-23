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

    // Matrix client for the profile (display name) API, plus the current
    // display name once fetched.
    private let client = MatrixSession.makeAPIClient()
    private var displayName: String?
    private var displayNameLoading = true

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
        fetchDisplayName()
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
    }

    private func reloadCacheRow() {
        guard isViewLoaded else { return }
        // Storage is section 1 (section 0 is Account/display name). Reloading
        // (0,0) here was the bug that left "Cache used" stuck showing "…": the
        // usage loaded fine but the wrong row was refreshed.
        tableView.reloadRows(at: [IndexPath(row: 0, section: 1)], with: .none)
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

    // MARK: - Display name

    private func fetchDisplayName() {
        guard let userId = MatrixSession.userId else { displayNameLoading = false; return }
        // Matrix IDs (@user:server) go UNENCODED in the path — percent-encoding
        // via Foundation crashes on this iOS 6 runtime, and curl accepts the raw
        // path fine (same as every other room/user path in this project).
        let path = "/_matrix/client/v3/profile/\(userId)/displayname"
        client.get(path) { [weak self] json, _ in
            guard let self = self else { return }
            self.displayName = json?["displayname"] as? String
            self.displayNameLoading = false
            guard self.isViewLoaded else { return }
            self.tableView.reloadRows(at: [IndexPath(row: 0, section: 0)], with: .none)
        }
    }

    private func promptEditDisplayName() {
        // A dedicated pushed editor rather than a UIAlertView text-input alert:
        // UIAlertView's `.plainTextInput` style froze the app on the iOS 6
        // runtime. A plain pushed VC with a UITextField + Save bar button uses
        // only rock-solid iOS 6 primitives.
        let editor = DisplayNameEditVC(current: displayName ?? "")
        editor.onSave = { [weak self] name in self?.saveDisplayName(name) }
        navigationController?.pushViewController(editor, animated: true)
    }

    fileprivate func saveDisplayName(_ raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != displayName, let userId = MatrixSession.userId else { return }
        let path = "/_matrix/client/v3/profile/\(userId)/displayname"
        client.put(path, body: ["displayname": name]) { [weak self] _, error in
            guard let self = self else { return }
            if error == nil {
                self.displayName = name
                if self.isViewLoaded {
                    self.tableView.reloadRows(at: [IndexPath(row: 0, section: 0)], with: .none)
                }
            } else {
                let title = "Couldn't update"
                let message = error?.localizedDescription ?? "Please try again."
#if IOS6_TARGET
                UIAlertView(title: title, message: message, delegate: nil, cancelButtonTitle: "OK").show()
#else
                let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                self.present(alert, animated: true)
#endif
            }
        }
    }
}

extension UserSettingsVC: UITableViewDataSource, UITableViewDelegate {
    // Section 0 = Account (display name), 1 = Storage (cache), 2 = Diagnostics.
    func numberOfSections(in tableView: UITableView) -> Int { return 3 }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0: return "Account"
        case 1: return "Storage"
        default: return "Diagnostics"
        }
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        // Surfaces the last recorded crash (if any) here rather than as a
        // launch-time popup — inspectable on demand without interrupting startup.
        guard section == 2, crashExpanded, let crash = CrashLogger.lastCrash else { return nil }
        return "Last crash:\n\(crash)"
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0: return 1                     // display name
        case 1: return 2                     // cache usage + reset
        default:
            // Diagnostics: crash-log toggle row (+ a copy row when expanded),
            // only when a crash was actually recorded.
            guard CrashLogger.lastCrash != nil else { return 0 }
            return crashExpanded ? 2 : 1
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        // Section 0: Account — display name (value1, tap to edit).
        if indexPath.section == 0 {
            let cell = tableView.dequeueReusableCell(withIdentifier: cellId + "V") ??
                UITableViewCell(style: .value1, reuseIdentifier: cellId + "V")
            cell.textLabel?.text = "Display name"
            cell.textLabel?.textColor = .black
            cell.textLabel?.textAlignment = .left
            cell.detailTextLabel?.text = displayNameLoading
                ? "\u{2026}"
                : (displayName ?? "Not set")
            cell.selectionStyle = .default
            cell.accessoryType = .disclosureIndicator
            return cell
        }

        // Section 1: Storage.
        if indexPath.section == 1 {
            if indexPath.row == 0 {
                let cell = tableView.dequeueReusableCell(withIdentifier: cellId + "V") ??
                    UITableViewCell(style: .value1, reuseIdentifier: cellId + "V")
                cell.textLabel?.text = "Cache used"
                cell.textLabel?.textColor = .black
                cell.textLabel?.textAlignment = .left
                cell.detailTextLabel?.text = cacheLoading
                    ? "\u{2026}"
                    : "\(humanSize(cacheBytes)) (\(cacheFiles) file\(cacheFiles == 1 ? "" : "s"))"
                cell.selectionStyle = .none
                cell.accessoryType = .none
                return cell
            }
            let cell = tableView.dequeueReusableCell(withIdentifier: cellId) ??
                UITableViewCell(style: .default, reuseIdentifier: cellId)
            cell.textLabel?.text = "Reset Cache"
            cell.textLabel?.textColor = UIColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 1.0)
            cell.textLabel?.textAlignment = .center
            cell.selectionStyle = .default
            cell.accessoryType = .none
            return cell
        }

        // Section 2: Diagnostics — crash-log toggle + copy.
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
            promptEditDisplayName()
        case 1:
            if indexPath.row == 1 { confirmClearCache() }
        default:
            if indexPath.row == 0 {
                crashExpanded.toggle()
                tableView.reloadSections(IndexSet(integer: 2), with: .automatic)
            } else {
                copyCrashLog()
            }
        }
    }
}

#if IOS6_TARGET
extension UserSettingsVC: UIActionSheetDelegate {
    func actionSheet(_ actionSheet: UIActionSheet, clickedButtonAt buttonIndex: Int) {
        if buttonIndex == actionSheet.destructiveButtonIndex {
            performClearCache()
        }
    }
}

#endif

// Simple pushed editor for a single text value (the account display name).
// Deliberately built from the most basic iOS 6 primitives — a UITextField and
// a Save bar button — because the UIAlertView `.plainTextInput` approach froze
// the app on the iOS 6 runtime.
class DisplayNameEditVC: UIViewController, UITextFieldDelegate {
    var onSave: ((String) -> Void)?
    private let current: String
    private var field: UITextField!

    init(current: String) {
        self.current = current
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Display name"
        view.backgroundColor = UIColor(white: 0.95, alpha: 1.0)

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Save", style: .done, target: self, action: #selector(saveTapped))

        let f = UITextField(frame: .zero)
        f.borderStyle = .none
        f.backgroundColor = .white
        f.textColor = .black
        f.text = current
        f.placeholder = "Display name"
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
        field.frame = CGRect(x: 0, y: 76, width: view.bounds.width, height: 44)
    }

    @objc private func saveTapped() {
        onSave?(field.text ?? "")
        navigationController?.popViewController(animated: true)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        saveTapped()
        return true
    }
}
