#define _GNU_SOURCE
#include <sys/prctl.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <libgen.h>
#include <string.h>
#include <errno.h>
#include <limits.h>
#include <fcntl.h>
#include <archive.h>
#include <archive_entry.h>

#define UMU_VERSION_CHECKSUM ""

#define BUFFER_SIZE 4096
#define SIZE_STR_LEN 20

static long get_file_size(const char *filename) {
    struct stat st;
    return (stat(filename, &st) == 0) ? st.st_size : -1;
}

static int read_archive_size(FILE *file, long file_size, unsigned long long *archive_size) {
    char size_str[SIZE_STR_LEN + 1] = {0};

    if (fseek(file, -SIZE_STR_LEN, SEEK_END) != 0 ||
        fread(size_str, 1, SIZE_STR_LEN, file) != SIZE_STR_LEN) {
        return -1;
    }

    *archive_size = strtoull(size_str, NULL, 10);
    if (*archive_size == ULLONG_MAX && errno == ERANGE) {
        return -1;
    }

    if (*archive_size > (unsigned long long)file_size - SIZE_STR_LEN) {
        return -1;
    }

    return 0;
}

static int copy_data(struct archive *ar, struct archive *aw) {
    int r;
    const void *buff;
    size_t size;
    la_int64_t offset; // strange libarchive type

    for (;;) {
        r = archive_read_data_block(ar, &buff, &size, &offset);
        if (r == ARCHIVE_EOF)
            return (ARCHIVE_OK);
        if (r < ARCHIVE_OK)
            return (r);
        r = archive_write_data_block(aw, buff, size, offset);
        if (r < ARCHIVE_OK) {
            fprintf(stderr, "%s\n", archive_error_string(aw));
            return (r);
        }
    }
}

static int extract_archive(const char *self_path, const char *target_dir) {
    struct archive *a, *ext;
    struct archive_entry *entry;
    int flags, r;
    FILE *self_file = NULL;
    long file_size, archive_start;
    unsigned long long archive_size;
    char *buffer = NULL;

    file_size = get_file_size(self_path);
    if (file_size == -1 || !(self_file = fopen(self_path, "rb")) ||
        read_archive_size(self_file, file_size, &archive_size) != 0) {
        fprintf(stderr, "Failed to read archive\n");
        if (self_file) fclose(self_file);
        return -1;
    }

    archive_start = file_size - archive_size - SIZE_STR_LEN;
    if (fseek(self_file, archive_start, SEEK_SET) != 0 ||
        !(buffer = malloc(archive_size)) ||
        fread(buffer, 1, archive_size, self_file) != archive_size) {
        fprintf(stderr, "Failed to read archive data\n");
        free(buffer);
        fclose(self_file);
        return -1;
    }
    fclose(self_file);

    flags = ARCHIVE_EXTRACT_TIME | ARCHIVE_EXTRACT_PERM | ARCHIVE_EXTRACT_FFLAGS;
    a = archive_read_new();
    ext = archive_write_disk_new();
    archive_read_support_format_all(a);
    archive_read_support_filter_all(a);
    archive_write_disk_set_options(ext, flags);

    if ((r = archive_read_open_memory(a, buffer, archive_size)) != ARCHIVE_OK) {
        fprintf(stderr, "Failed to open archive: %s\n", archive_error_string(a));
        free(buffer);
        return -1;
    }

    for (;;) {
        r = archive_read_next_header(a, &entry);
        if (r == ARCHIVE_EOF)
            break;
        if (r < ARCHIVE_OK)
            fprintf(stderr, "%s\n", archive_error_string(a));
        if (r < ARCHIVE_WARN) {
            fprintf(stderr, "Fatal error, aborting.\n");
            break;
        }

        const char* current_file = archive_entry_pathname(entry);

        char new_path[PATH_MAX];
        snprintf(new_path, sizeof(new_path), "%s/%s", target_dir, current_file);
        archive_entry_set_pathname(entry, new_path);

        archive_entry_set_uid(entry, getuid());
        archive_entry_set_gid(entry, getgid());

        r = archive_write_header(ext, entry);
        if (r < ARCHIVE_OK)
            fprintf(stderr, "%s\n", archive_error_string(ext));
        else if (archive_entry_size(entry) > 0) {
            r = copy_data(a, ext);
            if (r < ARCHIVE_OK)
                fprintf(stderr, "%s\n", archive_error_string(ext));
        }
        r = archive_write_finish_entry(ext);
        if (r < ARCHIVE_OK)
            fprintf(stderr, "%s\n", archive_error_string(ext));
    }

    archive_read_close(a);
    archive_read_free(a);
    archive_write_close(ext);
    archive_write_free(ext);
    free(buffer);

    return (r == ARCHIVE_EOF ? 0 : -1);
}

int main(int argc, char *argv[]) {
    char exe_path[PATH_MAX], dir_path[PATH_MAX], umu_run_path[PATH_MAX], umu_version_path[PATH_MAX];
    char *dir;
    struct stat st;
    char **new_argv;
    ssize_t len;

    // Do this here instead of in umu-run so that we can be statically linked and not worry about python's ctypes
    // The setting will be preserved across the following execv call
    if (prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) == -1) {
        perror("Failed to set child subreaper");
        return 1;
    }

    if ((len = readlink("/proc/self/exe", exe_path, sizeof(exe_path) - 1)) == -1) {
        perror("Failed to read executable path");
        return 1;
    }
    exe_path[len] = '\0';

    strncpy(dir_path, exe_path, sizeof(dir_path));
    dir = dirname(dir_path);

    snprintf(umu_run_path, sizeof(umu_run_path), "%s/umu-run-pyoxidizer", dir);
    snprintf(umu_version_path, sizeof(umu_version_path), "%s/umu_version.json", dir);

    if (stat(umu_run_path, &st) == -1 || stat(umu_version_path, &st) == -1) {
        if (extract_archive(exe_path, dir) != 0) {
            fprintf(stderr, "Failed to extract archive\n");
            return 1;
        }
    } else {
        // Check for updates
        FILE *umu_version_file = fopen(umu_version_path, "rb");
        if (umu_version_file) {
            fseek(umu_version_file, 0, SEEK_END);
            long umu_version_size = ftell(umu_version_file);
            fseek(umu_version_file, 0, SEEK_SET);

            char *umu_version_content = malloc(umu_version_size + 1);
            if (umu_version_content) {
                fread(umu_version_content, 1, umu_version_size, umu_version_file);
                umu_version_content[umu_version_size] = 0;

                unsigned long checksum = 0;
                for (long i = 0; i < umu_version_size; i++) {
                    checksum += (unsigned char)umu_version_content[i];
                }
                free(umu_version_content);

                if (checksum != UMU_VERSION_CHECKSUM) {
                    if (extract_archive(exe_path, dir) != 0) {
                        fprintf(stderr, "Failed to extract updated archive\n");
                        return 1;
                    }
                }
            }
            fclose(umu_version_file);
        }
    }

    // Run umu-run with a hacked argv so that the wrapper is transparent
    new_argv = malloc(sizeof(char *) * (argc + 1));
    if (new_argv == NULL) {
        perror("Failed to allocate memory for new argv");
        return 1;
    }

    memcpy(new_argv, argv, sizeof(char *) * argc);
    new_argv[argc] = NULL;

    execv(umu_run_path, new_argv);

    perror("Failed to execute umu-run-pyoxidizer");
    free(new_argv);
    return 1;
}