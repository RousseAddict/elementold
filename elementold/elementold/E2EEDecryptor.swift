import Foundation

// Primitives for the Matrix end-to-end-encryption recovery path: recovery key
// -> 4S secret storage -> server-side megolm key backup -> decrypt.
//
// Encoding is hand-rolled here on purpose. `NSData`'s base64 API is iOS 7+, so
// on this target it compiles without a warning and only fails on a real device
// (the same class of bug as the addingPercentEncoding crash), and Matrix uses
// UNPADDED base64 in most places, which Foundation's decoder rejects outright.
// Both routines below are pure-stdlib byte loops, like SyncEngine.percentEncode.

enum Base64 {

    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)

    // 0-63 for a value character, -1 for padding/whitespace (skipped), -2 for
    // anything else (rejected).
    private static let reverse: [Int8] = {
        var table = [Int8](repeating: -2, count: 256)
        for (index, byte) in alphabet.enumerated() { table[Int(byte)] = Int8(index) }
        for byte in Array("=\r\n\t ".utf8) { table[Int(byte)] = -1 }
        return table
    }()

    // Accepts padded and unpadded input, and ignores embedded whitespace.
    static func decode(_ text: String) -> [UInt8]? {
        var out: [UInt8] = []
        out.reserveCapacity(text.utf8.count * 3 / 4)
        var accumulator = 0
        var bits = 0
        for byte in text.utf8 {
            let value = reverse[Int(byte)]
            if value == -1 { continue }
            if value < 0 { return nil }
            accumulator = (accumulator << 6) | Int(value)
            bits += 6
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((accumulator >> bits) & 0xFF))
            }
        }
        // Whatever is left over is the zero padding of the final group; it must
        // be fewer than 8 bits and must actually be zero.
        if bits >= 8 { return nil }
        if bits > 0 && (accumulator & ((1 << bits) - 1)) != 0 { return nil }
        return out
    }

    // Unpadded, which is what Matrix expects nearly everywhere.
    static func encode(_ bytes: [UInt8]) -> String {
        var out = ""
        out.reserveCapacity((bytes.count + 2) / 3 * 4)
        var index = 0
        while index < bytes.count {
            let remaining = bytes.count - index
            let b0 = Int(bytes[index])
            let b1 = remaining > 1 ? Int(bytes[index + 1]) : 0
            let b2 = remaining > 2 ? Int(bytes[index + 2]) : 0
            out.unicodeScalars.append(UnicodeScalar(alphabet[b0 >> 2]))
            out.unicodeScalars.append(UnicodeScalar(alphabet[((b0 & 0x03) << 4) | (b1 >> 4)]))
            if remaining > 1 {
                out.unicodeScalars.append(UnicodeScalar(alphabet[((b1 & 0x0F) << 2) | (b2 >> 6)]))
            }
            if remaining > 2 {
                out.unicodeScalars.append(UnicodeScalar(alphabet[b2 & 0x3F]))
            }
            index += 3
        }
        return out
    }
}

enum Base58 {

    private static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".utf8)

    private static let reverse: [Int8] = {
        var table = [Int8](repeating: -1, count: 256)
        for (index, byte) in alphabet.enumerated() { table[Int(byte)] = Int8(index) }
        return table
    }()

    // Whitespace is ignored: a recovery key is displayed in groups of four.
    static func decode(_ text: String) -> [UInt8]? {
        var digits: [UInt8] = [0]
        var leadingZeroes = 0
        var seenNonZero = false
        for byte in text.utf8 {
            if byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 { continue }
            let value = reverse[Int(byte)]
            if value < 0 { return nil }
            if value == 0 && !seenNonZero {
                leadingZeroes += 1
                continue
            }
            seenNonZero = true
            // digits holds the running value as base-256, most significant first.
            var carry = Int(value)
            var index = digits.count - 1
            while index >= 0 {
                carry += Int(digits[index]) * 58
                digits[index] = UInt8(carry & 0xFF)
                carry >>= 8
                index -= 1
            }
            while carry > 0 {
                digits.insert(UInt8(carry & 0xFF), at: 0)
                carry >>= 8
            }
        }
        if !seenNonZero && leadingZeroes == 0 { return nil }
        // Drop the seed zero byte we started with, then restore the '1's.
        while digits.count > 1 && digits[0] == 0 { digits.removeFirst() }
        if !seenNonZero { digits = [] }
        return [UInt8](repeating: 0, count: leadingZeroes) + digits
    }
}

