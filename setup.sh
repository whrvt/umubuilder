#!/bin/bash
pkgver=9-4
buildname="proton-osu"
pkgname="${buildname}-${pkgver}"

protonurl=https://github.com/CachyOS/proton-cachyos.git
protontag=cachyos_9.0_20240917
protonsdk="registry.gitlab.steamos.cloud/proton/sniper/sdk:latest"

umu_protonfixesurl=https://github.com/Open-Wine-Components/umu-protonfixes.git
umu_launcherurl=https://github.com/Open-Wine-Components/umu-launcher.git

##############################################
# Do everything
##############################################
_main() {
    { _dirsetup && _envsetup ; } || _failure "Failed preparing script environment."

    if [ "${_do_build}" = "true" ]; then {
        _sources &&
        _patch proton wine &&
        _build
        } || _failure "Build failed."
    fi

    if [ "${_do_install}" = "true" ]; then
        _install || _failure "Install failed."
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

    # messed up way to build&install if either "build install" is specified or neither are specified
    if     [[ "${*}" =~ ^build ]] && [[ "${*}" =~ "install" ]] ||
       ! { [[ "${*}" =~ ^build ]] || [[ "${*}" =~ "install" ]] ; }; then
        _do_build=true
        _do_install=true
        _message "Will build Proton and also install it to the Steam compatibility tools directory."
    elif [[ "${*}" =~ ^build ]]; then
        _do_build=true
        _message "Will only be building Proton without installing it."
    elif [[ "${*}" =~ "install" ]]; then
        _do_install=true
        _message "Will only install the already built files to the Steam compatibility tools directory."
        return
    fi

    if [[ "${*}" =~ "reclone" ]]; then
        _do_reclone=true
        _message "Will reclone sources before bulding."
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
# Download sources
##############################################
_sources() {
    if [ "${_do_reclone}" = "true" ]; then rm -rf "${srcdir}"; fi

    if ! { [ -d "${srcdir}" ] && [ -f "${srcdir}"/Makefile ] ; }; then
        git clone --depth 1 --recurse-submodules --shallow-submodules "${protonurl}" "${srcdir}" -b "${protontag}" ||
            _failure "Couldn't clone your chosen Proton repo at the tag."
    fi

    git -C "${srcdir}" reset --hard --recurse-submodules HEAD ||
        _failure "Couldn't reset the Proton sources to their original state."

    # Keep protonfixes up-to-date, since we don't pin it to a specific version 
    rm -rf "${srcdir}"/protonfixes "${scriptdir}"/protonfixes
    git clone --depth 1 --recurse-submodules --shallow-submodules "${umu_protonfixesurl}" "${scriptdir}"/protonfixes ||
        _failure "Couldn't add the required umu-protonfixes repo."
    cp -r "${scriptdir}"/protonfixes "${srcdir}"/protonfixes

    if [ "${_do_bundle_umu}" = "true" ]; then
        # Same with umu-launcher, if we want that
        rm -rf "${scriptdir}"/umu-launcher
        git clone --depth 1 --recurse-submodules --shallow-submodules "${umu_launcherurl}" "${scriptdir}"/umu-launcher ||
            _failure "Couldn't add the umu-launcher repo you wanted."
    fi

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

    make -j1 redist &&
    if [ "${_do_bundle_umu}" = "true" ]; then 
        cd "${scriptdir}"/umu-launcher && ./configure.sh --user-install && mkdir pkg && make DESTDIR=pkg install && cd "${builddir}"
        rm -rf "${buildname}"/umu-run
        shopt -s globstar
    	cp -a "${scriptdir}"/umu-launcher/pkg/**/.local/bin/umu-run "${buildname}"/umu-run
        shopt -u globstar
    fi &&
    _message "Creating archive: ${pkgname}.tar.xz" &&
    XZ_OPT="-9 -T0" tar -Jcf "${scriptdir}"/"${pkgname}".tar.xz --numeric-owner --owner=0 --group=0 --null "${buildname}" &&
    sha512sum "${scriptdir}"/"${pkgname}".tar.xz > "${scriptdir}"/"${pkgname}".sha512sum &&
    _message "${pkgname}.tar.xz is now ready in the current directory"
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
    echo -e '\033[1;31m'"Exiting.\033[0m Run './setup.sh help' to see some available options."
    exit 1
}
_help() {
    _message "./setup.sh [help] [reclone] [build (cleanbuild)] [bundle-umu] [install]"
    echo ""
    _message "No arguments grabs sources, patches, builds, and installs"
    _message "Adding 'build' will only build without installing to the steam compatibility tools directory"
    _message "  Adding 'cleanbuild' just runs 'make clean' in the build directory before 'make'"
    _message "  Adding 'no-bundle-umu' WON'T build the latest umu-launcher from master and place 'umu-run' it in Proton's toplevel directory"
    _message "Adding 'install' will only install to the steam compatibility tools directory without rebuilding"
    _message "Adding 'reclone' redownloads sources, use this if your sources are outdated"

    exit 0
}
##############################################
# Parse arguments and run main function
##############################################
_parse_args "$@"
_main
