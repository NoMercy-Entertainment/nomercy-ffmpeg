#!/usr/bin/env bash
# Minimal CI smoke gate: assert the freshly-built binary runs, reports the
# expected version, and exits cleanly. This is NOT the full codec suite — that
# is tests/tests.sh, run manually on real hardware by a contributor.
#
# Usage: smoke.sh <workspace_dir> <expected_version> [platform]
#
# Cross-arch note: a platform built for a different CPU arch than its smoke-test
# runner (e.g. linux-aarch64 on an x86_64 runner) cannot execute. ONLY for such
# known cross-arch platforms do we accept the exec-format failure (exit 126 /
# "Exec format error") and fall back to a presence+non-empty check. On a native
# platform ANY non-zero exit — including 126 — is a real failure, so a broken
# native binary can never slip through as "cross-arch".
set -uo pipefail

WORKSPACE="${1:?workspace dir required}"
EXPECTED_VERSION="${2:?expected version required}"
PLATFORM="${3:-}"

fail() { echo "❌ $*" >&2; exit 1; }
note() { echo "ℹ️  $*"; }
ok()   { echo "✅ $*"; }

# Platforms whose binary is built for a different arch than its smoke-test
# runner and therefore cannot be executed there. Keep in sync with the build
# matrix if another cross-arch target is added.
is_cross_arch_platform() {
  case "$1" in
    linux-aarch64) return 0 ;;
    *)             return 1 ;;
  esac
}

ffmpeg_bin="${WORKSPACE}/ffmpeg"
ffprobe_bin="${WORKSPACE}/ffprobe"

[[ -f "${ffmpeg_bin}"  ]] || fail "ffmpeg binary not found at ${ffmpeg_bin}"
[[ -f "${ffprobe_bin}" ]] || fail "ffprobe binary not found at ${ffprobe_bin}"
[[ -s "${ffmpeg_bin}"  ]] || fail "ffmpeg binary is empty"
[[ -s "${ffprobe_bin}" ]] || fail "ffprobe binary is empty"
chmod +x "${ffmpeg_bin}" "${ffprobe_bin}" 2>/dev/null || true

is_exec_format_error() {
  echo "$1" | grep -qiE "exec format error|cannot execute binary file"
}

assert_version() {  # bin, banner
  local bin="$1" banner="$2" out code
  out="$("${bin}" -version 2>&1)"; code=$?
  if [[ ${code} -ne 0 ]]; then
    if is_cross_arch_platform "${PLATFORM}" && { [[ ${code} -eq 126 ]] || is_exec_format_error "${out}"; }; then
      note "Cross-arch (${PLATFORM}): $(basename "${bin}") present but not executable here — presence check only."
      return 10   # signal: cross-arch, skip remaining version asserts
    fi
    echo "${out}"; fail "$(basename "${bin}") -version exited ${code}"
  fi
  echo "${out}" | grep -q "${banner}" || { echo "${out}"; fail "missing '${banner}' banner"; }
  echo "${out}" | grep -q "${EXPECTED_VERSION}" || { echo "${out}"; fail "expected version ${EXPECTED_VERSION} not found"; }
  ok "$(basename "${bin}") reports version ${EXPECTED_VERSION} and exits 0"
  return 0
}

assert_version "${ffmpeg_bin}" "ffmpeg version"; rc=$?
if [[ ${rc} -eq 10 ]]; then
  ok "Smoke (presence-only) passed for cross-arch binaries."
  exit 0
fi
assert_version "${ffprobe_bin}" "ffprobe version"
ok "Smoke test passed."
