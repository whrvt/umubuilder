#!/bin/bash

# Set up a driver for umu-run so that we can do things like call prctl()
# without messing with the static python distributions

# This should be transparent on both user-facing and application-facing ends

set -euo pipefail

build_static_libarchive() {
    local work_dir="$1"
    local util_dir="$2"
    local libarchive_version="3.7.7"
    local libarchive_dir="${work_dir}/libarchive-${libarchive_version}"

    if [ -f "${util_dir}/libarchive.a" ] && [ -d "${util_dir}/include" ] && [ -f "${util_dir}/include/archive.h" ] && [ -f "${util_dir}/include/archive_entry.h" ]; then
        return 0
    fi

    echo "Building static libarchive..."
    curl -L "https://github.com/libarchive/libarchive/releases/download/v${libarchive_version}/libarchive-${libarchive_version}.tar.gz" | tar xz -C "${work_dir}"

    cd "${libarchive_dir}"
    ./configure \
        --prefix="${work_dir}/libarchive-build" \
        --enable-static \
        --disable-shared \
        --disable-bsdtar \
        --disable-bsdcat \
        --disable-bsdcpio \
        --disable-bsdunzip \
        --disable-acl \
        --disable-xattr \
        --disable-largefile \
        --disable-posix-regex-lib \
        --disable-rpath \
        --without-zlib \
        --without-bz2lib \
        --without-libb2 \
        --without-iconv \
        --without-lz4 \
        --without-zstd \
        --without-lzma \
        --without-lzo2 \
        --without-cng \
        --without-openssl \
        --without-xml2 \
        --without-expat \
        --without-nettle \
        CFLAGS="-static -Os -ffunction-sections -fdata-sections" \
        LDFLAGS="-static -Wl,--gc-sections"

    make -j"$(($(nproc) + 1))"

    find . -name "libarchive.a" -exec cp {} "${util_dir}/" \;
    mkdir -p "${util_dir}/include"
    find . -name "*.h" -exec cp {} "${util_dir}/include/" \;

    cd "${work_dir}"
    rm -rf "${libarchive_dir}"

    echo "libarchive built successfully and stored in ${util_dir}."
}

create_self_extracting_wrapper() {
    local work_dir="$1"
    local oxidize_dir="$2"
    local umu_bundler_dir="$3"
    local umu_build_dir="$4"
    local util_dir="${umu_bundler_dir}/util"

    build_static_libarchive "${work_dir}" "${util_dir}"

    local umu_version_file="${oxidize_dir}/build/x86_64-unknown-linux-musl/release/install/umu_version.json"
    local umu_version_checksum=$(python3 -c "print(sum(open('${umu_version_file}', 'rb').read()))")
    sed -i "s/^#define UMU_VERSION_CHECKSUM.*/#define UMU_VERSION_CHECKSUM ${umu_version_checksum}/" "${umu_bundler_dir}/util/umu-run-wrapper.c"

    cc -static -O2 -o "${work_dir}/umu-run" "${util_dir}/umu-run-wrapper.c" \
        -I"${util_dir}/include" \
        -L"${util_dir}" -l:libarchive.a

    tar czf "${work_dir}/archive.tar.gz" -C "${oxidize_dir}/build/x86_64-unknown-linux-musl/release/install" \
        --exclude="COPYING.txt" umu-run-pyoxidizer umu_version.json

    local archive_size=$(stat -c%s "${work_dir}/archive.tar.gz")

    cat "${work_dir}/umu-run" "${work_dir}/archive.tar.gz" > "${umu_build_dir}/umu-run"
    printf "%020d" $archive_size >> "${umu_build_dir}/umu-run"
    chmod +x "${umu_build_dir}/umu-run"

    rm "${work_dir}/archive.tar.gz" "${work_dir}/umu-run"
}

if [ "$#" -ne 4 ]; then
    echo "Usage: $0 <work_dir> <oxidize_dir> <umu_bundler_dir> <umu_build_dir>"
    exit 1
fi

create_self_extracting_wrapper "$1" "$2" "$3" "$4"
