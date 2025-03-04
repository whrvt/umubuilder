#!/bin/bash

pkgver=9-16
buildname="proton-osu"
pkgname="${buildname}-${pkgver}"

protonurl=https://github.com/CachyOS/proton-cachyos.git
protontag=cachyos-9.0-20250227-slr
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

    if [ "${_do_rearchive}" = "true" ]; then
        _create_archive || _failure "Couldn't create the compressed archive. You need to have already built proton to use this."
    elif [ "${_do_umu_only}" = "true" ]; then
        "${umu_builder_dir}/build.sh" || _failure "Building umu-run failed."
    elif [ "${_do_build}" = "true" ]; then
        _sources || _failure "Failed to prepare sources."
        _patch proton wine || _failure "Failed to apply patches."
        _build || _failure "Build failed."
        { [ "${_do_install}" = "true" ] && _install ; } || _failure "Install failed."
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
    _do_rearchive=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            *help*) _help ;;
            buildonly) _do_build=true ;;
            no-bundle-umu) _do_bundle_umu=false ;;
            cleanbuild) _do_cleanbuild=true ;;
            umu-only) _do_umu_only=true ;;
            rearchive) _do_rearchive=true ;;
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
    CPUs="$(($(nproc) + 1))"
    [ -z "${CPUs}" ] && CPUs=4
    export CPUs
    export srcdir="${scriptdir}/proton"
    export patchdir="${scriptdir}/patches"
    export protonurl

    export MAKEFLAGS="-j$CPUs"
    export NINJAFLAGS="-j$CPUs"
    export SUBJOBS="$CPUs"
    export J="$CPUs"
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

    _create_archive
}
##############################################
# Create the final compressed archive.
##############################################
_create_archive() {
    cd "${builddir}" || _failure "Can't build because there is no build directory."

    if [ "${_do_bundle_umu}" = "true" ]; then
        _message "Starting static umu-run bundling procedure..."
        if ! _build_umu_run; then
            _warning "Failed to build umu-run"
            { read -rp "\033[0;33m[!] %s\033[0m\n Continue without it? (y/N): " confirm && [[ $confirm == [yY] || $confirm == [yY][eE][sS] ]] ; } || _failure
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
        _failure "Couldn't copy ${builddir}/${buildname} to ${HOME}/.steam/root/compatibilitytools.d/${buildname}. Do you have rsync?"

    _message "Build done, it should be installed to ~/.steam/root/compatibilitytools.d/${buildname}"
    _message "Along with the archive in the current directory"
}
##############################################
# Patching
##############################################
_patch() {
    [ -z "${*}" ] && _failure "No directories specified to _patch."
    [ -z "${srcdir:-}" ] && _failure "srcdir is not set"
    [ -z "${patchdir:-}" ] && _failure "patchdir is not set"
    [ -z "${CPUs:-}" ] && CPUs="$(($(nproc) + 1))"
    [ -z "${CPUs}" ] && CPUs=4

    for subdir in "${@}"; do
        local target_dir
        case "${subdir}" in
        proton) target_dir="${srcdir}" ;;
        wine) target_dir="${srcdir}/${subdir}" ;;
        *) _failure "Unknown patch target: ${subdir}" ;;
        esac

        _patch_dir "${target_dir}" "${patchdir}/${subdir}" || return $?

        # Handle proton-specific post-patch operations
        if [ "${subdir}" = "proton" ]; then
            if [ -n "${protonurl:-}" ] && [[ "${protonurl}" =~ "GloriousEggroll" ]]; then
                _message "Applying GE patches"
                cd "${target_dir}" || return 1
                ./patches/protonprep-valve-staging.sh || _failure "Failed to apply GE protonprep patch"
                cd - || return 1
            fi
            if [ -n "${protonurl:-}" ] && [[ "${protonurl}" =~ "cachyos" ]] && [ -f "${target_dir}/patches/apply.sh" ]; then
                _message "Applying CachyOS patches"
                cd "${target_dir}" || return 1
                ./patches/apply.sh || _failure "Failed to apply CachyOS Proton patches"
                cd - || return 1
            fi

            # Update CPU count in makefiles
            find "${target_dir}"/make/*mk "${target_dir}"/Makefile.in -execdir sed -i \
                -e "s/[\$]*(SUBJOBS)/$CPUs/g" \
                -e "s/J = \$(patsubst -j%,%,\$(filter -j%,\$(MAKEFLAGS)))/J = $CPUs/" \
                -e "s/J := \$(shell nproc)/J := $CPUs/" \
                '{}' +
        fi
    done
    return 0
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
                _repo_updater "${scriptdir}" "${scriptdir}/proton" "${protonurl}" "${protontag}"
                rm -rf "${srcdir}/protonfixes" 2>/dev/null || true
                ;;
            protonfixes)
                _repo_updater "${scriptdir}" "${scriptdir}/protonfixes" "${umu_protonfixesurl}"
                [ -d "${srcdir}"/protonfixes ] && rm -rf "${srcdir}"/protonfixes
                rsync -a --exclude='.git' --exclude='.git*' "${scriptdir}"/protonfixes "${srcdir}"/ || _failure "Couldn't copy protonfixes to the proton source... Do you have rsync?"
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
    _message "  help          Show this help message"
    _message "  buildonly     Only build without installing to the steam compatibility tools directory"
    _message "  cleanbuild    Run 'make clean' in the build directory before 'make'"
    _message "  no-bundle-umu Don't build and bundle umu-run with Proton"
    _message "  umu-only      Only build the static umu-run self-extracting executable"
    _message "  rearchive     Just re-bundle umu-run and proton into the final tarball. You must have already built proton to use this, but umu will be rebuilt."
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
    _message "  rearchive: ${_do_rearchive}"
}
##############################################
# Run
##############################################
_main "$@"
