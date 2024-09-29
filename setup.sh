#!/bin/bash
pkgver=9-6
buildname="proton-osu"
pkgname="${buildname}-${pkgver}"

protonurl=https://github.com/CachyOS/proton-cachyos.git
protontag=cachyos-9.0-20240918
protonsdk="registry.gitlab.steamos.cloud/proton/sniper/sdk:latest"

umu_protonfixesurl=https://github.com/Open-Wine-Components/umu-protonfixes.git
umu_launcherurl=https://github.com/Open-Wine-Components/umu-launcher.git

##############################################
# Do everything
##############################################
_main() {
    _script_realpath=$(realpath "$(dirname "$0")")

    _envsetup || _failure "Failed preparing build environment."
    _dirsetup_initial || _failure "Failed initial directory setup."

    if [ "${_do_build}" = "true" ]; then
        _sources || _failure "Failed to prepare sources."
        _patch proton wine || _failure "Failed to apply patches."
        _build || _failure "Build failed."
        if [ "${_do_install}" = "true" ]; then
            _install || _failure "Install failed."
        fi
    fi

    _message "Script finished."
    exit 0
}
##############################################
# Parse arguments (badly, PRs welcome :^) )
##############################################
_parse_args() {
    # will exit early here if help specified
    if [[ "${*}" =~ .*help.* ]]; then _help; fi

    if [[ "${*}" =~ "buildonly" ]]; then
        _do_build=true
        _message "Will only be building Proton without installing it."
    else
        _do_build=true
        _do_install=true
        _message "Will build Proton and also install it to the Steam compatibility tools directory."
    fi

    if [[ "${*}" =~ "no-bundle-umu" ]]; then
        _do_bundle_umu=false
        _message "Won't bundle umu-run with Proton."
    else
        _do_bundle_umu=true
        _message "Will bundle umu-run with Proton."
    fi
    if [[ "${*}" =~ "cleanbuild" ]]; then
        _do_cleanbuild=true
        _message "Will run 'make clean' before building."
    fi
    if [[ "${*}" =~ "wineonly" ]]; then
        _do_build_wine_only=true
        _message "Will only build wine without the rest of Proton's sources (BROKEN)"
    fi
}
##############################################
# Directories
##############################################
_dirsetup_initial() {
    scriptdir="${_script_realpath}" && export scriptdir
    srcdir="${scriptdir}/proton" && export srcdir
    builddir="${scriptdir}/build" && export builddir
    if [ ! -d "${builddir}" ]; then mkdir "${builddir}"; fi

    build_out_dir="${scriptdir}/build_tarballs"
    if [ ! -d "${build_out_dir}" ]; then mkdir "${build_out_dir}"; fi

    patchdir="${scriptdir}/patches" && export patchdir
}
##############################################
# Environment
##############################################
_envsetup() {
    # For wineprefix setup during build
    export WINEESYNC=0
    export WINEFSYNC=0
    export DISPLAY=

    CPUs="$(nproc)" && export CPUs
    export MAKEFLAGS="-j$CPUs"
    export NINJAFLAGS="-j$CPUs"
    export SUBJOBS="$CPUs"
}
##############################################
# Patches
##############################################
_patch() {
    cd "${srcdir}" || _failure "No source dir!"

    if [ -z "${*}" ]; then _failure "There were no directories specified to _patch."; fi

    for subdir in "${@}"; do
        # "hack" to support patches that are rooted in wine
        if [ "${subdir}" = "wine" ]; then 
            cd "${srcdir}/wine"
        fi

        mapfile -t patchlist < <(find "${patchdir}/${subdir}" -type f -regex ".*\.patch" | LC_ALL=C sort -f)

        for patch in "${patchlist[@]}"; do
            shortname="${patch#"${scriptdir}/"}"
            _message "Applying ${shortname}"
            patch -Np1 <"${patch}" || _failure "Couldn't apply ${shortname}"
        done
    done

    cd "${srcdir}"

    # Hardcode #CPUs in files to speed up compilation and avoid strange substitution problems
    find make/*mk Makefile.in -execdir sed -i "s/[\$]*(SUBJOBS)/$CPUs/g" '{}' +
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

    if [ "${_do_cleanbuild}" = "true" ]; then 
        _message "Cleaning build directory."
        make clean
    fi

    make -j1 redist || _failure "Build failed."

    if [ "${_do_bundle_umu}" = "true" ]; then 
        cd "${scriptdir}"/umu-launcher && ./configure.sh --user-install && mkdir pkg && make DESTDIR=pkg install && cd "${builddir}"
        rm -rf "${buildname}"/umu-run
        shopt -s globstar
        cp -a "${scriptdir}"/umu-launcher/pkg/**/.local/bin/umu-run "${buildname}"/umu-run
        shopt -u globstar
    fi

    _message "Creating archive: ${pkgname}.tar.xz" &&
    XZ_OPT="-9 -T0" tar -Jcf "${build_out_dir}"/"${pkgname}".tar.xz --numeric-owner --owner=0 --group=0 --null "${buildname}" &&
    sha512sum "${build_out_dir}"/"${pkgname}".tar.xz > "${build_out_dir}"/"${pkgname}".sha512sum &&
    _message "${pkgname}.tar.xz is now ready in the build_tarballs directory"
}
##############################################
# Install
##############################################
_install() {
    cd "${builddir}" || _failure "Can't install because there is no build directory."

    make install || _failure "make install didn't succeed"

    _message "Build done, it should be installed to ~/.steam/root/compatibilitytools.d/${buildname}"
    _message "Along with the archive in the current directory"
}
##############################################
# Source preparation
##############################################
_sources() {
    cd "${scriptdir}" || _failure "Couldn't change to script directory."

    _repo_updater "proton" "${protonurl}" "${protontag}"

    _repo_updater "protonfixes" "${umu_protonfixesurl}"

    # Clean protonfixes from Proton and copy the new one
    if [ -d "proton/protonfixes" ]; then rm -rf "proton/protonfixes"; fi
    cp -r "protonfixes" "proton/protonfixes"

    if [ "${_do_bundle_umu}" = "true" ]; then
        _repo_updater "umu-launcher" "${umu_launcherurl}"
    fi

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
            git submodule update --init --depth 1 --recursive
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
# Log messages
##############################################
_message() {
    if [ -n "$*" ]; then
        echo -e '\033[1;34m'"Message:\033[0m $*"
    else
        echo ""
    fi
}
_warning() {
    if [ -n "$*" ]; then
        echo -e '\033[1;33m'"Message:\033[0m $*"
    else
        echo ""
    fi
}
_failure() {
    if [ -n "$*" ]; then echo -e '\033[1;31m'"Error:\033[0m $*"; fi
    echo -e '\033[1;31m'"Exiting.\033[0m Run './setup.sh help' to see some available options."
    exit 1
}
_help() {
    _message "./setup.sh [help] [buildonly] [cleanbuild] [no-bundle-umu]"
    echo ""
    _message "No arguments grabs sources, patches, builds, and installs"
    _message "  Adding 'buildonly' will only build without installing to the steam compatibility tools directory"
    _message "  Adding 'cleanbuild' just runs 'make clean' in the build directory before 'make'"
    _message "  Adding 'no-bundle-umu' WON'T build the latest umu-launcher from master and place 'umu-run' in Proton's toplevel directory"

    exit 0
}
##############################################
# Parse arguments and run main function
##############################################
_parse_args "$@"
_main
