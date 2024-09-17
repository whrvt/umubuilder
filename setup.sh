#!/bin/bash
pkgver=9-4
buildname="proton-osu"
pkgname="${buildname}-${pkgver}"

protonurl=https://github.com/CachyOS/proton-cachyos.git
protontag=cachyos_9.0_20240917
umu_protonfixesurl=https://github.com/Open-Wine-Components/umu-protonfixes.git
protonsdk="registry.gitlab.steamos.cloud/proton/sniper/sdk:latest"

##############################################
# Do everything
##############################################
_main() {
    if [[ "${*}" =~ .*help.* ]]; then
        _help
    fi

    if     [[ "${*}" =~ ^build ]] && [[ "${*}" =~ "install" ]] ||
       ! { [[ "${*}" =~ ^build ]] || [[ "${*}" =~ "install" ]] ; }; then
        _message "Fully building and installing."
        _prepare "$@"
        _build "$@" &&
        _install
    elif [[ "${*}" =~ ^build ]]; then
        _message "Only building."
        _prepare "$@"
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
# Prepare for a full build
##############################################
_prepare() {
    { _dirsetup &&
      _envsetup &&
      _sources "$@" &&
      _patch proton wine ; } ||
    _failure "Failed preparing build."
}
##############################################
# Download sources
##############################################
_sources() {
    if [[ "${*}" =~ "reclone" ]]; then rm -rf "${srcdir}"; fi
    if ! { [ -d "${srcdir}" ] && [ -f "${srcdir}"/Makefile ] ; }; then
        git clone --depth 1 --recurse-submodules --shallow-submodules "${protonurl}" "${srcdir}" -b "${protontag}" || _failure "Couldn't clone your chosen repo at the tag."
    fi

    # Keep protonfixes up-to-date, since we don't pin it to a specific version 
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
    # For wineprefix setup during build
    export WINEESYNC=0
    export WINEFSYNC=0
    unset DISPLAY

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
        --build-name="${buildname}" || _failure "Configuring proton failed."

    if [[ "${*}" =~ "cleanbuild" ]]; then 
        _message "Cleaning build directory."
        make clean
    fi

    if ! [[ "${*}" =~ "wineonly" ]]; then
        make -j1 redist &&
        mv "${builddir}/${buildname}".tar.xz "${scriptdir}/${pkgname}.tar.xz" &&
        cp "${builddir}/${buildname}".sha512sum "${scriptdir}/${pkgname}.sha512sum" &&
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

    _message "Build done, it should be installed to ~/.steam/root/compatibilitytools.d/${pkgname}"
    _message "Along with the archive in the current directory"
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
_failure() {
    if [ -n "$*" ]; then echo -e '\033[1;31m'"Error:\033[0m $*"; fi
    echo -e '\033[1;31m'"Exiting.\033[0m"
    exit 1
}
_help() {
    _message "./setup.sh [help] [reclone] [build (cleanbuild)] [install]"
    _message "No arguments grabs sources, patches, builds, and installs"
    _message "Adding 'cleanbuild' just runs 'make clean' in the build directory before 'make'"
    _message "'reclone' redownloads sources, use this if your sources are outdated"
    exit 0
}
##############################################
# Run main function
##############################################

_main "$@"
