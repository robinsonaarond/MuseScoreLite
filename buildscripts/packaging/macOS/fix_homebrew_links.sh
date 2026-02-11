#!/usr/bin/env bash

# Rewrites Homebrew-linked Mach-O load commands inside a packaged .app so the
# app resolves all bundled dependencies from Contents/Frameworks.

set -euo pipefail

APP_BUNDLE="${1:-}"
if [[ -z "${APP_BUNDLE}" ]]; then
    echo "Usage: $0 /path/to/App.app"
    exit 1
fi

if [[ ! -d "${APP_BUNDLE}/Contents" ]]; then
    echo "Not an app bundle: ${APP_BUNDLE}"
    exit 1
fi

fix_file() {
    local file="$1"
    local dep=""
    local rel=""
    local replacement=""
    local otool_output=""

    # Skip non-Mach-O files quickly.
    otool_output="$(otool -L "${file}" 2>/dev/null || true)"
    if [[ -z "${otool_output}" ]]; then
        return 0
    fi
    if [[ "${otool_output}" == *"is not an object file"* ]]; then
        return 0
    fi

    while IFS= read -r dep; do
        [[ "${dep}" == /opt/homebrew/* ]] || continue

        rel=""
        if [[ "${dep}" =~ /([^/]+\.framework)/Versions/([^/]+)/([^/]+)$ ]]; then
            rel="${BASH_REMATCH[1]}/Versions/${BASH_REMATCH[2]}/${BASH_REMATCH[3]}"
        elif [[ "${dep}" =~ /([^/]+\.dylib)$ ]]; then
            rel="${BASH_REMATCH[1]}"
        fi

        [[ -n "${rel}" ]] || continue
        [[ -e "${APP_BUNDLE}/Contents/Frameworks/${rel}" ]] || continue

        replacement="@executable_path/../Frameworks/${rel}"
        install_name_tool -change "${dep}" "${replacement}" "${file}"
    done < <(printf '%s\n' "${otool_output}" | awk 'NR > 1 { print $1 }')

    while IFS= read -r rpath; do
        [[ "${rpath}" == /opt/homebrew* ]] || continue
        install_name_tool -delete_rpath "${rpath}" "${file}" || true
    done < <(otool -l "${file}" | awk '/LC_RPATH/ { getline; getline; print $2 }')

    # Normalize install IDs of bundled framework/dylib binaries so they don't
    # keep a Homebrew-prefixed ID.
    if [[ "${file}" == "${APP_BUNDLE}/Contents/Frameworks/"* ]]; then
        rel="${file#${APP_BUNDLE}/Contents/Frameworks/}"
        replacement="@executable_path/../Frameworks/${rel}"
        install_name_tool -id "${replacement}" "${file}" || true
    fi
}

while IFS= read -r macho_file; do
    fix_file "${macho_file}"
done < <(find "${APP_BUNDLE}/Contents" -type f \( -path "*/MacOS/*" -o -path "*/Frameworks/*" -o -path "*/PlugIns/*" \))
