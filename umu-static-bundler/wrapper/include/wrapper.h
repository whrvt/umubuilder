#ifndef RUN_WRAPPER_H
#define RUN_WRAPPER_H

#define _GNU_SOURCE

/* System includes - alphabetically ordered */
#include <archive.h>
#include <archive_entry.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

/* Status codes for wrapper operations */
typedef enum {
  WRP_OK = 0,        /* Operation completed successfully */
  WRP_EINVAL = -1,   /* Invalid parameter or configuration */
  WRP_ENOENT = -2,   /* Required file or directory not found */
  WRP_EVERSION = -3, /* Version mismatch or invalid version */
  WRP_EPYTHON = -4,  /* Python installation error */
  WRP_EEXTRACT = -5, /* Archive extraction error */
  WRP_EPERM = -6,    /* Permission or access error */
  WRP_EENV = -7,     /* Environment setup error */
  WRP_EMOVE = -8,    /* Directory operation error */
  WRP_EERRNO = -9,   /* System call error, check errno */
  WRP_ELOCK = -10,   /* Failed to acquire lock */

  PATH_OK = WRP_OK,          /* Operation completed successfully */
  PATH_TOOLONG = WRP_EMOVE,  /* Path exceeds maximum length */
  PATH_INVALID = WRP_EINVAL, /* Invalid path or parameters */
  PATH_NOTFOUND = WRP_ENOENT /* Path does not exist */
} wrp_status_t;

/* Installation component flags */
typedef enum {
  INSTALL_NONE = 0,
  INSTALL_PYTHON = 1 << 0,
  INSTALL_APP = 1 << 1,
  INSTALL_ALL = INSTALL_PYTHON | INSTALL_APP
} install_flags_t;

/* Buffer size for general operations */
#define BUFFER_SIZE 4096

/* Size of the archive size footer in digits */
#define ARCHIVE_SIZE_DIGITS 20

/* Lock file timeout in seconds */
#define LOCK_TIMEOUT 5

/* Base directory for all installations */
#define PYBSTRAP_SUBDIR "pybstrap"

/* Archive section identifiers */
#define SECTION_PYTHON "./python/"
#define SECTION_APP "./apps/"

/* Installation metadata */
struct install_meta {
  const char *app_name;       /* Application identifier */
  const char *python_version; /* Required Python version */
  const char *version_file;   /* Required file for version check */
  unsigned long version_sum;  /* Expected checksum of version file */
  mode_t dir_mode;            /* Mode for created directories */
  int timeout;                /* Lock timeout in seconds */
};

/* Installation paths */
struct install_paths {
  char base_dir[PATH_MAX];   /* Base installation directory */
  char python_dir[PATH_MAX]; /* Python installation directory */
  char app_dir[PATH_MAX];    /* Application installation directory */
  char temp_dir[PATH_MAX];   /* Temporary extraction directory */
  char lock_file[PATH_MAX];  /* Lock file path */
};

/* Configuration structure for the wrapper */
struct wrapper_config {
  struct install_meta meta;   /* Installation metadata */
  struct install_paths paths; /* Installation paths */
  install_flags_t flags;      /* Component installation flags */
};

/* Core functions */
wrp_status_t init_wrapper_config(struct wrapper_config *config,
                                 const char *app_name,
                                 const char *python_version,
                                 const char *version_file,
                                 unsigned long version_sum);

wrp_status_t exec_python_script(const char *python_path,
                                const char *script_path, int argc,
                                char *argv[]);

int run_wrapped_application(const struct wrapper_config *config, int argc,
                            char *argv[]);

/* Archive extraction function */
wrp_status_t extract_bundled_archive(const char *self_path,
                                     const char *target_dir,
                                     install_flags_t flags);

/* Component validation functions */
wrp_status_t ensure_components(const struct wrapper_config *config);
wrp_status_t verify_python_install(const char *python_dir,
                                   const char *python_version,
                                   int *needs_repair);

wrp_status_t verify_app_install(const char *app_dir,
                                const struct install_meta *meta,
                                int *needs_repair);

/* Environment setup function */
wrp_status_t setup_python_environment(const char *app_dir,
                                      const char *python_dir);

/* Helper for safe path construction */
static inline wrp_status_t check_path_length(int printed, size_t bufsize) {
  if (printed < 0) {
    return WRP_EERRNO; /* snprintf error */
  }
  if ((size_t)printed >= bufsize) {
    return WRP_EINVAL; /* buffer too small */
  }
  return WRP_OK;
}

#endif /* RUN_WRAPPER_H */
