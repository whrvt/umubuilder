#!/bin/bash

set -euo pipefail

# Base directory setup
readonly SCRIPT_DIR="$(realpath "$(dirname "$0")")"
readonly PROJECT_ROOT="${SCRIPT_DIR}"

# Project structure
readonly BUILDER_DIR="${PROJECT_ROOT}/builder"
readonly WRAPPER_DIR="${PROJECT_ROOT}/wrapper"
readonly THIRD_PARTY_DIR="${PROJECT_ROOT}/third_party"
readonly PATCHES_DIR="${PROJECT_ROOT}/patches"

# Build artifacts and caching
readonly WORK_DIR="${PROJECT_ROOT}/work"
readonly BUILD_DIR="${PROJECT_ROOT}/build"
readonly CACHE_DIR="${THIRD_PARTY_DIR}/cache"
readonly CACHE_STATE="${CACHE_DIR}/build_state.txt"
readonly DOCKER_IMAGE="umu-static-builder:latest"

# Import utilities
source "${PROJECT_ROOT}/lib/messaging.sh"
source "${PROJECT_ROOT}/lib/git-utils.sh"

# Source versions
readonly PYTHON_VERSION="3.13.1"
readonly STATIC_PYTHON_URL="https://github.com/indygreg/python-build-standalone/releases/download/20241206/cpython-${PYTHON_VERSION}+20241206-x86_64-unknown-linux-musl-install_only_stripped.tar.gz"
readonly LIBARCHIVE_VERSION="3.7.7"
readonly LIBARCHIVE_URL="https://github.com/libarchive/libarchive/releases/download/v${LIBARCHIVE_VERSION}/libarchive-${LIBARCHIVE_VERSION}.tar.gz"
readonly ZSTD_VERSION="1.5.6"
readonly ZSTD_URL="https://github.com/facebook/zstd/releases/download/v${ZSTD_VERSION}/zstd-${ZSTD_VERSION}.tar.zst"
readonly UMU_LAUNCHER_URL="https://github.com/Open-Wine-Components/umu-launcher.git"
readonly UMU_LAUNCHER_VERSION="e9cb4d764013d4c8c3d1166f59581da8f56a3d83"

parse_args() {
    local clean_build=false
    local skip_docker_build=false
    local keep_work=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            clean)
                clean_build=true
                ;;
            skip-docker-build)
                skip_docker_build=true
                ;;
            keep-work)
                keep_work=true
                ;;
            help)
                show_help
                exit 0
                ;;
            *)
                _error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
        shift
    done

    echo "${clean_build}:${skip_docker_build}:${keep_work}"
}

show_help() {
    cat << EOF
Usage: $0 [options]

Build a static executable bundled with Python

Options:
  clean           Clean all build artifacts before building
  skip-docker-build Skip rebuilding the Docker image
  keep-work      Keep work directory after successful build
  help           Show this help message
EOF
}

prepare_directories() {
    local clean_build="$1"

    if [[ "${clean_build}" == "true" ]]; then
        _message "Cleaning build environment..."
        rm -rf "${BUILD_DIR}"
    fi

    rm -rf "${WORK_DIR}"
    mkdir -p "${WORK_DIR}" "${BUILD_DIR}" "${CACHE_DIR}"
}

cached_download() {
    local url="$1"
    local output="$2"
    local cache_file="${CACHE_DIR}/$(basename "${url}")"
    local tmp_file="${cache_file}.tmp"

    if [[ -f "${output}" ]]; then
        _message "Using cached $(basename "${url}")"
        return 0
    fi

    _message "Downloading $(basename "${url}")..."
    if ! curl -L "${url}" -o "${tmp_file}"; then
        rm -f "${tmp_file}"
        _error "Failed to download $(basename "${url}")"
        return 1
    fi

    # Atomic move to prevent partial downloads
    mv "${tmp_file}" "${cache_file}"

    # Only copy if target doesn't exist (handles race conditions)
    if [[ ! -f "${output}" ]]; then
        cp "${cache_file}" "${output}"
    fi
}

