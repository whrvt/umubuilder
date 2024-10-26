#!/bin/bash

set -e

source "/build/lib/messaging.sh"

PYTHON_DIR="${WORK_DIR}/python"
UMU_LAUNCHER_DIR="${WORK_DIR}/umu-launcher"
BUILD_OUTPUT="${BUILD_DIR}/umu-run"
WRAPPER_SRC="${WORK_DIR}/umu-run-wrapper.c"

OLDHOME=${HOME}
HOME=${BUILD_DIR}

cd "${UMU_LAUNCHER_DIR}"
./configure.sh --user-install
make

HOME=${OLDHOME}

cd "${WORK_DIR}"

# Embed version checksum in the wrapper source
UMU_VERSION_FILE="${UMU_LAUNCHER_DIR}/umu/umu_version.json"
if [[ ! -f "${UMU_VERSION_FILE}" ]]; then
    _error "umu_version.json not found at ${UMU_VERSION_FILE}"
    exit 1
fi

UMU_VERSION_CHECKSUM=$(python3 -c "print(sum(open('${UMU_VERSION_FILE}', 'rb').read()))")

sed -i "s/^#define UMU_VERSION_CHECKSUM.*/#define UMU_VERSION_CHECKSUM ${UMU_VERSION_CHECKSUM}/" "${WRAPPER_SRC}"

# Build static wrapper with libarchive
_message "Building static wrapper..."
if ! clang -static \
    --target=x86_64-alpine-linux-musl \
    -Oz \
    -fno-stack-protector \
    -ffunction-sections \
    -fdata-sections \
    -fmerge-all-constants \
    -fno-unwind-tables \
    -fno-asynchronous-unwind-tables \
    -Wl,--gc-sections \
    -Wl,--strip-all \
    -o "${WORK_DIR}/umu-run" "${WRAPPER_SRC}" \
    -I/usr/local/include \
    -L/usr/local/lib \
    -l:libarchive.a \
    -l:libzstd.a \
    -pthread; then
    _error "Failed to compile wrapper"
    rm -f "${WRAPPER_SRC}"
    exit 1
fi

STAGE_DIR="${WORK_DIR}/stage"
mkdir -p "${STAGE_DIR}/python"

cp -r "${PYTHON_DIR}"/* "${STAGE_DIR}/python/"
cp "${UMU_LAUNCHER_DIR}/builddir/umu-run" "${STAGE_DIR}/"
cp "${UMU_LAUNCHER_DIR}/umu/umu_version.json" "${STAGE_DIR}/"

_message "Creating archive to append to wrapper..."
if ! bsdtar --options zstd:compression-level=22,zstd:threads=0 \
            --zstd -C "${STAGE_DIR}" \
            -cf "${WORK_DIR}/archive.tar.zst" .; then
    _error "Failed to create archive"
    rm -rf "${STAGE_DIR}"
    rm -f "${WORK_DIR}/umu-run" "${WRAPPER_SRC}"
    exit 1
fi

ARCHIVE_SIZE=$(stat -c%s "${WORK_DIR}/archive.tar.zst")

# Make the sausage
if ! cat "${WORK_DIR}/umu-run" "${WORK_DIR}/archive.tar.zst" > "${BUILD_OUTPUT}"; then
    _error "Failed to combine wrapper with archive"
    rm -f "${WORK_DIR}/umu-run" "${WORK_DIR}/archive.tar.zst" "${WRAPPER_SRC}"
    exit 1
fi

if ! printf "%020d" "${ARCHIVE_SIZE}" >> "${BUILD_OUTPUT}"; then
    _error "Failed to append archive size"
    rm -f "${BUILD_OUTPUT}" "${WORK_DIR}/umu-run" "${WORK_DIR}/archive.tar.zst" "${WRAPPER_SRC}"
    exit 1
fi

chmod +x "${BUILD_OUTPUT}"

# Delete temp files
rm -rf "${STAGE_DIR}"
rm -f "${WORK_DIR}/umu-run" "${WORK_DIR}/archive.tar.zst" "${WRAPPER_SRC}"
