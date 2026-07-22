import Foundation

// Thin wrapper over HTTPClient (libcurl-backed, see HTTPClient.swift/CurlFetcher.swift)
// for the Matrix Client-Server API. No Codable/JSONDecoder — per MediaItem.swift's
// documented finding, casting a JSONSerialization-bridged number via `as? Int`
// silently fails on the swapped Swift 5.1.5 runtime. Always go through
// `(x as? NSNumber)?.intValue` when reading numeric fields out of the [String: Any]
// dictionaries this returns.
class MatrixAPIClient {

    struct MatrixError: Error, CustomStringConvertible {
        let errcode: String
        let error: String
        var description: String { "\(errcode): \(error)" }
    }

    var homeserverBaseURL: String   // e.g. "http://matrix.whispyy.xyz:8008" — no trailing slash
    var accessToken: String?

    init(homeserverBaseURL: String, accessToken: String? = nil) {
        self.homeserverBaseURL = homeserverBaseURL
        self.accessToken = accessToken
    }

    // MARK: - Generic verbs
    //
    // `path` must start with "/_matrix/..." and already include any query string.

    func get(_ path: String, timeout: Int = 30, completion: @escaping ([String: Any]?, Error?) -> Void) {
        HTTPClient.get(url: fullURL(path), headers: authHeaders(), timeout: timeout) { data, error in
            self.parse(data, error, completion: completion)
        }
    }

    func post(_ path: String, body: [String: Any], completion: @escaping ([String: Any]?, Error?) -> Void) {
        HTTPClient.post(url: fullURL(path), headers: authHeaders(), body: body) { data, error in
            self.parse(data, error, completion: completion)
        }
    }

    func put(_ path: String, body: [String: Any], completion: @escaping ([String: Any]?, Error?) -> Void) {
        HTTPClient.put(url: fullURL(path), headers: authHeaders(), body: body) { data, error in
            self.parse(data, error, completion: completion)
        }
    }

    // Uploads raw bytes to the media repo and returns the parsed JSON (with the
    // resulting mxc:// in `content_uri`). Goes straight to CurlFetcher.postData —
    // NOT the generic post() above — because that forces Content-Type:
    // application/json, whereas a media upload must send the image's real MIME
    // type. Upload stayed at /_matrix/media/v3/upload (already authenticated)
    // when download/thumbnail moved to /_matrix/client/v1 in Matrix 1.11.
    // `filename` must be pre-sanitized to plain ASCII (no spaces) by the caller
    // so it needs no percent-encoding — this project's percent-encoding path has
    // an iOS-6 selector-crash history, so we avoid it here entirely.
    func uploadMedia(data: Data, filename: String, mimeType: String,
                     completion: @escaping ([String: Any]?, Error?) -> Void) {
        var headers = authHeaders()
        headers["Content-Type"] = mimeType
        let path = "/_matrix/media/v3/upload?filename=\(filename)"
        CurlFetcher.postData(url: fullURL(path), headers: headers, body: data, timeout: 120) { responseData in
            self.parse(responseData,
                       responseData == nil ? MatrixError(errcode: "M_UNKNOWN", error: "Upload connection failed") : nil,
                       completion: completion)
        }
    }

    // MARK: - Helpers

    private func fullURL(_ path: String) -> String {
        return homeserverBaseURL + path
    }

    private func authHeaders() -> [String: String] {
        guard let token = accessToken else { return [:] }
        return ["Authorization": "Bearer \(token)"]
    }

    // Parses a raw HTTPClient response into a JSON dict, mapping Matrix's
    // {errcode, error} error body (returned with a non-2xx HTTP status, which
    // HTTPClient/CurlFetcher already turn into a nil-data connection error —
    // so this mostly protects against homeservers that return errcode/error
    // with a 200) into a MatrixError.
    private func parse(_ data: Data?, _ error: Error?, completion: @escaping ([String: Any]?, Error?) -> Void) {
        if let error = error {
            completion(nil, error)
            return
        }
        guard let data = data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            completion(nil, MatrixError(errcode: "M_UNKNOWN", error: "Invalid or empty JSON response"))
            return
        }
        if let errcode = json["errcode"] as? String {
            let message = json["error"] as? String ?? "Unknown Matrix error"
            completion(nil, MatrixError(errcode: errcode, error: message))
            return
        }
        completion(json, nil)
    }
}
