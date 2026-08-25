import UIKit

// Login screen: homeserver URL (configurable, not hardcoded) + username/password,
// via UIAlertView/plain UIViewController forms per the iOS6/7 cheatsheet
// (no UIAlertController). Adapted from jellyold's ServerSetupVC.swift.
class LoginVC: UIViewController {

    // Soft logout: the stored access token was rejected by the homeserver, so
    // the user has to sign in again — but the server and the account are known,
    // and everything cached for them is still valid. This is what Element shows
    // in the same situation. A recovery key cannot help here: it unlocks secret
    // storage (message keys), and an access token comes only from /login.
    private let softLogoutUserId: String?
    private var isSoftLogout: Bool { softLogoutUserId != nil }

    private var scrollView: UIScrollView!
    private var headlineLabel: UILabel!
    private var logoView: UIImageView!
    private var serverField: UITextField!
    private var usernameField: UITextField!
    private var passwordField: UITextField!
    private var connectButton: UIButton!
    private var spinner: UIActivityIndicatorView!

    // How much of our view the keyboard covers right now. The scroll view is
    // shortened by it rather than the whole view being shoved upwards, so the
    // form can always be scrolled to whatever the keyboard hides.
    private var keyboardOverlap: CGFloat = 0
    private weak var activeField: UITextField?

    // Layout metrics. The form is laid out fresh on every layout pass (see
    // layoutContent) instead of being frozen at build time, so a rotation —
    // where both the width and the available height change a lot — re-centres
    // it and re-measures whether it still fits.
    private let controlHeight: CGFloat = 46
    private let logoSize: CGFloat = 110
    private let logoGap: CGFloat = 24
    private let fieldGap: CGFloat = 12
    private let buttonGap: CGFloat = 20
    private let edgePadding: CGFloat = 20
    // Landscape (and iPad) is wide enough that full-width fields look stretched
    // and stranded; cap them and centre the column instead.
    private let maxContentWidth: CGFloat = 420

    private let headlineHeight: CGFloat = 52
    private let headlineGap: CGFloat = 16

    private let bgColor = UIColor(red: 0.10, green: 0.10, blue: 0.14, alpha: 1.0)
    private let accentColor = UIColor(red: 0.13, green: 0.55, blue: 0.60, alpha: 1.0)

