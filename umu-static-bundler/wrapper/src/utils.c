#include "locking.h"
#include "logging.h"
#include "pathutils.h"
#include "wrapper.h"

extern char **environ;

/* Process context cleanup */
struct process_cleanup {
  char **argv;
  int lock_fd;
};

static void cleanup_process(void *ctx) {
  struct process_cleanup *pc = (struct process_cleanup *)ctx;
  if (!pc)
    return;

  free(pc->argv);
  if (pc->lock_fd >= 0) {
    release_lock_safe(pc->lock_fd);
  }
}

/* Check if the installed version needs updating */
static wrp_status_t needs_version_update(const char *app_dir,
                                         const struct install_meta *meta) {
  char version_path[PATH_MAX];
  wrp_status_t status;
  FILE *f = NULL;
  char buffer[BUFFER_SIZE];
  size_t bytes_read;
  unsigned long checksum = 0;

  if (!app_dir || !meta || !meta->version_file) {
    return handle_error(WRP_EINVAL, NULL, NULL,
                        "Invalid version check parameters");
  }

  /* Construct complete version file path */
  status = path_join(version_path, sizeof(version_path), app_dir,
                     meta->version_file, NULL);
  if (status != WRP_OK) {
    return handle_error(status, NULL, NULL,
                        "Failed to construct version file path");
  }

  f = fopen(version_path, "rb");
  if (!f) {
    if (errno == ENOENT) {
      log_debug("Version file not found: %s", version_path);
      return WRP_EVERSION;
    }
    return handle_error(WRP_EERRNO, NULL, NULL,
                        "Failed to open version file: %s", version_path);
  }

  while ((bytes_read = fread(buffer, 1, sizeof(buffer), f)) > 0) {
    for (size_t i = 0; i < bytes_read; i++) {
      checksum += (unsigned char)buffer[i];
    }
  }

  fclose(f);

  if (checksum != meta->version_sum) {
    log_debug("Version mismatch - current: %lu, expected: %lu", checksum,
              meta->version_sum);
    return WRP_EVERSION;
  }

  return WRP_OK;
}

/* Execute the Python script with the bundled Python */
wrp_status_t exec_python_script(const char *python_path,
                                const char *script_path, int argc,
                                char *argv[]) {
  struct process_cleanup pc = {0};
  int is_exec;

  if (!python_path || !script_path) {
    return handle_error(WRP_EINVAL, NULL, NULL,
                        "Invalid parameters for Python execution");
  }

  /* Verify executables exist and are executable */
  wrp_status_t status = path_is_executable(python_path, &is_exec);
  if (status != WRP_OK || !is_exec) {
    return handle_error(WRP_EPYTHON, NULL, NULL,
                        "Python interpreter not executable: %s", python_path);
  }

  status = path_is_executable(script_path, &is_exec);
  if (status != WRP_OK || !is_exec) {
    return handle_error(WRP_EPYTHON, NULL, NULL, "Script not executable: %s",
                        script_path);
  }

  pc.argv = malloc(sizeof(char *) * (argc + 2));
  if (!pc.argv) {
    return handle_error(WRP_EERRNO, NULL, NULL,
                        "Failed to allocate memory for exec argv");
  }

  /* Build new argument array */
  pc.argv[0] = (char *)python_path;
  pc.argv[1] = (char *)script_path;
  memcpy(pc.argv + 2, argv + 1, (argc - 1) * sizeof(char *));
  pc.argv[argc + 1] = NULL;

  log_debug("Executing Python: %s %s", python_path, script_path);
  execve(python_path, pc.argv, environ);

  /* Only reached if execve fails */
  return handle_error(WRP_EERRNO, cleanup_process, &pc,
                      "Failed to execute Python interpreter");
}

