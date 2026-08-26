#ifndef crypto_bridge_h
#define crypto_bridge_h

#include <stdint.h>
#include <stddef.h>

/* Thin wrappers over the OpenSSL already vendored and linked for libcurl
   (ThirdParty/curl, -lcrypto). They exist so the Matrix E2EE key-recovery
   path (4S secret storage -> megolm key backup -> megolm decryption) can be
   written in Swift without touching OpenSSL's macro-heavy headers, which do
   not survive the bridging header cleanly.

   All of them are allocation-free from the caller's point of view: every
   buffer is supplied by the caller, and every function returns 0 on success
   and a negative value on failure. */

/* out32 receives SHA-256(data). */
int crypto_sha256(const uint8_t *data, size_t len, uint8_t *out32);

/* out32 receives HMAC-SHA256(key, data). */
int crypto_hmac_sha256(const uint8_t *key, size_t key_len,
                       const uint8_t *data, size_t data_len,
                       uint8_t *out32);

/* HKDF-SHA256 (extract-and-expand). `salt` and `info` may be NULL/0.
   `out` receives out_len bytes. */
int crypto_hkdf_sha256(const uint8_t *ikm, size_t ikm_len,
                       const uint8_t *salt, size_t salt_len,
                       const uint8_t *info, size_t info_len,
                       uint8_t *out, size_t out_len);

/* AES-256-CTR over `len` bytes. CTR is its own inverse, so this both
   encrypts and decrypts. `out` must have room for `len` bytes. */
int crypto_aes256_ctr(const uint8_t *key32, const uint8_t *iv16,
                      const uint8_t *in, size_t len, uint8_t *out);

/* AES-256-CBC decrypt with PKCS7 padding. `out` must have room for `len`
   bytes; the plaintext length (always < len) is written to *out_len. */
int crypto_aes256_cbc_decrypt(const uint8_t *key32, const uint8_t *iv16,
                              const uint8_t *in, size_t len,
                              uint8_t *out, size_t *out_len);

/* X25519 ECDH: out_shared32 = scalarmult(private32, peer_public32). */
int crypto_x25519(const uint8_t *private32, const uint8_t *peer_public32,
                  uint8_t *out_shared32);

/* Derives the X25519 public key of `private32`. Used to check a recovered
   backup key against the backup version's advertised public_key before
   trying to decrypt anything with it. */
int crypto_x25519_public(const uint8_t *private32, uint8_t *out_public32);

/* Ed25519 signature check. Returns 0 when the signature is valid. */
int crypto_ed25519_verify(const uint8_t *public32,
                          const uint8_t *msg, size_t msg_len,
                          const uint8_t *sig64);

#endif /* crypto_bridge_h */
