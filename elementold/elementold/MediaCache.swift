import UIKit
import ImageIO

// Downloads + caches Matrix media (mxc:// URIs) for inline image display.
//
// Uses the AUTHENTICATED media endpoints added in Matrix 1.11
// (/_matrix/client/v1/media/thumbnail/{server}/{mediaId}), which require the
// bearer token. The older unauthenticated /_matrix/media/v3/download endpoints
// are deprecated and return 404/403 on any homeserver that has frozen
// unauthenticated media, so we don't use them. All network I/O goes through
// CurlFetcher (libcurl + embedded OpenSSL) like the rest of the app — never
// NSURLConnection, which can't negotiate GCM-only TLS on iOS 6.
//
// Two-tier cache:
//   - an in-memory NSCache of decoded UIImages (fast, but evicted under memory
//     pressure — important on A5/A6 devices with little RAM)
//   - a persistent on-disk cache in Caches/ so an image evicted from memory (or
//     seen in a previous launch) never needs re-downloading.
class MediaCache {
    static let shared = MediaCache()

    // Recent media-fetch outcomes, surfaced in the user-settings "Diagnostics" row.
    // A single value is useless here because several thumbnails load in parallel
    // (a conversation with N images fires N requests at once) — one would just
    // overwrite the others, so a "2 of 4 failed" case looked like a lone "ok".
    // We keep the last few outcomes (newest first) so one round-trip shows EACH
    // image's result: "ok" with a byte count, "not an image" with the server's
    // {errcode,error}/HTML body (e.g. M_UNKNOWN_TOKEN, or a rejected thumbnail
    // size), "no data" for a transport/timeout failure, or "bad mxc" when the
    // URI itself couldn't be parsed (that path never reaches the network).
    // Appended only from CurlFetcher completions / parse guards, both on the main
    // thread, so no locking is needed.
    private static var recentLog: [String] = []
    private static let recentLogLimit = 24
    static var lastDiagnostic: String? {
        return recentLog.isEmpty ? nil : recentLog.joined(separator: "\n\n")
    }
    static func record(_ line: String) {
        recentLog.insert(line, at: 0)
        if recentLog.count > recentLogLimit { recentLog.removeLast(recentLog.count - recentLogLimit) }
    }

    // Compact "WxH" pixel size of a decoded image, for the diagnostic — a "mem
    // hit" that shows blank on screen is either a degenerate (0x0) cached image
    // or a display/layout problem; logging the size tells the two apart.
    private static func dims(_ image: UIImage) -> String {
        return "\(Int(image.size.width))x\(Int(image.size.height))"
    }

