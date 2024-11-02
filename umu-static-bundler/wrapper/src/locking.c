#include "locking.h"
#include "logging.h"
#include "pathutils.h"
#include "wrapper.h"
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <time.h>

/* Lock file metadata structure */
struct lock_info {
  pid_t owner_pid;                 /* Process holding the lock */
  time_t acquisition_time;         /* When the lock was acquired */
  char owner_executable[PATH_MAX]; /* Path to owner's executable */
  uint32_t checksum;               /* Simple validation checksum */
};

/* Calculate simple checksum of lock info */
static uint32_t calculate_lock_checksum(const struct lock_info *info) {
  uint32_t sum = 0;
  const unsigned char *data = (const unsigned char *)info;
  /* Skip checksum field in calculation */
  size_t len = offsetof(struct lock_info, checksum);

  for (size_t i = 0; i < len; i++) {
    sum = (sum << 4) + data[i];
    uint32_t g = sum & 0xf0000000;
    if (g != 0) {
      sum ^= (g >> 24);
      sum ^= g;
    }
  }
  return sum;
}

/* Write lock metadata to file with validation */
static wrp_status_t write_lock_info(int fd, struct lock_info *info) {
  if (lseek(fd, 0, SEEK_SET) == -1) {
    return WRP_EERRNO;
  }

  if (ftruncate(fd, 0) == -1) {
    return WRP_EERRNO;
  }

  /* Calculate and set checksum before writing */
  info->checksum = calculate_lock_checksum(info);

  /* Write atomically using a single write call */
  ssize_t written = write(fd, info, sizeof(*info));
  if (written == -1) {
    return WRP_EERRNO;
  }
  if (written != sizeof(*info)) {
    return WRP_EINVAL;
  }

  /* Ensure data is written to disk */
  if (fsync(fd) == -1) {
    return WRP_EERRNO;
  }

  return WRP_OK;
}

/* Read and validate lock metadata from file */
static wrp_status_t read_lock_info(int fd, struct lock_info *info) {
  if (lseek(fd, 0, SEEK_SET) == -1) {
    return WRP_EERRNO;
  }

  ssize_t bytes = read(fd, info, sizeof(*info));
  if (bytes == -1) {
    return WRP_EERRNO;
  }
  if (bytes != sizeof(*info)) {
    return WRP_EINVAL;
  }

  /* Verify checksum */
  uint32_t expected = info->checksum;
  info->checksum = 0;
  uint32_t calculated = calculate_lock_checksum(info);

  if (calculated != expected) {
    log_warning("Lock file corruption detected");
    return WRP_EINVAL;
  }

  return WRP_OK;
}

/* Check if process is still running with improved error handling */
static wrp_status_t check_process_alive(pid_t pid, const char *exe_path,
                                        int *alive) {
  *alive = 0;
  char proc_path[PATH_MAX];
  char real_exe[PATH_MAX];

  /* First check if process exists */
  if (kill(pid, 0) == -1) {
    if (errno == ESRCH) {
      return WRP_OK; /* Process doesn't exist */
    }
    return WRP_EERRNO;
  }

  /* Verify it's the same executable with better path handling */
  if (path_join(proc_path, sizeof(proc_path), "/proc", "self", "exe", NULL) !=
      WRP_OK) {
    return WRP_EINVAL;
  }

  ssize_t len = readlink(proc_path, real_exe, sizeof(real_exe) - 1);
  if (len == -1) {
    if (errno == ENOENT) {
      return WRP_OK; /* Process terminated */
    }
    return WRP_EERRNO;
  }
  real_exe[len] = '\0';

  *alive = (strcmp(real_exe, exe_path) == 0);
  return WRP_OK;
}

