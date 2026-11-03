import UIKit

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Install the crash handler for this run. We no longer pop up the
        // previous run's crash log at launch — that box appeared on every cold
        // start and was intrusive. A recorded crash is now surfaced quietly,
        // on demand, in Settings → Diagnostics instead (CrashLogger.lastCrash).
        CrashLogger.install()

        // No-op on the iOS 6/7 build and when the notifications kill switch is
        // off; only registers UILocalNotification settings on the iOS 8+ target.
        NotificationManager.shared.registerSettingsIfNeeded()

        // Black status bar above the light nav bar. Only the iOS 6 runtime reads
        // this setter: Info.plist has no UIViewControllerBasedStatusBarAppearance
        // key, so on iOS 7+ the status bar follows the nav bar's (default) style
        // and its text turns dark by itself.
        UIApplication.shared.statusBarStyle = .lightContent
        Palette.applyBarAppearance()

        window = UIWindow(frame: UIScreen.main.bounds)
        let root: UIViewController = MatrixSession.isConfigured ? RoomListVC() : LoginVC()
        window?.rootViewController = UINavigationController(rootViewController: root)
        window?.makeKeyAndVisible()

        return true
    }
}

// MARK: - Palette

/// The app's colours in one place: light, flat chrome with a single blue
/// accent, after the classic Telegram (Onegram) look.
enum Palette {
    /// Buttons, links, badges and our own message bubbles.
    static let accent = UIColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 1.0)
    /// Navigation bar fill, the hairline under it, and its title — the values
    /// iOS 7 draws natively, reproduced by hand on iOS 6.
    static let barBackground = UIColor(white: 0.97, alpha: 1.0)
    static let barHairline = UIColor(white: 0.70, alpha: 1.0)
    static let barTitle = UIColor.black
    /// Lists: previews and timestamps, the hairline between rows, a pressed
    /// row, and the search field.
    static let secondaryText = UIColor(red: 0.56, green: 0.56, blue: 0.58, alpha: 1.0)
    static let separator = UIColor(red: 0.78, green: 0.78, blue: 0.80, alpha: 1.0)
    static let rowHighlight = UIColor(white: 0.85, alpha: 1.0)
    static let searchField = UIColor(white: 0.90, alpha: 1.0)
    /// Chat screen: the canvas behind the bubbles, and other people's bubbles
    /// on it (ours use the accent).
    static let chatBackground = UIColor(red: 0.91, green: 0.92, blue: 0.94, alpha: 1.0)
    static let incomingBubble = UIColor.white

    /// Light navigation bar with accent-coloured buttons on every runtime.
    static func applyBarAppearance() {
        let bar = UINavigationBar.appearance()
        bar.tintColor = accent
        // iOS 7+ already draws this bar (light fill, hairline, dark title), so the
        // accent is all it needs. Detected by selector, not #available.
        if UINavigationBar.instancesRespond(to: NSSelectorFromString("setBarTintColor:")) {
            return
        }

        // iOS 6: replace the glossy gradient with a flat fill + hairline, and
        // flatten the bordered bar buttons into plain accent text. The keys are
        // UIKit's iOS 5/6 values of UITextAttributeTextColor & co. (kept in
        // UIKit as _legacy_UITextAttribute*) — the constants are unavailable in
        // Swift, and on iOS 7+ they alias the NS keys, which iOS 6 ignores here.
        let textColor = NSAttributedString.Key("TextColor")
        let shadowColor = NSAttributedString.Key("TextShadowColor")
        let font = NSAttributedString.Key("Font")
        bar.titleTextAttributes = [textColor: barTitle, shadowColor: UIColor.clear,
                                   font: UIFont.boldSystemFont(ofSize: 17)]
        bar.shadowImage = image(of: barHairline, height: 1 / UIScreen.main.scale)

        let item = UIBarButtonItem.appearance()
        let buttonFont = UIFont.systemFont(ofSize: 17)
        item.setTitleTextAttributes([textColor: accent, shadowColor: UIColor.clear,
                                     font: buttonFont], for: .normal)
        item.setTitleTextAttributes([textColor: accent.withAlphaComponent(0.3), shadowColor: UIColor.clear,
                                     font: buttonFont], for: .highlighted)
        // iOS 6 places the back title where its stock 12pt bold one would sit,
        // so our taller one hangs below the chevron and the screen title. Lift
        // it by half the difference in line height.
        let backLift = ((buttonFont.lineHeight - UIFont.boldSystemFont(ofSize: 12).lineHeight) / 2).rounded()
        let fill = image(of: barBackground)
        let clear = image(of: .clear)
        for metrics in [UIBarMetrics.default, .compact] {
            bar.setBackgroundImage(fill, for: metrics)
            // Bordered buttons are 30pt tall in portrait, 24pt in landscape.
            let height: CGFloat = metrics == .default ? 30 : 24
            item.setBackButtonBackgroundImage(backChevron(height: height, color: accent),
                                              for: .normal, barMetrics: metrics)
            item.setBackButtonBackgroundImage(backChevron(height: height, color: accent.withAlphaComponent(0.3)),
                                              for: .highlighted, barMetrics: metrics)
            item.setBackButtonTitlePositionAdjustment(UIOffset(horizontal: 0, vertical: -backLift), for: metrics)
            for state in [UIControl.State.normal, .highlighted] {
                item.setBackgroundImage(clear, for: state, barMetrics: metrics)
                item.setBackgroundImage(clear, for: state, style: .done, barMetrics: metrics)
            }
        }
    }

    /// A solid image for bar fills and hairlines. With a corner radius it is a
    /// rounded rect that stretches without distorting its corners.
    static func image(of color: UIColor, height: CGFloat = 1, cornerRadius: CGFloat = 0) -> UIImage? {
        let rect = CGRect(x: 0, y: 0, width: cornerRadius * 2 + 1, height: height)
        UIGraphicsBeginImageContextWithOptions(rect.size, false, 0)
        color.setFill()
        UIBezierPath(roundedRect: rect, cornerRadius: cornerRadius).fill()
        let img = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        guard cornerRadius > 0 else { return img }
        let caps = UIEdgeInsets(top: cornerRadius, left: cornerRadius, bottom: cornerRadius, right: cornerRadius)
        return img?.resizableImage(withCapInsets: caps, resizingMode: .stretch)
    }

    /// iOS 6 back-button background: a chevron at the left edge, stretched only
    /// through the empty column to its right. Drawn at the button's own height
    /// so the chevron never scales vertically.
    private static func backChevron(height: CGFloat, color: UIColor) -> UIImage? {
        let width: CGFloat = 16
        UIGraphicsBeginImageContextWithOptions(CGSize(width: width + 1, height: height), false, 0)
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 11, y: height / 2 - 8))
        path.addLine(to: CGPoint(x: 3, y: height / 2))
        path.addLine(to: CGPoint(x: 11, y: height / 2 + 8))
        path.lineWidth = 2.5
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        color.setStroke()
        path.stroke()
        let img = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return img?.resizableImage(withCapInsets: UIEdgeInsets(top: 0, left: width, bottom: 0, right: 0),
                                   resizingMode: .stretch)
    }
}

