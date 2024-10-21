#!/bin/sh

# Creates an executable file called `umu-run`, which extracts the python
# umu-run and umu_version.json into the directory it's run in, and moves itself to
# an .umu-run-zip backup file

# Warning: mostly LLM-generated
# Don't do this at home

set -e

UMU_BUILD_DIR="./build/x86_64-unknown-linux-musl/release/install"

create_temp_dir() {
    mktemp -d 2>/dev/null || mktemp -d -t 'umutmp' 2>/dev/null || {
        dir="/tmp/umu-$RANDOM-$RANDOM-$RANDOM"
        mkdir -p "$dir" 2>/dev/null && echo "$dir"
    }
}

TEMP_DIR=$(create_temp_dir) || { echo "Failed to create temp directory" >&2; exit 1; }
trap 'rm -rf "$TEMP_DIR"' EXIT

for file in umu-run umu_version.json prctl_helper; do
    [ -f "$UMU_BUILD_DIR/$file" ] || { echo "$file not found" >&2; exit 1; }
    cp -- "$UMU_BUILD_DIR/$file" "$TEMP_DIR/$file" || { echo "Failed to copy $file" >&2; exit 1; }
done

cat > umu-run << 'EOL'
#!/bin/sh

set -e

create_temp_dir() {
    mktemp -d 2>/dev/null || mktemp -d -t 'umutmp' 2>/dev/null || {
        dir="/tmp/umu-$RANDOM-$RANDOM-$RANDOM"
        mkdir -p "$dir" 2>/dev/null && echo "$dir"
    }
}

TEMP_DIR=$(create_temp_dir) || { echo "Failed to create temp directory" >&2; exit 1; }
trap 'rm -rf "$TEMP_DIR"' EXIT

get_script_dir() {
    SCRIPT_PATH="$0"
    if command -v readlink >/dev/null 2>&1; then
        SCRIPT_PATH=$(readlink -f "$SCRIPT_PATH" 2>/dev/null) || SCRIPT_PATH="$0"
    fi
    dirname -- "$SCRIPT_PATH"
}

SCRIPT_DIR=$(get_script_dir)

ARCHIVE_START=$(awk '/^__ARCHIVE_BELOW__$/ {print NR + 1; exit 0;}' "$0")

if ! tail -n +"$ARCHIVE_START" "$0" | (cd "$TEMP_DIR" && tar xzf -) 2>/dev/null; then
    echo "Failed to extract archive" >&2
    exit 1
fi

mv_with_fallback() {
    mv -- "$1" "$2" 2>/dev/null || { cp -a -- "$1" "$2" && rm -rf -- "$1"; }
}

mv_with_fallback "$0" "$SCRIPT_DIR/.umu-run-zip" || { echo "Failed to rename self" >&2; exit 1; }

for file in umu-run umu_version.json prctl_helper; do
    mv_with_fallback "$TEMP_DIR/$file" "$SCRIPT_DIR/$file" || { echo "Failed to move $file" >&2; exit 1; }
done

chmod +x -- "$SCRIPT_DIR/umu-run" 2>/dev/null || true

exec "$SCRIPT_DIR/umu-run" "$@"

__ARCHIVE_BELOW__
EOL

{ cd "$TEMP_DIR" && tar czf - .; } >> umu-run || { echo "Failed to append archive" >&2; exit 1; }

chmod +x -- umu-run 2>/dev/null || true

echo "Self-extracting executable 'umu-run' created successfully."
