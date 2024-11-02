#include "pathutils.h"
#include "logging.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static void cleanup_dir(void *ctx) {
  struct dir_cleanup *dc = (struct dir_cleanup *)ctx;
  if (!dc)
    return;

  if (dc->dir) {
    closedir(dc->dir);
  }
  free(dc->path);
}

/* Internal helper to check path buffer capacity */
static inline wrp_status_t check_path_capacity(int printed, size_t bufsize) {
  if (printed < 0 || (size_t)printed >= bufsize) {
    return PATH_TOOLONG;
  }
  return PATH_OK;
}

/* Recursively remove a directory and its contents */
wrp_status_t remove_directory_recursive(const char *path) {
  struct dir_cleanup dc = {0};
  struct dirent *entry;
  char filepath[PATH_MAX];
  struct stat statbuf;

  if (!path) {
    return handle_error(WRP_EINVAL, NULL, NULL, "Invalid path parameter");
  }

  dc.dir = opendir(path);
  if (!dc.dir) {
    return (errno == ENOENT)
               ? WRP_OK
               : handle_error(WRP_EERRNO, NULL, NULL,
                              "Failed to open directory: %s", path);
  }

  while ((entry = readdir(dc.dir))) {
    if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) {
      continue;
    }

    if (path_join(filepath, sizeof(filepath), path, entry->d_name, NULL) !=
        WRP_OK) {
      return handle_error(WRP_EINVAL, cleanup_dir, &dc, "Path too long: %s/%s",
                          path, entry->d_name);
    }

    if (lstat(filepath, &statbuf) != 0) {
      return handle_error(WRP_EERRNO, cleanup_dir, &dc,
                          "Failed to stat file: %s", filepath);
    }

    if (S_ISDIR(statbuf.st_mode)) {
      wrp_status_t status = remove_directory_recursive(filepath);
      if (status != WRP_OK) {
        return handle_error(status, cleanup_dir, &dc,
                            "Failed to remove subdirectory: %s", filepath);
      }
    } else if (unlink(filepath) != 0) {
      return handle_error(WRP_EERRNO, cleanup_dir, &dc,
                          "Failed to remove file: %s", filepath);
    }
  }

  cleanup_dir(&dc);

  if (rmdir(path) != 0 && errno != ENOENT) {
    return handle_error(WRP_EERRNO, NULL, NULL,
                        "Failed to remove directory: %s", path);
  }

  return WRP_OK;
}

/* Create directory and its parents with specified mode */
wrp_status_t create_directory_with_parents(const char *path, mode_t mode) {
  wrp_status_t status;
  int exists;

  if (!path) {
    return handle_error(WRP_EINVAL, NULL, NULL, "Invalid path parameter");
  }

  /* Check if directory already exists */
  status = path_directory_exists(path, &exists);
  if (status != WRP_OK) {
    return status;
  }
  if (exists) {
    return WRP_OK;
  }

  /* Create parent directories */
  char parent[PATH_MAX];
  status = path_get_dirname(parent, sizeof(parent), path);
  if (status != WRP_OK) {
    return handle_error(status, NULL, NULL,
                        "Failed to get parent directory for: %s", path);
  }

  if (strlen(parent) > 0 && strcmp(parent, ".") != 0) {
    status = create_directory_with_parents(parent, mode);
    if (status != WRP_OK) {
      return status;
    }
  }

  /* Create directory */
  if (mkdir(path, mode) != 0 && errno != EEXIST) {
    return handle_error(WRP_EERRNO, NULL, NULL,
                        "Failed to create directory: %s", path);
  }

  return WRP_OK;
}

