#ifndef WRAPPER_LOCK_MANAGER_H
#define WRAPPER_LOCK_MANAGER_H

#include "wrapper.h"
#include <unistd.h>

/* Lock acquisition with metadata storage and stale lock detection
 *
 * Parameters:
 *   lock_path   - Path to the lock file
 *   exe_path    - Path to current executable for lock ownership verification
 *   timeout     - Maximum time to wait for lock acquisition in seconds
 *
 * Returns:
 *   File descriptor for the lock file (>= 0) on success
 *   -1 on failure with errno set
 *
 * The lock is automatically released if the process terminates.
 * Stale locks from crashed processes are detected and broken.
 */
int acquire_lock_safe(const char *lock_path, const char *exe_path, int timeout);

/* Release lock and cleanup lock file state
 *
 * Parameters:
 *   lock_fd - File descriptor returned by acquire_lock_safe
 *
 * The lock file is truncated and the lock is released.
 * If lock_fd is invalid (< 0), this function is a no-op.
 */
void release_lock_safe(int lock_fd);

#endif /* WRAPPER_LOCK_MANAGER_H */