// Swift-side names for crypto_bridge.c. Every call returns nil rather than
// throwing: at this layer a failure is either a wrong key or malformed data
// from the server, and both are handled the same way.
enum Crypto {

    static func sha256(_ data: [UInt8]) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: 32)
        let rc = data.withUnsafeBufferPointer { input in
            crypto_sha256(input.baseAddress, data.count, &out)
        }
        return rc == 0 ? out : nil
    }

    static func hmacSHA256(key: [UInt8], data: [UInt8]) -> [UInt8]? {
        guard !key.isEmpty else { return nil }
        var out = [UInt8](repeating: 0, count: 32)
        let rc = key.withUnsafeBufferPointer { k in
            data.withUnsafeBufferPointer { d in
                crypto_hmac_sha256(k.baseAddress, key.count, d.baseAddress, data.count, &out)
            }
        }
        return rc == 0 ? out : nil
    }

    static func hkdfSHA256(ikm: [UInt8], salt: [UInt8], info: [UInt8], length: Int) -> [UInt8]? {
        guard !ikm.isEmpty, length > 0 else { return nil }
        var out = [UInt8](repeating: 0, count: length)
        let rc = ikm.withUnsafeBufferPointer { i in
            salt.withUnsafeBufferPointer { s in
                info.withUnsafeBufferPointer { n in
                    crypto_hkdf_sha256(i.baseAddress, ikm.count,
                                       s.baseAddress, salt.count,
                                       n.baseAddress, info.count,
                                       &out, length)
                }
            }
        }
        return rc == 0 ? out : nil
    }

    // CTR is its own inverse, so this is both directions.
    static func aes256CTR(key: [UInt8], iv: [UInt8], data: [UInt8]) -> [UInt8]? {
        guard key.count == 32, iv.count == 16, !data.isEmpty else { return nil }
        var out = [UInt8](repeating: 0, count: data.count)
        let rc = key.withUnsafeBufferPointer { k in
            iv.withUnsafeBufferPointer { v in
                data.withUnsafeBufferPointer { d in
                    crypto_aes256_ctr(k.baseAddress, v.baseAddress, d.baseAddress, data.count, &out)
                }
            }
        }
        return rc == 0 ? out : nil
    }

    static func aes256CBCDecrypt(key: [UInt8], iv: [UInt8], data: [UInt8]) -> [UInt8]? {
        guard key.count == 32, iv.count == 16, !data.isEmpty, data.count % 16 == 0 else { return nil }
        var out = [UInt8](repeating: 0, count: data.count)
        var written = 0
        let rc = key.withUnsafeBufferPointer { k in
            iv.withUnsafeBufferPointer { v in
                data.withUnsafeBufferPointer { d in
                    crypto_aes256_cbc_decrypt(k.baseAddress, v.baseAddress,
                                              d.baseAddress, data.count,
                                              &out, &written)
                }
            }
        }
        guard rc == 0, written <= out.count else { return nil }
        return Array(out[0..<written])
    }

    static func x25519(privateKey: [UInt8], peerPublicKey: [UInt8]) -> [UInt8]? {
        guard privateKey.count == 32, peerPublicKey.count == 32 else { return nil }
        var out = [UInt8](repeating: 0, count: 32)
        let rc = privateKey.withUnsafeBufferPointer { p in
            peerPublicKey.withUnsafeBufferPointer { q in
                crypto_x25519(p.baseAddress, q.baseAddress, &out)
            }
        }
        return rc == 0 ? out : nil
    }

    static func x25519PublicKey(privateKey: [UInt8]) -> [UInt8]? {
        guard privateKey.count == 32 else { return nil }
        var out = [UInt8](repeating: 0, count: 32)
        let rc = privateKey.withUnsafeBufferPointer { p in
            crypto_x25519_public(p.baseAddress, &out)
        }
        return rc == 0 ? out : nil
    }

    static func ed25519Verify(publicKey: [UInt8], message: [UInt8], signature: [UInt8]) -> Bool {
        guard publicKey.count == 32, signature.count == 64 else { return false }
        let rc = publicKey.withUnsafeBufferPointer { p in
            message.withUnsafeBufferPointer { m in
                signature.withUnsafeBufferPointer { s in
                    crypto_ed25519_verify(p.baseAddress, m.baseAddress, message.count, s.baseAddress)
                }
            }
        }
        return rc == 0
    }
}

