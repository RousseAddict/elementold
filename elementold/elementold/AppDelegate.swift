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

        // Light status bar text throughout the app
        UIApplication.shared.statusBarStyle = .lightContent
        // White navigation bar title
        UINavigationBar.appearance().titleTextAttributes = [
            NSAttributedString.Key.foregroundColor: UIColor.white
        ]

        window = UIWindow(frame: UIScreen.main.bounds)
        let root: UIViewController = MatrixSession.isConfigured ? RoomListVC() : LoginVC()
        let nav = UINavigationController(rootViewController: root)
        nav.navigationBar.barStyle = .black
        nav.navigationBar.tintColor = UIColor(red: 0.13, green: 0.55, blue: 0.60, alpha: 1.0)
        window?.rootViewController = nav
        window?.makeKeyAndVisible()

        return true
    }
}
