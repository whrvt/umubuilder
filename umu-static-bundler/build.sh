#!/bin/bash

set -euo pipefail

# Base directory setup
readonly u_scriptdir="$(realpath "$(dirname "$0")")"
readonly third_party_dir="${u_scriptdir}/third_party"
readonly u_work_dir="${u_scriptdir}/work"
readonly u_build_dir="${u_scriptdir}/build"
readonly u_patches_dir="${u_scriptdir}/patches"
readonly cache_dir="${third_party_dir}/cache"
readonly cache_state="${cache_dir}/build_state.txt"

readonly python_version="3.13.0"
readonly static_python_url="https://github.com/indygreg/python-build-standalone/releases/download/20241016/cpython-${python_version}+20241016-x86_64-unknown-linux-musl-install_only_stripped.tar.gz"

readonly libarchive_version="3.7.7"
readonly libarchive_url="https://github.com/libarchive/libarchive/releases/download/v${libarchive_version}/libarchive-${libarchive_version}.tar.gz"
readonly zstd_version="1.5.6"
readonly zstd_url="https://github.com/facebook/zstd/releases/download/v${zstd_version}/zstd-${zstd_version}.tar.zst"
readonly umu_launcher_url="https://github.com/Open-Wine-Components/umu-launcher.git"

readonly docker_image="umu-static-builder:latest"

source "${u_scriptdir}/lib/messaging.sh"
source "${u_scriptdir}/lib/git-utils.sh"
source "${u_scriptdir}/lib/python-cleanup.sh"

parse_args() {
    u_clean_build=false
    u_skip_docker_build=false
    u_keep_work=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            clean)
                u_clean_build=true
                ;;
            skip-docker-build)
                u_skip_docker_build=true
                ;;
            keep-work)
                u_keep_work=true
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

    export u_clean_build u_skip_docker_build u_keep_work
}

show_help() {
    _message "Usage: $0 [options]"
    _message ""
    _message "Build a static umu-run executable bundled with Python"
    _message ""
    _message "Options:"
    _message "  clean           Clean all build artifacts before building"
    _message "  skip-docker-build Skip rebuilding the Docker image"
    _message "  keep-work      Keep work directory after successful build"
    _message "  help           Show this help message"
}

prepare_directories() {
    if [[ "${u_clean_build}" == "true" ]]; then
        _message "Cleaning build environment..."
        rm -rf "${u_build_dir}"
    fi

    rm -rf "${u_work_dir}"
    mkdir -p "${u_work_dir}" "${u_build_dir}" "${cache_dir}"
}

cached_download() {
    local url="$1"
    local output="$2"
    local cache_file="${third_party_dir}/cache/$(basename "${url}")"

    if [[ -f "${output}" ]]; then
        _message "Using cached $(basename "${url}")"
    else
        _message "Downloading $(basename "${url}")..."
        curl -L "${url}" -o "${cache_file}"
        if [[ ! -f "${output}" ]]; then # Messy...
            mv "${cache_file}" "${output}"
        fi
    fi
}

# Try not to do unnecessary work if nothing changed, useful if called from umubuilder's setup.sh
_check_cache_state() {
    local current_state

    current_state=$(cat << EOF
python_version=${python_version}
libarchive_version=${libarchive_version}
zstd_version=${zstd_version}
EOF
)

    # Add hashes for all git repositories in third_party
    while IFS= read -r repo_dir; do
        local repo_name
        repo_name=$(basename "${repo_dir}")
        if [ -d "${repo_dir}/.git" ]; then
            local repo_hash
            repo_hash=$(cd "${repo_dir}" && git rev-parse HEAD)
            current_state+=$'\n'"${repo_name}_commit=${repo_hash}"
        fi
    done < <(find "${third_party_dir}" -maxdepth 1 -type d -not -name "cache" -not -name "third_party")

    # Add hashes for patches and lib
    current_state+=$'\n'"patches_hash=$(find "${u_patches_dir}" -type f -exec sha256sum {} + 2>/dev/null | sort | sha256sum | cut -d' ' -f1)"
    current_state+=$'\n'"lib_hash=$(find "${u_scriptdir}/lib" -type f -exec sha256sum {} + | sort | sha256sum | cut -d' ' -f1)"

    if [ ! -f "${cache_state}" ] || [ "${current_state}" != "$(cat "${cache_state}")" ]; then
        echo "${current_state}" > "${cache_state}"
        return 1
    fi
    return 0
}

