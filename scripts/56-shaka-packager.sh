#!/bin/bash

#/******************************************/#
#/*  NoMercy Entertainment — shaka-packager */#
#/*  Pre-built binary download + staging   */#
#/******************************************/#
#
# shaka-packager v3.7.2 — BSD-3-Clause
# https://github.com/shaka-project/shaka-packager/releases/tag/v3.7.2
#
# This script downloads the official pre-built static binary for the
# current build target and stages it next to ffmpeg in /ffmpeg/${TARGET_OS}/${ARCH}/
# so it is included in the distribution tarball/zip.
#
# No compilation required — shaka-packager ships fully static binaries.
#
# SHA256 verification:
# TODO: pin SHA256 — fetch real hashes from
#   https://github.com/shaka-project/shaka-packager/releases/tag/v3.7.2
# Once fetched, replace each EXPECTED_SHA with the real value and remove this block.

SHAKA_VERSION="v3.7.2"
BASE_URL="https://github.com/shaka-project/shaka-packager/releases/download/${SHAKA_VERSION}"

# Resolve platform binary name
if [[ "${TARGET_OS}" == "windows" ]]; then
    BINARY_NAME="packager-win-x64.exe"
    DEST_NAME="packager.exe"
elif [[ "${TARGET_OS}" == "darwin" ]]; then
    if [[ "${ARCH}" == "arm64" ]]; then
        BINARY_NAME="packager-osx-arm64"
    else
        BINARY_NAME="packager-osx-x64"
    fi
    DEST_NAME="packager"
else
    # linux
    if [[ "${ARCH}" == "aarch64" ]]; then
        BINARY_NAME="packager-linux-arm64"
    else
        BINARY_NAME="packager-linux-x64"
    fi
    DEST_NAME="packager"
fi

DOWNLOAD_URL="${BASE_URL}/${BINARY_NAME}"
DEST_DIR="/ffmpeg/${TARGET_OS}/${ARCH}"
DEST_PATH="${DEST_DIR}/${DEST_NAME}"

log "Downloading shaka-packager ${SHAKA_VERSION} (${BINARY_NAME})"

mkdir -p "${DEST_DIR}"

curl -fsSL --retry 3 --retry-delay 5 \
    -o "${DEST_PATH}" \
    "${DOWNLOAD_URL}" \
    || { log "ERROR: Failed to download ${DOWNLOAD_URL}"; exit 1; }

# TODO: verify SHA256 once hashes are pinned (see top of file).
# sha256sum -c <(echo "${EXPECTED_SHA}  ${DEST_PATH}")

if [[ "${TARGET_OS}" != "windows" ]]; then
    chmod +x "${DEST_PATH}"
    log "Set executable bit on ${DEST_PATH}"
fi

# Verify the binary exists and is non-empty
if [[ ! -s "${DEST_PATH}" ]]; then
    log "ERROR: ${DEST_PATH} is empty or missing after download"
    exit 1
fi

log "shaka-packager ${SHAKA_VERSION} staged at ${DEST_PATH}"

exit 0