_check_cache_state() {
    local current_state

    # Add build configuration to cache state
    current_state=$(cat << EOF
static_python_url=${STATIC_PYTHON_URL}
libarchive_version=${LIBARCHIVE_VERSION}
zstd_version=${ZSTD_VERSION}
compiler_flags=$(grep '^CFLAGS' "${BUILDER_DIR}/docker/Makefile")
linker_flags=$(grep '^LDFLAGS' "${BUILDER_DIR}/docker/Makefile")
EOF
)

    # Add hashes for git repositories in third_party
    while IFS= read -r repo_dir; do
        local repo_name
        repo_name=$(basename "${repo_dir}")
        if [[ -d "${repo_dir}/.git" ]]; then
            local repo_hash
            repo_hash=$(cd "${repo_dir}" && git rev-parse HEAD)
            current_state+=$'\n'"${repo_name}_commit=${repo_hash}"
        fi
    done < <(find "${THIRD_PARTY_DIR}" -maxdepth 1 -type d -not -name "cache" -not -name "third_party")

    # Add hashes for project files
    current_state+=$'\n'"patches_hash=$(find "${PATCHES_DIR}" -type f -exec sha256sum {} + 2>/dev/null | sort | sha256sum | cut -d' ' -f1)"
    current_state+=$'\n'"builder_hash=$(find "${BUILDER_DIR}" -type f -exec sha256sum {} + | sort | sha256sum | cut -d' ' -f1)"
    current_state+=$'\n'"wrapper_hash=$(find "${WRAPPER_DIR}" -type f -exec sha256sum {} + | sort | sha256sum | cut -d' ' -f1)"

    if [[ ! -f "${CACHE_STATE}" ]] || [[ "${current_state}" != "$(cat "${CACHE_STATE}")" ]]; then
        echo "${current_state}" > "${CACHE_STATE}"
        return 1
    fi
    return 0
}

_cleanup_python_dist() {
    local original_size
    original_size=$(du -sh "${WORK_DIR}/python" | cut -f1)
    _message "Initial Python distribution size: ${original_size}"

    _message "Running Python distribution cleaner..."
    "${CACHE_DIR}/cleanup_python${PYTHON_VERSION}/bin/python3" "${BUILDER_DIR}/python/cleaner.py" \
        "${WORK_DIR}/python" \
        "${WORK_DIR}/umu-launcher" \
        --config "${BUILDER_DIR}/python/config.py" \
        ${DEBUG:+--debug} || _failure "Python distribution cleanup failed"

    # Metadata cleanup
    find "${WORK_DIR}/python" -type f -name "*.py" \
        -exec sed -i '/^#.*coding/d;/^#.*Author/d;/^#.*Copyright/d' {} +

    local final_size
    final_size=$(du -sh "${WORK_DIR}/python" | cut -f1)

    _message "Python distribution cleaned successfully!"
    _message "Size reduced from ${original_size} to ${final_size}"
}

