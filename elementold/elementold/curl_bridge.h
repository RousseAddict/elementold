#ifndef curl_bridge_h
#define curl_bridge_h

#include <stddef.h>

typedef void *CurlHandle;

/* Write callback: return number of bytes processed (must equal size*nmemb or curl aborts) */
typedef size_t (*CurlBridgeWriteFn)(const void *ptr, size_t size, size_t nmemb, void *userdata);

/* Progress callback (xferinfo style, curl_off_t = long long).
   Return 0 to continue, non-zero to abort. */
typedef int (*CurlBridgeProgressFn)(void *clientp,
                                    long long dltotal, long long dlnow,
                                    long long ultotal, long long ulnow);

void        curl_bridge_global_init(void);
CurlHandle  curl_bridge_init(void);
void        curl_bridge_cleanup(CurlHandle h);
void        curl_bridge_set_url(CurlHandle h, const char *url);
void        curl_bridge_set_ssl_verify(CurlHandle h);
void        curl_bridge_set_ca_bundle(CurlHandle h, const char *path);
void        curl_bridge_set_follow_redirects(CurlHandle h);
void        curl_bridge_set_timeout(CurlHandle h, long secs);

/* Abort a transfer that has stalled below bytes_per_sec for secs consecutive
   seconds. For the streamed upload/download paths, which have no total timeout
   because they may legitimately run for minutes. */
void        curl_bridge_set_low_speed_abort(CurlHandle h, long bytes_per_sec, long secs);
void        curl_bridge_set_write_fn(CurlHandle h, CurlBridgeWriteFn fn, void *userdata);
void        curl_bridge_set_progress_fn(CurlHandle h, CurlBridgeProgressFn fn, void *clientp);

/* POST + custom headers (used by the login path) */
void        curl_bridge_set_post_body(CurlHandle h, const void *body, long len);
void        curl_bridge_set_put_body(CurlHandle h, const void *body, long len);

/* Streaming POST straight off disk: libcurl pulls the body in chunks instead of
   taking a full in-memory copy the way set_post_body does, so upload size stops
   being bounded by RAM. The caller opens the file, hands the handle to
   set_post_stream, and closes it after curl_bridge_perform returns. */
void       *curl_bridge_upload_open(const char *path);
void        curl_bridge_upload_close(void *file);
void        curl_bridge_set_post_stream(CurlHandle h, void *file, long long len);
void       *curl_bridge_headers_append(void *list, const char *header);
void        curl_bridge_set_headers(CurlHandle h, void *list);
void        curl_bridge_headers_free(void *list);

int         curl_bridge_perform(CurlHandle h);
long        curl_bridge_response_code(CurlHandle h);
const char *curl_bridge_strerror(int code);

#endif /* curl_bridge_h */
