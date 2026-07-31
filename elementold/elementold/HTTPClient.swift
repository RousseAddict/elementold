import Foundation

class HTTPClient {

    static func get(url: String, headers: [String: String] = [:], timeout: Int = 30, completion: @escaping (Data?, Error?) -> Void) {
        guard URL(string: url) != nil else {
            completion(nil, makeError("Invalid URL: \(url)"))
            return
        }
        // Route GET through libcurl + embedded OpenSSL for the same reason as
        // post(): iOS 6 Secure Transport can't negotiate GCM-only TLS, so HTTPS
        // hosts fail under NSURLConnection. Works over both HTTP and HTTPS.
        // timeout is overridable so long-poll callers (Matrix /sync) can wait
        // longer than a normal request without racing the server-side timeout.
        // Both closures below run on the main thread and transportError fires
        // first, so `reason` is already set by the time the body is inspected.
        var reason: String?
        CurlFetcher.fetchData(url: url, headers: headers, timeout: timeout,
                              transportError: { reason = $0 }) { data in
            if let data = data {
                completion(data, nil)
            } else {
                completion(nil, makeError(failureMessage(reason)))
            }
        }
    }

    static func post(url: String, headers: [String: String] = [:], body: [String: Any], completion: @escaping (Data?, Error?) -> Void) {
        guard URL(string: url) != nil else {
            completion(nil, makeError("Invalid URL: \(url)"))
            return
        }
        var allHeaders = headers
        allHeaders["Content-Type"] = "application/json"
        let bodyData = (try? JSONSerialization.data(withJSONObject: body, options: [])) ?? Data()
        // Route POST (login) through libcurl + embedded OpenSSL. iOS 6 Secure
        // Transport only negotiates CBC cipher suites, so HTTPS servers that
        // require GCM-only TLS fail the handshake under NSURLConnection. OpenSSL
        // negotiates GCM correctly — HTTPS logins now work and HTTP logins are
        // unaffected (curl handles both schemes).
        var reason: String?
        CurlFetcher.postData(url: url, headers: allHeaders, body: bodyData,
                             transportError: { reason = $0 }) { data in
            if let data = data {
                completion(data, nil)
            } else {
                completion(nil, makeError(failureMessage(reason)))
            }
        }
    }

    static func put(url: String, headers: [String: String] = [:], body: [String: Any], completion: @escaping (Data?, Error?) -> Void) {
        guard URL(string: url) != nil else {
            completion(nil, makeError("Invalid URL: \(url)"))
            return
        }
        var allHeaders = headers
        allHeaders["Content-Type"] = "application/json"
        let bodyData = (try? JSONSerialization.data(withJSONObject: body, options: [])) ?? Data()
        // Used for Matrix event sends (PUT /rooms/{id}/send/...) and state
        // updates. Same libcurl + embedded OpenSSL transport as get()/post().
        var reason: String?
        CurlFetcher.putData(url: url, headers: allHeaders, body: bodyData,
                            transportError: { reason = $0 }) { data in
            if let data = data {
                completion(data, nil)
            } else {
                completion(nil, makeError(failureMessage(reason)))
            }
        }
    }

    // The old text was a single generic sentence for every transport failure,
    // which actively misled: a request that timed out because the server was
    // still building the response read as a wrong or unreachable URL. When curl
    // tells us what went wrong, say so; keep the guidance only as a fallback.
    private static func failureMessage(_ reason: String?) -> String {
        if let reason = reason {
            return "Connection failed: \(reason)"
        }
        return "Connection failed. Check the server URL and that it is reachable."
    }

    private static func makeError(_ message: String) -> NSError {
        return NSError(domain: "HTTPClient", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