    private let memory: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 80
        c.totalCostLimit = 20 * 1024 * 1024   // ~20 MB of decoded images
        return c
    }()

    // Coalesces concurrent requests for the SAME cache key. A table reload
    // (driven by every /sync response) re-runs cellForRowAt for every visible
    // image cell, which — without this — fired a brand-new download for each
    // not-yet-cached thumbnail on EVERY reload. Under a busy sync loop that
    // became a request storm: it exhausted CurlFetcher's worker threads (so
    // nothing past the first screen ever loaded) and pinned the CPU (the device
    // warmed up). Now the first miss for a key owns the single download and
    // later misses just queue their completion behind it. Only ever touched on
    // the main thread (the network kickoff below runs there), so no locking.
    private var inFlight: [String: [(UIImage?) -> Void]] = [:]

    private let dir: String
    // Serializes disk reads/writes off the main thread. Downloads themselves run
    // on CurlFetcher's own concurrent queue, so many thumbnails load in parallel.
    // This queue must stay responsive: image cells read from it on scroll, so
    // nothing slow (e.g. a full-directory trim pass) may run here — see trimQueue.
    private let ioQueue = DispatchQueue(label: "com.jellyold.mediacache")

    // Disk trimming runs on its OWN low-priority queue, NEVER on ioQueue. Trimming
    // enumerates the whole cache directory and stats every file, which on old flash
    // storage is slow enough that doing it on ioQueue would stall the cache reads
    // that image cells depend on — that starvation made thumbnails and the
    // full-screen viewer appear to "never load". Deletions here race harmlessly
    // with ioQueue reads (a missing file just falls through to a re-download).
    // Plain serial queue (no QoS argument — DispatchQoS is iOS 8+, and this
    // project's 7.0 deployment target / iOS 6 ship would reject it).
    private let trimQueue = DispatchQueue(label: "com.jellyold.mediacache.trim")

    // Upper bound for the on-disk tier. When exceeded, the least-recently-modified
    // files are deleted down to 80% of this to leave headroom (avoids trimming on
    // every single write). The in-memory NSCache is bounded separately above.
    private let maxDiskBytes: UInt64 = 100 * 1024 * 1024
    // Debounce flag so a burst of writes schedules only one trim pass. Only ever
    // touched on trimQueue.
    private var trimScheduled = false

    // Downloaded attachments live under Documents, NOT the Caches media dir:
    // they're deliberate user downloads, so they must survive both the 100MB
    // oldest-first trim and iOS's own eviction of Caches under disk pressure.
    // Sized and cleared separately from the image cache.
    private let filesDir: String

    // Coalesces concurrent requests for the same attachment (double taps, cell
    // reuse). Main thread only, like `inFlight`.
    private var fileWaiters: [String: [(progress: ((Float) -> Void)?, completion: (String?) -> Void)]] = [:]

    private init() {
        let caches = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first
            ?? NSTemporaryDirectory()
        dir = (caches as NSString).appendingPathComponent("elementold-media")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: nil)
        let documents = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first
            ?? NSTemporaryDirectory()
        filesDir = (documents as NSString).appendingPathComponent("elementold-files")
        try? FileManager.default.createDirectory(atPath: filesDir, withIntermediateDirectories: true, attributes: nil)
        // Trim once at launch to reclaim space left by previous runs.
        trimQueue.async { [weak self] in self?.trimDiskCache() }
    }

    // Loads a thumbnail for `mxc` scaled to fit width x height (server-side
    // scale). completion is always called on the main thread; nil on any failure
    // (malformed mxc, no token, network/decoding error).
    func loadThumbnail(mxc: String, width: Int, height: Int, completion: @escaping (UIImage?) -> Void) {
        guard let (server, mediaId) = parseMxc(mxc) else {
            MediaCache.record("bad mxc (thumbnail): \(mxc)")
            completion(nil)
            return
        }
        let key = cacheKey(server: server, mediaId: mediaId, width: width, height: height)
        let path = "/_matrix/client/v1/media/thumbnail/\(server)/\(mediaId)?width=\(width)&height=\(height)&method=scale"
        load(key: key, urlPath: path, timeout: 30, completion: completion)
    }

    // Loads the full-resolution image for `mxc` (no server-side scaling) — used
    // by the full-screen viewer and by "save to photos". Cached separately from
    // any thumbnail under a `_full` key. completion is on the main thread.
    func loadFullImage(mxc: String, completion: @escaping (UIImage?) -> Void) {
        guard let (server, mediaId) = parseMxc(mxc) else {
            MediaCache.record("bad mxc (full): \(mxc)")
            completion(nil)
            return
        }
        let key = sanitize("\(server)_\(mediaId)_full")
        let path = "/_matrix/client/v1/media/download/\(server)/\(mediaId)"
        // Only the full download carries the original bytes, so it's the only
        // place a GIF can be animated — the thumbnail endpoint returns a single
        // flattened frame whatever the source was.
        load(key: key, urlPath: path, timeout: 60, animated: true, completion: completion)
    }

    // MARK: - Shared load path (memory → disk → network)

    private func load(key: String, urlPath: String, timeout: Int, animated: Bool = false,
                      completion: @escaping (UIImage?) -> Void) {
        // Compact identifier for the diagnostic log: drop the long common endpoint
        // prefix so each line reads just "thumbnail/server/id?wxh". Recorded for
        // EVERY source (mem/disk/network) so the "Diagnostics" row shows one line
        // per image — a missing line then means the cell never requested it at all.
        let apiPrefix = "/_matrix/client/v1/media/"
        let tag = urlPath.hasPrefix(apiPrefix) ? String(urlPath.dropFirst(apiPrefix.count)) : urlPath
        if let cached = memory.object(forKey: key as NSString) {
            MediaCache.record("mem hit \(MediaCache.dims(cached)) \(tag)")
            completion(cached)
            return
        }
        let diskPath = (dir as NSString).appendingPathComponent(key)
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            if let data = FileManager.default.contents(atPath: diskPath),
               let img = MediaCache.decode(data, animated: animated) {
                self.memory.setObject(img, forKey: key as NSString,
                                      cost: MediaCache.memoryCost(img, dataCount: data.count))
                DispatchQueue.main.async {
                    MediaCache.record("disk hit (\(data.count)B \(MediaCache.dims(img))) \(tag)")
                    completion(img)
                }
                return
            }
            // Not on disk — download. CurlFetcher hops to its own background queue
            // and returns on the main thread, so kick it off from main.
            DispatchQueue.main.async {
                guard let base = MatrixSession.homeserverURL, let token = MatrixSession.accessToken else {
                    MediaCache.record("no session (no base/token) \(tag)")
                    completion(nil)
                    return
                }
                // Already downloading this key? Just wait on the existing request.
                // Recorded too, so the diagnostic still shows one line per cell
                // request — otherwise a coalesced request would look like a cell
                // that never asked for its image at all.
                if self.inFlight[key] != nil {
                    self.inFlight[key]?.append(completion)
                    MediaCache.record("coalesced \(tag)")
                    return
                }
                self.inFlight[key] = [completion]
                let headers = ["Authorization": "Bearer \(token)"]
                let fullURL = base + urlPath
                CurlFetcher.fetchData(url: fullURL, headers: headers, timeout: timeout) { [weak self] data in
                    guard let self = self else { return }
                    // Hand the one result to every completion that coalesced onto this key.
                    let waiters = self.inFlight.removeValue(forKey: key) ?? []
                    guard let data = data, let img = MediaCache.decode(data, animated: animated) else {
                        // Record WHY this failed so the user-settings "Diagnostics" row can
                        // show it on a device with no attached console. nil data == the
                        // transport itself failed (connect/TLS/timeout); non-nil-but-not-an-
                        // image usually means the server returned a JSON error body
                        // ({errcode,error}, e.g. M_UNKNOWN_TOKEN) or an HTML error page.
                        if let data = data {
                            let preview = String(data: data.prefix(160), encoding: .utf8) ?? "<\(data.count) non-utf8 bytes>"
                            MediaCache.record("not an image (\(data.count)B) \(tag)\n\(preview)")
                        } else {
                            MediaCache.record("no data (connect/TLS/timeout) \(tag)")
                        }
                        waiters.forEach { $0(nil) }
                        return
                    }
                    MediaCache.record("ok (\(data.count)B \(MediaCache.dims(img))) \(tag)")
                    self.memory.setObject(img, forKey: key as NSString,
                                          cost: MediaCache.memoryCost(img, dataCount: data.count))
                    self.ioQueue.async {
                        // Path-based NSData write. The Swift `Data.write(to: URL)`
                        // overlay HANGS indefinitely on the swapped 5.1.5 runtime
                        // (iOS 6), permanently wedging this serial queue so every
                        // later disk read/write never runs — which made received
                        // images blank on the 2nd conversation and after NSCache
                        // eviction. The read side already uses the path-based
                        // FileManager API; match it here.
                        (data as NSData).write(toFile: diskPath, atomically: true)
                        self.scheduleTrim()
                    }
                    waiters.forEach { $0(img) }
                }
            }
        }
    }

    // MARK: - Decoding (incl. animated GIF)

    // An animated GIF costs one decoded bitmap PER FRAME, so it has to be
    // bounded: a 480x270 clip at 100 frames is ~52 MB in memory (against a 20 MB
    // cache budget) even though it's a couple of MB on the wire. Past these
    // limits we keep the frames decoded so far and drop the rest — a truncated
    // loop is a far better outcome than an out-of-memory kill on a 4S.
    private static let maxGifFrames = 120
    private static let maxGifPixels = 12 * 1024 * 1024

    // UIImage(data:) only ever yields the FIRST frame of a GIF, which is why
    // these render frozen. `animated` is set only for the full-size download
    // (the viewer); everywhere else we deliberately keep the cheap static path.
    private static func decode(_ data: Data, animated: Bool) -> UIImage? {
        if animated, isGIF(data), let gif = animatedGIF(data) { return gif }
        return UIImage(data: data)
    }

    // Sniff the GIF87a/GIF89a magic rather than trusting the sender-supplied
    // info.mimetype, which is arbitrary text from another client.
    private static func isGIF(_ data: Data) -> Bool {
        guard data.count >= 6 else { return false }
        let magic = [UInt8](data.prefix(3))
        return magic == [0x47, 0x49, 0x46]   // "GIF"
    }

    // ImageIO (iOS 4+) is the only GIF frame decoder available to us;
    // UIImage.animatedImage(with:duration:) is iOS 5+. A UIImageView plays such
    // an image on its own the moment it's assigned, so no timer is needed and
    // the viewer needs no changes.
    private static func animatedGIF(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        // A single-frame GIF is just an image — let the normal path handle it.
        guard count > 1 else { return nil }

        var frames: [UIImage] = []
        var duration: Double = 0
        var pixels = 0
        for i in 0..<min(count, maxGifFrames) {
            guard let cg = CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }
            pixels += cg.width * cg.height
            if pixels > maxGifPixels && !frames.isEmpty { break }
            frames.append(UIImage(cgImage: cg))
            duration += frameDelay(source: source, index: i)
        }
        guard frames.count > 1 else { return nil }
        // Some GIFs declare no delay at all; ~10 fps is the usual browser default.
        if duration <= 0 { duration = Double(frames.count) * 0.1 }
        return UIImage.animatedImage(with: frames, duration: duration)
    }

    // Per-frame delay in seconds. The unclamped value is the file's real intent;
    // the clamped one is what browsers enforce, and is all some encoders write.
    // Numbers out of a bridged dictionary must go through NSNumber — `as? Double`
    // silently fails on this runtime.
    private static func frameDelay(source: CGImageSource, index: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any],
              let gif = props[kCGImagePropertyGIFDictionary as String] as? [String: Any] else {
            return 0.1
        }
        var delay = (gif[kCGImagePropertyGIFUnclampedDelayTime as String] as? NSNumber)?.doubleValue ?? 0
        if delay <= 0 {
            delay = (gif[kCGImagePropertyGIFDelayTime as String] as? NSNumber)?.doubleValue ?? 0
        }
        // A 0/1-hundredth delay means "as fast as possible", which every renderer
        // reads as ~10 fps rather than a busy loop.
        return delay < 0.02 ? 0.1 : delay
    }

    // What an entry really occupies in the NSCache budget. Charging the
    // compressed byte count is close enough for a still, but under-bills an
    // animation by ~25x — enough of them would sit in a 20 MB cache to exhaust
    // the device's RAM instead.
    private static func memoryCost(_ image: UIImage, dataCount: Int) -> Int {
        guard let frames = image.images, !frames.isEmpty else { return dataCount }
        let scale = image.scale
        let perFrame = Int(image.size.width * scale * image.size.height * scale) * 4
        return max(dataCount, perFrame * frames.count)
    }

    // MARK: - Audio (voice messages)

    // Downloads (and disk-caches) the audio file for `mxc`, returning its local
    // file path on completion (main thread) or nil on failure. Unlike images
    // there's no in-memory tier (audio isn't a UIImage) — disk only. AVAudioPlayer
    // plays from this file path. Uses the same authenticated download endpoint and
    // CurlFetcher transport as images. No coalescing: voice taps are one-at-a-time.
    func loadAudioPath(mxc: String, completion: @escaping (String?) -> Void) {
        guard let (server, mediaId) = parseMxc(mxc) else {
            MediaCache.record("bad mxc (audio): \(mxc)")
            completion(nil)
            return
        }
        // Keep an .m4a extension so AVAudioPlayer reliably identifies the format.
        let key = sanitize("\(server)_\(mediaId)_audio") + ".m4a"
        let diskPath = (dir as NSString).appendingPathComponent(key)
        let urlPath = "/_matrix/client/v1/media/download/\(server)/\(mediaId)"
        let tag = "download/\(server)/\(mediaId) (audio)"
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            if FileManager.default.fileExists(atPath: diskPath) {
                let playable = self.playablePath(diskPath, server: server, mediaId: mediaId)
                DispatchQueue.main.async {
                    MediaCache.record("audio disk hit \(tag)")
                    completion(playable)
                }
                return
            }
            DispatchQueue.main.async {
                guard let base = MatrixSession.homeserverURL, let token = MatrixSession.accessToken else {
                    MediaCache.record("no session (audio) \(tag)")
                    completion(nil)
                    return
                }
                let headers = ["Authorization": "Bearer \(token)"]
                CurlFetcher.fetchData(url: base + urlPath, headers: headers, timeout: 60) { [weak self] data in
                    guard let self = self else { return }
                    guard let data = data, data.count > 0 else {
                        MediaCache.record("no data (audio) \(tag)")
                        completion(nil)
                        return
                    }
                    self.ioQueue.async {
                        // Path-based NSData write — Swift `Data.write(to:)` hangs on
                        // the 5.1.5 runtime (see image write sites).
                        (data as NSData).write(toFile: diskPath, atomically: true)
                        self.scheduleTrim()
                        let playable = self.playablePath(diskPath, server: server, mediaId: mediaId)
                        DispatchQueue.main.async {
                            MediaCache.record("audio ok (\(data.count)B) \(tag)")
                            completion(playable)
                        }
                    }
                }
            }
        }
    }

    // Copies a just-recorded local audio file into the disk cache under the key
    // its mxc will later resolve to, so the sender's own voice message plays
    // instantly (and never re-downloads) — mirrors storeThumbnail/storeFull for
    // images. A freshly-uploaded mxc can 404 on download for a moment otherwise.
    func storeAudioFile(fromPath src: String, mxc: String) {
        guard let (server, mediaId) = parseMxc(mxc) else { return }
        let key = sanitize("\(server)_\(mediaId)_audio") + ".m4a"
        let diskPath = (dir as NSString).appendingPathComponent(key)
        ioQueue.async { [weak self] in
            guard let self = self, let data = FileManager.default.contents(atPath: src) else { return }
            (data as NSData).write(toFile: diskPath, atomically: true)
            self.scheduleTrim()
        }
    }

    // iOS 6's AVAudioPlayer can't decode Opus, and voice notes bridged from
    // WhatsApp (via mautrix-whatsapp) are Ogg/Opus. If the cached file is an Ogg
    // stream (magic "OggS"), transcode it ONCE to a sibling PCM WAV (via the
    // vendored libopus/libogg C bridge) and return the WAV path; the decoded WAV
    // is cached on disk so the decode only happens on first play. Anything that
    // isn't Ogg (our own AAC .m4a recordings, MP3, etc.) is returned unchanged.
    // Runs on the caller's ioQueue — a few-second voice note decodes in well
    // under the queue-starvation danger zone, and voice taps are one-at-a-time.
    private func playablePath(_ rawPath: String, server: String, mediaId: String) -> String {
        let wavPath = (dir as NSString).appendingPathComponent(sanitize("\(server)_\(mediaId)_audio") + ".wav")
        if FileManager.default.fileExists(atPath: wavPath) { return wavPath }
        guard let data = FileManager.default.contents(atPath: rawPath), data.count >= 4 else { return rawPath }
        let isOgg = data[0] == 0x4F && data[1] == 0x67 && data[2] == 0x67 && data[3] == 0x53
        guard isOgg else { return rawPath }
        let rc = opus_ogg_to_wav(rawPath, wavPath)
        if rc == 0 {
            MediaCache.record("opus->wav ok \(mediaId)")
            return wavPath
        }
        MediaCache.record("opus->wav fail (\(rc)) \(mediaId)")
        return rawPath
    }

    // MARK: - Priming (used by the sender so its own image renders immediately)

    // Stores an image directly under the thumbnail key a cell will later request —
    // called right after a successful upload so the sender sees their own photo
    // without waiting for the homeserver to make the fresh mxc thumbnailable
    // (freshly-uploaded media frequently 404s on the thumbnail endpoint for a
    // moment). Loads from cache thereafter, so no wasted download either.
    func storeThumbnail(_ image: UIImage, mxc: String, width: Int, height: Int) {
        guard let (server, mediaId) = parseMxc(mxc) else { return }
        store(image, key: cacheKey(server: server, mediaId: mediaId, width: width, height: height))
    }

    // Same, for the full-resolution viewer key.
    func storeFull(_ image: UIImage, mxc: String) {
        guard let (server, mediaId) = parseMxc(mxc) else { return }
        store(image, key: sanitize("\(server)_\(mediaId)_full"))
    }

    private func store(_ image: UIImage, key: String) {
        // Populate the in-memory tier SYNCHRONOUSLY so a just-sent image is
        // available to the very next cell that asks for it — the cell requests its
        // thumbnail as soon as the echoed event arrives over /sync, and making it
        // wait behind disk I/O (or worse, miss entirely) is exactly what left our
        // own sent photos blank. The disk copy is written in the background.
        memory.setObject(image, forKey: key as NSString)
        let diskPath = (dir as NSString).appendingPathComponent(key)
        ioQueue.async { [weak self] in
            guard let self = self, let data = image.jpegData(compressionQuality: 0.9) else { return }
            // Path-based NSData write — the Swift `Data.write(to: URL)` overlay
            // hangs on the 5.1.5 runtime and wedges this serial queue (see the
            // download-write site above for the full explanation).
            (data as NSData).write(toFile: diskPath, atomically: true)
            self.scheduleTrim()
        }
    }

    // MARK: - Attachments (m.file / m.video)

    // Local path for an already-downloaded attachment, nil when it isn't on disk
    // yet. One stat call — cheap enough for cellForRowAt.
    func downloadedFilePath(mxc: String, filename: String, mimeType: String) -> String? {
        guard let path = filePath(mxc: mxc, filename: filename, mimeType: mimeType) else { return nil }
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    // Streams an attachment straight to disk instead of buffering the whole body
    // in memory the way fetchData does — a large attachment would otherwise be
    // fatal on a 512MB device. Downloads land on a ".part" file and are renamed
    // on success, so a kill mid-transfer can't leave a truncated file that later
    // looks complete. progress and completion both arrive on the main thread.
    func downloadFile(mxc: String, filename: String, mimeType: String,
                      progress: ((Float) -> Void)?,
                      completion: @escaping (String?) -> Void) {
        guard let (server, mediaId) = parseMxc(mxc),
              let path = filePath(mxc: mxc, filename: filename, mimeType: mimeType) else {
            MediaCache.record("bad mxc (file): \(mxc)")
            completion(nil)
            return
        }
        if FileManager.default.fileExists(atPath: path) {
            completion(path)
            return
        }
        if fileWaiters[path] != nil {
            fileWaiters[path]?.append((progress, completion))
            return
        }
        guard let base = MatrixSession.homeserverURL, let token = MatrixSession.accessToken else {
            MediaCache.record("no session (file) \(mediaId)")
            completion(nil)
            return
        }
        fileWaiters[path] = [(progress, completion)]

        let partPath = path + ".part"
        let url = base + "/_matrix/client/v1/media/download/\(server)/\(mediaId)"
        CurlFetcher.downloadToFile(url: url,
                                   headers: ["Authorization": "Bearer \(token)"],
                                   outputPath: partPath,
                                   progress: { [weak self] fraction in
                                       for waiter in self?.fileWaiters[path] ?? [] {
                                           waiter.progress?(fraction)
                                       }
                                   }) { [weak self] ok in
            guard let self = self else { return }
            let fm = FileManager.default
            var succeeded = ok
            if ok {
                try? fm.removeItem(atPath: path)
                do { try fm.moveItem(atPath: partPath, toPath: path) } catch { succeeded = false }
            } else {
                try? fm.removeItem(atPath: partPath)
            }
            MediaCache.record(succeeded ? "file ok \(mediaId)" : "file failed \(mediaId)")
            let waiters = self.fileWaiters.removeValue(forKey: path) ?? []
            for waiter in waiters { waiter.completion(succeeded ? path : nil) }
        }
    }

    // Disk name is "<server>_<mediaId>.<ext>": unique per media, with the real
    // extension preserved because the preview/open-in machinery infers the file
    // type from it. The sender-supplied filename is untrusted and never used as
    // a path component — only its extension, sanitized.
    private func filePath(mxc: String, filename: String, mimeType: String) -> String? {
        guard let (server, mediaId) = parseMxc(mxc) else { return nil }
        let ext = fileExtension(filename: filename, mimeType: mimeType)
        let name = sanitize("\(server)_\(mediaId)") + "." + ext
        return (filesDir as NSString).appendingPathComponent(name)
    }

    // Mime types whose subtype isn't a usable extension. Getting this right
    // matters: the preview machinery infers the file type from the extension,
    // and an unknown one ("…​.plain") leaves Quick Look spinning forever.
    private static let mimeExtensions: [String: String] = [
        "text/plain": "txt",
        "text/markdown": "md",
        "text/csv": "csv",
        "text/html": "html",
        "application/json": "json",
        "application/xml": "xml",
        "text/xml": "xml",
        "image/jpeg": "jpg",
        "image/svg+xml": "svg",
        "audio/mpeg": "mp3",
        "audio/mp4": "m4a",
        "video/quicktime": "mov",
        "application/msword": "doc",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document": "docx",
        "application/vnd.ms-excel": "xls",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": "xlsx",
        "application/zip": "zip",
    ]

    // Extension for the on-disk copy: the original filename's, else a known
    // mapping for the mime type, else the mime subtype when it's a plain short
    // token ("pdf", "mp4"), else "bin".
    private func fileExtension(filename: String, mimeType: String) -> String {
        if let dot = filename.lastIndex(of: "."), dot < filename.index(before: filename.endIndex) {
            let candidate = String(filename[filename.index(after: dot)...])
            return sanitize(String(candidate.prefix(8)))
        }
        if let mapped = MediaCache.mimeExtensions[mimeType.lowercased()] { return mapped }
        if let slash = mimeType.lastIndex(of: "/"), slash < mimeType.index(before: mimeType.endIndex) {
            let subtype = String(mimeType[mimeType.index(after: slash)...])
            let isPlain = subtype.count <= 8 && subtype.allSatisfy { $0.isLetter || $0.isNumber }
            if isPlain { return sanitize(subtype) }
        }
        return "bin"
    }

    // Total bytes + file count of downloaded attachments (Documents), separate
    // from the image cache. Computed on trimQueue; completion on the main thread.
    func filesUsage(completion: @escaping (_ bytes: UInt64, _ files: Int) -> Void) {
        trimQueue.async {
            let fm = FileManager.default
            var total: UInt64 = 0
            var count = 0
            if let names = try? fm.contentsOfDirectory(atPath: self.filesDir) {
                for name in names {
                    let path = (self.filesDir as NSString).appendingPathComponent(name)
                    guard let attrs = try? fm.attributesOfItem(atPath: path) else { continue }
                    total += (attrs[.size] as? NSNumber)?.uint64Value ?? 0
                    count += 1
                }
            }
            DispatchQueue.main.async { completion(total, count) }
        }
    }

    // Deletes every downloaded attachment. completion on the main thread.
    func clearFiles(completion: @escaping () -> Void) {
        trimQueue.async {
            let fm = FileManager.default
            if let names = try? fm.contentsOfDirectory(atPath: self.filesDir) {
                for name in names {
                    try? fm.removeItem(atPath: (self.filesDir as NSString).appendingPathComponent(name))
                }
            }
            DispatchQueue.main.async { completion() }
        }
    }

    // MARK: - Stats / reset (surfaced in the user-settings screen)

    // Total bytes currently on disk + file count. Computed on trimQueue (same
    // directory walk trimming does); completion on the main thread.
    func diskUsage(completion: @escaping (_ bytes: UInt64, _ files: Int) -> Void) {
        trimQueue.async {
            let fm = FileManager.default
            var total: UInt64 = 0
            var count = 0
            if let names = try? fm.contentsOfDirectory(atPath: self.dir) {
                for name in names {
                    let path = (self.dir as NSString).appendingPathComponent(name)
                    guard let attrs = try? fm.attributesOfItem(atPath: path) else { continue }
                    total += (attrs[.size] as? NSNumber)?.uint64Value ?? 0
                    count += 1
                }
            }
            DispatchQueue.main.async { completion(total, count) }
        }
    }

    // Empties both tiers. completion on the main thread.
    func clear(completion: @escaping () -> Void) {
        memory.removeAllObjects()
        trimQueue.async {
            let fm = FileManager.default
            if let names = try? fm.contentsOfDirectory(atPath: self.dir) {
                for name in names {
                    try? fm.removeItem(atPath: (self.dir as NSString).appendingPathComponent(name))
                }
            }
            DispatchQueue.main.async { completion() }
        }
    }

    // MARK: - Disk trimming

    // Debounced entry point: collapses a burst of writes into a single trim pass
    // 5s later. Hops to trimQueue (where trimScheduled is only ever touched, and
    // where the trim itself runs — off the latency-sensitive ioQueue).
    private func scheduleTrim() {
        trimQueue.async { [weak self] in
            guard let self = self, !self.trimScheduled else { return }
            self.trimScheduled = true
            self.trimQueue.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self = self else { return }
                self.trimScheduled = false
                self.trimDiskCache()
            }
        }
    }

    // Enumerates the cache dir; if the total exceeds maxDiskBytes, deletes files
    // oldest-first (by modification date) until we're back under 80% of the cap.
    // Runs on trimQueue.
    private func trimDiskCache() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return }

        var entries: [(path: String, size: UInt64, date: Date)] = []
        var total: UInt64 = 0
        for name in names {
            let path = (dir as NSString).appendingPathComponent(name)
            guard let attrs = try? fm.attributesOfItem(atPath: path) else { continue }
            let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
            let date = (attrs[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
            entries.append((path, size, date))
            total += size
        }
        if total <= maxDiskBytes { return }

        let target = maxDiskBytes * 8 / 10
        entries.sort { $0.date < $1.date }   // oldest first
        for entry in entries {
            if total <= target { break }
            try? fm.removeItem(atPath: entry.path)
            total = total > entry.size ? total - entry.size : 0
        }
    }

    // MARK: - Helpers

    // mxc://server/mediaId → (server, mediaId). mediaId is an opaque
    // server-generated token with no slashes, so a plain split on "/" is enough.
    private func parseMxc(_ mxc: String) -> (server: String, mediaId: String)? {
        guard mxc.hasPrefix("mxc://") else { return nil }
        let rest = String(mxc.dropFirst("mxc://".count))
        let parts = rest.components(separatedBy: "/")
        guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (parts[0], parts[1])
    }

    private func cacheKey(server: String, mediaId: String, width: Int, height: Int) -> String {
        return sanitize("\(server)_\(mediaId)_\(width)x\(height)")
    }

    // Reduces an arbitrary string to a safe flat filename. Avoids CharacterSet
    // convenience APIs (some are unreliable on the swapped 5.1.5 runtime) — a
    // hand-rolled allow-list over Characters uses only Swift stdlib.
    private func sanitize(_ s: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
        return String(s.map { allowed.contains($0) ? $0 : "_" })
    }
}

