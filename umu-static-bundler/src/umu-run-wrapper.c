#define _GNU_SOURCE
#include <sys/prctl.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>
#include <limits.h>
#include <fcntl.h>
#include <archive.h>
#include <archive_entry.h>

/* Set by lib/umu-build.sh */
#define UMU_VERSION_CHECKSUM ""

#define BUFFER_SIZE 4096
#define ARCHIVE_SIZE_DIGITS 20
#define UMU_STANDALONE_DIR ".local/share/umu-standalone"

#define WRP_SUCCESS 0
#define WRP_ERROR -1

/**
 * Get the size of a file in bytes.
 *
 * @param filename Path to the file
 * @return File size in bytes, or WRP_ERROR on failure
 */
static long get_file_size(const char *filename) {
    struct stat st;
    if (stat(filename, &st) != 0) {
        return WRP_ERROR;
    }
    return st.st_size;
}

/**
 * Read the archive size from the end of the executable.
 * The size is stored as a 20-digit decimal number.
 *
 * @param file Open file handle positioned at start
 * @param file_size Total size of the executable
 * @param archive_size Pointer to store the parsed archive size
 * @return WRP_SUCCESS on success, WRP_ERROR on failure
 */
static int read_archive_size(FILE *file, long file_size, unsigned long long *archive_size) {
    char size_str[ARCHIVE_SIZE_DIGITS + 1] = {0};

    if (fseek(file, -ARCHIVE_SIZE_DIGITS, SEEK_END) != 0) {
        perror("Failed to seek to archive size");
        return WRP_ERROR;
    }

    if (fread(size_str, 1, ARCHIVE_SIZE_DIGITS, file) != ARCHIVE_SIZE_DIGITS) {
        perror("Failed to read archive size");
        return WRP_ERROR;
    }

    *archive_size = strtoull(size_str, NULL, 10);
    if ((*archive_size == ULLONG_MAX && errno == ERANGE) ||
        *archive_size > (unsigned long long)file_size - ARCHIVE_SIZE_DIGITS) {
        fprintf(stderr, "Invalid archive size\n");
        return WRP_ERROR;
    }

    return WRP_SUCCESS;
}

/**
 * Copy data between libarchive read/write handles.
 *
 * @param ar Archive reader handle
 * @param aw Archive writer handle
 * @return ARCHIVE_OK on success, error code on failure
 */
static int copy_archive_data(struct archive *ar, struct archive *aw) {
    const void *buff;
    size_t size;
    la_int64_t offset;
    int r;

    for (;;) {
        r = archive_read_data_block(ar, &buff, &size, &offset);
        if (r == ARCHIVE_EOF) {
            return ARCHIVE_OK;
        }
        if (r != ARCHIVE_OK) {
            return r;
        }

        r = archive_write_data_block(aw, buff, size, offset);
        if (r != ARCHIVE_OK) {
            fprintf(stderr, "%s\n", archive_error_string(aw));
            return r;
        }
    }
}

/**
 * Extract the embedded archive from this executable to the target directory.
 *
 * @param self_path Path to this executable
 * @param target_dir Directory to extract to
 * @return WRP_SUCCESS on success, WRP_ERROR on failure
 */
