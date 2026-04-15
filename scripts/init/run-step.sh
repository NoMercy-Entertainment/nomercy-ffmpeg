#!/bin/bash
# ──────────────────────────────────────────────────────────────
# run-step.sh — Execute a single FFmpeg dependency build script
#
# Usage: /scripts/init/run-step.sh <script-filename>
#   e.g. /scripts/init/run-step.sh 01-iconv.sh
#
# Sources helpers.sh so the script has access to:
#   add_enable, add_cflag, add_ldflag, add_extralib, check_enabled
#
# Exit codes:
#   0   — script succeeded or was skipped (exit 255)
#   1   — script failed
# ──────────────────────────────────────────────────────────────

SCRIPT_NAME="$1"
SCRIPT_PATH="/scripts/${SCRIPT_NAME}"

if [ ! -f "${SCRIPT_PATH}" ]; then
    echo "❌ Script not found: ${SCRIPT_PATH}"
    exit 1
fi

# Source helper functions so build scripts can call add_enable, etc.
. /scripts/init/helpers.sh
export -f hr text_with_padding add_enable add_cflag add_ldflag add_extralib \
         join_lines split_lines clean_whitespace apply_sed check_enabled log

# Extract human-readable name from filename (e.g. "01-iconv.sh" → "ICONV")
NAME="${SCRIPT_NAME#*-}"
NAME="${NAME%.sh}"
NAME="${NAME^^}"

echo "------------------------------------------------------"
echo "🛠️ Building ${NAME}"
echo "------------------------------------------------------"

chmod +x "${SCRIPT_PATH}"
START_TIME=$(date +%s)

set +e
"${SCRIPT_PATH}"
RESULT=$?
set -e

END_TIME=$(( $(date +%s) - START_TIME ))

if [ ${RESULT} -eq 255 ]; then
    echo "➖ ${NAME} skipped (not needed for ${TARGET_OS} ${ARCH})"
    exit 0
elif [ ${RESULT} -eq 0 ]; then
    if [ ${END_TIME} -gt 60 ]; then
        echo "✅ ${NAME} built successfully ($(( END_TIME / 60 ))m)"
    else
        echo "✅ ${NAME} built successfully (${END_TIME}s)"
    fi
    exit 0
else
    echo "❌ ${NAME} FAILED after ${END_TIME}s (exit code ${RESULT})"
    exit 1
fi