prepare_sources() {
    # Download dependencies
    cached_download "${STATIC_PYTHON_URL}" "${CACHE_DIR}/python-standalone-${PYTHON_VERSION}.tar.gz"
    cached_download "${LIBARCHIVE_URL}" "${CACHE_DIR}/libarchive-${LIBARCHIVE_VERSION}.tar.gz"
    cached_download "${ZSTD_URL}" "${CACHE_DIR}/zstd-${ZSTD_VERSION}.tar.zst"

    # Prepare UMU launcher
    _message "Preparing umu-launcher sources..."
    _repo_updater "${THIRD_PARTY_DIR}/umu-launcher" "${UMU_LAUNCHER_URL}" "${UMU_LAUNCHER_VERSION}"
    cp -r "${THIRD_PARTY_DIR}/umu-launcher" "${WORK_DIR}/"

    if [[ -d "${PATCHES_DIR}/umu" ]]; then
        _message "Applying umu-launcher patches..."
        _patch_dir "${WORK_DIR}/umu-launcher" "${PATCHES_DIR}/umu"
    fi

    # Setup Python environment for cleanup
    if [[ ! -d "${CACHE_DIR}/cleanup_python${PYTHON_VERSION}" ]]; then
        _message "Extracting Python distribution..."
        mkdir -p "${CACHE_DIR}/cleanup_python${PYTHON_VERSION}"
        tar xf "${CACHE_DIR}/python-standalone-${PYTHON_VERSION}.tar.gz" \
            -C "${CACHE_DIR}/cleanup_python${PYTHON_VERSION}" --strip-components=1
    fi

    # Prepare Python distribution
    mkdir -p "${WORK_DIR}/python"
    rsync -a "${CACHE_DIR}/cleanup_python${PYTHON_VERSION}"/* "${WORK_DIR}/python"
    _cleanup_python_dist

    # Extract build dependencies
    _message "Extracting libarchive..."
    mkdir -p "${WORK_DIR}/libarchive"
    tar xf "${CACHE_DIR}/libarchive-${LIBARCHIVE_VERSION}.tar.gz" \
        -C "${WORK_DIR}/libarchive" --strip-components=1

    _message "Extracting zstd..."
    mkdir -p "${WORK_DIR}/zstd"
    tar xf "${CACHE_DIR}/zstd-${ZSTD_VERSION}.tar.zst" \
        -C "${WORK_DIR}/zstd" --strip-components=1

    # Copy wrapper sources
    _message "Copying wrapper sources..."
    cp -r "${WRAPPER_DIR}" "${WORK_DIR}/" || _failure "Failed to copy wrapper sources"
}

prepare_docker_context() {
    local docker_context="${WORK_DIR}/docker_context"
    mkdir -p "${docker_context}/build"

    # Copy build dependencies
    cp -r "${WORK_DIR}/libarchive" "${docker_context}/build/" || _failure "Failed to copy libarchive"
    cp -r "${WORK_DIR}/zstd" "${docker_context}/build/" || _failure "Failed to copy zstd"
    cp -r "${WORK_DIR}/wrapper" "${docker_context}/build/" || _failure "Failed to copy wrapper sources"

    # Copy build system files
    mkdir -p "${docker_context}/build/lib"
    cp "${BUILDER_DIR}/docker/docker-build.sh" "${docker_context}/build/lib/" || _failure "Failed to copy build script"
    cp "${BUILDER_DIR}/docker/Makefile" "${docker_context}/build/lib/" || _failure "Failed to copy makefile"
    cp "${PROJECT_ROOT}/lib/messaging.sh" "${docker_context}/build/lib/" || _failure "Failed to copy messaging utilities"

    echo "${docker_context}"
}

build_docker_image() {
    local skip_docker_build="$1"
    local docker_context="$2"

    if [[ "${skip_docker_build}" == "true" ]] && docker image inspect "${DOCKER_IMAGE}" >/dev/null 2>&1; then
        _message "Skipping Docker image build as requested"
        return 0
    fi

    _message "Building Docker image..."
    if ! docker buildx build --progress=plain -t ${DOCKER_IMAGE} -f "${BUILDER_DIR}/docker/Dockerfile" "${docker_context}"; then
        _error "Docker build failed"
        rm -rf "${docker_context}"
        return 1
    fi

    rm -rf "${docker_context}"
}

run_docker_build() {
    _message "Running build in Docker container..."

    if ! docker run --rm -i \
        --user "$(id -u):$(id -g)" \
        -v "${WORK_DIR}:/build/work:rw" \
        -v "${BUILD_DIR}:/build/output:rw" \
        -e WORK_DIR=/build/work \
        -e BUILD_DIR=/build/output \
        "${DOCKER_IMAGE}"; then
        _failure "Docker build failed"
    fi
}

cleanup() {
    local keep_work="$1"
    
    if [[ "${keep_work}" != "true" ]]; then
        rm -rf "${WORK_DIR}"
    fi
}

main() {
    IFS=':' read -r clean_build skip_docker_build keep_work <<< "$(parse_args "$@")"

    if [[ "${clean_build}" == "true" ]]; then
        _message "Clean build requested, starting fresh..."
    elif [[ -x "${BUILD_DIR}/umu-run" ]] && _check_cache_state; then
        _message "No changes detected in sources or configurations"
        _message "Existing binary found at: ${BUILD_DIR}/umu-run"
        return 0
    else
        _message "Changes detected or binary doesn't exist, starting fresh..."
    fi

    prepare_directories "${clean_build}"
    prepare_sources

    local docker_context
    docker_context=$(prepare_docker_context)
    build_docker_image "${skip_docker_build}" "${docker_context}" || _failure
    run_docker_build

    _message "Build completed successfully"
    _message "The executable is located at: ${BUILD_DIR}/umu-run"

    cleanup "${keep_work}"
}

main "$@"