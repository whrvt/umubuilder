#include "logging.h"

#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

/* Terminal colors for different log levels */
static const char *level_colors[] = {
    [LOG_DEBUG] = "\033[1;36m",   /* Bold Cyan */
    [LOG_INFO] = "\033[1;32m",    /* Bold Green */
    [LOG_WARNING] = "\033[1;33m", /* Bold Yellow */
    [LOG_ERROR] = "\033[1;31m"    /* Bold Red */
};

/* Symbols for different log levels */
static const char *level_symbols[] = {[LOG_DEBUG] = "[*]",
                                      [LOG_INFO] = "[+]",
                                      [LOG_WARNING] = "[!]",
                                      [LOG_ERROR] = "[-]"};

/* Current logging configuration */
static struct {
  log_level_t min_level;
  int use_colors;
  int initialized;
  int debug_enabled; /* Runtime debug control */
} log_config = {.min_level = LOG_INFO,
                .use_colors = 1,
                .initialized = 0,
                .debug_enabled = 0};

/* Logging configuration setters/getters */
void log_set_level(log_level_t level) {
  log_config.min_level = level;
  log_config.initialized = 1;
}

void log_set_colors(int use_colors) {
  log_config.use_colors = use_colors && isatty(STDERR_FILENO);
}

log_level_t log_get_level(void) { return log_config.min_level; }

int log_get_colors(void) { return log_config.use_colors; }

/* Initialize logging system */
void log_init(log_level_t min_level, int use_colors) {
  const char *debug_env = secure_getenv("PYB_DEBUG");
  log_config.debug_enabled = (debug_env && *debug_env == '1');

  /* If debug is not enabled, force minimum level to INFO */
  if (!log_config.debug_enabled && min_level == LOG_DEBUG) {
    min_level = LOG_INFO;
  }

  log_set_level(min_level);
  log_set_colors(use_colors);
}

/* Internal function to write log message */
static void write_log(log_level_t level, const char *fmt, va_list args) {
  /* Skip if message level is below minimum level */
  if (level < log_config.min_level) {
    return;
  }

  /* Skip debug messages if debug not enabled at runtime */
  if (level == LOG_DEBUG && !log_config.debug_enabled) {
    return;
  }

  if (!log_config.initialized) {
    log_init(LOG_INFO, 1);
  }

  /* Buffer for timestamp */
  char timestamp[32];
  time_t now = time(NULL);
  struct tm *tm_info = localtime(&now);
  strftime(timestamp, sizeof(timestamp), "%Y-%m-%d %H:%M:%S", tm_info);

  /* Write log entry */
  if (log_config.use_colors) {
    fprintf(stderr, "%s%s ", level_colors[level], level_symbols[level]);
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wformat-nonliteral"
    vfprintf(stderr, fmt, args);
#pragma GCC diagnostic pop
    fprintf(stderr, "\033[0m\n");
  } else {
    fprintf(stderr, "%s %s ", level_symbols[level], timestamp);
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wformat-nonliteral"
    vfprintf(stderr, fmt, args);
#pragma GCC diagnostic pop
    fprintf(stderr, "\n");
  }
}

/* Public logging functions */
#ifndef NDEBUG
void _log_debug(const char *fmt, ...) {
  /* Skip if debug not enabled at runtime */
  if (!log_config.debug_enabled) {
    return;
  }

  va_list args;
  va_start(args, fmt);
  write_log(LOG_DEBUG, fmt, args);
  va_end(args);
}
#endif

void log_error(const char *fmt, ...) {
  va_list args;
  va_start(args, fmt);
  write_log(LOG_ERROR, fmt, args);
  va_end(args);
}

void log_warning(const char *fmt, ...) {
  va_list args;
  va_start(args, fmt);
  write_log(LOG_WARNING, fmt, args);
  va_end(args);
}

void log_info(const char *fmt, ...) {
  va_list args;
  va_start(args, fmt);
  write_log(LOG_INFO, fmt, args);
  va_end(args);
}

/* Error handler with cleanup callback */
wrp_status_t handle_error(wrp_status_t status, cleanup_fn cleanup,
                          void *cleanup_ctx, const char *fmt, ...) {
  if (status != WRP_OK) {
    va_list args;
    va_start(args, fmt);
    char msg[256];
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wformat-nonliteral"
    vsnprintf(msg, sizeof(msg), fmt, args);
#pragma GCC diagnostic pop
    va_end(args);

    if (status == WRP_EERRNO) {
      log_error("%s: %s", msg, strerror(errno));
    } else {
      log_error("%s (code: %d)", msg, status);
    }

    if (cleanup) {
      cleanup(cleanup_ctx);
    }
  }
  return status;
}
