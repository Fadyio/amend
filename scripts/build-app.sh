#!/usr/bin/env bash
set -euo pipefail

# 1. Determine repository root safely
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "==> Packaging MacDub.app from ${REPO_ROOT}"

# 2. Build macdub in release configuration
echo "==> Building release executable (swift build -c release --product macdub)..."
swift build -c release --product macdub --package-path "${REPO_ROOT}"

# 3. Determine the actual SwiftPM release binary directory
RELEASE_BIN_DIR="$(swift build -c release --package-path "${REPO_ROOT}" --show-bin-path)"
EXECUTABLE_SRC="${RELEASE_BIN_DIR}/macdub"

if [[ ! -x "${EXECUTABLE_SRC}" ]]; then
    echo "ERROR: Built executable not found or not executable at: ${EXECUTABLE_SRC}" >&2
    exit 1
fi

# 4. Create bundle directory layout
DIST_DIR="${REPO_ROOT}/dist"
APP_DIR="${DIST_DIR}/MacDub.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "==> Preparing bundle directory at ${APP_DIR}..."
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

# 5. Copy executable into bundle
echo "==> Installing executable into Contents/MacOS/MacDub..."
cp "${EXECUTABLE_SRC}" "${MACOS_DIR}/MacDub"
chmod +x "${MACOS_DIR}/MacDub"

# 6. Copy Info.plist
PLIST_SRC="${REPO_ROOT}/Packaging/Info.plist"
if [[ ! -f "${PLIST_SRC}" ]]; then
    echo "ERROR: Packaging Info.plist not found at ${PLIST_SRC}" >&2
    exit 1
fi
echo "==> Installing Info.plist..."
cp "${PLIST_SRC}" "${CONTENTS_DIR}/Info.plist"

# 7. Copy SwiftPM resource bundles (if any are produced)
shopt -s nullglob
RESOURCE_BUNDLES=("${RELEASE_BIN_DIR}"/*.bundle)
if [[ ${#RESOURCE_BUNDLES[@]} -gt 0 ]]; then
    echo "==> Copying SwiftPM resource bundles to Contents/Resources/..."
    for b in "${RESOURCE_BUNDLES[@]}"; do
        echo "    Copying $(basename "${b}")..."
        cp -R "${b}" "${RESOURCES_DIR}/"
    done
fi
shopt -u nullglob

# Check for optional app icon
if [[ -f "${REPO_ROOT}/Packaging/AppIcon.icns" ]]; then
    echo "==> Copying AppIcon.icns to Contents/Resources/..."
    cp "${REPO_ROOT}/Packaging/AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"
fi

# 8. Validate Info.plist and executable
echo "==> Validating Info.plist..."
plutil -lint "${CONTENTS_DIR}/Info.plist"

if [[ ! -x "${MACOS_DIR}/MacDub" ]]; then
    echo "ERROR: Packaged executable missing or not executable at ${MACOS_DIR}/MacDub" >&2
    exit 1
fi

# 9. Local ad-hoc code signing and verification
echo "==> Ad-hoc code signing bundle..."
codesign --force --deep --sign - "${APP_DIR}"

echo "==> Verifying code signature..."
codesign --verify --deep --strict "${APP_DIR}"

echo "==> Successfully packaged: ${APP_DIR}"
