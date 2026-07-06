#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname)" == "Linux" ]]; then
    LINUX_LIB=$(ls -d "$HOME"/.local/share/swiftly/toolchains/*/usr/lib/swift/linux 2>/dev/null | tail -1 || true)
    if [[ -n "${LINUX_LIB:-}" ]]; then
        export LD_LIBRARY_PATH="${LINUX_LIB}:${LD_LIBRARY_PATH:-}"
    fi
fi

swift build
swift test "$@"
