import Foundation

// Persisted login state. Replaces jellyold's JellyfinServer.swift.
//
// All fields live in UserDefaults. An earlier version stored access_token/
// device_id/user_id in the Keychain instead, but SecItemAdd silently failed
// under this project's ad-hoc (`codesign --sign -`), no-provisioning-profile
// signing pipeline (no `keychain-access-groups` entitlement baked in) — the
// write appeared to succeed (no error was ever checked) but the value read
// back nil, causing every /sync request to go out with no Authorization
// header (M_MISSING_TOKEN). UserDefaults has no such entitlement dependency
// and is exactly what jellyold already relied on in this same pipeline, so
// credentials are stored there too now.
struct MatrixSession {
    private static let defaults = UserDefaults.standard

    static var homeserverURL: String? {
        get { defaults.string(forKey: "homeserverURL") }
        set { defaults.set(newValue, forKey: "homeserverURL") }
    }

    static var accessToken: String? {
        get { defaults.string(forKey: "accessToken") }
        set { defaults.set(newValue, forKey: "accessToken") }
    }
    static var deviceId: String? {
        get { defaults.string(forKey: "deviceId") }
        set { defaults.set(newValue, forKey: "deviceId") }
    }
    static var userId: String? {
        get { defaults.string(forKey: "userId") }
        set { defaults.set(newValue, forKey: "userId") }
    }

    // Empty strings count as unconfigured. A stored "" used to pass this check
    // and route AppDelegate straight to the room list with nothing usable to
    // authenticate with, which surfaces minutes later as M_MISSING_TOKEN rather
    // than at the point the credentials were actually bad.
    static var isConfigured: Bool {
        guard let h = homeserverURL, !h.isEmpty,
              let t = accessToken, !t.isEmpty,
              let u = userId, !u.isEmpty else { return false }
        return true
    }

    // Soft logout: the session was rejected by the server, but the account and
    // the data we hold for it are still valid. Dropping only the token sends the
    // user back to a pre-filled login screen while leaving the persisted room
    // list and media cache intact, so re-authenticating is instant.
    static func clearAccessToken() {
        defaults.removeObject(forKey: "accessToken")
    }

    static func clear() {
        defaults.removeObject(forKey: "homeserverURL")
        defaults.removeObject(forKey: "accessToken")
        defaults.removeObject(forKey: "deviceId")
        defaults.removeObject(forKey: "userId")
    }

    static func makeAPIClient() -> MatrixAPIClient {
        return MatrixAPIClient(homeserverBaseURL: homeserverURL ?? "", accessToken: accessToken)
    }
}