// A decoded Matrix recovery key ("EsT x9Xr ..."): base58 of a 2-byte prefix,
// the 32-byte key, and a parity byte chosen so every byte XORs to zero.
enum RecoveryKey {

    private static let prefix: [UInt8] = [0x8B, 0x01]

    static func decode(_ text: String) -> [UInt8]? {
        guard let bytes = Base58.decode(text), bytes.count == 35 else { return nil }
        guard bytes[0] == prefix[0], bytes[1] == prefix[1] else { return nil }
        var parity: UInt8 = 0
        for byte in bytes { parity ^= byte }
        guard parity == 0 else { return nil }
        return Array(bytes[2..<34])
    }
}

// MARK: - Megolm ratchet

// A megolm ratchet is four 32-byte parts advanced like an odometer: part 0
// turns over every 2^24 messages, part 3 every message. Advancing is one-way —
// you can derive index i+1 from index i but never the reverse, which is the
// whole point (a leaked ratchet can't read older messages).
//
// Everything here works on a COPY. Advancing the stored ratchet in place would
// permanently destroy our ability to read every message below the new index.
enum MegolmRatchet {

    // HMAC-SHA256 keyed by part `from`, over the single byte `to`.
    private static func rehash(_ parts: inout [UInt8], from: Int, to: Int) -> Bool {
        // Copy the key out first: `from` and `to` are the same part on the
        // bump-in-place path below.
        let key = Array(parts[(from * 32)..<(from * 32 + 32)])
        guard let out = Crypto.hmacSHA256(key: key, data: [UInt8(to)]) else { return false }
        for i in 0..<32 { parts[to * 32 + i] = out[i] }
        return true
    }

    // Cost is bounded by the four parts, not by the distance: at most 255 steps
    // per part however far `to` is, so jumping thousands of messages ahead is
    // still ~1000 hashes.
    static func advance(_ ratchet: [UInt8], from: Int, to: Int) -> [UInt8]? {
        guard ratchet.count == 128, from >= 0, to >= from else { return nil }
        if to == from { return ratchet }
        var parts = ratchet
        var counter = UInt32(truncatingIfNeeded: from)
        let target = UInt32(truncatingIfNeeded: to)
        for j in 0..<4 {
            let shift = UInt32((3 - j) * 8)
            var steps = ((target >> shift) &- (counter >> shift)) & 0xFF
            if steps == 0 { continue }
            // All but the last step only touch part j; the parts below it are
            // about to be rebuilt from it anyway.
            while steps > 1 {
                guard rehash(&parts, from: j, to: j) else { return nil }
                steps -= 1
            }
            // Last step rebuilds parts 3..j from j. Descending order matters:
            // part j must keep its old value until it is written last.
            var k = 3
            while k >= j {
                guard rehash(&parts, from: j, to: k) else { return nil }
                k -= 1
            }
            counter = target & (~UInt32(0) << shift)
        }
        return parts
    }
}