// A circular avatar view: shows a color+initials placeholder immediately, then
// asynchronously swaps in the Matrix media thumbnail for an mxc:// URI (via
// MediaCache). Reused by the room list, the timeline nav bar, and per-message
// sender avatars. Reuse-safe: an in-flight load whose mxc no longer matches the
// view's current one is discarded. Defined here (not a new file) so it needs no
// pbxproj registration and can share MediaCache directly.
class AvatarView: UIView {
    private let imageView = UIImageView()
    private let initialsLabel = UILabel()
    private var currentMxc: String?

    // Thumbnail pixel size requested from the server — comfortably covers the
    // largest on-screen avatar (room-list 40pt @2x, timeline nav ~30pt, sender
    // ~28pt) at Retina scale without per-view size juggling.
    private static let thumbPx = 96

    // Deterministic placeholder background palette, indexed by a stable hash of
    // the name so the same room/user keeps the same colour across launches.
    private static let palette: [UIColor] = [
        UIColor(red: 0.90, green: 0.30, blue: 0.35, alpha: 1),
        UIColor(red: 0.95, green: 0.55, blue: 0.20, alpha: 1),
        UIColor(red: 0.30, green: 0.65, blue: 0.40, alpha: 1),
        UIColor(red: 0.20, green: 0.55, blue: 0.85, alpha: 1),
        UIColor(red: 0.55, green: 0.40, blue: 0.80, alpha: 1),
        UIColor(red: 0.40, green: 0.60, blue: 0.65, alpha: 1),
    ]

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        addSubview(imageView)
        // iOS 6: UILabel defaults to an OPAQUE WHITE background — must clear it or
        // it paints a white square over the colour circle.
        initialsLabel.backgroundColor = .clear
        initialsLabel.textColor = .white
        initialsLabel.textAlignment = .center
        addSubview(initialsLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.width / 2
        imageView.frame = bounds
        initialsLabel.frame = bounds
        initialsLabel.font = UIFont.boldSystemFont(ofSize: max(9, bounds.width * 0.42))
    }

