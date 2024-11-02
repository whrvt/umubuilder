#include "logging.h"
#include "pathutils.h"
#include "wrapper.h"

/* Initialize wrapper configuration with paths and metadata */
wrp_status_t init_wrapper_config(struct wrapper_config *config,
                                 const char *app_name,
                                 const char *python_version,
                                 const char *version_file,
                                 unsigned long version_sum) {
  const char *home;
  wrp_status_t status;

  if (!config || !app_name || !python_version) {
    log_error("Invalid configuration parameters");
    return WRP_EINVAL;
  }

  /* Initialize metadata */
  config->meta.app_name = app_name;
  config->meta.python_version = python_version;
  config->meta.version_file = version_file;
  config->meta.version_sum = version_sum;
  config->meta.dir_mode = 0700; /* Default directory permissions */
  config->meta.timeout = LOCK_TIMEOUT;

  /* Get home directory for installation path */
  if (!(home = secure_getenv("HOME"))) {
    log_error("Cannot determine user home directory");
    return WRP_EENV;
  }

  /* Construct and validate installation paths */
  status = path_join(config->paths.base_dir, sizeof(config->paths.base_dir),
                     home, DEFAULT_PYBSTRAP_DIR, NULL);
  if (status != WRP_OK) {
    return handle_error(status, NULL, NULL,
                        "Failed to construct base directory path");
  }

  status = path_get_python_dir(config->paths.python_dir,
                               sizeof(config->paths.python_dir),
                               config->paths.base_dir, python_version);
  if (status != WRP_OK) {
    return handle_error(status, NULL, NULL,
                        "Failed to construct Python directory path");
  }

  status =
      path_get_app_dir(config->paths.app_dir, sizeof(config->paths.app_dir),
                       config->paths.base_dir, app_name);
  if (status != WRP_OK) {
    return handle_error(status, NULL, NULL,
                        "Failed to construct application directory path");
  }

  status =
      path_get_temp_dir(config->paths.temp_dir, sizeof(config->paths.temp_dir),
                        config->paths.base_dir);
  if (status != WRP_OK) {
    return handle_error(status, NULL, NULL,
                        "Failed to construct temporary directory path");
  }

  status = path_get_lock_file(config->paths.lock_file,
                              sizeof(config->paths.lock_file),
                              config->paths.base_dir);
  if (status != WRP_OK) {
    return handle_error(status, NULL, NULL,
                        "Failed to construct lock file path");
  }

  /* Verify all paths are safe */
  const char *paths[] = {config->paths.base_dir, config->paths.python_dir,
                         config->paths.app_dir, config->paths.temp_dir, NULL};

  for (const char **path = paths; *path; path++) {
    status = path_is_safe(*path);
    if (status != WRP_OK) {
      return handle_error(status, NULL, NULL, "Path is not safe: %s", *path);
    }
  }

  /* Initialize installation flags to none */
  config->flags = INSTALL_NONE;

  return WRP_OK;
}

int run_wrapped_application(const struct wrapper_config *config, int argc,
                            char *argv[]) {
  wrp_status_t status;
  char exe_path[PATH_MAX];

  if (!config) {
    log_error("Invalid configuration parameter");
    return EXIT_FAILURE;
  }

  /* Enable subreaper mode to prevent orphaned processes */
  if (prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) == -1) {
    return handle_error(WRP_EERRNO, NULL, NULL,
                        "Failed to set child subreaper");
  }

  /* Get executable path */
  status = path_readlink(exe_path, sizeof(exe_path), "/proc/self/exe");
  if (status != WRP_OK) {
    return handle_error(status, NULL, NULL, "Failed to read executable path");
  }

  /* Ensure base directory exists with correct permissions */
  status = path_ensure_directory(config->paths.base_dir, config->meta.dir_mode);
  if (status != WRP_OK) {
    return handle_error(status, NULL, NULL,
                        "Failed to create or verify base directory");
  }

  /* Ensure all components are installed */
  status = ensure_components(config);
  if (status != WRP_OK) {
    return handle_error(status, NULL, NULL, "Component installation failed");
  }

  /* Set up environment and execute */
  status =
      setup_python_environment(config->paths.app_dir, config->paths.python_dir);
  if (status != WRP_OK) {
    return EXIT_FAILURE;
  }

  /* Prepare paths for execution */
  char python_bin[PATH_MAX];
  char app_bin[PATH_MAX];

  status = path_get_python_binary(python_bin, sizeof(python_bin),
                                  config->paths.python_dir);
  if (status != WRP_OK) {
    return handle_error(status, NULL, NULL,
                        "Failed to construct Python binary path");
  }

  /* Verify Python binary exists and is executable */
  int is_exec;
  status = path_is_executable(python_bin, &is_exec);
  if (status != WRP_OK || !is_exec) {
    return handle_error(WRP_EPYTHON, NULL, NULL,
                        "Python binary not found or not executable: %s",
                        python_bin);
  }

  status = path_get_app_binary(app_bin, sizeof(app_bin), config->paths.app_dir,
                               config->meta.app_name);
  if (status != WRP_OK) {
    return handle_error(status, NULL, NULL,
                        "Failed to construct application binary path");
  }

  /* Verify app binary exists and is executable */
  status = path_is_executable(app_bin, &is_exec);
  if (status != WRP_OK || !is_exec) {
    return handle_error(WRP_EPERM, NULL, NULL,
                        "Application binary not found or not executable: %s",
                        app_bin);
  }

  /* Execute the application */
  status = exec_python_script(python_bin, app_bin, argc, argv);
  return (status == WRP_EERRNO) ? errno : EXIT_FAILURE;
}