// MARK: - Megolm decryption

// Turns an `m.room.encrypted` content dictionary back into the `{type, content}`
// it was before encryption, using a session recovered from the key backup.
//
// Main-thread only, and deliberately so: the whole /sync pipeline runs on main,
// which is also why both caches below exist. `RoomEvent.parse` runs for every
// event of every room on every sync, so an uncached decrypt would mean ratchet
// hashing plus AES on the main thread several times a second.
final class E2EEDecryptor {

    static let shared = E2EEDecryptor()

    enum Outcome {
        case decrypted([String: Any])   // {type, content}
        case locked                     // no message keys on this device at all
        case noKey                      // keys, but not one that reaches this message
        case failed(String)             // reached the crypto and it didn't work out
    }

    // Blunt caps with a full flush, matching EventCell.bodySizeCache: an LRU
    // would cost more bookkeeping than the re-derivation it saves.
    private static let maxCachedPlaintexts = 600
    private static let maxCachedRatchets = 200

    private var plaintexts: [String: [String: Any]] = [:]   // eventId -> payload
    private var ratchets: [String: [UInt8]] = [:]           // "sessionId|index" -> ratchet

    private init() {}

    // Called when the keys go away (hard logout, cache reset). Failures are
    // never cached, so keys ARRIVING needs no invalidation: a message that
    // reported .locked simply succeeds the next time it is parsed.
    func reset() {
        plaintexts.removeAll()
        ratchets.removeAll()
    }

    func decrypt(eventId: String, content: [String: Any]) -> Outcome {
        if let cached = plaintexts[eventId] { return .decrypted(cached) }

        guard content["algorithm"] as? String == "m.megolm.v1.aes-sha2",
              let sessionId = content["session_id"] as? String,
              let cipherText = content["ciphertext"] as? String else {
            return .failed("unsupported encryption")
        }
        // Cheapest possible check first, because this is the path taken on
        // every sync for every message we can't read.
        guard let session = MegolmKeyStore.shared.session(id: sessionId) else {
            return MegolmKeyStore.shared.count == 0 ? .locked : .noKey
        }
        guard let raw = Base64.decode(cipherText),
              let message = E2EEDecryptor.parseMessage(raw) else {
            return .failed("malformed message")
        }
        // Our copy of the session starts partway through: anything older than
        // that is unreadable by design, not a failure.
        guard message.index >= session.firstKnownIndex else { return .noKey }

        guard let ratchet = self.ratchet(for: session, at: message.index),
              let derived = Crypto.hkdfSHA256(ikm: ratchet,
                                              salt: [UInt8](repeating: 0, count: 32),
                                              info: Array("MEGOLM_KEYS".utf8),
                                              length: 80) else {
            return .failed("key derivation failed")
        }
        // 8-byte truncated HMAC over everything up to it.
        guard let mac = Crypto.hmacSHA256(key: Array(derived[32..<64]), data: message.macBody),
              Array(mac[0..<8]) == message.mac else {
            return .failed("MAC mismatch")
        }
        guard let plain = Crypto.aes256CBCDecrypt(key: Array(derived[0..<32]),
                                                  iv: Array(derived[64..<80]),
                                                  data: message.ciphertext) else {
            return .failed("could not decrypt")
        }
        guard let json = (try? JSONSerialization.jsonObject(with: Data(plain),
                                                            options: [])) as? [String: Any],
              let type = json["type"] as? String, !type.isEmpty else {
            return .failed("decrypted data is not an event")
        }
        // Proves the message came from the device that created the session,
        // rather than from anyone who later got hold of the session key.
        guard Crypto.ed25519Verify(publicKey: session.signingKey,
                                   message: message.signedBody,
                                   signature: message.signature) else {
            return .failed("bad signature")
        }

        let payload: [String: Any] = ["type": type,
                                      "content": json["content"] as? [String: Any] ?? [:]]
        if plaintexts.count >= E2EEDecryptor.maxCachedPlaintexts { plaintexts.removeAll() }
        plaintexts[eventId] = payload
        return .decrypted(payload)
    }

