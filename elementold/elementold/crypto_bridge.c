#include "crypto_bridge.h"

#include <string.h>

#include <openssl/evp.h>
#include <openssl/hmac.h>
#include <openssl/kdf.h>

int crypto_sha256(const uint8_t *data, size_t len, uint8_t *out32) {
    if (!out32 || (len > 0 && !data)) return -1;
    unsigned int outLen = 0;
    EVP_MD_CTX *ctx = EVP_MD_CTX_new();
    if (!ctx) return -2;
    int rc = -3;
    if (EVP_DigestInit_ex(ctx, EVP_sha256(), NULL) == 1 &&
        EVP_DigestUpdate(ctx, data, len) == 1 &&
        EVP_DigestFinal_ex(ctx, out32, &outLen) == 1 &&
        outLen == 32) {
        rc = 0;
    }
    EVP_MD_CTX_free(ctx);
    return rc;
}

int crypto_hmac_sha256(const uint8_t *key, size_t key_len,
                       const uint8_t *data, size_t data_len,
                       uint8_t *out32) {
    if (!out32 || !key || (data_len > 0 && !data)) return -1;
    unsigned int outLen = 0;
    /* HMAC() with an explicit NULL context allocates and frees internally. */
    if (!HMAC(EVP_sha256(), key, (int)key_len, data, data_len, out32, &outLen)) return -2;
    return outLen == 32 ? 0 : -3;
}

int crypto_hkdf_sha256(const uint8_t *ikm, size_t ikm_len,
                       const uint8_t *salt, size_t salt_len,
                       const uint8_t *info, size_t info_len,
                       uint8_t *out, size_t out_len) {
    if (!ikm || !out || out_len == 0) return -1;
    EVP_PKEY_CTX *ctx = EVP_PKEY_CTX_new_id(EVP_PKEY_HKDF, NULL);
    if (!ctx) return -2;
    int rc = -3;
    if (EVP_PKEY_derive_init(ctx) == 1 &&
        EVP_PKEY_CTX_set_hkdf_md(ctx, EVP_sha256()) == 1 &&
        EVP_PKEY_CTX_set1_hkdf_key(ctx, ikm, (int)ikm_len) == 1) {
        rc = 0;
        /* A zero-length salt is legal HKDF (it means "all zeroes"), but the
           OpenSSL setter rejects it, so skip the call rather than fail. */
        if (rc == 0 && salt && salt_len > 0 &&
            EVP_PKEY_CTX_set1_hkdf_salt(ctx, salt, (int)salt_len) != 1) rc = -4;
        if (rc == 0 && info && info_len > 0 &&
            EVP_PKEY_CTX_add1_hkdf_info(ctx, info, (int)info_len) != 1) rc = -5;
        if (rc == 0) {
            size_t len = out_len;
            if (EVP_PKEY_derive(ctx, out, &len) != 1 || len != out_len) rc = -6;
        }
    }
    EVP_PKEY_CTX_free(ctx);
    return rc;
}

int crypto_aes256_ctr(const uint8_t *key32, const uint8_t *iv16,
                      const uint8_t *in, size_t len, uint8_t *out) {
    if (!key32 || !iv16 || (len > 0 && (!in || !out))) return -1;
    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    if (!ctx) return -2;
    int rc = -3;
    int written = 0;
    if (EVP_EncryptInit_ex(ctx, EVP_aes_256_ctr(), NULL, key32, iv16) == 1 &&
        EVP_EncryptUpdate(ctx, out, &written, in, (int)len) == 1 &&
        (size_t)written == len) {
        rc = 0;
    }
    EVP_CIPHER_CTX_free(ctx);
    return rc;
}

int crypto_aes256_cbc_decrypt(const uint8_t *key32, const uint8_t *iv16,
                              const uint8_t *in, size_t len,
                              uint8_t *out, size_t *out_len) {
    if (!key32 || !iv16 || !in || !out || !out_len) return -1;
    if (len == 0 || (len % 16) != 0) return -2;
    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    if (!ctx) return -3;
    int rc = -4;
    int written = 0, finalWritten = 0;
    if (EVP_DecryptInit_ex(ctx, EVP_aes_256_cbc(), NULL, key32, iv16) == 1 &&
        EVP_DecryptUpdate(ctx, out, &written, in, (int)len) == 1 &&
        EVP_DecryptFinal_ex(ctx, out + written, &finalWritten) == 1) {
        *out_len = (size_t)written + (size_t)finalWritten;
        rc = 0;
    }
    EVP_CIPHER_CTX_free(ctx);
    return rc;
}

int crypto_x25519(const uint8_t *private32, const uint8_t *peer_public32,
                  uint8_t *out_shared32) {
    if (!private32 || !peer_public32 || !out_shared32) return -1;
    EVP_PKEY *priv = EVP_PKEY_new_raw_private_key(EVP_PKEY_X25519, NULL, private32, 32);
    if (!priv) return -2;
    EVP_PKEY *peer = EVP_PKEY_new_raw_public_key(EVP_PKEY_X25519, NULL, peer_public32, 32);
    if (!peer) { EVP_PKEY_free(priv); return -3; }
    EVP_PKEY_CTX *ctx = EVP_PKEY_CTX_new(priv, NULL);
    int rc = -4;
    if (ctx) {
        size_t len = 32;
        if (EVP_PKEY_derive_init(ctx) == 1 &&
            EVP_PKEY_derive_set_peer(ctx, peer) == 1 &&
            EVP_PKEY_derive(ctx, out_shared32, &len) == 1 &&
            len == 32) {
            rc = 0;
        }
        EVP_PKEY_CTX_free(ctx);
    }
    EVP_PKEY_free(peer);
    EVP_PKEY_free(priv);
    return rc;
}

int crypto_x25519_public(const uint8_t *private32, uint8_t *out_public32) {
    if (!private32 || !out_public32) return -1;
    EVP_PKEY *priv = EVP_PKEY_new_raw_private_key(EVP_PKEY_X25519, NULL, private32, 32);
    if (!priv) return -2;
    size_t len = 32;
    int rc = (EVP_PKEY_get_raw_public_key(priv, out_public32, &len) == 1 && len == 32) ? 0 : -3;
    EVP_PKEY_free(priv);
    return rc;
}

int crypto_ed25519_verify(const uint8_t *public32,
                          const uint8_t *msg, size_t msg_len,
                          const uint8_t *sig64) {
    if (!public32 || !sig64 || (msg_len > 0 && !msg)) return -1;
    EVP_PKEY *pub = EVP_PKEY_new_raw_public_key(EVP_PKEY_ED25519, NULL, public32, 32);
    if (!pub) return -2;
    EVP_MD_CTX *ctx = EVP_MD_CTX_new();
    int rc = -3;
    if (ctx) {
        /* Ed25519 is a one-shot algorithm: EVP_DigestVerify, never Update. */
        if (EVP_DigestVerifyInit(ctx, NULL, NULL, NULL, pub) == 1 &&
            EVP_DigestVerify(ctx, sig64, 64, msg, msg_len) == 1) {
            rc = 0;
        } else {
            rc = -4;
        }
        EVP_MD_CTX_free(ctx);
    }
    EVP_PKEY_free(pub);
    return rc;
}
