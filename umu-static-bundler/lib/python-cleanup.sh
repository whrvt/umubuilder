#!/bin/bash

# Run DEBUG=1 ./(build.sh or setup.sh [umu-only]) to see debug output from the python-cleaner.py

_cleanup_python_dist() {
    local cleanup_python_dir="$1"
    local python_dir="$2"

    [[ ! -d "${python_dir}" ]] && _failure "Python directory not found at ${python_dir}"

    local original_size
    original_size=$(du -sh "${python_dir}" | cut -f1)
    _message "Initial Python distribution size: ${original_size}"

    _message "Running Python distribution cleaner..."
    "${cleanup_python_dir}/bin/python3" "${u_scriptdir}/lib/python-cleaner.py" \
        "${python_dir}" \
        "${u_work_dir}/umu-launcher" \
        --config "${u_scriptdir}/lib/umu-cleaner-config.py" \
        ${DEBUG:+--debug} || _failure "Python distribution cleanup failed"

    # Metadata
    find "${python_dir}" -type f -name "*.py" \
        -exec sed -i '/^#.*coding/d;/^#.*Author/d;/^#.*Copyright/d' {} +

    local final_size
    final_size=$(du -sh "${python_dir}" | cut -f1)

    _message "Python distribution cleaned successfully!"
    _message "Size reduced from ${original_size} to ${final_size}"
}