/* Try to break a stale lock with improved error handling */
static wrp_status_t break_stale_lock(int fd, struct lock_info *info) {
  int alive;
  wrp_status_t status =
      check_process_alive(info->owner_pid, info->owner_executable, &alive);

  if (status != WRP_OK) {
    return status;
  }

  if (!alive) {
    log_warning("Breaking stale lock held by dead process %d", info->owner_pid);
    struct flock fl = {
        .l_type = F_UNLCK, .l_whence = SEEK_SET, .l_start = 0, .l_len = 0};

    if (fcntl(fd, F_SETLK, &fl) == -1) {
      return WRP_EERRNO;
    }
    return WRP_OK;
  }

  time_t now = time(NULL);
  if (now - info->acquisition_time > LOCK_TIMEOUT * 2) {
    log_warning("Breaking expired lock (age: %ld seconds)",
                now - info->acquisition_time);
    return WRP_OK;
  }

  return WRP_ELOCK;
}

/* Acquire lock with improved security and robustness */
int acquire_lock_safe(const char *lock_path, const char *exe_path,
                      int timeout) {
  struct timespec start_time, current_time;
  struct lock_info info = {0};
  int fd = -1;

  if (!lock_path || !exe_path) {
    log_error("Invalid lock parameters");
    return -1;
  }

  /* Create parent directory safely */
  char parent_dir[PATH_MAX];
  if (path_get_dirname(parent_dir, sizeof(parent_dir), lock_path) != WRP_OK) {
    log_error("Failed to get lock file parent directory");
    return -1;
  }

  /* Create directory with secure permissions */
  if (create_directory_with_parents(parent_dir, 0700) != WRP_OK) {
    log_error("Failed to create lock directory: %s", parent_dir);
    return -1;
  }

  if (clock_gettime(CLOCK_MONOTONIC, &start_time) == -1) {
    log_error("Failed to get start time");
    return -1;
  }

  while (1) {
    /* Open/create lock file with secure permissions */
    fd = open(lock_path, O_RDWR | O_CREAT, 0600);
    if (fd == -1) {
      log_error("Failed to create/open lock file: %s", strerror(errno));
      return -1;
    }

    struct flock fl = {
        .l_type = F_WRLCK, .l_whence = SEEK_SET, .l_start = 0, .l_len = 0};

    if (fcntl(fd, F_SETLK, &fl) == 0) {
      /* Lock acquired successfully */
      info.owner_pid = getpid();
      info.acquisition_time = time(NULL);
      strncpy(info.owner_executable, exe_path,
              sizeof(info.owner_executable) - 1);

      if (write_lock_info(fd, &info) != WRP_OK) {
        log_error("Failed to write lock info");
        close(fd);
        return -1;
      }

      /* Set close-on-exec flag */
      int flags = fcntl(fd, F_GETFD);
      if (flags != -1) {
        fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
      }

      return fd;
    }

    /* Failed to acquire lock - check if it's stale */
    if (read_lock_info(fd, &info) == WRP_OK) {
      if (break_stale_lock(fd, &info) == WRP_OK) {
        close(fd);
        continue;
      }
    }

    close(fd);

    /* Check timeout */
    if (clock_gettime(CLOCK_MONOTONIC, &current_time) == -1) {
      log_error("Failed to get current time");
      return -1;
    }

    if (current_time.tv_sec - start_time.tv_sec >= timeout) {
      log_error("Lock acquisition timed out after %d seconds", timeout);
      return -1;
    }

    struct timespec wait_time = {.tv_sec = 0, .tv_nsec = 100000000}; /* 100ms */
    nanosleep(&wait_time, NULL);
  }
}

/* Release lock safely */
void release_lock_safe(int lock_fd) {
  if (lock_fd >= 0) {
    /* Clear lock file contents securely */
    struct lock_info zeroed_info = {0};
    if (write_lock_info(lock_fd, &zeroed_info) != WRP_OK) {
      log_warning("Failed to clear lock file contents");
    }

    /* Release lock */
    struct flock fl = {
        .l_type = F_UNLCK, .l_whence = SEEK_SET, .l_start = 0, .l_len = 0};

    if (fcntl(lock_fd, F_SETLK, &fl) == -1) {
      log_warning("Failed to release lock: %s", strerror(errno));
    }

    close(lock_fd);
    log_debug("Lock released");
  }
}