/* Helper function for Python installation validation */
wrp_status_t verify_python_install(const char *python_dir,
                                   const char *python_version,
                                   int *needs_repair) {
  wrp_status_t status;
  int exists;
  int is_exec;
  char path[PATH_MAX];
  char lib_path[PATH_MAX];

  if (!python_dir || !python_version || !needs_repair) {
    return handle_error(WRP_EINVAL, NULL, NULL,
                        "Invalid parameters for Python validation");
  }

  *needs_repair = 0;

  /* Extract major version from version string (e.g., "3" from "3.13.0") */
  const char *first_dot = strchr(python_version, '.');
  if (!first_dot) {
    return handle_error(WRP_EPYTHON, NULL, NULL,
                        "Invalid Python version format: %s", python_version);
  }

  size_t major_ver_len = first_dot - python_version;
  char major_version[8];
  if (major_ver_len >= sizeof(major_version)) {
    return handle_error(WRP_EPYTHON, NULL, NULL,
                        "Python version string too long: %s", python_version);
  }

  strncpy(major_version, python_version, major_ver_len);
  major_version[major_ver_len] = '\0';

  log_debug("Checking Python %s installation in: %s", python_version,
            python_dir);

  /* Check for python executables */
  const char *required_paths[] = {"bin/python3", /* Main executable symlink */
                                  "bin/python",  /* Alternative symlink */
                                  NULL};

  for (const char **req_path = required_paths; *req_path; req_path++) {
    status = path_join(path, sizeof(path), python_dir, *req_path, NULL);
    if (status != WRP_OK) {
      return handle_error(status, NULL, NULL,
                          "Failed to construct Python executable path: %s/%s",
                          python_dir, *req_path);
    }

    /* First check if file exists */
    status = path_exists(path, &exists);
    if (status != WRP_OK) {
      return handle_error(status, NULL, NULL,
                          "Failed to check Python executable path: %s", path);
    }

    if (!exists) {
      log_debug("Python executable not found: %s", path);
      return WRP_ENOENT;
    }

    /* Check if it's executable */
    status = path_is_executable(path, &is_exec);
    if (status != WRP_OK || !is_exec) {
      log_warning("Python executable exists but not executable: %s - will "
                  "attempt repair",
                  path);
      *needs_repair = 1; /* Mark for repair rather than failing */
      return WRP_ENOENT; /* Trigger re-extraction */
    }
  }

  /* Check Python library directory - try both layouts */
  int found_lib = 0;

  /* Try version-specific layout first (e.g., lib/python3.13) */
  const char *second_dot = strchr(first_dot + 1, '.');
  char versioned_path[32];
  size_t version_len;

  /* Get version string up to minor version (3.13 from 3.13.0) */
  if (second_dot) {
    version_len = second_dot - python_version;
  } else {
    /* If no second dot, use the whole version string */
    version_len = strlen(python_version);
  }

  if (version_len < sizeof(versioned_path)) {
    char base_path[32];
    snprintf(base_path, sizeof(base_path), "python%.*s", (int)version_len,
             python_version);

    status = path_join(lib_path, sizeof(lib_path), python_dir, "lib", base_path,
                       NULL);
    if (status == WRP_OK) {
      status = path_directory_exists(lib_path, &exists);
      if (status == WRP_OK && exists) {
        found_lib = 1;
        log_debug("Found versioned Python library directory: %s", lib_path);

        int is_readable;
        status = path_is_readable(lib_path, &is_readable);
        if (status != WRP_OK || !is_readable) {
          log_warning("Python library directory exists but not readable: %s "
                      "- will attempt repair",
                      lib_path);
          *needs_repair = 1;
          return WRP_ENOENT;
        }
      }
    }
  }

  /* If not found, try traditional layout (e.g., lib/python3) */
  if (!found_lib) {
    char base_path[16];
    snprintf(base_path, sizeof(base_path), "python%s", major_version);

    status = path_join(lib_path, sizeof(lib_path), python_dir, "lib", base_path,
                       NULL);
    if (status == WRP_OK) {
      status = path_directory_exists(lib_path, &exists);
      if (status == WRP_OK && exists) {
        found_lib = 1;
        log_debug("Found traditional Python library directory: %s", lib_path);

        int is_readable;
        status = path_is_readable(lib_path, &is_readable);
        if (status != WRP_OK || !is_readable) {
          log_warning("Python library directory exists but not readable: %s - "
                      "will attempt repair",
                      lib_path);
          *needs_repair = 1;
          return WRP_ENOENT;
        }
      }
    }
  }

  if (!found_lib) {
    log_debug("Python library directory not found");
    return WRP_ENOENT;
  }

  /* Additional sanity checks for Python installation */
  const char *required_dirs[] = {"include", "lib", "bin", NULL};

  for (const char **req_dir = required_dirs; *req_dir; req_dir++) {
    status = path_join(path, sizeof(path), python_dir, *req_dir, NULL);
    if (status != WRP_OK) {
      return handle_error(status, NULL, NULL,
                          "Failed to construct directory path: %s/%s",
                          python_dir, *req_dir);
    }

    status = path_directory_exists(path, &exists);
    if (status != WRP_OK) {
      return handle_error(status, NULL, NULL, "Failed to check directory: %s",
                          path);
    }

    if (!exists) {
      log_debug("Required Python directory missing: %s", path);
      return WRP_ENOENT;
    }

    int is_readable;
    status = path_is_readable(path, &is_readable);
    if (status != WRP_OK || !is_readable) {
      log_warning(
          "Python directory exists but not readable: %s - will attempt repair",
          path);
      *needs_repair = 1;
      return WRP_ENOENT;
    }
  }

  if (*needs_repair) {
    log_debug("Python installation requires repair");
    return WRP_ENOENT;
  }

  log_debug("Python installation validation successful");
  return WRP_OK;
}