/* Atomically replace a directory with a new one, keeping a backup */
wrp_status_t atomic_replace_directory(const char *old_dir, const char *new_dir,
                                      const char *backup_dir) {
  wrp_status_t status;
  int exists;

  if (!old_dir || !new_dir) {
    return handle_error(WRP_EINVAL, NULL, NULL, "Invalid directory parameters");
  }

  log_debug("Attempting atomic directory replace:");
  log_debug("  Target: %s", old_dir);
  log_debug("  Source: %s", new_dir);
  if (backup_dir) {
    log_debug("  Backup: %s", backup_dir);
  }

  /* Create parent directory for target if needed */
  char parent_dir[PATH_MAX];
  status = path_get_dirname(parent_dir, sizeof(parent_dir), old_dir);
  if (status != WRP_OK) {
    return handle_error(status, NULL, NULL,
                        "Failed to get parent directory for target: %s",
                        old_dir);
  }

  log_debug("Creating parent directory: %s", parent_dir);
  status = create_directory_with_parents(parent_dir, 0700);
  if (status != WRP_OK) {
    return handle_error(status, NULL, NULL,
                        "Failed to create parent directory: %s", parent_dir);
  }

  /* Verify source directory exists */
  status = path_directory_exists(new_dir, &exists);
  if (status != WRP_OK || !exists) {
    return handle_error(WRP_ENOENT, NULL, NULL,
                        "Source directory does not exist: %s", new_dir);
  }

  /* If target exists but no backup requested, clean it first */
  status = path_exists(old_dir, &exists);
  if (status != WRP_OK) {
    return handle_error(status, NULL, NULL,
                        "Failed to check target directory existence: %s",
                        old_dir);
  }

  if (!backup_dir && exists) {
    log_debug("Removing existing target directory: %s", old_dir);
    status = remove_directory_recursive(old_dir);
    if (status != WRP_OK) {
      return handle_error(status, NULL, NULL,
                          "Failed to remove existing target: %s", old_dir);
    }
  }

  /* Handle backup if requested */
  if (backup_dir) {
    status = path_exists(backup_dir, &exists);
    if (status != WRP_OK) {
      return handle_error(status, NULL, NULL,
                          "Failed to check backup directory existence: %s",
                          backup_dir);
    }

    if (exists) {
      char *real_backup = realpath(backup_dir, NULL);
      if (real_backup) {
        if (strcmp(real_backup, old_dir) != 0) {
          log_debug("Removing existing backup directory: %s", backup_dir);
          status = remove_directory_recursive(backup_dir);
          if (status != WRP_OK) {
            free(real_backup);
            return handle_error(status, NULL, NULL,
                                "Failed to remove existing backup: %s",
                                backup_dir);
          }
        }
        free(real_backup);
      }
    }

    /* Move current to backup if it exists */
    status = path_exists(old_dir, &exists);
    if (status != WRP_OK) {
      return handle_error(status, NULL, NULL,
                          "Failed to check target existence: %s", old_dir);
    }

    if (exists) {
      /* Create parent directory for backup if needed */
      status = path_get_dirname(parent_dir, sizeof(parent_dir), backup_dir);
      if (status != WRP_OK) {
        return handle_error(status, NULL, NULL,
                            "Failed to get backup parent directory: %s",
                            backup_dir);
      }

      status = create_directory_with_parents(parent_dir, 0700);
      if (status != WRP_OK) {
        return handle_error(status, NULL, NULL,
                            "Failed to create backup parent directory: %s",
                            parent_dir);
      }

      log_debug("Moving current to backup: %s -> %s", old_dir, backup_dir);
      if (rename(old_dir, backup_dir) != 0) {
        return handle_error(WRP_EERRNO, NULL, NULL,
                            "Failed to backup current installation: %s -> %s",
                            old_dir, backup_dir);
      }
    }
  }

  /* Move new to current */
  log_debug("Moving new to target: %s -> %s", new_dir, old_dir);
  if (rename(new_dir, old_dir) != 0) {
    status = handle_error(WRP_EERRNO, NULL, NULL,
                          "Failed to move new installation: %s -> %s", new_dir,
                          old_dir);
    /* Try to restore backup */
    if (backup_dir) {
      status = path_exists(backup_dir, &exists);
      if (status == WRP_OK && exists) {
        log_debug("Restore attempt: %s -> %s", backup_dir, old_dir);
        rename(backup_dir, old_dir);
      }
    }
    return status;
  }

  log_debug("Directory replacement completed successfully");
  return WRP_OK;
}

wrp_status_t path_strip_archive_prefix(char *dest, size_t size,
                                       const char *path, const char *prefix) {
  const char *path_start, *prefix_start;
  size_t prefix_len;

  if (!dest || !path || !prefix || size == 0) {
    return PATH_INVALID;
  }

  /* Skip leading ./ from both paths */
  path_start = path;
  prefix_start = prefix;
  if (strncmp(path_start, "./", 2) == 0) {
    path_start += 2;
  }
  if (strncmp(prefix_start, "./", 2) == 0) {
    prefix_start += 2;
  }

  /* Verify path starts with prefix */
  prefix_len = strlen(prefix_start);
  if (strncmp(path_start, prefix_start, prefix_len) != 0) {
    log_debug("Path prefix mismatch: expected '%s', got '%s'", prefix_start,
              path_start);
    return PATH_INVALID;
  }

  /* Keep the normalized path including the section directory */
  if (strlen(path_start) >= size) {
    return PATH_TOOLONG;
  }

  strcpy(dest, path_start);
  return PATH_OK;
}