static int extract_archive(const char *self_path, const char *target_dir) {
    struct archive *a = NULL;
    struct archive *ext = NULL;
    struct archive_entry *entry;
    FILE *self_file = NULL;
    char *buffer = NULL;
    long file_size, archive_start;
    unsigned long long archive_size;
    int flags, r = WRP_ERROR;
    char new_path[PATH_MAX];

    /* Get executable size and open it */
    if ((file_size = get_file_size(self_path)) == WRP_ERROR ||
        !(self_file = fopen(self_path, "rb"))) {
        perror("Failed to access executable");
        goto cleanup;
    }

    /* Read and validate archive size */
    if (read_archive_size(self_file, file_size, &archive_size) != WRP_SUCCESS) {
        goto cleanup;
    }

    /* Position file at start of archive and read it */
    archive_start = file_size - archive_size - ARCHIVE_SIZE_DIGITS;
    if (fseek(self_file, archive_start, SEEK_SET) != 0 ||
        !(buffer = malloc(archive_size)) ||
        fread(buffer, 1, archive_size, self_file) != archive_size) {
        perror("Failed to read archive data");
        goto cleanup;
    }

    /* Initialize libarchive */
    flags = ARCHIVE_EXTRACT_TIME | ARCHIVE_EXTRACT_PERM | ARCHIVE_EXTRACT_FFLAGS;
    if (!(a = archive_read_new()) ||
        !(ext = archive_write_disk_new())) {
        fprintf(stderr, "Failed to initialize archive handles\n");
        goto cleanup;
    }

    archive_read_support_format_all(a);
    archive_read_support_filter_all(a);
    archive_write_disk_set_options(ext, flags);

    if (archive_read_open_memory(a, buffer, archive_size) != ARCHIVE_OK) {
        fprintf(stderr, "Failed to open archive: %s\n", archive_error_string(a));
        goto cleanup;
    }

    /* Extract files */
    while ((r = archive_read_next_header(a, &entry)) == ARCHIVE_OK) {
        /* Rewrite paths to extract to target directory */
        snprintf(new_path, sizeof(new_path), "%s/%s",
                target_dir, archive_entry_pathname(entry));
        archive_entry_set_pathname(entry, new_path);

        if (archive_write_header(ext, entry) != ARCHIVE_OK) {
            fprintf(stderr, "%s\n", archive_error_string(ext));
            goto cleanup;
        }

        if (archive_entry_size(entry) > 0) {
            if (copy_archive_data(a, ext) != ARCHIVE_OK) {
                goto cleanup;
            }
        }

        if (archive_write_finish_entry(ext) != ARCHIVE_OK) {
            fprintf(stderr, "%s\n", archive_error_string(ext));
            goto cleanup;
        }
    }

    /* Check final archive read status */
    if (r != ARCHIVE_EOF) {
        fprintf(stderr, "Error reading archive: %s\n", archive_error_string(a));
        goto cleanup;
    }

    r = WRP_SUCCESS;

cleanup:
    if (a) {
        archive_read_close(a);
        archive_read_free(a);
    }
    if (ext) {
        archive_write_close(ext);
        archive_write_free(ext);
    }
    free(buffer);
    if (self_file) {
        fclose(self_file);
    }
    return r;
}

/**
 * Check if the installed version needs updating by comparing checksums.
 *
 * @param version_path Path to installed version file
 * @return true if update needed, false if current
 */
static bool check_version_needs_update(const char *version_path) {
    FILE *version_file;
    char buffer[BUFFER_SIZE];
    size_t bytes_read;
    unsigned long checksum = 0;

    if (!(version_file = fopen(version_path, "rb"))) {
        return true;  /* No version file means update needed */
    }

    while ((bytes_read = fread(buffer, 1, sizeof(buffer), version_file)) > 0) {
        for (size_t i = 0; i < bytes_read; i++) {
            checksum += (unsigned char)buffer[i];
        }
    }

    fclose(version_file);
    return checksum != UMU_VERSION_CHECKSUM;
}

/**
 * Set up the Python environment variables for the bundled Python.
 *
 * @param base_dir Base installation directory
 * @return WRP_SUCCESS on success, WRP_ERROR on failure
 */
static int setup_python_environment(const char *base_dir) {
    char python_path[PATH_MAX];
    char path_env[PATH_MAX * 2];
    const char *current_path;

    if (strlen(base_dir) >= PATH_MAX - strlen("/python")) {
        fprintf(stderr, "Base directory path too long\n");
        return WRP_ERROR;
    }

    /* Update PATH to include bundled Python */
    current_path = secure_getenv("PATH");
    if (!current_path) {
        current_path = "/usr/local/bin:/usr/bin:/bin";
    }

    snprintf(python_path, sizeof(python_path), "%s/python/bin", base_dir);

    if (strlen(python_path) + strlen(current_path) + 2 >= sizeof(path_env)) {
        fprintf(stderr, "PATH environment variable would exceed maximum length\n");
        return WRP_ERROR;
    }

    snprintf(path_env, sizeof(path_env), "%s:%s", python_path, current_path);

    /* Set required environment variables */
    snprintf(python_path, sizeof(python_path), "%s/python/bin/python3", base_dir);
    if (setenv("PATH", path_env, 1) != 0 ||
        setenv("PYTHONEXECUTABLE", python_path, 1) != 0) ||
        unsetenv("UMU_RUNTIME_UPDATE") {
        perror("Failed to set environment variables");
        return WRP_ERROR;
    }

    return WRP_SUCCESS;
}

