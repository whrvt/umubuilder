#ifndef WRAPPER_PATHUTILS_H
#define WRAPPER_PATHUTILS_H

#include "wrapper.h"
#include <limits.h>
#include <stdarg.h>

/* Directory cleanup context */
struct dir_cleanup {
  DIR *dir;
  char *path;
};

wrp_status_t remove_directory_recursive(const char *path);
wrp_status_t create_directory_with_parents(const char *path, mode_t mode);
wrp_status_t atomic_replace_directory(const char *old_dir, const char *new_dir,
                                      const char *backup_dir);

/* Path construction and manipulation */
wrp_status_t path_join(char *dest, size_t size, const char *first, ...);
wrp_status_t path_normalize(char *path, size_t size);
wrp_status_t path_make_absolute(char *dest, size_t size, const char *base,
                                const char *path);
wrp_status_t path_strip_archive_prefix(char *dest, size_t size,
                                       const char *path, const char *prefix);

/* Path inspection and validation */
wrp_status_t path_is_safe(const char *path);
wrp_status_t path_exists(const char *path, int *exists);
wrp_status_t path_is_readable(const char *path, int *is_readable);
wrp_status_t path_is_directory(const char *path, int *is_dir);
wrp_status_t path_is_executable(const char *path, int *is_exec);
wrp_status_t path_is_absolute(const char *path, int *is_absolute);
wrp_status_t path_is_relative(const char *path, int *is_relative);
wrp_status_t path_has_extension(const char *path, const char *ext,
                                int *has_ext);
wrp_status_t path_is_subpath(const char *parent, const char *child,
                             int *is_subpath);
wrp_status_t path_is_symlink(const char *path, int *is_symlink);
wrp_status_t path_directory_exists(const char *path, int *exists);

/* Path component extraction */
wrp_status_t path_get_dirname(char *dest, size_t size, const char *path);
wrp_status_t path_get_basename(char *dest, size_t size, const char *path);
wrp_status_t path_get_extension(char *dest, size_t size, const char *path);
wrp_status_t path_strip_extension(char *dest, size_t size, const char *path);
wrp_status_t path_readlink(char *dest, size_t size, const char *path);

/* Directory operations */
wrp_status_t path_ensure_directory(const char *path, mode_t mode);
wrp_status_t path_ensure_parent_directory(const char *path, mode_t mode);
wrp_status_t path_create_temp_dir(char *path, size_t size, const char *base_dir,
                                  const char *prefix);
wrp_status_t path_cleanup_temp_dir(const char *path);

/* Installation path helpers */
wrp_status_t path_get_python_dir(char *dest, size_t size, const char *base_dir,
                                 const char *python_version);
wrp_status_t path_get_app_dir(char *dest, size_t size, const char *base_dir,
                              const char *app_name);
wrp_status_t path_get_lock_file(char *dest, size_t size, const char *base_dir);
wrp_status_t path_get_temp_dir(char *dest, size_t size, const char *base_dir);

/* Python installation path helpers */
wrp_status_t path_get_python_binary(char *dest, size_t size,
                                    const char *python_dir);
wrp_status_t path_get_app_binary(char *dest, size_t size, const char *app_dir,
                                 const char *app_name);

/* Installation validation helper */
wrp_status_t path_validate_components(const char *base_dir,
                                      const char *python_ver, char *python_dir,
                                      size_t python_dir_size, char *app_dir,
                                      size_t app_dir_size,
                                      const char *app_name);

#endif /* WRAPPER_PATHUTILS_H */
