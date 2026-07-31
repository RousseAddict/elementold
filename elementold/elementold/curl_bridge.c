#include "curl_bridge.h"
#include <curl/curl.h>
#include <stdio.h>

void curl_bridge_global_init(void) {
    curl_global_init(CURL_GLOBAL_ALL);
}

CurlHandle curl_bridge_init(void) {
    return curl_easy_init();
}

void curl_bridge_cleanup(CurlHandle h) {
    curl_easy_cleanup(h);
}

void curl_bridge_set_url(CurlHandle h, const char *url) {
    curl_easy_setopt(h, CURLOPT_URL, url);
}

/* Full cert verification. This vendored OpenSSL has no default trust store on
 * iOS (unlike Linux /etc/ssl/certs), so a CA bundle MUST be supplied explicitly
 * via curl_bridge_set_ca_bundle() (see CurlFetcher, which points this at the
 * app-bundled Mozilla cacert.pem) — otherwise HTTPS fails with "unable to get
 * local issuer certificate". Plain-HTTP requests ignore all of this. */
void curl_bridge_set_ssl_verify(CurlHandle h) {
    curl_easy_setopt(h, CURLOPT_SSL_VERIFYPEER, 1L);
    curl_easy_setopt(h, CURLOPT_SSL_VERIFYHOST, 2L);
}

/* Point OpenSSL at a PEM file of trusted CA roots (CURLOPT_CAINFO). Required on
 * iOS because there is no system trust store the vendored OpenSSL can read. */
void curl_bridge_set_ca_bundle(CurlHandle h, const char *path) {
    if (path) {
        curl_easy_setopt(h, CURLOPT_CAINFO, path);
    }
}

void curl_bridge_set_follow_redirects(CurlHandle h) {
    curl_easy_setopt(h, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(h, CURLOPT_MAXREDIRS, 10L);
}

void curl_bridge_set_timeout(CurlHandle h, long secs) {
    curl_easy_setopt(h, CURLOPT_TIMEOUT, secs);
}

/* Stall detector for transfers that legitimately have no total timeout (a large
 * media upload or download can run for minutes). Aborts once the transfer has
 * moved fewer than `bytes_per_sec` bytes/second for `secs` consecutive seconds.
 * Without this, a connection that goes quiet without dropping hangs forever —
 * and because uploads and downloads each run on a SERIAL queue, one such hang
 * blocks every later transfer for the rest of the process's life. */
void curl_bridge_set_low_speed_abort(CurlHandle h, long bytes_per_sec, long secs) {
    curl_easy_setopt(h, CURLOPT_LOW_SPEED_LIMIT, bytes_per_sec);
    curl_easy_setopt(h, CURLOPT_LOW_SPEED_TIME, secs);
}

void curl_bridge_set_write_fn(CurlHandle h, CurlBridgeWriteFn fn, void *userdata) {
    curl_easy_setopt(h, CURLOPT_WRITEFUNCTION, fn);
    curl_easy_setopt(h, CURLOPT_WRITEDATA, userdata);
}

void curl_bridge_set_progress_fn(CurlHandle h, CurlBridgeProgressFn fn, void *clientp) {
    curl_easy_setopt(h, CURLOPT_NOPROGRESS, 0L);
    curl_easy_setopt(h, CURLOPT_XFERINFOFUNCTION, fn);
    curl_easy_setopt(h, CURLOPT_XFERINFODATA, clientp);
}

/* POSTFIELDSIZE must be set before COPYPOSTFIELDS so curl copies exactly len
   bytes (the body is not NUL-terminated). COPYPOSTFIELDS also switches the
   method to POST and takes its own copy, so the caller's buffer can be freed
   immediately after this call. */
void curl_bridge_set_post_body(CurlHandle h, const void *body, long len) {
    curl_easy_setopt(h, CURLOPT_POSTFIELDSIZE, len);
    curl_easy_setopt(h, CURLOPT_COPYPOSTFIELDS, body);
}

/* Same COPYPOSTFIELDS trick as post_body, but forces the PUT verb via
   CUSTOMREQUEST. Used for Matrix event sends (PUT /rooms/{id}/send/...) and
   state updates (PUT /rooms/{id}/state/...). */
void curl_bridge_set_put_body(CurlHandle h, const void *body, long len) {
    curl_easy_setopt(h, CURLOPT_CUSTOMREQUEST, "PUT");
    curl_easy_setopt(h, CURLOPT_POSTFIELDSIZE, len);
    curl_easy_setopt(h, CURLOPT_COPYPOSTFIELDS, body);
}

/* Feeds the request body to libcurl a chunk at a time. Reading stays on the C
   side so no Swift buffer copy sits in the middle of the transfer. */
static size_t curl_bridge_upload_read(char *buffer, size_t size, size_t nitems, void *userdata) {
    return fread(buffer, size, nitems, (FILE *)userdata);
}

void *curl_bridge_upload_open(const char *path) {
    return fopen(path, "rb");
}

void curl_bridge_upload_close(void *file) {
    if (file) {
        fclose((FILE *)file);
    }
}

/* POSTFIELDSIZE_LARGE gives a real Content-Length, so the body is sent as a plain
   sized POST rather than chunked — Synapse's upload endpoint expects the former.
   Note this deliberately pairs with NO redirect following: replaying a redirected
   POST would mean rewinding the file, which needs a seek callback we don't set. */
void curl_bridge_set_post_stream(CurlHandle h, void *file, long long len) {
    curl_easy_setopt(h, CURLOPT_POST, 1L);
    curl_easy_setopt(h, CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)len);
    curl_easy_setopt(h, CURLOPT_READFUNCTION, curl_bridge_upload_read);
    curl_easy_setopt(h, CURLOPT_READDATA, file);
}

void *curl_bridge_headers_append(void *list, const char *header) {
    return curl_slist_append((struct curl_slist *)list, header);
}

void curl_bridge_set_headers(CurlHandle h, void *list) {
    curl_easy_setopt(h, CURLOPT_HTTPHEADER, (struct curl_slist *)list);
}

void curl_bridge_headers_free(void *list) {
    curl_slist_free_all((struct curl_slist *)list);
}

int curl_bridge_perform(CurlHandle h) {
    return (int)curl_easy_perform(h);
}

long curl_bridge_response_code(CurlHandle h) {
    long code = 0;
    curl_easy_getinfo(h, CURLINFO_RESPONSE_CODE, &code);
    return code;
}

const char *curl_bridge_strerror(int code) {
    return curl_easy_strerror((CURLcode)code);
}