wrp_status_t path_directory_exists(const char *path, int *exists) {
  struct stat st;

  if (!path || !exists) {
    return PATH_INVALID;
  }

  *exists = (stat(path, &st) == 0 && S_ISDIR(st.st_mode));
  return PATH_OK;
}

wrp_status_t path_create_temp_dir(char *path, size_t size, const char *base_dir,
                                  const char *prefix) {
  char template[PATH_MAX];
  int printed;

  if (!path || !base_dir || size == 0) {
    return PATH_INVALID;
  }

  /* Create template string */
  if (!prefix) {
    prefix = "tmp";
  }

  printed =
      snprintf(template, sizeof(template), "%s/%s-XXXXXX", base_dir, prefix);
  if (check_path_capacity(printed, sizeof(template)) != PATH_OK) {
    return PATH_TOOLONG;
  }

  /* Ensure parent directory exists */
  wrp_status_t status = path_ensure_parent_directory(template, 0700);
  if (status != PATH_OK) {
    return status;
  }

  /* Create temporary directory */
  if (!mkdtemp(template)) {
    log_error("Failed to create temporary directory: %s", strerror(errno));
    return WRP_EERRNO;
  }

  if (strlen(template) >= size) {
    rmdir(template); /* Clean up on error */
    return PATH_TOOLONG;
  }

  strcpy(path, template);
  return PATH_OK;
}

wrp_status_t path_cleanup_temp_dir(const char *path) {
  DIR *dir;
  struct dirent *entry;
  char full_path[PATH_MAX];
  struct stat st;

  if (!path) {
    return PATH_INVALID;
  }

  dir = opendir(path);
  if (!dir) {
    if (errno == ENOENT) {
      return PATH_OK;
    }
    return WRP_EERRNO;
  }

  while ((entry = readdir(dir))) {
    if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) {
      continue;
    }

    if (snprintf(full_path, sizeof(full_path), "%s/%s", path, entry->d_name) >=
        (int)sizeof(full_path)) {
      closedir(dir);
      return PATH_TOOLONG;
    }

    if (lstat(full_path, &st) != 0) {
      continue;
    }

    if (S_ISDIR(st.st_mode)) {
      path_cleanup_temp_dir(full_path);
      rmdir(full_path);
    } else {
      unlink(full_path);
    }
  }

  closedir(dir);
  rmdir(path);

  return PATH_OK;
}

/* Internal helper to check if path component is safe */
static int is_component_safe(const char *comp) {
  if (!comp || !*comp)
    return 0;
  if (strcmp(comp, ".") == 0 || strcmp(comp, "..") == 0)
    return 0;
  if (strchr(comp, '/'))
    return 0;
  return 1;
}

wrp_status_t path_join(char *dest, size_t size, const char *first, ...) {
  if (!dest || !first || size == 0) {
    return WRP_EINVAL;
  }

  va_list args;
  const char *part;
  size_t used = 0;
  int needs_sep = 0;

  /* Copy first component */
  size_t len = strlen(first);
  if (len >= size) {
    return PATH_TOOLONG;
  }

  strcpy(dest, first);
  used = len;
  needs_sep = (used > 0 && dest[used - 1] != '/');

  va_start(args, first);
  while ((part = va_arg(args, const char *))) {
    /* Skip empty components */
    if (!*part)
      continue;

    /* Skip leading slashes */
    while (*part == '/')
      part++;
    if (!*part)
      continue;

    /* Check if we need to add a separator */
    if (needs_sep) {
      if (used + 1 >= size) {
        va_end(args);
        return PATH_TOOLONG;
      }
      dest[used++] = '/';
      dest[used] = '\0';
    }

    len = strlen(part);
    if (used + len >= size) {
      va_end(args);
      return PATH_TOOLONG;
    }

    strcpy(dest + used, part);
    used += len;
    needs_sep = (part[len - 1] != '/');
  }
  va_end(args);

  return PATH_OK;
}