/* Helper function for application installation validation */
wrp_status_t verify_app_install(const char *app_dir,
                                const struct install_meta *meta,
                                int *needs_repair) {
  char path[PATH_MAX];
  wrp_status_t status;
  int exists;
  int is_exec;

  if (!app_dir || !meta || !meta->app_name) {
    return handle_error(WRP_EINVAL, NULL, NULL,
                        "Invalid parameters for application validation");
  }

  *needs_repair = 0;

  /* Check for application executable */
  status = path_join(path, sizeof(path), app_dir, "bin", meta->app_name, NULL);
  if (status != WRP_OK) {
    return handle_error(status, NULL, NULL,
                        "Failed to construct application binary path");
  }

  /* First check if file exists */
  status = path_exists(path, &exists);
  if (status != WRP_OK) {
    return handle_error(status, NULL, NULL,
                        "Failed to check application binary path: %s", path);
  }

  if (!exists) {
    log_debug("Application binary not found: %s", path);
    return WRP_ENOENT;
  }

  /* Check if it's executable */
  status = path_is_executable(path, &is_exec);
  if (status != WRP_OK || !is_exec) {
    log_warning("Application binary exists but not executable: %s - will "
                "attempt repair",
                path);
    *needs_repair = 1; /* Mark for repair rather than failing */
    return WRP_ENOENT; /* Trigger re-extraction */
  }

  /* Check version if configured */
  if (meta->version_file && meta->version_sum > 0) {
    status = needs_version_update(app_dir, meta);
    if (status == WRP_EVERSION) {
      log_debug("Application version update needed");
      return WRP_ENOENT;
    } else if (status != WRP_OK) {
      *needs_repair = 1; /* Version file issues should also trigger repair */
      return WRP_ENOENT;
    }
  }

  return WRP_OK;
}

