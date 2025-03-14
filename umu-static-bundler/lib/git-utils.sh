#!/bin/bash

#############################################################
# _repo_updater : git clone --recurse-submodules but better #
#############################################################
# - Clean checkouts from specific refs
# - Submodule handling
# - Local build versioning tags
# - Repository state verification

_repo_updater() {
    local cache_dir="$1/.cache"
    local repo_path="$2"
    local repo_url="$3"
    local specific_ref="${4:-}"
    local is_new_clone=false
    local timestamp=$(date +%Y%m%d%H%M%S)

    _message "Ensuring ${repo_path} is up-to-date."

    if [ ! -d "${repo_path}" ]; then
        _message "Cloning ${repo_path}."
        git clone --depth 1 "${repo_url}" "${repo_path}" ||
            _failure "Couldn't clone the ${repo_path} repository."
        is_new_clone=true
    elif [ "$(git -C ${repo_path} remote get-url origin)" != "${repo_url}" ]; then
        git -C "${repo_path}" remote set-url origin "${repo_url}"
    fi

    cd "${repo_path}" || _failure "Couldn't change directory to ${repo_path}."

    # Set optimal git configuration for shallow clones
    export GIT_COMMITTER_NAME="umubuilder"
    export EMAIL="proton@umu.builder"
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

    local target_ref="${specific_ref:-origin/HEAD}"

    # specific commit hashes need special handling, setup a cache to speed it up on subsequent runs
    mkdir -p "${cache_dir}"

    local repo_cache="${cache_dir}/$(basename "${repo_path}")"
    if [ ! -d "${repo_cache}" ]; then
        git init --bare "${repo_cache}" >/dev/null 2>&1
        git -C "${repo_cache}" config core.compression 0
    fi

    if [ -n "${specific_ref}" ] && [[ "${specific_ref}" =~ ^[0-9a-f]{5,40}$ ]]; then
        # Check if commit exists in cache
        if git -C "${repo_cache}" cat-file -e "${specific_ref}^{commit}" 2>/dev/null; then
            _message "Found commit ${specific_ref} in cache"
            # Fetch from cache into main repository
            git remote add cache "${repo_cache}" 2>/dev/null || git remote set-url cache "${repo_cache}"
            git fetch --depth 1 cache "${specific_ref}"
        else
            # Fetch branch metadata and recent commits
            git fetch --depth 1 origin '+refs/heads/*:refs/remotes/origin/*'

            # Get list of remote branches sorted by most recently modified
            local branches
            branches=$(git for-each-ref --sort=-committerdate refs/remotes/origin --format='%(refname)')

            # Try each branch with a slightly deeper history
            local found_branch=""
            while IFS= read -r branch; do
                # Skip origin/HEAD
                [[ "${branch}" == "refs/remotes/origin/HEAD" ]] && continue

                # Deepen this branch by a few commits
                branch_name="${branch#refs/remotes/origin/}"
                _message "Checking branch ${branch_name} for commit ${specific_ref}"
                git fetch --depth 10 origin "${branch_name}"

                if git branch -r --contains "${specific_ref}" | grep -q "${branch#refs/remotes/}"; then
                    found_branch="${branch_name}"
                    break
                fi
            done <<<"${branches}"

            if [ -n "${found_branch}" ]; then
                # Found the branch, fetch it with history
                _message "Found commit ${specific_ref} in branch ${found_branch}"
                git fetch --depth 1 origin "${found_branch}"
            else
                # Fallback to incremental deepening if branch not found
                local depth=1
                while ! git cat-file -e "${specific_ref}^{commit}" 2>/dev/null; do
                    if [ ${depth} -gt 100 ]; then
                        _failure "Commit ${specific_ref} not found within reasonable history"
                    fi
                    _message "Deepening repository to find commit ${specific_ref}..."
                    depth=$((depth * 2))
                    git fetch --depth=${depth} origin || true
                done
            fi

            # If we found the commit, cache it for future use
            if git cat-file -e "${specific_ref}^{commit}" 2>/dev/null; then
                _message "Caching commit ${specific_ref} for future use"
                # Create a temporary packfile containing just this commit
                local pack_dir=$(mktemp -d)
                git rev-parse "${specific_ref}" >"${pack_dir}/want"
                git rev-list --objects --no-walk --stdin <"${pack_dir}/want" >"${pack_dir}/objects"
                git pack-objects --stdout <"${pack_dir}/objects" >"${pack_dir}/pack"

                # Import the packfile into our cache
                cat "${pack_dir}/pack" | git -C "${repo_cache}" unpack-objects -q
                git -C "${repo_cache}" update-ref "refs/heads/cached-${specific_ref}" "${specific_ref}"
                rm -rf "${pack_dir}"
            fi
        fi
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
            submodule_error=$(mktemp)
            if ! git submodule update --init --depth 1 --recursive -f --progress 2> >(tee "${submodule_error}" >&2); then
                # If it fails, check if it's due to directory conflicts
                if grep -q "destination path.*already exists and is not an empty directory" "${submodule_error}"; then
                    # Extract the problematic path from the error message
                    local conflict_path
                    conflict_path=$(grep "destination path.*already exists" "${submodule_error}" | sed -E "s/.*path '(.*)' already exists.*/\1/")
                    if [ -n "${conflict_path}" ] && [ -d "${conflict_path}" ] && [ ! -d "${conflict_path}/.git" ]; then
                        # Safety check: ensure the conflict path is under repo_path
                        local abs_repo_path
                        local abs_conflict_path
                        abs_repo_path=$(cd "${repo_path}" && pwd)
                        abs_conflict_path=$(cd "$(dirname "${conflict_path}")" && pwd)/$(basename "${conflict_path}")
                        if [[ "${abs_conflict_path}" == "${abs_repo_path}"* ]]; then
                            _message "Removing conflicting directory: ${conflict_path}"
                            rm -rf "${conflict_path}"
                            # Retry the submodule update
                            git submodule update --init --depth 1 --recursive -f || _failure "Submodule update failed after cleaning conflict"
                        else
                            _failure "Security check failed: conflicting path ${conflict_path} is outside repository"
                        fi
                    else
                        _failure "Submodule update failed: $(cat "${submodule_error}")"
                    fi
                else
                    _failure "Submodule update failed: $(cat "${submodule_error}")"
                fi
            fi

            _message "Cleaning and tagging submodules recursively for ${repo_path}."

            # shellcheck disable=SC2016
            git submodule foreach --recursive '
                if [ -n "$(git status --porcelain)" ]; then
                    git reset --hard
                    git clean -ffdx
                fi
                # Tag submodule with same timestamp if it has content
                if [ -n "$(git ls-files)" ]; then
                    git tag -l "local-*" | xargs -r git tag -d
                    branch=$(git rev-parse --abbrev-ref HEAD)
                    hash=$(git rev-parse HEAD)
                    tag_name="local-${branch}-'"${timestamp}"'"
                    git tag -a -f "${tag_name}" -m "Local build tag for ${branch} at '"${timestamp}"'" "${hash}"
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
    local current_branch=$(git rev-parse --abbrev-ref HEAD)
    local local_tag="local-${current_branch}-${timestamp}"
    local commit_hash=$(git rev-parse HEAD)
    git tag -a -f "${local_tag}" -m "Local build tag for ${current_branch} at ${timestamp}" "${commit_hash}"
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