wrp_status_t path_is_safe(const char *path) {
  char *component;
  char *saveptr;
  char *pathdup;

  if (!path || !*path) {
    return PATH_INVALID;
  }

  /* Work on a copy since strtok_r modifies the string */
  pathdup = strdup(path);
  if (!pathdup) {
    return WRP_EERRNO;
  }

  /* Check each path component */
  component = strtok_r(pathdup, "/", &saveptr);
  while (component) {
    if (!is_component_safe(component)) {
      free(pathdup);
      return PATH_INVALID;
    }
    component = strtok_r(NULL, "/", &saveptr);
  }

  free(pathdup);
  return PATH_OK;
}

wrp_status_t path_normalize(char *path, size_t size) {
  char temp[PATH_MAX];
  char *out = temp;
  char *in = path;
  size_t outlen = 0;
  int had_slash = 0;

  if (!path || !*path) {
    return PATH_INVALID;
  }

  /* Preserve initial slash if present */
  if (*in == '/') {
    *out++ = *in++;
    outlen++;
    had_slash = 1;
  }

  while (*in) {
    if (*in == '/') {
      if (!had_slash) {
        if (outlen + 1 >= size)
          return PATH_TOOLONG;
        *out++ = '/';
        outlen++;
        had_slash = 1;
      }
      in++;
      continue;
    }

    had_slash = 0;
    if (outlen + 1 >= size)
      return PATH_TOOLONG;
    *out++ = *in++;
    outlen++;
  }

  /* Remove trailing slash unless it's root */
  if (outlen > 1 && out[-1] == '/') {
    out--;
    outlen--;
  }

  *out = '\0';
  strcpy(path, temp);
  return PATH_OK;
}

wrp_status_t path_exists(const char *path, int *exists) {
  if (!path || !exists) {
    return WRP_EINVAL;
  }
  *exists = (access(path, F_OK) == 0);
  return PATH_OK;
}

wrp_status_t path_is_readable(const char *path, int *is_readable) {
  if (!path || !is_readable) {
    return WRP_EINVAL;
  }
  *is_readable = (access(path, R_OK) == 0);
  return WRP_OK;
}

wrp_status_t path_is_directory(const char *path, int *is_dir) {
  struct stat st;
  if (!path || !is_dir) {
    return WRP_EINVAL;
  }
  if (stat(path, &st) != 0) {
    *is_dir = 0;
    return (errno == ENOENT) ? PATH_OK : WRP_EERRNO;
  }
  *is_dir = S_ISDIR(st.st_mode);
  return PATH_OK;
}

wrp_status_t path_is_executable(const char *path, int *is_exec) {
  struct stat st;
  if (!path || !is_exec) {
    return WRP_EINVAL;
  }
  if (stat(path, &st) != 0) {
    *is_exec = 0;
    return (errno == ENOENT) ? PATH_OK : WRP_EERRNO;
  }
  *is_exec = (st.st_mode & S_IXUSR) != 0;
  return PATH_OK;
}

wrp_status_t path_get_dirname(char *dest, size_t size, const char *path) {
  const char *last_slash;
  size_t len;

  if (!dest || !path || size == 0) {
    return WRP_EINVAL;
  }

  /* Handle special cases */
  if (!*path) {
    if (size < 2)
      return PATH_TOOLONG;
    strcpy(dest, ".");
    return PATH_OK;
  }

  last_slash = strrchr(path, '/');
  if (!last_slash) {
    if (size < 2)
      return PATH_TOOLONG;
    strcpy(dest, ".");
    return PATH_OK;
  }

  /* Handle root directory */
  if (last_slash == path) {
    if (size < 2)
      return PATH_TOOLONG;
    strcpy(dest, "/");
    return PATH_OK;
  }

  len = last_slash - path;
  if (len >= size) {
    return PATH_TOOLONG;
  }

  memcpy(dest, path, len);
  dest[len] = '\0';

  return PATH_OK;
}

/* Installation path helpers */
wrp_status_t path_get_python_dir(char *dest, size_t size, const char *base_dir,
                                 const char *python_version) {
  return path_join(dest, size, base_dir, "python", python_version, NULL);
}

wrp_status_t path_get_app_dir(char *dest, size_t size, const char *base_dir,
                              const char *app_name) {
  return path_join(dest, size, base_dir, "apps", app_name, NULL);
}

wrp_status_t path_get_lock_file(char *dest, size_t size, const char *base_dir) {
  return path_join(dest, size, base_dir, ".install.lock", NULL);
}

wrp_status_t path_get_temp_dir(char *dest, size_t size, const char *base_dir) {
  return path_join(dest, size, base_dir, ".tmp", NULL);
}

