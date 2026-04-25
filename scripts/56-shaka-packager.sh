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
# Hashes computed from the official v3.7.2 GitHub release assets on
# 2026-04-25. Update this block whenever SHAKA_VERSION is bumped.

SHAKA_VERSION="v3.7.2"
BASE_URL="https://github.com/shaka-project/shaka-packager/releases/download/${SHAKA_VERSION}"

# Resolve platform binary name + expected sha256
if [[ "${TARGET_OS}" == "windows" ]]; then
    BINARY_NAME="packager-win-x64.exe"
    DEST_NAME="packager.exe"
    EXPECTED_SHA="61e26b68884c81d107ebd5b7ba6499bfa5a589b90245dac9683c5d50f999574a"
elif [[ "${TARGET_OS}" == "darwin" ]]; then
    if [[ "${ARCH}" == "arm64" ]]; then
        BINARY_NAME="packager-osx-arm64"
        EXPECTED_SHA="e755c7fb6f913e2c6de32efcf2a330f233110bfe3dc1b496d897e54d6d1ec9a6"
    else
        BINARY_NAME="packager-osx-x64"
        EXPECTED_SHA="7f68db502c09807f013758885a3de259a641dc2258cb95011c4af0b203dca028"
    fi
    DEST_NAME="packager"
else
    # linux
    if [[ "${ARCH}" == "aarch64" ]]; then
        BINARY_NAME="packager-linux-arm64"
        EXPECTED_SHA="e4a43aaa8fdb87d0306876bc41581b371d7082e9d1b8469aef06a4e74004fd69"
    else
        BINARY_NAME="packager-linux-x64"
        EXPECTED_SHA="88b022b8cb12602ddb539972efd07a3496ea64f8662a484798c96e95afa41fd8"
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

ACTUAL_SHA=$(sha256sum "${DEST_PATH}" | awk '{print $1}')
if [[ "${ACTUAL_SHA}" != "${EXPECTED_SHA}" ]]; then
    log "ERROR: SHA256 mismatch for ${BINARY_NAME}"
    log "  expected: ${EXPECTED_SHA}"
    log "  actual:   ${ACTUAL_SHA}"
    rm -f "${DEST_PATH}"
    exit 1
fi
log "SHA256 verified for ${BINARY_NAME}"

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
