#!/bin/bash
pkgver=9-7
buildname="proton-osu"
pkgname="${buildname}-${pkgver}"

protonurl=https://github.com/GloriousEggroll/proton-ge-custom.git
protontag=GE-Proton9-16
protonsdk="registry.gitlab.steamos.cloud/proton/sniper/sdk:latest"

umu_protonfixesurl=https://github.com/Open-Wine-Components/umu-protonfixes.git
umu_launcherurl=https://github.com/Open-Wine-Components/umu-launcher.git

##############################################
# Do everything
##############################################
_main() {
    _envsetup || _failure "Failed preparing build environment."
    _dirsetup_initial || _failure "Failed initial directory setup."
    _parse_args "$@"

    if [ "${_do_umu_only}" = "true" ]; then
        _sources umu || _failure "Failed to prepare umu sources."
        _patch umu || _failure "Failed to apply umu patches."
        _build_umu_run || _failure "Building umu-run failed."
        _message "umu-run has been built and is located at: ${scriptdir}/umu-build/umu-run"
    elif [ "${_do_build}" = "true" ]; then
        _sources || _failure "Failed to prepare sources."
        _patch proton wine umu || _failure "Failed to apply patches."
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
    scriptdir="$(realpath "$(dirname "$0")")" && export scriptdir
    srcdir="${scriptdir}/proton" && export srcdir
    builddir="${scriptdir}/build" && export builddir
    mkdir -p "${builddir}"

    build_out_dir="${scriptdir}/build_tarballs"
    mkdir -p "${build_out_dir}"

    patchdir="${scriptdir}/patches" && export patchdir

    umu_launcher_dir="${scriptdir}/umu-launcher" && export umu_launcher_dir
    umu_bundler_dir="${scriptdir}/umu-bundler" && export umu_bundler_dir
    umu_build_dir="${scriptdir}/umu-build" && export umu_build_dir
}
##############################################
# Environment
##############################################
_envsetup() {
    export WINEESYNC=0
    export WINEFSYNC=0
    export DISPLAY=

    CPUs="$(($(nproc) + 1))" && export CPUs
    export MAKEFLAGS="-j$CPUs"
    export NINJAFLAGS="-j$CPUs"
    export SUBJOBS="$CPUs"
}
##############################################
# Patches
##############################################
_patch() {
    [ -z "${*}" ] && _failure "No directories specified to _patch."

    for subdir in "${@}"; do
        local target_dir
        case "${subdir}" in
            proton) target_dir="${srcdir}" ;;
            wine) target_dir="${srcdir}/${subdir}" ;;
            umu) target_dir="${umu_launcher_dir}" ;;
            *) _failure "Unknown patch target: ${subdir}" ;;
        esac

        cd "${target_dir}" || _failure "Specified root directory to apply patches doesn't exist: ${target_dir}"

        mapfile -t patchlist < <(find "${patchdir}/${subdir}" -type f -regex ".*\.patch" | LC_ALL=C sort -f)

        for patch in "${patchlist[@]}"; do
            shortname="${patch#"${patchdir}/"}"
            _message "Applying ${shortname}"
            patch -Np1 <"${patch}" || _failure "Couldn't apply ${shortname}"
        done

        if [ "${subdir}" = "proton" ] && [[ "${protonurl}" =~ "GloriousEggroll" ]]; then
            _message "Applying GE patches"
            ./patches/protonprep-valve-staging.sh || _failure "Couldn't apply a GE protonprep patch"
        fi

        if [ "${subdir}" = "proton" ]; then
            find make/*mk Makefile.in -execdir sed -i \
                -e "s/[\$]*(SUBJOBS)/$CPUs/g" \
                -e "s/J = \$(patsubst -j%,%,\$(filter -j%,\$(MAKEFLAGS)))/J = $CPUs/" \
                -e "s/J := \$(shell nproc)/J := $CPUs/" \
                '{}' +
        fi
    done
    return 0;
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
    cd "${scriptdir}" || _failure "Failed to change to script directory."

    local oxidize_dir="${umu_launcher_dir}/oxidize"
    local work_dir="${umu_bundler_dir}/work"
    local sentinel_file="${umu_bundler_dir}/util/pyoxidizer_bootstrap_info.sh"

    mkdir -p "${umu_build_dir}"

    [ -f "$sentinel_file" ] && {
        source "$sentinel_file"
        [ "$BOOTSTRAP_COMPLETE" != "true" ] && {
            "${umu_bundler_dir}/pyoxidizer_bootstrap.sh" || {
                _warning "PyOxidizer bootstrap failed. Skipping umu-run build."
                return 1
            }
            source "$sentinel_file"
        }
    } || {
        "${umu_bundler_dir}/pyoxidizer_bootstrap.sh" || {
            _warning "PyOxidizer bootstrap failed. Skipping umu-run build."
            return 1
        }
        source "$sentinel_file"
    }

    rm -rf "${work_dir}"
    mkdir -p "${work_dir}"

    cd "${umu_launcher_dir}" || _failure "Failed to change directory to ${umu_launcher_dir}"
    ./configure.sh --user-install || _failure "Failed to run configure.sh for umu-launcher"
    make version || _failure "Failed to run make version for umu-launcher"

    mkdir -p "${oxidize_dir}"
    cp "${umu_bundler_dir}/util/pyoxidizer.bzl" "${oxidize_dir}/"

    cd "${oxidize_dir}" || _failure "Failed to change directory to ${oxidize_dir}"

    case $PYOXIDIZER_INSTALL in
        venv)
            source "$PYOXIDIZER_VENV/bin/activate"
            pyoxidizer build --release --target-triple x86_64-unknown-linux-musl || _failure "PyOxidizer build failed"
            deactivate
            ;;
        *)
            pyoxidizer build --release --target-triple x86_64-unknown-linux-musl || _failure "PyOxidizer build failed"
            ;;
    esac

    # Create the self-extracting wrapper
    "${umu_bundler_dir}/create_self_extracting_wrapper.sh" \
        "${work_dir}" \
        "${oxidize_dir}" \
        "${umu_bundler_dir}" \
        "${umu_build_dir}" || _failure "Failed to create self-extracting wrapper"

    _message "Static umu-run built successfully"
    rm -rf "${umu_bundler_dir}/work"
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
    local components=("umu-launcher")
    [ "$1" != "umu" ] && components+=("proton" "protonfixes")

    cd "${scriptdir}" || _failure "Couldn't change to script directory."

    for component in "${components[@]}"; do
        case $component in
            proton)
                _repo_updater "proton" "${protonurl}" "${protontag}"
                ;;
            protonfixes)
                _repo_updater "protonfixes" "${umu_protonfixesurl}"
                [ -d "${srcdir}"/protonfixes ] && rm -rf "${srcdir}"/protonfixes
                cp -r "${scriptdir}"/protonfixes "${srcdir}"/protonfixes
                ;;
            umu-launcher)
                _repo_updater "umu-launcher" "${umu_launcherurl}"
                ;;
        esac
    done

    _message "Sources are ready."
}

_repo_updater() {
    local repo_path="$1"
    local repo_url="$2"
    local specific_ref="$3"

    _message "Ensuring ${repo_path} is up-to-date."

    if [ ! -d "${repo_path}" ]; then
        _message "Cloning ${repo_path}."
        git clone --depth 1 "${repo_url}" "${repo_path}" ||
            _failure "Couldn't clone the ${repo_path} repository."
        local is_new_clone=true
    fi

    cd "${repo_path}" || _failure "Couldn't change directory to ${repo_path}."

    # set a fake git config so it's not prompted
    git config commit.gpgsign false &>/dev/null || true
    git config user.email "proton@umu.builder" &>/dev/null || true
    git config user.name "umubuilder" &>/dev/null || true
    git config advice.detachedHead false &>/dev/null || true

    git fetch --depth 1 origin

    local target_ref="${specific_ref:-origin/HEAD}"

    # Check if the repository needs to be updated or cleaned
    if [ "${is_new_clone}" = "true" ] || [ -n "$(git status --porcelain)" ] || [ "$(git rev-parse HEAD)" != "$(git rev-parse ${target_ref})" ]; then
        _message "The ${repo_path} repository will be set to a clean state at ${target_ref}."

        # Reset and clean the main repository
        git reset --hard
        git clean -ffdx

        if [ -n "${specific_ref}" ]; then
            git fetch --depth 1 origin "${specific_ref}:refs/remotes/origin/${specific_ref}" || true

            # Tag case
            if git rev-parse "refs/tags/${specific_ref}" >/dev/null 2>&1; then
            {
                git checkout -f "${specific_ref}" &&
                _message "Checked out ${repo_path} at tag ${specific_ref}."
            } || _failure "Couldn't check out your tag."
            else # Branch case
            {
                git checkout -B "${specific_ref}" "origin/${target_ref}" &&
                _message "Checked out ${repo_path} at branch ${specific_ref} targeting origin/${target_ref}."
            } || _failure "Couldn't check out your tag."
            fi
        else
            # Otherwise just reset to origin/HEAD
            git reset --hard origin/HEAD
        fi

        # Keep submodules updated
        if [ -f ".gitmodules" ]; then
            _message "Updating submodules for ${repo_path}."
            git submodule update --init --depth 1 --recursive -f
            # shellcheck disable=SC2016
            git submodule foreach --recursive '
                if [ -n "$(git status --porcelain)" ]; then
                    git reset --hard
                    git clean -ffdx
                fi
            ' 2>/dev/null
        fi

        _message "Cleaned files from ${repo_path}"
    else
        _message "The ${repo_path} repository is already up-to-date and clean."
    fi

    # Delete any old tags we made
    git tag -l "local-*" | xargs -r git tag -d

    # Create a new "fake" tag at the current position with a timestamp, so that proton/protonfixes/umu-launcher is happy when versioning the build
    local timestamp=$(date +%Y%m%d%H%M%S)
    local current_branch=$(git rev-parse --abbrev-ref HEAD)
    local local_tag="local-${current_branch}-${timestamp}"
    local commit_hash=$(git rev-parse HEAD)
    git tag -a -f "${local_tag}" -m "Local build tag for ${current_branch} at ${timestamp}" "${commit_hash}"
    _message "Created temporary tag ${local_tag} for ${repo_path} to use in versioning."

    cd "${scriptdir}" || _failure "Couldn't change directory back to script's directory (somehow.)"
}
##############################################
# Terminal output
##############################################
_message() {
    [ -n "$*" ] && echo -e '\033[1;34m'"Message:\033[0m $*" || echo ""
}

_warning() {
    [ -n "$*" ] && echo -e '\033[1;33m'"Warning:\033[0m $*" || echo ""
}

_failure() {
    [ -n "$*" ] && echo -e '\033[1;31m'"Error:\033[0m $*"
    echo -e '\033[1;31m'"Exiting.\033[0m Run './setup.sh help' to see available options."
    exit 1
}

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
    _message "  Build: ${_do_build}"
    _message "  Install: ${_do_install}"
    _message "  Bundle UMU: ${_do_bundle_umu}"
    _message "  Clean Build: ${_do_cleanbuild}"
    _message "  UMU Only: ${_do_umu_only}"
}
##############################################
# Run
##############################################
_main "$@"