/**
 * Execute the bundled Python script (i.e. umu-run) with the bundled Python.
 * This function only returns on error.
 *
 * @param python_path Path to Python interpreter
 * @param python_script_path Path to the python script to execute
 * @param argc Original argc from main
 * @param argv Original argv from main
 * @return WRP_ERROR on exec failure
 */
static int exec_python(const char *python_path, const char *python_script_path, int argc, char *argv[]) {
    char **new_argv = malloc(sizeof(char *) * (argc + 2));
    if (!new_argv) {
        perror("Failed to allocate memory for exec argv");
        return WRP_ERROR;
    }

    /* Build new argument array */
    new_argv[0] = (char *)python_path;
    new_argv[1] = (char *)python_script_path;
    memcpy(new_argv + 2, argv + 1, (argc - 1) * sizeof(char *));
    new_argv[argc + 1] = NULL;

    execve(python_path, new_argv, environ);
    perror("Failed to execute Python interpreter");
    free(new_argv);
    return WRP_ERROR;
}

int main(int argc, char *argv[]) {
    char exe_path[PATH_MAX];
    char umu_standalone_path[PATH_MAX];
    char umu_bin_path[PATH_MAX];
    char umu_version_path[PATH_MAX];
    char python_bin_path[PATH_MAX];
    const char *home;
    ssize_t len;

    /* Enable subreaper mode to prevent orphaned wine processes */
    if (prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) == -1) {
        perror("Failed to set child subreaper");
        return EXIT_FAILURE;
    }

    /* Get paths needed for extraction and execution */
    if ((len = readlink("/proc/self/exe", exe_path, sizeof(exe_path) - 1)) == -1) {
        perror("Failed to read executable path");
        return EXIT_FAILURE;
    }
    exe_path[len] = '\0';

    if (!(home = secure_getenv("HOME"))) {
        fprintf(stderr, "Cannot determine user home directory\n");
        return EXIT_FAILURE;
    }

    if (strlen(home) >= PATH_MAX - strlen("/" UMU_STANDALONE_DIR)) {
        fprintf(stderr, "Home directory path too long\n");
        return EXIT_FAILURE;
    }

    /* Build all required paths */
    snprintf(umu_standalone_path, sizeof(umu_standalone_path), "%s/%s",
             home, UMU_STANDALONE_DIR);
    snprintf(umu_bin_path, sizeof(umu_bin_path), "%s/umu-run",
             umu_standalone_path);
    snprintf(umu_version_path, sizeof(umu_version_path), "%s/umu_version.json",
             umu_standalone_path);
    snprintf(python_bin_path, sizeof(python_bin_path), "%s/python/bin/python",
             umu_standalone_path);

    /* Check if extraction is needed */
    if (access(umu_bin_path, X_OK) != 0 ||
        access(python_bin_path, X_OK) != 0 ||
        check_version_needs_update(umu_version_path)) {

        /* Create installation directory with restrictive permissions */
        if (mkdir(umu_standalone_path, 0700) == -1 && errno != EEXIST) {
            perror("Failed to create standalone directory");
            return EXIT_FAILURE;
        }

        /* Extract bundled files */
        if (extract_archive(exe_path, umu_standalone_path) != WRP_SUCCESS) {
            fprintf(stderr, "Failed to extract archive\n");
            return EXIT_FAILURE;
        }
    }

    /* Set up environment and execute */
    if (setup_python_environment(umu_standalone_path) != WRP_SUCCESS) {
        return EXIT_FAILURE;
    }

    return exec_python(python_bin_path, umu_bin_path, argc, argv);
}
