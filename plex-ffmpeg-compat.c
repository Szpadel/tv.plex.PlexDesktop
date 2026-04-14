#include <pthread.h>
#include <stdlib.h>
#include <string.h>

static pthread_mutex_t plex_extlibs_lock = PTHREAD_MUTEX_INITIALIZER;
static char *plex_extlibs_path;
static int plex_needs_rescan;
static const void *plex_decryption_callbacks;

/*
 * Plex's bundled FFmpeg exposes this private setter so libPlexMediaServer can
 * record the external codec directory. Stock FFmpeg does not consume it, so
 * the experiment only needs a stable no-op-compatible implementation.
 */
void av_set_extlibs_path(const char *path) {
  pthread_mutex_lock(&plex_extlibs_lock);
  free(plex_extlibs_path);
  plex_extlibs_path = path ? strdup(path) : NULL;
  pthread_mutex_unlock(&plex_extlibs_lock);
}

/*
 * Plex toggles a private "rescan external codec libs" flag in its FFmpeg fork.
 * Stock FFmpeg has no external codec scan path, so retaining the flag locally
 * is enough to satisfy callers without changing behavior.
 */
void av_set_needs_rescan(int needs_rescan) {
  pthread_mutex_lock(&plex_extlibs_lock);
  plex_needs_rescan = needs_rescan;
  pthread_mutex_unlock(&plex_extlibs_lock);
}

/*
 * Plex's libavformat fork lets the app register decryption callbacks for its
 * private media pipeline. Stock FFmpeg lacks this hook, so we retain the
 * pointer only to satisfy the ABI and keep the experiment moving.
 */
void avformat_set_decryption_callbacks(const void *callbacks) {
  pthread_mutex_lock(&plex_extlibs_lock);
  plex_decryption_callbacks = callbacks;
  pthread_mutex_unlock(&plex_extlibs_lock);
}
