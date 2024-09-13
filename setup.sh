#!/bin/bash
pkgrel=9-1
pkgname="proton-osu-${pkgrel}"
protonurl=https://github.com/CachyOS/proton-cachyos.git
umu_protonfixesurl=https://github.com/Open-Wine-Components/umu-protonfixes.git
gittag=cachyos-9.0-20240905

##############################################
# Do everything
##############################################
_run_all() {
    if [[ "${*}" =~ .*help.* ]]; then
        _help
    fi

    if     [[ "${*}" =~ ^build ]] && [[ "${*}" =~ "install" ]] ||
       ! { [[ "${*}" =~ ^build ]] || [[ "${*}" =~ "install" ]] ; }; then
        _message "Fully building and installing."
        _prepare
        _build "$@" &&
        _install
    elif [[ "${*}" =~ ^build ]]; then
        _message "Only building."
        _prepare
        _build "$@" || _failure "Build failed."
    elif [[ "${*}" =~ "install" ]]; then
        _message "Only installing."
        _dirsetup
        _envsetup
        _install || _failure "Install failed."
    else
        _message "Invalid arguments."
        _help
    fi
    exit 0
}
##############################################
# Help message
##############################################
_prepare() {
    { _dirsetup &&
      _envsetup &&
      _sources &&
      _patch proton wine ; } ||
    _failure "Failed preparing build."
}
##############################################
# Download sources
##############################################
_sources() {
    if ! { [ -d "${srcdir}" ] && [ -f "${srcdir}"/Makefile ] ; }; then
        git clone --depth 1 --recurse-submodules --shallow-submodules "${protonurl}" "${srcdir}" -b "${gittag}" || _failure "Couldn't clone your chosen repo at the tag."
    fi

    rm -rf "${srcdir}"/protonfixes

    if ! { [ -d "${scriptdir}"/protonfixes ] && [ -f "${scriptdir}"/protonfixes/Makefile ] ; }; then
        git clone --depth 1 --recurse-submodules --shallow-submodules "${umu_protonfixesurl}" "${scriptdir}"/protonfixes || _failure "Couldn't add the required umu-protonfixes repo."
    fi

    for tree in "${srcdir}" "${scriptdir}"/protonfixes; do cd "${tree}" && git reset --hard --recurse-submodules HEAD; done
    cp -r "${scriptdir}"/protonfixes "${srcdir}"/protonfixes
    cd "${scriptdir}"
    _message "Sources are ready."
}
##############################################
# Directories
##############################################
_dirsetup() {
    scriptdir="$(pwd)" && export scriptdir

    srcdir="${scriptdir}"/proton && export srcdir
    builddir="${scriptdir}"/build && export builddir
    if [ ! -d "${builddir}" ]; then mkdir "${builddir}"; fi

    patchdir="${scriptdir}"/patches && export patchdir

    # Currently hardcoded in the Makefile anyways, but we can switch to other manual installation methods easily
    # A tar.xz file is dropped in the build/ directory as well
    installdir="${HOME}"/.steam/root/compatibilitytools.d/"${pkgname}" && export installdir
}
##############################################
# Env
##############################################
_envsetup() {
    # Try to sanitize my own PATH
    if [[ "${PATH}" =~ "llvm-mingw" ]]; then
        _mingw_path="$(dirname "$(command -v i686-w64-mingw32-clang)")"
        _cross_path="${PATH//"${_mingw_path}":/}"
    else
        _cross_path="${PATH}"
    fi
    export PATH="${_cross_path}"

    export protonsdk="registry.gitlab.steamos.cloud/proton/sniper/sdk:latest"

    # For wineprefix setup during build
    export WINEESYNC=0
    export WINEFSYNC=0
    unset DISPLAY

    CPUs="$(nproc)"
    export MAKEFLAGS="-j$CPUs"
    export NINJAFLAGS="-j$CPUs"
    export SUBJOBS="$CPUs"
}
##############################################
# Patches
##############################################
_patch() {
    cd "${srcdir}" || _failure "No source dir!"

    if [ -z "${*}" ]; then _failure "The _patch function needs (a) patch subdirector(y/ies)."; fi

    for subdir in "${@}"; do
        # "hack" to support patches that are rooted in wine
        if [ "${subdir}" = "wine" ]; then 
            cd "${srcdir}/wine" &&
            git clean -xdf
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

    "${srcdir}"/configure.sh \
        --container-engine="docker" \
        --proton-sdk-image="${protonsdk}" \
        --enable-ccache \
        --build-name="${pkgname}" || _failure "Configuring proton failed."

    if [[ "${*}" =~ "cleanbuild" ]]; then 
        _message "Cleaning build directory."
        make clean
    fi

    if ! [[ "${*}" =~ "wineonly" ]]; then
        make -j1 redist &&
        mv "${builddir}/${pkgname}".tar.xz "${scriptdir}" &&
        _message "${builddir}/${pkgname}.tar.xz is now ready in the current directory"
    else
        make wineonly # not sure why this isn't working
    fi
}
##############################################
# Install
##############################################
_install() {
    cd "${builddir}" || _failure "Can't install because there is no build directory."

    make install || _failure "make install didn't succeed"

    ## TODO: fix this
    ## Dirty hack copied from proton-cachyos pkg (I don't know either...)
    #########
    # For some unknown to me reason, 32bit vkd3d (not vkd3d-proton) always links
    # to libgcc_s_dw2-1.dll no matter what linker options I tried.
    # Copy the required dlls into the package, they will be copied later into the prefix
    # by the patched proton script. Bundle them to not depend on mingw-w64-gcc being installed.

    # { cp /usr/i686-w64-mingw32/bin/{libgcc_s_dw2-1.dll,libwinpthread-1.dll} \
    #     "${installdir}"/files/lib/vkd3d/ &&
    #   cp /usr/x86_64-w64-mingw32/bin/{libgcc_s_seh-1.dll,libwinpthread-1.dll} \
    #     "${installdir}"/files/lib64/vkd3d/ ; } ||
    #   _failure "Couldn't copy mingw files from /usr/{i686,x86_64}-w64-mingw/bin files to the install directory, you should install mingw-gcc."
    
    _message "Build done, it should be installed to ~/.steam/root/compatibilitytools.d/${pkgname}"
    _message "Along with the archive in the current directory"
}
##############################################
# Log messages
##############################################
_message() {
    if [ -n "$*" ]; then
        echo ""
        echo -e '\033[1;34m'"Notice:\033[0m $*"
    else
        echo ""
    fi
}
_failure() {
    if [ -n "$*" ]; then echo -e '\033[1;31m'"Error:\033[0m $*"; fi
    echo -e '\033[1;31m'"Exiting.\033[0m"
    exit 1
}
_help() {
    _message "./setup.sh [help] [build] [install]"
    _message "No arguments grabs sources, patches, builds, and installs"
    _exit 0
}
##############################################
# Main
##############################################

_run_all "$@"