/* Python installation path helpers */
wrp_status_t path_get_python_binary(char *dest, size_t size,
                                    const char *python_dir) {
  return path_join(dest, size, python_dir, "bin", "python", NULL);
}

wrp_status_t path_get_app_binary(char *dest, size_t size, const char *app_dir,
                                 const char *app_name) {
  return path_join(dest, size, app_dir, "bin", app_name, NULL);
}

wrp_status_t path_validate_components(const char *base_dir,
                                      const char *python_ver, char *python_dir,
                                      size_t python_dir_size, char *app_dir,
                                      size_t app_dir_size,
                                      const char *app_name) {
  wrp_status_t status;
  int exists;

  /* Validate input parameters */
  if (!base_dir || !python_ver || !python_dir || !app_dir || !app_name) {
    return WRP_EINVAL;
  }

  /* Validate base directory path */
  status = path_is_safe(base_dir);
  if (status != PATH_OK) {
    log_error("Invalid base directory path: %s", base_dir);
    return status;
  }

  /* Construct and validate Python directory path */
  status =
      path_get_python_dir(python_dir, python_dir_size, base_dir, python_ver);
  if (status != PATH_OK) {
    log_error("Failed to construct Python directory path");
    return status;
  }

  /* Construct and validate application directory path */
  status = path_get_app_dir(app_dir, app_dir_size, base_dir, app_name);
  if (status != PATH_OK) {
    log_error("Failed to construct application directory path");
    return status;
  }

  /* Additional safety checks */
  status = path_exists(base_dir, &exists);
  if (status != PATH_OK)
    return status;
  if (!exists) {
    log_debug("Base directory does not exist: %s", base_dir);
  }

  return PATH_OK;
}

wrp_status_t path_is_absolute(const char *path, int *is_absolute) {
  if (!path || !is_absolute) {
    return WRP_EINVAL;
  }
  *is_absolute = (path[0] == '/');
  return PATH_OK;
}

wrp_status_t path_is_relative(const char *path, int *is_relative) {
  int is_abs;
  wrp_status_t status = path_is_absolute(path, &is_abs);
  if (status == PATH_OK && is_relative) {
    *is_relative = !is_abs;
  }
  return status;
}

wrp_status_t path_has_extension(const char *path, const char *ext,
                                int *has_ext) {
  if (!path || !ext || !has_ext) {
    return WRP_EINVAL;
  }

  const char *dot = strrchr(path, '.');
  if (!dot || dot == path) {
    *has_ext = 0;
    return PATH_OK;
  }

  *has_ext = (strcmp(dot + 1, ext) == 0);
  return PATH_OK;
}

wrp_status_t path_get_extension(char *dest, size_t size, const char *path) {
  if (!dest || !path || size == 0) {
    return WRP_EINVAL;
  }

  const char *dot = strrchr(path, '.');
  if (!dot || dot == path) {
    dest[0] = '\0';
    return PATH_OK;
  }

  if (strlen(dot + 1) >= size) {
    return PATH_TOOLONG;
  }

  strcpy(dest, dot + 1);
  return PATH_OK;
}

wrp_status_t path_strip_extension(char *dest, size_t size, const char *path) {
  if (!dest || !path || size == 0) {
    return WRP_EINVAL;
  }

  const char *dot = strrchr(path, '.');
  if (!dot || dot == path) {
    if (strlen(path) >= size) {
      return PATH_TOOLONG;
    }
    strcpy(dest, path);
    return PATH_OK;
  }

  size_t len = dot - path;
  if (len >= size) {
    return PATH_TOOLONG;
  }

  strncpy(dest, path, len);
  dest[len] = '\0';
  return PATH_OK;
}

wrp_status_t path_make_absolute(char *dest, size_t size, const char *base,
                                const char *path) {
  int is_abs;
  wrp_status_t status;

  if (!dest || !base || !path || size == 0) {
    return WRP_EINVAL;
  }

  status = path_is_absolute(path, &is_abs);
  if (status != PATH_OK) {
    return status;
  }

  if (is_abs) {
    if (strlen(path) >= size) {
      return PATH_TOOLONG;
    }
    strcpy(dest, path);
    return PATH_OK;
  }

  return path_join(dest, size, base, path, NULL);
}

