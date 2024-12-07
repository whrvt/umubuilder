#include "logging.h"
#include "pathutils.h"
#include "wrapper.h"

/* Get the size of a file in bytes */
static long get_file_size(const char *filename) {
  struct stat st;
  if (stat(filename, &st) != 0) {
    return -1;
  }
  return st.st_size;
}

/* Read the archive size from the end of the executable */
static wrp_status_t read_archive_size(FILE *file, long file_size,
                                      unsigned long long *archive_size) {
  char size_str[ARCHIVE_SIZE_DIGITS + 1] = {0};

  if (fseek(file, -ARCHIVE_SIZE_DIGITS, SEEK_END) != 0) {
    return handle_error(WRP_EERRNO, NULL, NULL,
                        "Failed to seek to archive size position");
  }

  if (fread(size_str, 1, ARCHIVE_SIZE_DIGITS, file) != ARCHIVE_SIZE_DIGITS) {
    return handle_error(WRP_EERRNO, NULL, NULL, "Failed to read archive size");
  }

  errno = 0;
  *archive_size = strtoull(size_str, NULL, 10);
  if ((*archive_size == ULLONG_MAX && errno == ERANGE) ||
      *archive_size > (unsigned long long)file_size - ARCHIVE_SIZE_DIGITS) {
    return handle_error(WRP_EINVAL, NULL, NULL,
                        "Invalid archive size: %llu (file size: %ld)",
                        *archive_size, file_size);
  }

  log_debug("Archive size: %llu bytes", *archive_size);
  return WRP_OK;
}

/* Copy data between libarchive read/write handles */
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
      log_error("Write failed: %s", archive_error_string(aw));
      return r;
    }
  }
}

/* Archive extraction context */
struct archive_context {
  struct archive *ar;     /* Archive reader */
  struct archive *aw;     /* Archive writer */
  FILE *file;             /* Input file handle */
  void *buffer;           /* Archive buffer */
  char *target_dir;       /* Extraction target directory */
  const char *section;    /* Section being extracted */
  size_t files_extracted; /* Number of files extracted */
  int flags;              /* Extraction flags */
};

/* Initialize archive extraction context */
static wrp_status_t init_archive_context(struct archive_context *ctx,
                                         const char *target_dir,
                                         const char *section) {
  if (!ctx || !target_dir || !section) {
    return WRP_EINVAL;
  }

  memset(ctx, 0, sizeof(*ctx));
  ctx->target_dir = strdup(target_dir);
  ctx->section = section;
  ctx->flags =
      ARCHIVE_EXTRACT_TIME | ARCHIVE_EXTRACT_PERM | ARCHIVE_EXTRACT_FFLAGS;

  if (!ctx->target_dir) {
    return WRP_EERRNO;
  }

  return WRP_OK;
}

/* Cleanup archive context */
static void cleanup_archive_context(void *ctx) {
  struct archive_context *ac = (struct archive_context *)ctx;
  if (!ac) {
    return;
  }

  if (ac->ar) {
    archive_read_close(ac->ar);
    archive_read_free(ac->ar);
  }
  if (ac->aw) {
    archive_write_close(ac->aw);
    archive_write_free(ac->aw);
  }
  if (ac->file) {
    fclose(ac->file);
  }
  free(ac->buffer);
  free(ac->target_dir);
}

/* Process a single archive entry */
static wrp_status_t process_archive_entry(struct archive_context *ctx,
                                          struct archive_entry *entry) {
  wrp_status_t status;
  char full_path[PATH_MAX];
  char norm_path[PATH_MAX];
  char rel_path[PATH_MAX];
  int is_subpath;
  const char *entry_path = archive_entry_pathname(entry);
  int r;

  /* Check if entry is in the requested section */
  if (path_is_subpath(ctx->section, entry_path, &is_subpath) != WRP_OK ||
      !is_subpath) {
    log_debug("Skipping entry not in section %s: %s", ctx->section, entry_path);
    archive_read_data_skip(ctx->ar);
    return WRP_OK;
  }

  /* Strip archive prefix to get relative path */
  status = path_strip_archive_prefix(rel_path, sizeof(rel_path), entry_path,
                                     ctx->section);
  if (status != WRP_OK) {
    log_warning("Failed to strip archive prefix from path: %s", entry_path);
    return status;
  }

  /* Join paths safely */
  if (path_join(full_path, sizeof(full_path), ctx->target_dir, rel_path,
                NULL) != WRP_OK) {
    return handle_error(WRP_EINVAL, NULL, NULL,
                        "Failed to construct path for: %s", entry_path);
  }

  /* Normalize and verify the path */
  strcpy(norm_path, full_path);
  if (path_normalize(norm_path, sizeof(norm_path)) != WRP_OK) {
    return handle_error(WRP_EINVAL, NULL, NULL, "Failed to normalize path: %s",
                        full_path);
  }

  /* Verify the normalized path is still under target directory */
  if (path_is_subpath(ctx->target_dir, norm_path, &is_subpath) != WRP_OK ||
      !is_subpath) {
    return handle_error(WRP_EINVAL, NULL, NULL,
                        "Path escapes target directory: %s", entry_path);
  }

  /* Create parent directory */
  status = path_ensure_parent_directory(norm_path, 0700);
  if (status != WRP_OK) {
    return handle_error(status, NULL, NULL,
                        "Failed to create parent directory for: %s",
                        entry_path);
  }

  log_debug("Extracting: %s", entry_path);
  archive_entry_set_pathname(entry, norm_path);

  r = archive_write_header(ctx->aw, entry);
  if (r != ARCHIVE_OK) {
    return handle_error(WRP_EEXTRACT, NULL, NULL, "Failed to write header: %s",
                        archive_error_string(ctx->aw));
  }

  if (archive_entry_size(entry) > 0) {
    r = copy_archive_data(ctx->ar, ctx->aw);
    if (r != ARCHIVE_OK) {
      return handle_error(WRP_EEXTRACT, NULL, NULL,
                          "Failed to extract file: %s", full_path);
    }
  }

  r = archive_write_finish_entry(ctx->aw);
  if (r != ARCHIVE_OK) {
    return handle_error(WRP_EEXTRACT, NULL, NULL,
                        "Failed to finalize entry: %s",
                        archive_error_string(ctx->aw));
  }

  ctx->files_extracted++;
  return WRP_OK;
}