    // What the timeline shows when the message stays unreadable. Kept here so
    // the RoomEvent seam is a couple of lines.
    func placeholder(for outcome: Outcome) -> String {
        switch outcome {
        case .decrypted:
            return ""
        case .locked:
            return "\u{1F512} Encrypted — enter your recovery key in Settings"
        case .noKey:
            return "\u{1F512} Encrypted — no key for this message"
        case .failed(let reason):
            return "\u{1F512} Encrypted — \(reason)"
        }
    }

    // The derived ratchet at an absolute index is the same whatever index we
    // started from, so this stays valid even after a lower-index copy of the
    // session is merged in.
    private func ratchet(for session: MegolmSession, at index: Int) -> [UInt8]? {
        let key = session.sessionId + "|" + String(index)
        if let cached = ratchets[key] { return cached }
        guard let advanced = MegolmRatchet.advance(session.ratchet,
                                                   from: session.firstKnownIndex,
                                                   to: index) else { return nil }
        if ratchets.count >= E2EEDecryptor.maxCachedRatchets { ratchets.removeAll() }
        ratchets[key] = advanced
        return advanced
    }

    // MARK: message framing

    private struct MegolmMessage {
        let index: Int
        let ciphertext: [UInt8]
        let macBody: [UInt8]      // everything before the MAC
        let mac: [UInt8]          // 8 bytes
        let signedBody: [UInt8]   // everything before the signature
        let signature: [UInt8]    // 64 bytes
    }

    // version byte 0x03, a protobuf body (field 1 = message index varint,
    // field 2 = length-delimited ciphertext), then the truncated MAC and the
    // Ed25519 signature.
    private static func parseMessage(_ bytes: [UInt8]) -> MegolmMessage? {
        let trailer = 8 + 64
        guard bytes.count > 1 + trailer, bytes[0] == 0x03 else { return nil }
        let bodyEnd = bytes.count - trailer

        var i = 1
        var index: Int? = nil
        var ciphertext: [UInt8]? = nil
        while i < bodyEnd {
            let tag = bytes[i]
            i += 1
            switch tag {
            case 0x08:
                guard let value = readVarint(bytes, &i, bodyEnd) else { return nil }
                index = value
            case 0x12:
                guard let length = readVarint(bytes, &i, bodyEnd),
                      i + length <= bodyEnd else { return nil }
                ciphertext = Array(bytes[i..<(i + length)])
                i += length
            default:
                // Skip a field we don't know by its wire type; anything other
                // than varint or length-delimited we can't measure, so stop.
                switch tag & 0x07 {
                case 0:
                    guard readVarint(bytes, &i, bodyEnd) != nil else { return nil }
                case 2:
                    guard let length = readVarint(bytes, &i, bodyEnd),
                          i + length <= bodyEnd else { return nil }
                    i += length
                default:
                    return nil
                }
            }
        }
        guard i == bodyEnd, let messageIndex = index, let cipher = ciphertext,
              !cipher.isEmpty else { return nil }

        return MegolmMessage(index: messageIndex,
                             ciphertext: cipher,
                             macBody: Array(bytes[0..<bodyEnd]),
                             mac: Array(bytes[bodyEnd..<(bodyEnd + 8)]),
                             signedBody: Array(bytes[0..<(bytes.count - 64)]),
                             signature: Array(bytes[(bytes.count - 64)...]))
    }

    private static func readVarint(_ bytes: [UInt8], _ i: inout Int, _ end: Int) -> Int? {
        var value = 0
        var shift = 0
        while i < end {
            let byte = bytes[i]
            i += 1
            // Int is 32-bit on armv7, so cap the width rather than trap. 28
            // bits is far more than any message index or body length here.
            if shift > 21 { return nil }
            value |= Int(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        return nil
    }
}