/* Ensure components are properly installed */
wrp_status_t ensure_components(const struct wrapper_config *config) {
  struct process_cleanup pc = {.lock_fd = -1};
  char exe_path[PATH_MAX];
  wrp_status_t status;
  int needs_python = 0;
  int needs_app = 0;
  int needs_python_repair = 0;
  int needs_app_repair = 0;
  int retry_count = 0;
  const int MAX_REPAIR_ATTEMPTS = 1;

retry:
  if (!config) {
    return handle_error(WRP_EINVAL, NULL, NULL,
                        "Invalid parameters passed to ensure_components");
  }

  /* Get executable path */
  status = path_readlink(exe_path, sizeof(exe_path), "/proc/self/exe");
  if (status != WRP_OK) {
    return handle_error(status, NULL, NULL, "Failed to read executable path");
  }

  /* Determine what needs updating */
  status =
      verify_python_install(config->paths.python_dir,
                            config->meta.python_version, &needs_python_repair);
  if (status == WRP_ENOENT) {
    if (needs_python_repair) {
      log_info("Python installation needs repair: %s",
               config->paths.python_dir);
    } else {
      log_info("Python installation needs update: %s",
               config->paths.python_dir);
    }
    needs_python = 1;
  } else if (status != WRP_OK) {
    return status;
  }

  status = verify_app_install(config->paths.app_dir, &config->meta,
                              &needs_app_repair);
  if (status == WRP_ENOENT) {
    if (needs_app_repair) {
      log_info("Application installation needs repair: %s",
               config->paths.app_dir);
    } else {
      log_info("Application installation needs update: %s",
               config->paths.app_dir);
    }
    needs_app = 1;
  } else if (status != WRP_OK) {
    return status;
  }

  if (!needs_python && !needs_app) {
    log_debug("No component updates needed");
    return WRP_OK;
  }

  /* Acquire installation lock */
  pc.lock_fd = acquire_lock_safe(config->paths.lock_file, exe_path,
                                 config->meta.timeout);
  if (pc.lock_fd == -1) {
    return handle_error(WRP_ELOCK, NULL, NULL,
                        "Failed to acquire installation lock after %d seconds",
                        config->meta.timeout);
  }

  /* Create clean temporary directory */
  log_debug("Setting up temporary directory: %s", config->paths.temp_dir);
  status = remove_directory_recursive(config->paths.temp_dir);
  if (status != WRP_OK && status != WRP_ENOENT) {
    return handle_error(status, cleanup_process, &pc,
                        "Failed to clean temporary directory");
  }

  /* Extract required components */
  log_debug("Extracting components to: %s", config->paths.temp_dir);
  status = extract_bundled_archive(exe_path, config->paths.temp_dir,
                                   (needs_python ? INSTALL_PYTHON : 0) |
                                       (needs_app ? INSTALL_APP : 0));

  if (status != WRP_OK) {
    remove_directory_recursive(config->paths.temp_dir);
    return handle_error(status, cleanup_process, &pc,
                        "Component extraction failed");
  }

  /* After extraction, verify again if repair was needed (i.e. try one more time if something went wrong) */
  if ((needs_python_repair || needs_app_repair) &&
      retry_count < MAX_REPAIR_ATTEMPTS) {
    retry_count++;
    log_debug("Verifying repair results...");
    goto retry;
  }

  /* Perform component installations */
  char temp_python_dir[PATH_MAX];
  char temp_app_dir[PATH_MAX];
  char backup_dir[PATH_MAX];

  if (needs_python) {
    status = path_join(temp_python_dir, sizeof(temp_python_dir),
                       config->paths.temp_dir, "python", NULL);
    if (status != WRP_OK) {
      remove_directory_recursive(config->paths.temp_dir);
      return handle_error(status, cleanup_process, &pc,
                          "Failed to construct temporary Python path");
    }

    status = path_join(backup_dir, sizeof(backup_dir), config->paths.base_dir,
                       "python.bak", NULL);
    if (status != WRP_OK) {
      remove_directory_recursive(config->paths.temp_dir);
      return handle_error(status, cleanup_process, &pc,
                          "Failed to construct Python backup path");
    }

    status = atomic_replace_directory(config->paths.python_dir, temp_python_dir,
                                      backup_dir);
    if (status != WRP_OK) {
      remove_directory_recursive(config->paths.temp_dir);
      return handle_error(status, cleanup_process, &pc,
                          "Python installation failed");
    }
  }

  if (needs_app) {
    /* Construct full temporary app directory path including app name */
    status =
        path_join(temp_app_dir, sizeof(temp_app_dir), config->paths.temp_dir,
                  "apps", config->meta.app_name, NULL);
    if (status != WRP_OK) {
      remove_directory_recursive(config->paths.temp_dir);
      return handle_error(status, cleanup_process, &pc,
                          "Failed to construct temporary app path");
    }

    status = path_join(backup_dir, sizeof(backup_dir), config->paths.base_dir,
                       "app.bak", NULL);
    if (status != WRP_OK) {
      remove_directory_recursive(config->paths.temp_dir);
      return handle_error(status, cleanup_process, &pc,
                          "Failed to construct app backup path");
    }

    status = atomic_replace_directory(config->paths.app_dir, temp_app_dir,
                                      backup_dir);
    if (status != WRP_OK) {
      remove_directory_recursive(config->paths.temp_dir);
      return handle_error(status, cleanup_process, &pc,
                          "Application installation failed");
    }
  }

  /* Cleanup temporary directory */
  status = remove_directory_recursive(config->paths.temp_dir);
  if (status != WRP_OK) {
    log_warning("Failed to remove temporary directory: %s",
                config->paths.temp_dir);
  }

  cleanup_process(&pc);
  return WRP_OK;
}