/* Extract archive section to target directory */
static wrp_status_t extract_archive_section(const char *self_path,
                                            const char *target_dir,
                                            const char *section_prefix) {
  struct archive_context ctx;
  wrp_status_t status;
  long archive_start;
  unsigned long long archive_size = 0;
  int r;

  /* Initialize extraction context */
  status = init_archive_context(&ctx, target_dir, section_prefix);
  if (status != WRP_OK) {
    return status;
  }

  /* Ensure cleanup on exit */
  status = handle_error(WRP_OK, cleanup_archive_context, &ctx, NULL);

  /* Open and read archive */
  long file_size = get_file_size(self_path);
  if (file_size == -1 || !(ctx.file = fopen(self_path, "rb"))) {
    return handle_error(WRP_EERRNO, NULL, NULL, "Failed to open executable: %s",
                        self_path);
  }

  if (read_archive_size(ctx.file, file_size, &archive_size) != WRP_OK) {
    return handle_error(WRP_EEXTRACT, NULL, NULL,
                        "Failed to read archive size");
  }

  archive_start = file_size - archive_size - ARCHIVE_SIZE_DIGITS;
  if (fseek(ctx.file, archive_start, SEEK_SET) != 0) {
    return handle_error(WRP_EERRNO, NULL, NULL,
                        "Failed to seek to archive start position: %ld",
                        archive_start);
  }

  ctx.buffer = malloc(archive_size);
  if (!ctx.buffer ||
      fread(ctx.buffer, 1, archive_size, ctx.file) != archive_size) {
    return handle_error(WRP_EERRNO, NULL, NULL, "Failed to read archive data");
  }

  /* Initialize archive reader */
  if (!(ctx.ar = archive_read_new())) {
    return handle_error(WRP_EEXTRACT, NULL, NULL,
                        "Failed to initialize archive reader");
  }

  archive_read_support_format_all(ctx.ar);
  archive_read_support_filter_all(ctx.ar);

  if (archive_read_open_memory(ctx.ar, ctx.buffer, archive_size) !=
      ARCHIVE_OK) {
    return handle_error(WRP_EEXTRACT, NULL, NULL, "Failed to open archive: %s",
                        archive_error_string(ctx.ar));
  }

  /* Initialize disk writer */
  if (!(ctx.aw = archive_write_disk_new())) {
    return handle_error(WRP_EEXTRACT, NULL, NULL,
                        "Failed to initialize disk writer");
  }

  archive_write_disk_set_options(ctx.aw, ctx.flags);

  /* Process archive entries */
  struct archive_entry *entry;
  while ((r = archive_read_next_header(ctx.ar, &entry)) == ARCHIVE_OK) {
    status = process_archive_entry(&ctx, entry);
    if (status != WRP_OK && status != WRP_ENOENT) {
      return status;
    }
  }

  if (r != ARCHIVE_EOF) {
    return handle_error(WRP_EEXTRACT, NULL, NULL, "Error reading archive: %s",
                        archive_error_string(ctx.ar));
  }

  if (ctx.files_extracted == 0) {
    log_debug("No files found in section: %s", section_prefix);
    return WRP_ENOENT;
  }

  log_debug("Successfully extracted %zu files from section: %s",
            ctx.files_extracted, section_prefix);
  return WRP_OK;
}

/* Public function to extract specified sections */
wrp_status_t extract_bundled_archive(const char *self_path,
                                     const char *target_dir,
                                     install_flags_t flags) {
  wrp_status_t status;

  if (!self_path || !target_dir) {
    return handle_error(WRP_EINVAL, NULL, NULL,
                        "Invalid parameters for archive extraction");
  }

  /* Verify target path safety */
  status = path_is_safe(target_dir);
  if (status != WRP_OK) {
    return handle_error(status, NULL, NULL, "Invalid target directory path: %s",
                        target_dir);
  }

  log_debug("Extracting to target directory: %s", target_dir);

  /* Extract Python section if requested */
  if (flags & INSTALL_PYTHON) {
    log_info("Extracting Python files...");
    status = extract_archive_section(self_path, target_dir, SECTION_PYTHON);
    if (status != WRP_OK && status != WRP_ENOENT) {
      path_cleanup_temp_dir(target_dir);
      return handle_error(status, NULL, NULL,
                          "Failed to extract Python section");
    }
  }

  /* Extract application section if requested */
  if (flags & INSTALL_APP) {
    log_info("Extracting application files...");
    status = extract_archive_section(self_path, target_dir, SECTION_APP);
    if (status != WRP_OK) {
      path_cleanup_temp_dir(target_dir);
      return handle_error(status, NULL, NULL,
                          "Failed to extract application section");
    }
  }

  return WRP_OK;
}
