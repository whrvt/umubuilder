#!/bin/bash

SENTINEL_FILE="pyoxidizer_bootstrap_info.sh"

check_sentinel() {
    if [ -f "$SENTINEL_FILE" ]; then
        source "$SENTINEL_FILE"
        [ "$BOOTSTRAP_COMPLETE" = "true" ] && {
            echo "Bootstrap previously completed successfully. Skipping checks."
            return 0
        }
    fi
    return 1
}

write_sentinel() {
    echo "BOOTSTRAP_COMPLETE=true" > "$SENTINEL_FILE"
    echo "PYOXIDIZER_INSTALL=$1" >> "$SENTINEL_FILE"
    [ "$1" = "venv" ] && echo "PYOXIDIZER_VENV=$2" >> "$SENTINEL_FILE"
}

install_pyoxidizer() {
    if command -v pipx &> /dev/null; then
        echo "Installing PyOxidizer 0.23.0 using pipx..."
        pipx list | grep -q "pyoxidizer" && pipx uninstall pyoxidizer
        pipx install pyoxidizer==0.23.0 || {
            echo "Failed to install PyOxidizer using pipx. Check your pipx installation and try again."
            return 1
        }
        write_sentinel "pipx"
    elif command -v pip &> /dev/null; then
        if [ -z "$VIRTUAL_ENV" ]; then
            echo "Not in a virtual environment. It's recommended to install PyOxidizer in a virtual environment."
            read -p "Create a virtual environment and install PyOxidizer? (y/n) " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                python3 -m venv pyoxidizer_env
                source pyoxidizer_env/bin/activate
                echo "Virtual environment 'pyoxidizer_env' created and activated."
                write_sentinel "venv" "$(pwd)/pyoxidizer_env"
            else
                echo "Proceeding with system-wide installation."
                write_sentinel "system"
            fi
        else
            write_sentinel "venv" "$VIRTUAL_ENV"
        fi

        echo "Installing PyOxidizer 0.23.0 using pip..."
        pip install pyoxidizer==0.23.0 --force-reinstall || {
            echo "Failed to install PyOxidizer. Check your pip installation and try again."
            return 1
        }
    else
        echo "Neither pipx nor pip is available. Install one of them and try again."
        return 1
    fi

    echo "PyOxidizer 0.23.0 installed successfully."
    return 0
}

check_pyoxidizer() {
    if ! command -v pyoxidizer &> /dev/null; then
        echo "PyOxidizer is not installed."
        read -p "Install PyOxidizer 0.23.0? (y/n) " -n 1 -r
        echo
        [[ $REPLY =~ ^[Yy]$ ]] && install_pyoxidizer
        return $?
    fi

    local version=$(pyoxidizer --version | awk '{print $2}')
    if ! [[ "${version}" =~ "0.23.0" ]]; then
        echo "PyOxidizer version 0.23.0 is required, but version $version is installed."
        read -p "Install PyOxidizer 0.23.0? (y/n) " -n 1 -r
        echo
        [[ $REPLY =~ ^[Yy]$ ]] && install_pyoxidizer
        return $?
    fi
    return 0
}

install_rust_target() {
    if command -v rustup &> /dev/null; then
        echo "Installing x86_64-unknown-linux-musl target using rustup..."
        rustup target add x86_64-unknown-linux-musl || {
            echo "Failed to add x86_64-unknown-linux-musl target using rustup."
            return 1
        }
        echo "x86_64-unknown-linux-musl target installed successfully."
        return 0
    else
        echo "rustup is not available. Install the Rust musl target manually."
        echo "On Arch Linux, use: pacman -S rust-musl"
        echo "On other distributions, check your package manager for a musl target package for Rust."
        return 1
    fi
}

check_rust() {
    if ! command -v rustc &> /dev/null; then
        echo "Rust is not installed. Install Rust and try again."
        return 1
    fi

    if ! rustc --print target-list | grep -q "x86_64-unknown-linux-musl"; then
        echo "The x86_64-unknown-linux-musl target is not available for Rust."
        read -p "Install the x86_64-unknown-linux-musl target? (y/n) " -n 1 -r
        echo
        [[ $REPLY =~ ^[Yy]$ ]] && install_rust_target
        return $?
    fi

    temp_dir=$(mktemp -d)
    [ -z "$temp_dir" ] || [ ! -d "$temp_dir" ] && {
        echo "Could not create temporary directory"
        return 1
    }

    echo 'fn main() { println!("Hello, world!"); }' > "$temp_dir/test.rs"

    rustc --target x86_64-unknown-linux-musl -o "$temp_dir/test" "$temp_dir/test.rs" &> /dev/null || {
        echo "Unable to compile for x86_64-unknown-linux-musl target."
        echo "Ensure that the necessary libraries and linker are installed."
        rm -rf "$temp_dir"
        return 1
    }

    rm -rf "$temp_dir"
    return 0
}

check_python() {
    if ! command -v python3 &> /dev/null; then
        echo "Python 3 is not installed. Install Python 3 and try again."
        return 1
    fi
    return 0
}

check_dependencies() {
    check_sentinel && return 0

    local all_deps_met=true

    check_python || all_deps_met=false
    check_pyoxidizer || all_deps_met=false
    check_rust || all_deps_met=false

    if [ "$all_deps_met" = true ]; then
        echo "All dependencies are met. Bootstrap complete."
        write_sentinel "system"
        return 0
    else
        echo "Some dependencies are not met. Address the issues above and try again."
        return 1
    fi
}

check_dependencies
exit $?