/* Set up the Python environment variables */
wrp_status_t setup_python_environment(const char *app_dir,
                                      const char *python_dir) {
  char python_path[PATH_MAX];
  char python_bin[PATH_MAX];
  char app_bin[PATH_MAX];
  char new_path[PATH_MAX * 2];
  const char *current_path;
  wrp_status_t status;
  int printed;

  if (!app_dir || !python_dir) {
    return handle_error(WRP_EINVAL, NULL, NULL,
                        "Invalid parameters for environment setup");
  }

  /* Get current PATH or use default if not set */
  current_path = secure_getenv("PATH");
  if (!current_path) {
    current_path = "/usr/local/bin:/usr/bin:/bin";
  }

  /* Create paths for both Python and application binaries */
  status = path_join(python_bin, sizeof(python_bin), python_dir, "bin", NULL);
  if (status != WRP_OK) {
    return handle_error(status, NULL, NULL,
                        "Failed to construct Python binary path");
  }

  status = path_join(app_bin, sizeof(app_bin), app_dir, "bin", NULL);
  if (status != WRP_OK) {
    return handle_error(status, NULL, NULL,
                        "Failed to construct application binary path");
  }

  /* Construct new PATH */
  printed = snprintf(new_path, sizeof(new_path), "%s:%s:%s", python_bin,
                     app_bin, current_path);
  if (printed < 0 || (size_t)printed >= sizeof(new_path)) {
    return handle_error(WRP_EINVAL, NULL, NULL, "Combined PATH value too long");
  }

  /* Get Python executable path */
  status = path_join(python_path, sizeof(python_path), python_dir, "bin",
                     "python3", NULL);
  if (status != WRP_OK) {
    return handle_error(status, NULL, NULL,
                        "Failed to construct Python executable path");
  }

  /* Set environment variables */
  if (setenv("PATH", new_path, 1) != 0 ||
      setenv("PYTHONEXECUTABLE", python_path, 1) != 0 ||
      unsetenv("UMU_RUNTIME_UPDATE") != 0) { /* temporary osu-winello-specific workaround */
    return handle_error(WRP_EERRNO, NULL, NULL,
                        "Failed to set environment variables");
  }

  return WRP_OK;
}
