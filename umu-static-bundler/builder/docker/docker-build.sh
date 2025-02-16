#!/bin/bash

set -e

source "/build/lib/messaging.sh"

readonly PYTHON_DIR="${WORK_DIR}/python"
readonly UMU_DIR="${WORK_DIR}/umu-launcher"
readonly BUILD_OUTPUT="${BUILD_DIR}/umu-run"
readonly STAGE_DIR="${WORK_DIR}/stage"
readonly APP_NAME="umu-run"

# Configure umu-launcher
OLDHOME=${HOME}
HOME=${BUILD_DIR}

cd "${UMU_DIR}"
./configure.sh --user-install
make

HOME=${OLDHOME}

# Check for version file and stage it
readonly _VERSION_FILE="${UMU_DIR}/umu/umu_version.json"
readonly STAGED_VERSION="${WORK_DIR}/umu_version.json"

if [ ! -f "${_VERSION_FILE}" ]; then
    DATE=$(date)
    printf '%s %s' "${DATE}" "$(echo -n "${DATE}" | sha512sum -)" > "${_VERSION_FILE}"
fi
cp "${_VERSION_FILE}" "${STAGED_VERSION}"

# Build static wrapper
_message "Building static wrapper..."
cd "${WORK_DIR}/wrapper" || _failure "No wrapper src dir?"

export BINARY_NAME="umu-run"

# Pass absolute paths to the Makefile for version file handling
PYTHON_VERSION="$("${PYTHON_DIR}/bin/python" --version | cut -f2 -d' ')" \
PYTHON_SCRIPT="umu-run" \
VERSION_FILE="${STAGED_VERSION}" \
VERSION_FILE_NAME="umu_version.json" \
make -f /build/lib/Makefile || _failure "Failed to compile wrapper"

mv "${WORK_DIR}/wrapper/umu-run" "${WORK_DIR}/umu-run" && cd "${WORK_DIR}"

# Prepare staging directories with final structure
_message "Preparing staging directories..."
mkdir -p "${STAGE_DIR}/python" "${STAGE_DIR}/apps/${APP_NAME}/bin"

# Stage Python distribution
_message "Staging Python distribution..."
cp -r "${PYTHON_DIR}"/* "${STAGE_DIR}/python/"

# Stage application files
_message "Staging application files..."
cp "${UMU_DIR}/builddir/umu-run" "${STAGE_DIR}/apps/${APP_NAME}/bin/"

# Ensure version file exists in the correct location for the bundle
cp "${_VERSION_FILE}" "${STAGE_DIR}/apps/${APP_NAME}/"

# Verify staged files
_message "Verifying staged files..."
required_files=(
    "python/bin/python"
    "python/bin/python3"
    "apps/${APP_NAME}/bin/umu-run"
    "apps/${APP_NAME}/umu_version.json"
)

for file in "${required_files[@]}"; do
    if [[ ! -f "${STAGE_DIR}/${file}" ]]; then
        _error "Missing required file: ${file}"
        rm -rf "${STAGE_DIR}"
        _failure "Stage verification failed"
    fi
done

# Create compressed archive
_message "Creating archive..."
# Use a subshell to avoid changing the working directory in the main script
if ! (cd "${STAGE_DIR}" && bsdtar --options zstd:compression-level=22,zstd:threads=0 \
            --zstd -cf "${WORK_DIR}/archive.tar.zst" ./python ./apps); then
    rm -rf "${STAGE_DIR}"
    _failure "Archive creation failed"
fi

readonly ARCHIVE_SIZE=$(stat -c%s "${WORK_DIR}/archive.tar.zst")

# Combine wrapper and archive
_message "Assembling final executable..."
if ! cat "${WORK_DIR}/umu-run" "${WORK_DIR}/archive.tar.zst" > "${BUILD_OUTPUT}"; then
    rm -rf "${STAGE_DIR}"
    rm -f "${WORK_DIR}/umu-run" "${WORK_DIR}/archive.tar.zst"
    _failure "Failed to combine wrapper with archive"
fi

if ! printf "%020d" "${ARCHIVE_SIZE}" >> "${BUILD_OUTPUT}"; then
    rm -rf "${STAGE_DIR}"
    rm -f "${BUILD_OUTPUT}" "${WORK_DIR}/umu-run" "${WORK_DIR}/archive.tar.zst"
    _failure "Failed to append archive size"
fi

chmod +x "${BUILD_OUTPUT}"

# Cleanup
rm -rf "${STAGE_DIR}"
rm -f "${WORK_DIR}/umu-run" "${WORK_DIR}/archive.tar.zst"

_message "Build completed successfully"
