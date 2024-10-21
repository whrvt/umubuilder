#!/bin/bash

set -euo pipefail

# Set up a driver for umu-run so that we can do things like call prctl()
# without messing with the static python distributions

# This should be transparent on both user-facing and application-facing ends

# We use musl here to make sure we don't have host library instructions leaking into the resulting binary
# and it's still a more lightweight solution than docker for our requirements and simply sufficient

MUSL_CROSS_URL="https://more.musl.cc/x86_64-linux-musl/x86_64-linux-musl-cross.tgz"
MUSL_CROSS_ARCH="x86_64-linux-musl"

download_musl_cross() {
    local util_dir="$1"
    local toolchain_dir="${util_dir}/musl-toolchain"

    if [ -d "$toolchain_dir" ] && [ -f "${toolchain_dir}/bin/${MUSL_CROSS_ARCH}-gcc" ]; then
        echo "Musl toolchain already downloaded."
        return 0
    fi

    echo "Downloading musl cross-compiler toolchain..."
    mkdir -p "$toolchain_dir"
    curl -L "$MUSL_CROSS_URL" | tar xz -C "$toolchain_dir" --strip-components=1

    if [ ! -f "${toolchain_dir}/bin/${MUSL_CROSS_ARCH}-gcc" ]; then
        echo "Failed to download or extract musl toolchain."
        return 1
    fi

    echo "Musl toolchain downloaded and extracted to ${toolchain_dir}"
}

build_static_libarchive() {
    local work_dir="$1"
    local util_dir="$2"
    local libarchive_version="3.7.7"
    local libarchive_dir="${work_dir}/libarchive-${libarchive_version}"
    local toolchain_dir="${util_dir}/musl-toolchain"
    local musl_gcc="${toolchain_dir}/bin/${MUSL_CROSS_ARCH}-gcc"

    if [ -f "${util_dir}/libarchive.a" ] && [ -d "${util_dir}/include" ] && [ -f "${util_dir}/include/archive.h" ] && [ -f "${util_dir}/include/archive_entry.h" ]; then
        return 0
    fi

    echo "Building static libarchive using musl cross-compiler..."
    curl -L "https://github.com/libarchive/libarchive/releases/download/v${libarchive_version}/libarchive-${libarchive_version}.tar.gz" | tar xz -C "${work_dir}"

    cd "${libarchive_dir}"

    CC="$musl_gcc" CFLAGS="-static -Os -ffunction-sections -fdata-sections -fno-stack-protector -fno-math-errno -D_GNU_SOURCE" \
    LDFLAGS="-static -Wl,--gc-sections" \
    ./configure \
        --host="${MUSL_CROSS_ARCH}" \
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
        --disable-utimensat \
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
        --without-nettle

    make -j$(nproc) CC="$musl_gcc"

    find . -name "libarchive.a" -exec cp {} "${util_dir}/" \;
    mkdir -p "${util_dir}/include"
    find . -name "*.h" -exec cp {} "${util_dir}/include/" \;

    cd "${work_dir}"
    rm -rf "${libarchive_dir}"

    echo "libarchive built successfully using musl cross-compiler and stored in ${util_dir}."
}

create_self_extracting_wrapper() {
    local work_dir="$1"
    local oxidize_dir="$2"
    local umu_bundler_dir="$3"
    local umu_build_dir="$4"
    local util_dir="${umu_bundler_dir}/util"
    local toolchain_dir="${util_dir}/musl-toolchain"
    local musl_gcc="${toolchain_dir}/bin/${MUSL_CROSS_ARCH}-gcc"

    download_musl_cross "$util_dir"
    build_static_libarchive "${work_dir}" "${util_dir}"

    local umu_version_file="${oxidize_dir}/build/x86_64-unknown-linux-musl/release/install/umu_version.json"
    local umu_version_checksum=$(python3 -c "print(sum(open('${umu_version_file}', 'rb').read()))")
    sed -i "s/^#define UMU_VERSION_CHECKSUM.*/#define UMU_VERSION_CHECKSUM ${umu_version_checksum}/" "${umu_bundler_dir}/util/umu-run-wrapper.c"

    # Compile the wrapper using the musl cross-compiler
    "$musl_gcc" -static -O2 -fno-stack-protector -fno-math-errno \
        -o "${work_dir}/umu-run" "${util_dir}/umu-run-wrapper.c" \
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