    func setAvatar(mxc: String?, name: String) {
        currentMxc = mxc
        // Placeholder first (shown while loading, and permanently if no mxc).
        initialsLabel.text = AvatarView.initials(from: name)
        backgroundColor = AvatarView.color(for: name)
        imageView.image = nil
        imageView.isHidden = true

        guard let mxc = mxc, !mxc.isEmpty else { return }
        MediaCache.shared.loadThumbnail(mxc: mxc, width: AvatarView.thumbPx, height: AvatarView.thumbPx) { [weak self] image in
            guard let self = self, self.currentMxc == mxc, let image = image else { return }
            self.imageView.image = image
            self.imageView.isHidden = false
        }
    }

    // One or two uppercase initials, ignoring a leading Matrix sigil (@user, #room, !id).
    private static func initials(from name: String) -> String {
        var cleaned = name
        if let first = cleaned.first, first == "@" || first == "#" || first == "!" {
            cleaned = String(cleaned.dropFirst())
        }
        let words = cleaned.split(separator: " ").prefix(2)
        let letters = words.compactMap { $0.first }.map { String($0).uppercased() }
        return letters.isEmpty ? "?" : letters.joined()
    }

    private static func color(for name: String) -> UIColor {
        var hash = 0
        for scalar in name.unicodeScalars { hash = (hash &* 31 &+ Int(scalar.value)) & 0x7fffffff }
        return palette[hash % palette.count]
    }
}
