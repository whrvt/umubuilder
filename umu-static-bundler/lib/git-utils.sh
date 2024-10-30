#!/bin/bash

_repo_updater() {
    local repo_path="$1"
    local repo_url="$2"
    local specific_ref="${3:-}"
    local timestamp
    timestamp=$(date +%Y%m%d%H%M%S)

    export GIT_COMMITTER_NAME="umubuilder"
    export EMAIL="proton@umu.builder"

    _configure_git() {
        git config user.email "proton@umu.builder"
        git config user.name "umubuilder"
        git config advice.detachedHead false
        git config commit.gpgsign false
        git config core.compression 0
        git config pack.compression 0
        git config core.looseCompression 0
        git config pack.window 0
        git config pack.depth 0
        git config pack.deltaCacheSize 1
        git config pack.packSizeLimit 100m
        git config fetch.unpackLimit 1
        git config fetch.writeCommitGraph false
        git config gc.auto 0
        git config gc.autoDetach false
        git config submodule.fetchJobs "$(nproc)"
        git config protocol.version 2
        git config core.excludesFile /dev/null
    }

    _message "Ensuring ${repo_path} is up-to-date"

    # Handle initial clone if needed
    local is_new_clone=false
    if [ ! -d "${repo_path}" ]; then
        _message "Cloning ${repo_url} to ${repo_path}."
        GIT_CONFIG_COUNT=6 \
            GIT_CONFIG_KEY_0="core.compression" GIT_CONFIG_VALUE_0="0" \
            GIT_CONFIG_KEY_1="pack.compression" GIT_CONFIG_VALUE_1="0" \
            GIT_CONFIG_KEY_2="core.looseCompression" GIT_CONFIG_VALUE_2="0" \
            GIT_CONFIG_KEY_3="pack.window" GIT_CONFIG_VALUE_3="0" \
            GIT_CONFIG_KEY_4="pack.depth" GIT_CONFIG_VALUE_4="0" \
            GIT_CONFIG_KEY_5="pack.deltaCacheSize" GIT_CONFIG_VALUE_5="1" \
            git -c protocol.version=2 clone --filter=blob:none --depth 1 --no-tags \
            --single-branch "${repo_url}" "${repo_path}" || _failure "Clone failed."
        is_new_clone=true
    fi

    cd "${repo_path}" || _failure "Couldn't change to ${repo_path}."

    # Minimal config just to avoid prompts
    git config commit.gpgsign false
    git config user.email "proton@umu.builder"
    git config user.name "umubuilder"
    git config advice.detachedHead false

    local target_ref="origin/HEAD"
    if [ -n "${specific_ref}" ]; then
        target_ref="${specific_ref}"
        # Quick fetch of specific ref
        GIT_CONFIG_COUNT=2 \
            GIT_CONFIG_KEY_0="core.compression" GIT_CONFIG_VALUE_0="0" \
            GIT_CONFIG_KEY_1="pack.compression" GIT_CONFIG_VALUE_1="0" \
            git fetch --depth 1 origin "${specific_ref}:refs/remotes/origin/${specific_ref}" || true
    fi

    # Check if we need to do anything
    if [ "${is_new_clone}" = "true" ] || [ -n "$(git status --porcelain)" ] || [ "$(git rev-parse HEAD)" != "$(git rev-parse ${target_ref})" ]; then
        _message "Setting repository to clean state at ${target_ref}"

        # Now do full configuration since we need to update
        _configure_git

        git reset --hard
        git clean -ffdx

        # Handle checkout based on ref type
        if git rev-parse "refs/tags/${target_ref}" >/dev/null 2>&1; then
            git checkout -f "${target_ref}"
        elif [ -n "${specific_ref}" ]; then
            git checkout -B "${specific_ref}" "origin/${target_ref}"
        else
            git reset --hard origin/HEAD
        fi

        # Handle submodules if present
        if [ -f ".gitmodules" ]; then
            _message "Updating submodules recursively"
            git -c fetch.recurseSubmodules=false \
                -c submodule.fetchJobs="$(nproc)" \
                -c remote.origin.partialclonefilter=blob:none \
                -c protocol.version=2 \
                -c core.compression=0 \
                -c pack.compression=0 \
                submodule update --init --depth 1 --recursive --force --jobs="$(nproc)"

            # Clean up any dirty submodules
            # shellcheck disable=SC2016
            git submodule foreach --recursive '
                git config core.compression 0
                git config pack.compression 0

                if [ -n "$(git status --porcelain)" ]; then
                    git reset --hard
                    git clean -ffdx
                fi

                # Tag submodule with same timestamp if it has content
                if [ -n "$(git ls-files)" ]; then
                    branch=$(git rev-parse --abbrev-ref HEAD)
                    hash=$(git rev-parse HEAD)
                    tag_name="local-${branch}-'"${timestamp}"'"
                    git tag -a -f "${tag_name}" -m "Local build tag for ${branch} at '"${timestamp}"'" "${hash}"
                    git checkout -q "${tag_name}"
                fi
            '
        fi
    else
        _message "Repository already at correct revision and clean."
    fi

    # Handle local tagging for versioning
    git tag -l "local-*" | xargs -r git tag -d
    local current_branch
    current_branch=$(git rev-parse --abbrev-ref HEAD)
    local tag_name="local-${current_branch}-${timestamp}"
    local commit_hash
    commit_hash=$(git rev-parse HEAD)
    git tag -a -f "${tag_name}" -m "Local build tag for ${current_branch} at ${timestamp}" "${commit_hash}"
    git checkout -q "${tag_name}"
}

# Apply patches to a target directory following a structured patch directory layout
# Usage: _patch_dir <target_dir> <patch_dir> [<patch_opts>...]
# Example: _patch_dir "${srcdir}/wine" "${patchdir}/wine" ["extra_opts"...]
_patch_dir() {
    local target_dir="$1"
    local patch_dir="$2"
    shift 2
    local patch_opts=("$@")
    local shortname

    [ ! -d "${target_dir}" ] && _failure "Target directory doesn't exist: ${target_dir}"
    [ ! -d "${patch_dir}" ] && return 0 # No patches to apply is not an error

    cd "${target_dir}" || _failure "Failed to change to target directory: ${target_dir}"

    # Find and sort patches
    mapfile -t patchlist < <(find "${patch_dir}" -type f -regex ".*\.patch" | LC_ALL=C sort -f)

    # Apply each patch
    for patch in "${patchlist[@]}"; do
        shortname="${patch#"${patch_dir}/"}"
        _message "Applying ${shortname}"
        patch -Np1 "${patch_opts[@]}" <"${patch}" || _failure "Failed to apply ${shortname}"
    done

    return 0
}

# Legacy wrapper for proton build script compatibility
# Usage: _patch proton|wine [<extra_opts>...]
_patch() {
    [ -z "${*}" ] && _failure "No directories specified to _patch."
    [ -z "${srcdir:-}" ] && _failure "srcdir is not set"
    [ -z "${patchdir:-}" ] && _failure "patchdir is not set"
    [ -z "${CPUs:-}" ] && CPUs=$(($(nproc) + 1))

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
