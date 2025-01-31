#include "logging.h"
#include "wrapper.h"
#include "wrapper_config.h" /* Generated during build */

int main(int argc, char *argv[]) {
  struct wrapper_config config;
  wrp_status_t status;

#ifndef NDEBUG
  log_init(LOG_DEBUG, 1); /* Enable debug output in debug builds */
#else
  log_init(LOG_INFO, 1); /* Default to info level for release */
#endif

  /* Initialize wrapper configuration using build-time constants */
  status = init_wrapper_config(&config, BINARY_NAME, PYTHON_VERSION,
                               VERSION_FILE, VERSION_CHECKSUM);

  if (status != WRP_OK) {
    log_error("Failed to initialize wrapper configuration");
    return EXIT_FAILURE;
  }

  /* Execute the wrapped application */
  status = run_wrapped_application(&config, argc, argv);
  if (status != WRP_OK) {
    /* exec_python_script was unsuccessful - convert error code to exit status
     */
    return (status == WRP_EERRNO) ? errno : EXIT_FAILURE;
  }

  /* Should never reach here as exec replaces process */
  return EXIT_FAILURE;
}
