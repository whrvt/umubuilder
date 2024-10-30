#!/bin/bash

pkgver=9-8
buildname="proton-osu"
pkgname="${buildname}-${pkgver}"

protonurl=https://github.com/GloriousEggroll/proton-ge-custom.git
protontag=GE-Proton9-7
protonsdk="registry.gitlab.steamos.cloud/proton/sniper/sdk:latest"

umu_protonfixesurl=https://github.com/Open-Wine-Components/umu-protonfixes.git

scriptdir="$(realpath "$(dirname "$0")")"

set -a
source "${scriptdir}/umu-static-bundler/lib/messaging.sh"
source "${scriptdir}/umu-static-bundler/lib/git-utils.sh"
set +a

##############################################
# Do everything
##############################################
_main() {
    _parse_args "$@"
    _envsetup || _failure "Failed preparing build environment."
    _dirsetup_initial || _failure "Failed initial directory setup."

    if [ "${_do_umu_only}" = "true" ]; then
        "${umu_builder_dir}/build.sh" || _failure "Building umu-run failed."
    elif [ "${_do_build}" = "true" ]; then
        _sources || _failure "Failed to prepare sources."
        _patch proton wine || _failure "Failed to apply patches."
        _build || _failure "Build failed."
        [ "${_do_install}" = "true" ] && _install || _failure "Install failed."
    fi

    _message "Script finished."
    exit 0
}
##############################################
# Parse arguments
##############################################
_parse_args() {
    _do_build=false
    _do_install=false
    _do_bundle_umu=true
    _do_cleanbuild=false
    _do_umu_only=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            *help*) _help ;;
            buildonly) _do_build=true ;;
            no-bundle-umu) _do_bundle_umu=false ;;
            cleanbuild) _do_cleanbuild=true ;;
            umu-only) _do_umu_only=true ;;
            *) _warning "Unknown option: $1" ;;
        esac
        shift
    done

    if [ "${_do_umu_only}" = "false" ] && [ "${_do_build}" = "false" ]; then
        _do_build=true
        _do_install=true
    fi

    _print_config
}
##############################################
# Directories
##############################################
_dirsetup_initial() {
    srcdir="${scriptdir}/proton" && export srcdir
    builddir="${scriptdir}/build" && export builddir
    mkdir -p "${builddir}"

    build_out_dir="${scriptdir}/build_tarballs"
    mkdir -p "${build_out_dir}"

    patchdir="${scriptdir}/patches" && export patchdir

    umu_builder_dir="${scriptdir}/umu-static-bundler" && export umu_builder_dir
    umu_build_dir="${scriptdir}/umu-build"
}
##############################################
# Environment
##############################################
_envsetup() {
    export WINEESYNC=0
    export WINEFSYNC=0
    export DISPLAY=

    # exported for _patch
    export CPUs="$(($(nproc) + 1))"
    export srcdir="${scriptdir}/proton"
    export patchdir="${scriptdir}/patches"
    export protonurl

    export MAKEFLAGS="-j$CPUs"
    export NINJAFLAGS="-j$CPUs"
    export SUBJOBS="$CPUs"
}
##############################################
# Build
##############################################
_build() {
    cd "${builddir}" || _failure "Can't build because there is no build directory."

    _arglist=(
        --container-engine="docker"
        --proton-sdk-image="${protonsdk}"
        --build-name="${buildname}"
        --enable-ccache
    )

    "${srcdir}"/configure.sh "${_arglist[@]}" || _failure "Configuring proton failed."

    [ "${_do_cleanbuild}" = "true" ] && {
        _message "Cleaning build directory."
        make clean
    }

    make -j1 redist || _failure "Build failed."

    if [ "${_do_bundle_umu}" = "true" ]; then
        _message "Starting static umu-run bundling procedure..."
        if ! _build_umu_run; then
            _warning "Failed to build umu-run. Continuing without it."
        else
            _message "Copying umu-run to build directory..."
            rm -rf "${builddir}/${buildname}/umu-run"
            cp "${umu_build_dir}/umu-run" "${builddir}/${buildname}/umu-run" || _failure "Failed to copy umu-run to the final build directory."
        fi
        cd "${builddir}"
    fi

    _message "Creating archive: ${pkgname}.tar.xz"
    XZ_OPT="-9 -T0" tar -Jcf "${build_out_dir}"/"${pkgname}".tar.xz --numeric-owner --owner=0 --group=0 --null "${buildname}" &&
    sha512sum "${build_out_dir}"/"${pkgname}".tar.xz > "${build_out_dir}"/"${pkgname}".sha512sum &&
    _message "${pkgname}.tar.xz is now ready in the build_tarballs directory"
}
##############################################
# Build a static umu-run redistributable
##############################################
_build_umu_run() {
    _message "Building static umu-run..."
    "${scriptdir}/umu-static-bundler/build.sh" || return 1

    # Copy the built executable to the expected location
    mkdir -p "${umu_build_dir}"
    cp "${scriptdir}/umu-static-bundler/build/umu-run" "${umu_build_dir}/umu-run"

    return 0
}
##############################################
# Installation
##############################################
_install() {
    rsync -a --delete "${builddir}/${buildname}/" "${HOME}/.steam/root/compatibilitytools.d/${buildname}/" ||
        _failure "Couldn't copy ${builddir}/${buildname} to ${HOME}/.steam/root/compatibilitytools.d/${buildname}."

    _message "Build done, it should be installed to ~/.steam/root/compatibilitytools.d/${buildname}"
    _message "Along with the archive in the current directory"
}
##############################################
# Source preparation
##############################################
_sources() {
    local components=("proton" "protonfixes")

    cd "${scriptdir}" || _failure "Couldn't change to script directory."

    for component in "${components[@]}"; do
        case $component in
            proton)
                _repo_updater "${scriptdir}/proton" "${protonurl}" "${protontag}"
                rm -rf "${srcdir}/protonfixes" 2>/dev/null || true
                ;;
            protonfixes)
                _repo_updater "${scriptdir}/protonfixes" "${umu_protonfixesurl}"
                [ -d "${srcdir}"/protonfixes ] && rm -rf "${srcdir}"/protonfixes
                rsync -a --exclude='.git' --exclude='.git*' "${scriptdir}"/protonfixes "${srcdir}"/
                ;;
        esac
    done

    _message "Sources are ready."
}
##############################################
# Terminal output
##############################################
_help() {
    _message "./setup.sh [options]"
    echo ""
    _message "Options:"
    _message "  help         Show this help message"
    _message "  buildonly    Only build without installing to the steam compatibility tools directory"
    _message "  cleanbuild   Run 'make clean' in the build directory before 'make'"
    _message "  no-bundle-umu Don't build and bundle umu-run with Proton"
    _message "  umu-only     Only build the static umu-run self-extracting executable"
    echo ""
    _message "No arguments grabs sources, patches, builds, and installs"

    exit 0
}

_print_config() {
    _message "Build configuration:"
    _message "  build: ${_do_build}"
    _message "  install: ${_do_install}"
    _message "  bundle umu: ${_do_bundle_umu}"
    _message "  clean build: ${_do_cleanbuild}"
    _message "  umu only: ${_do_umu_only}"
}
##############################################
# Run
##############################################
_main "$@"