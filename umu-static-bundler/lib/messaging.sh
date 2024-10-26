#!/bin/bash
# Messaging utilities for build scripts

_message() {
    printf "\033[0;32m[+] %s\033[0m\n" "$*" >&2
}

_warning() {
    printf "\033[0;33m[!] %s\033[0m\n" "$*" >&2
}

_error() {
    printf "\033[0;31m[-] %s\033[0m\n" "$*" >&2
}

_failure() {
    _error "$*"
    exit 1
}
