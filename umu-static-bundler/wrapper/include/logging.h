#ifndef WRAPPER_LOGGING_H
#define WRAPPER_LOGGING_H

#include "wrapper.h"

/* Log levels in ascending order of severity */
typedef enum {
  LOG_DEBUG = 0,   /* Detailed debug information */
  LOG_INFO = 1,    /* General operational messages */
  LOG_WARNING = 2, /* Warning conditions */
  LOG_ERROR = 3    /* Error conditions */
} log_level_t;

/* Cleanup callback type */
typedef void (*cleanup_fn)(void *ctx);

/* Logging configuration and control */
void log_init(log_level_t min_level, int use_colors);
void log_set_level(log_level_t level);
void log_set_colors(int use_colors);
log_level_t log_get_level(void);
int log_get_colors(void);

/* Debug logging enabled if either:
 * - DEBUG defined at compile-time AND
 * - PYB_DEBUG=1 environment variable set at runtime
 */
#ifndef NDEBUG
#define log_debug(...) _log_debug(__VA_ARGS__)
void _log_debug(const char *fmt, ...);
#else
#define log_debug(...) ((void)0)
#endif

/* These logging functions are always available */
void log_error(const char *fmt, ...);
void log_warning(const char *fmt, ...);
void log_info(const char *fmt, ...);

/* Error handling with cleanup */
wrp_status_t handle_error(wrp_status_t status, cleanup_fn cleanup,
                          void *cleanup_ctx, const char *fmt, ...);

#endif /* WRAPPER_LOGGING_H */
