#!/bin/bash

# Git repository management utilities
# This module provides robust git repository handling with features like:
# - Clean checkouts from specific refs
# - Submodule handling
# - Local build versioning tags
# - Repository state verification
# - Patching

_repo_updater() {
    local repo_path="$1"
    local repo_url="$2"
    local specific_ref="${3:-}"
    local is_new_clone=false

    _message "Ensuring ${repo_path} is up-to-date."

    if [ ! -d "${repo_path}" ]; then
        _message "Cloning ${repo_path}."
        git clone --depth 1 "${repo_url}" "${repo_path}" ||
            _failure "Couldn't clone the ${repo_path} repository."
        is_new_clone=true
    fi

    cd "${repo_path}" || _failure "Couldn't change directory to ${repo_path}."

    # set a fake git config so it's not prompted
    git config commit.gpgsign false &>/dev/null || true
    git config user.email "proton@umu.builder" &>/dev/null || true
    git config user.name "umubuilder" &>/dev/null || true
    git config advice.detachedHead false &>/dev/null || true

    local target_ref="${specific_ref:-origin/HEAD}"

    # For unshallow fetching specific commits while keeping other fetches shallow
    if [ -n "${specific_ref}" ] && [[ "${specific_ref}" =~ ^[0-9a-f]{5,40}$ ]]; then
        # If it looks like a commit hash, deepen until we find it
        local depth=1
        while ! git cat-file -e "${specific_ref}^{commit}" 2>/dev/null; do
            if [ ${depth} -gt 100 ]; then
                _failure "Commit ${specific_ref} not found within reasonable history"
            fi
            _message "Deepening repository to find commit ${specific_ref}..."
            depth=$((depth * 2))
            git fetch --depth=${depth} origin || true
        done
        target_ref="${specific_ref}"
    else
        git fetch --depth 1 origin
        if [ -n "${specific_ref}" ]; then
            git fetch --depth 1 origin "${specific_ref}:refs/remotes/origin/${specific_ref}" || true
        fi
    fi

    # Check if the repository needs to be updated or cleaned
    if [ "${is_new_clone}" = "true" ] || [ -n "$(git status --porcelain)" ] || [ "$(git rev-parse HEAD)" != "$(git rev-parse ${target_ref})" ]; then
        _message "The ${repo_path} repository will be set to a clean state at ${target_ref}."

        # Reset and clean the main repository
        git reset --hard
        git clean -ffdx

        if [ -n "${specific_ref}" ]; then
            if git cat-file -e "${specific_ref}^{commit}" 2>/dev/null; then
                # Direct commit checkout
                git checkout -f "${specific_ref}" &&
                _message "Checked out ${repo_path} at commit ${specific_ref}."
            elif git rev-parse "refs/tags/${specific_ref}" >/dev/null 2>&1; then
                # Tag checkout
                git checkout -f "${specific_ref}" &&
                _message "Checked out ${repo_path} at tag ${specific_ref}."
            else
                # Branch checkout
                git checkout -B "${specific_ref}" "origin/${specific_ref}" &&
                _message "Checked out ${repo_path} at branch ${specific_ref}."
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
    [ ! -d "${patch_dir}" ] && return 0  # No patches to apply is not an error

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