wrp_status_t path_ensure_directory(const char *path, mode_t mode) {
  wrp_status_t status;
  int exists, is_dir;

  status = path_exists(path, &exists);
  if (status != PATH_OK) {
    return status;
  }

  if (exists) {
    status = path_is_directory(path, &is_dir);
    if (status != PATH_OK) {
      return status;
    }
    if (!is_dir) {
      return PATH_INVALID;
    }
    return PATH_OK;
  }

  return create_directory_with_parents(path, mode);
}

wrp_status_t path_ensure_parent_directory(const char *path, mode_t mode) {
  char parent[PATH_MAX];
  wrp_status_t status;

  status = path_get_dirname(parent, sizeof(parent), path);
  if (status != PATH_OK) {
    return status;
  }

  return path_ensure_directory(parent, mode);
}

wrp_status_t path_is_subpath(const char *parent, const char *child,
                             int *is_subpath) {
  char normalized_parent[PATH_MAX];
  char normalized_child[PATH_MAX];
  char *parent_ptr, *child_ptr;
  wrp_status_t status;

  if (!parent || !child || !is_subpath) {
    return WRP_EINVAL;
  }

  /* Work with copies we can modify */
  strncpy(normalized_parent, parent, sizeof(normalized_parent) - 1);
  normalized_parent[sizeof(normalized_parent) - 1] = '\0';

  strncpy(normalized_child, child, sizeof(normalized_child) - 1);
  normalized_child[sizeof(normalized_child) - 1] = '\0';

  /* Skip leading ./ in both paths */
  parent_ptr = normalized_parent;
  child_ptr = normalized_child;

  if (strncmp(parent_ptr, "./", 2) == 0) {
    parent_ptr += 2;
  }
  if (strncmp(child_ptr, "./", 2) == 0) {
    child_ptr += 2;
  }

  /* Handle trailing slashes consistently */
  size_t parent_len = strlen(parent_ptr);
  size_t child_len = strlen(child_ptr);

  if (parent_len > 0 && parent_ptr[parent_len - 1] == '/') {
    parent_ptr[parent_len - 1] = '\0';
    parent_len--;
  }
  if (child_len > 0 && child_ptr[child_len - 1] == '/') {
    child_ptr[child_len - 1] = '\0';
    child_len--;
  }

  /* Normalize both paths */
  status = path_normalize(parent_ptr, sizeof(normalized_parent) -
                                          (parent_ptr - normalized_parent));
  if (status != PATH_OK) {
    return status;
  }

  status = path_normalize(child_ptr, sizeof(normalized_child) -
                                         (child_ptr - normalized_child));
  if (status != PATH_OK) {
    return status;
  }

  /* Check if child starts with parent */
  parent_len = strlen(parent_ptr);
  child_len = strlen(child_ptr);

  if (parent_len == 0) {
    *is_subpath = 1; /* Empty parent means any child is valid */
    return PATH_OK;
  }

  if (child_len < parent_len) {
    *is_subpath = 0;
    return PATH_OK;
  }

  /* Do the actual path comparison */
  if (strncmp(parent_ptr, child_ptr, parent_len) == 0) {
    /* If lengths are equal, paths must match exactly */
    if (child_len == parent_len) {
      *is_subpath = 1;
    } else {
      /* Otherwise, next character must be a separator */
      *is_subpath = (child_ptr[parent_len] == '/');
    }
  } else {
    *is_subpath = 0;
  }

  log_debug("path_is_subpath check:");
  log_debug("  Parent: '%s' -> '%s'", parent, parent_ptr);
  log_debug("  Child:  '%s' -> '%s'", child, child_ptr);
  log_debug("  Result: %s", *is_subpath ? "true" : "false");

  return PATH_OK;
}

wrp_status_t path_is_symlink(const char *path, int *is_symlink) {
  struct stat st;

  if (!path || !is_symlink) {
    return WRP_EINVAL;
  }

  if (lstat(path, &st) != 0) {
    if (errno == ENOENT) {
      *is_symlink = 0;
      return PATH_OK;
    }
    return WRP_EERRNO;
  }

  *is_symlink = S_ISLNK(st.st_mode);
  return PATH_OK;
}

wrp_status_t path_readlink(char *dest, size_t size, const char *path) {
  ssize_t len;

  if (!dest || !path || size == 0) {
    return WRP_EINVAL;
  }

  len = readlink(path, dest, size - 1);
  if (len == -1) {
    return WRP_EERRNO;
  }

  if ((size_t)len >= size) {
    return PATH_TOOLONG;
  }

  dest[len] = '\0';
  return PATH_OK;
}