    init(softLogoutUserId: String? = nil) {
        self.softLogoutUserId = softLogoutUserId
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "elementold"
        view.backgroundColor = bgColor
        registerKeyboardObservers()
        buildUI()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutContent()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Belt and braces: UIKit's nav-bar inset lands around the first layout
        // pass, and layoutContent measures against it. Re-running it once we're
        // definitely on screen costs nothing and can't leave the form measured
        // against an inset of zero.
        layoutContent()
        // Only in soft logout, where the other two fields are locked and the
        // password is the single thing left to supply.
        if isSoftLogout && passwordField.text?.isEmpty != false {
            passwordField.becomeFirstResponder()
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    private func buildUI() {
        // Must be the first subview: on iOS 7+ that's what makes UIKit inset the
        // content for the navigation bar by itself, which is how every table in
        // this app already clears it. On iOS 6 no inset is applied and none is
        // needed — the view already starts below the bar.
        scrollView = UIScrollView(frame: view.bounds)
        scrollView.backgroundColor = .clear
        scrollView.showsHorizontalScrollIndicator = false
        view.addSubview(scrollView)

        // Only built in soft-logout mode; a normal login is unchanged.
        headlineLabel = UILabel(frame: .zero)
        headlineLabel.backgroundColor = .clear   // iOS 6: labels default to white bg
        headlineLabel.numberOfLines = 0
        headlineLabel.textAlignment = .center
        headlineLabel.font = UIFont.systemFont(ofSize: 14)
        headlineLabel.textColor = UIColor(white: 0.72, alpha: 1.0)
        headlineLabel.isHidden = !isSoftLogout
        if let userId = softLogoutUserId {
            headlineLabel.text = "Your session has expired.\nSign in again as \(userId)."
        }
        scrollView.addSubview(headlineLabel)

        logoView = UIImageView(frame: .zero)
        logoView.image = UIImage(named: "Logo@2x")
        logoView.contentMode = .scaleAspectFit
        logoView.backgroundColor = .clear
        scrollView.addSubview(logoView)

        serverField = makeField("Homeserver URL  (e.g. http://matrix.example.org:8008)",
                                secure: false)
        serverField.keyboardType = .URL
        serverField.text = MatrixSession.homeserverURL
        scrollView.addSubview(serverField)

        usernameField = makeField("Username", secure: false)
        scrollView.addSubview(usernameField)

        passwordField = makeField("Password", secure: true)
        scrollView.addSubview(passwordField)

        // In soft logout the server and account are not the user's to change —
        // signing in as someone else is a full logout, from the account menu.
        if let userId = softLogoutUserId {
            usernameField.text = userId
            for field in [serverField, usernameField] {
                field?.isUserInteractionEnabled = false
                field?.textColor = UIColor(white: 0.6, alpha: 1.0)
            }
        }

        connectButton = UIButton(type: .custom)
        connectButton.setTitle("Log In", for: .normal)
        connectButton.setTitleColor(.white, for: .normal)
        connectButton.setTitleColor(UIColor(white: 1.0, alpha: 0.5), for: .disabled)
        connectButton.titleLabel?.font = UIFont.boldSystemFont(ofSize: 17)
        connectButton.backgroundColor = accentColor
        connectButton.layer.cornerRadius = 10
        connectButton.addTarget(self, action: #selector(connectTapped), for: .touchUpInside)
        scrollView.addSubview(connectButton)

        // Sits on the view, not the scroll view, so it stays put if the form is
        // scrolled while a login is in flight.
        spinner = UIActivityIndicatorView(style: .whiteLarge)
        spinner.hidesWhenStopped = true
        view.addSubview(spinner)
    }

    private func layoutContent() {
        guard scrollView != nil else { return }
        let bounds = view.bounds
        scrollView.frame = CGRect(x: 0, y: 0, width: bounds.width,
                                  height: max(0, bounds.height - keyboardOverlap))

        // UIKit's own nav-bar inset (iOS 7+) — the form has to be measured and
        // centred inside what's left, not the full frame.
        let inset = scrollView.contentInset
        let visibleHeight = scrollView.bounds.height - inset.top - inset.bottom

        let contentWidth = min(bounds.width - edgePadding * 2, maxContentWidth)
        let left = (bounds.width - contentWidth) / 2

        let headlineBlock = isSoftLogout ? headlineHeight + headlineGap : 0
        let formHeight = logoSize + logoGap + headlineBlock + controlHeight * 3 + fieldGap * 2
            + buttonGap + controlHeight

        // Centre it when there's room, otherwise start at the top and let the
        // rest scroll — which is the landscape case on a phone.
        var y = max(edgePadding, (visibleHeight - formHeight) / 2)

        logoView.frame = CGRect(x: (bounds.width - logoSize) / 2, y: y,
                                width: logoSize, height: logoSize)
        y += logoSize + logoGap

        if isSoftLogout {
            headlineLabel.frame = CGRect(x: left, y: y, width: contentWidth, height: headlineHeight)
            y += headlineBlock
        }

        for field in [serverField, usernameField, passwordField] {
            field?.frame = CGRect(x: left, y: y, width: contentWidth, height: controlHeight)
            y += controlHeight + fieldGap
        }
        y += buttonGap - fieldGap

        connectButton.frame = CGRect(x: left, y: y, width: contentWidth, height: controlHeight)
        y += controlHeight + edgePadding

        scrollView.contentSize = CGSize(width: bounds.width, height: y)
        spinner.center = CGPoint(x: bounds.width / 2, y: inset.top + visibleHeight / 2)
    }

    private func makeField(_ placeholder: String, secure: Bool) -> UITextField {
        let f = UITextField(frame: .zero)
        f.backgroundColor = UIColor(white: 1.0, alpha: 0.08)
        f.textColor = .white
        f.contentVerticalAlignment = .center
        f.layer.cornerRadius = 10
        f.layer.borderColor = UIColor(white: 1.0, alpha: 0.15).cgColor
        f.layer.borderWidth = 1
        f.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 14, height: 46))
        f.leftViewMode = .always
        f.isSecureTextEntry = secure
        f.autocapitalizationType = .none
        f.autocorrectionType = .no
        f.keyboardAppearance = .dark
        f.returnKeyType = .done
        f.delegate = self
        f.attributedPlaceholder = NSAttributedString(
            string: placeholder,
            attributes: [NSAttributedString.Key.foregroundColor: UIColor(white: 0.5, alpha: 1.0)]
        )
        return f
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
        keyboardOverlap = overlap(with: keyboardFrame)
        UIView.animate(withDuration: duration) {
            self.layoutContent()
            self.scrollActiveFieldIntoView()
        }
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        keyboardOverlap = 0
        UIView.animate(withDuration: duration) { self.layoutContent() }
    }

    // How far up our view the keyboard reaches. The notification carries the
    // frame in SCREEN coordinates, and before iOS 8 those aren't rotated — so in
    // landscape its `height` is the screen's short side, not what the keyboard
    // actually covers. Converting screen -> window -> view gets it right on
    // every version and orientation.
    private func overlap(with keyboardFrame: CGRect) -> CGFloat {
        guard let window = view.window else { return keyboardFrame.height }
        let inWindow = window.convert(keyboardFrame, from: nil)
        let inView = view.convert(inWindow, from: window)
        return max(0, view.bounds.maxY - inView.minY)
    }

    private func scrollActiveFieldIntoView() {
        guard let field = activeField else { return }
        scrollView.scrollRectToVisible(field.frame.insetBy(dx: 0, dy: -edgePadding),
                                       animated: false)
    }

    // MARK: - Actions

    @objc private func connectTapped() {
        view.endEditing(true)
        guard let raw = serverField.text, !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
            showAlert("Please enter the homeserver URL."); return
        }
        guard let user = usernameField.text, !user.trimmingCharacters(in: .whitespaces).isEmpty else {
            showAlert("Please enter your username."); return
        }
        let pass = passwordField.text ?? ""

        // Trim before use, not just for the emptiness check above: a pasted URL
        // carrying a trailing space produced a base URL that curl could not
        // resolve, and stripping only ONE trailing slash left "…:8008//" — both
        // silently malformed, surfacing much later as an opaque failure.
        var homeserverURL = raw.trimmingCharacters(in: .whitespaces)
        while homeserverURL.hasSuffix("/") { homeserverURL = String(homeserverURL.dropLast()) }
        guard homeserverURL.hasPrefix("http://") || homeserverURL.hasPrefix("https://") else {
            showAlert("The homeserver URL must start with http:// or https://")
            return
        }

        setLoading(true)
        let client = MatrixAPIClient(homeserverBaseURL: homeserverURL)
        let body: [String: Any] = [
            "type": "m.login.password",
            "identifier": ["type": "m.id.user", "user": user],
            "password": pass,
            "initial_device_display_name": "elementold"
        ]
        client.post("/_matrix/client/v3/login", body: body) { json, error in
            self.setLoading(false)
            if let error = error {
                self.showAlert("\(error)")
                return
            }
            // The token must be non-empty, not merely present: an empty string
            // passes every downstream nil-check, so it would be stored, count as
            // a configured session, and only reveal itself as M_MISSING_TOKEN
            // once the sync loop was already running.
            guard let json = json,
                  let accessToken = json["access_token"] as? String, !accessToken.isEmpty,
                  let userId = json["user_id"] as? String, !userId.isEmpty else {
                self.showAlert("Unexpected response from server.")
                return
            }
            MatrixSession.homeserverURL = homeserverURL
            MatrixSession.accessToken = accessToken
            MatrixSession.deviceId = json["device_id"] as? String
            MatrixSession.userId = userId
            self.navigationController?.setViewControllers([RoomListVC()], animated: true)
        }
    }

    private func setLoading(_ loading: Bool) {
        connectButton.isEnabled = !loading
        connectButton.alpha = loading ? 0.5 : 1.0
        loading ? spinner.startAnimating() : spinner.stopAnimating()
    }

    private func showAlert(_ message: String) {
#if IOS6_TARGET
        let alert = UIAlertView()
        alert.title = "elementold"
        alert.message = message
        alert.addButton(withTitle: "OK")
        alert.show()
#else
        let alert = UIAlertController(title: "elementold", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
#endif
    }
}

extension LoginVC: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    func textFieldDidBeginEditing(_ textField: UITextField) {
        activeField = textField
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        if activeField === textField { activeField = nil }
    }
}