extension UIImage {
    /// This image's shape filled with `color`. iOS 6 has no template rendering
    /// mode, so icons are recoloured by drawing; the scale is kept.
    func tinted(_ color: UIColor) -> UIImage {
        UIGraphicsBeginImageContextWithOptions(size, false, scale)
        let rect = CGRect(origin: .zero, size: size)
        color.setFill()
        UIRectFill(rect)
        draw(in: rect, blendMode: .destinationIn, alpha: 1)
        let img = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return img ?? self
    }
}

extension UIBarButtonItem {
    /// A bar button showing `image` in the accent colour. Built on a custom view
    /// because the iOS 6 runtime draws a plain image item as a white mask, which
    /// would vanish against the light bar; a pre-tinted image draws the same on
    /// every version.
    convenience init(accentImage image: UIImage?, target: Any?, action: Selector) {
        let button = UIButton(type: .custom)
        button.frame = CGRect(x: 0, y: 0, width: 36, height: 30)
        button.setImage(image?.tinted(Palette.accent), for: .normal)
        button.addTarget(target, action: action, for: .touchUpInside)
        self.init(customView: button)
    }
}

extension UIButton {
    /// A borderless text button in `color`, faded while pressed or disabled.
    /// Built as `.custom` because `.system` shares its raw value with iOS 6's
    /// white rounded-rect button.
    convenience init(plainTitle title: String, color: UIColor, font: UIFont) {
        self.init(type: .custom)
        setTitle(title, for: .normal)
        titleLabel?.font = font
        titleLabel?.backgroundColor = .clear   // iOS 6: labels default to white bg
        setTitleColor(color, for: .normal)
        setTitleColor(color.withAlphaComponent(0.3), for: .highlighted)
        setTitleColor(color.withAlphaComponent(0.3), for: .disabled)
    }
}