prepare_sources() {
    cached_download "${static_python_url}" "${cache_dir}/python-standalone-${python_version}.tar.gz"
    cached_download "${libarchive_url}" "${cache_dir}/libarchive-${libarchive_version}.tar.gz"
    cached_download "${zstd_url}" "${cache_dir}/zstd-${zstd_version}.tar.zst"

    _message "Preparing umu-launcher sources..."
    _repo_updater "${third_party_dir}/umu-launcher" "${umu_launcher_url}"
    cp -r "${third_party_dir}/umu-launcher" "${u_work_dir}/"

    if [[ -d "${u_patches_dir}/umu" ]]; then
        _message "Applying umu-launcher patches..."
        _patch_dir "${u_work_dir}/umu-launcher" "${u_patches_dir}/umu"
    fi

    if [ ! -d "${cache_dir}/cleanup_python" ]; then
        _message "Extracting Python distribution..."
        mkdir -p "${cache_dir}/cleanup_python"
        tar xf "${cache_dir}/python-standalone-${python_version}.tar.gz" -C "${cache_dir}/cleanup_python" --strip-components=1
    fi

    mkdir -p "${u_work_dir}/python"
    rsync -a "${cache_dir}/cleanup_python"/* "${u_work_dir}/python"

    _message "Cleaning Python distribution..."
    _cleanup_python_dist "${cache_dir}/cleanup_python" "${u_work_dir}/python"

    _message "Extracting libarchive..."
    mkdir -p "${u_work_dir}/libarchive"
    tar xf "${cache_dir}/libarchive-${libarchive_version}.tar.gz" -C "${u_work_dir}/libarchive" --strip-components=1

    _message "Extracting zstd..."
    mkdir -p "${u_work_dir}/zstd"
    tar xf "${cache_dir}/zstd-${zstd_version}.tar.zst" -C "${u_work_dir}/zstd" --strip-components=1

    cp "${u_scriptdir}/src/umu-run-wrapper.c" "${u_work_dir}/"
}

prepare_docker_build() {
    local docker_context="${u_work_dir}/docker_context"
    mkdir -p "${docker_context}/lib"

    cp -r "${u_work_dir}/libarchive" "${docker_context}/"
    cp -r "${u_work_dir}/zstd" "${docker_context}/"

    cp "${u_scriptdir}/lib/umu-build.sh" "${docker_context}/"
    cp "${u_scriptdir}/lib/messaging.sh" "${docker_context}/lib/"

    echo "${docker_context}"
}

build_docker_image() {
    local docker_context
    docker_context=$(prepare_docker_build)

    if [[ "${u_skip_docker_build}" == "true" ]] && docker image inspect "${docker_image}" >/dev/null 2>&1; then
        _message "Skipping Docker image build as requested"
        return 0
    fi

    _message "Building Docker image..."
    docker build --progress=plain -t "${docker_image}" -f "${u_scriptdir}/lib/Dockerfile" "${docker_context}" || {
        local ret=$?
        _error "Docker build failed"
        rm -rf "${docker_context}"
        return $ret
    }

    rm -rf "${docker_context}"
}

run_docker_build() {
    _message "Running build in Docker container..."

    docker run --rm -i \
        --user "$(id -u):$(id -g)" \
        -v "${u_work_dir}:/build/work:rw" \
        -v "${u_build_dir}:/build/output:rw" \
        -v "${u_scriptdir}/lib:/build/lib:ro" \
        -e WORK_DIR=/build/work \
        -e BUILD_DIR=/build/output \
        "${docker_image}" || _failure "Docker build failed"
}

cleanup() {
    if [[ "${u_keep_work}" != "true" ]]; then
        rm -rf "${u_work_dir}"
    fi
}

main() {
    parse_args "$@"

    if [ "${u_clean_build}" = "true" ]; then
        _message "Clean build requested, starting fresh..."
    elif [ -x "${u_build_dir}/umu-run" ] && _check_cache_state; then
        _message "No changes detected in versions, sources or configurations, and binary exists at ${u_build_dir}/umu-run"
        return 0
    else
        _message "Changes detected or binary doesn't exist, starting fresh..."
    fi

    prepare_directories
    prepare_sources
    build_docker_image
    run_docker_build

    _message "umu-run has been built successfully"
    _message "The executable is located at: ${u_build_dir}/umu-run"

    cleanup
}

main "$@"
