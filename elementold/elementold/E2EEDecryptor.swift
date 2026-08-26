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
