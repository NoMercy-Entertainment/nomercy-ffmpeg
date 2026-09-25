#!/usr/bin/env bash
# Tests tests/smoke.sh against stub ffmpeg/ffprobe binaries (shell scripts).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SMOKE="${HERE}/smoke.sh"
PASS=0; FAIL=0

make_stub() {  # dir, name, version_string, exit_code
  local dir="$1" name="$2" ver="$3" code="$4"
  cat > "${dir}/${name}" <<EOF
#!/usr/bin/env bash
echo "${name} version ${ver} Copyright (c) the FFmpeg developers"
exit ${code}
EOF
  chmod +x "${dir}/${name}"
}

make_execfmt_stub() {  # dir, name — emulates running a foreign-arch binary
  local dir="$1" name="$2"
  cat > "${dir}/${name}" <<EOF
#!/usr/bin/env bash
echo "${name}: cannot execute binary file: Exec format error" >&2
exit 126
EOF
  chmod +x "${dir}/${name}"
}

# Like make_stub, but carries the literal string smoke.sh's
# cpu_variant_dispatcher_compiled_in() greps for, so this stub reads as a
# dispatcher-enabled binary. crash_on_override=1 makes it exit non-zero
# whenever NOMERCY_GGML_CPU is set at all, simulating a dispatcher that
# bricks itself on an override — what cpu_variant_startup_ok exists to catch.
make_dispatcher_stub() {  # dir, name, version_string, exit_code, crash_on_override(0|1)
  local dir="$1" name="$2" ver="$3" code="$4" crash="$5"
  cat > "${dir}/${name}" <<EOF
#!/usr/bin/env bash
# getenv("NOMERCY_GGML_CPU") -- marks this stub as dispatcher-enabled.
if [[ "${crash}" == "1" && -n "\${NOMERCY_GGML_CPU:-}" ]]; then
  echo "${name}: simulated crash on NOMERCY_GGML_CPU override" >&2
  exit 9
fi
echo "${name} version ${ver} Copyright (c) the FFmpeg developers"
exit ${code}
EOF
  chmod +x "${dir}/${name}"
}

expect() {  # description, expected_rc, actual_rc
  if [[ "$2" == "$3" ]]; then echo "✅ $1"; ((PASS++)); else echo "❌ $1 (expected rc $2, got $3)"; ((FAIL++)); fi
}

# Case 1: correct version on a native platform → pass (rc 0)
# Uses make_dispatcher_stub (not make_stub): tests/smoke.sh now also asserts
# the ggml cpu dispatcher is compiled in (see Case 7), so a stub meant to
# represent an overall-passing binary has to carry that marker too.
d="$(mktemp -d)"; make_dispatcher_stub "$d" ffmpeg 8.1.1 0 0; make_dispatcher_stub "$d" ffprobe 8.1.1 0 0
bash "$SMOKE" "$d" 8.1.1 linux-x86_64 >/dev/null 2>&1; expect "correct version passes" 0 $?

# Case 2: wrong version → fail (rc != 0)
d="$(mktemp -d)"; make_stub "$d" ffmpeg 7.0.0 0; make_stub "$d" ffprobe 7.0.0 0
bash "$SMOKE" "$d" 8.1.1 linux-x86_64 >/dev/null 2>&1; rc=$?; [[ $rc -ne 0 ]] && rc=1; expect "wrong version fails" 1 $rc

# Case 3: non-zero ffmpeg exit (not exec-format) → fail
d="$(mktemp -d)"; make_stub "$d" ffmpeg 8.1.1 3; make_stub "$d" ffprobe 8.1.1 0
bash "$SMOKE" "$d" 8.1.1 linux-x86_64 >/dev/null 2>&1; rc=$?; [[ $rc -ne 0 ]] && rc=1; expect "non-zero ffmpeg exit fails" 1 $rc

# Case 4: missing binary → fail
d="$(mktemp -d)"; make_stub "$d" ffprobe 8.1.1 0
bash "$SMOKE" "$d" 8.1.1 linux-x86_64 >/dev/null 2>&1; rc=$?; [[ $rc -ne 0 ]] && rc=1; expect "missing ffmpeg fails" 1 $rc

# Case 5: exec-format error on the cross-arch platform → presence-only PASS
d="$(mktemp -d)"; make_execfmt_stub "$d" ffmpeg; make_execfmt_stub "$d" ffprobe
bash "$SMOKE" "$d" 8.1.1 linux-aarch64 >/dev/null 2>&1; expect "exec-format on linux-aarch64 passes (presence-only)" 0 $?

# Case 6: SAME exec-format failure on a NATIVE platform → must FAIL (not masked as cross-arch)
d="$(mktemp -d)"; make_execfmt_stub "$d" ffmpeg; make_execfmt_stub "$d" ffprobe
bash "$SMOKE" "$d" 8.1.1 linux-x86_64 >/dev/null 2>&1; rc=$?; [[ $rc -ne 0 ]] && rc=1; expect "exec-format on native platform fails" 1 $rc

# Case 7: correct version, but no ggml cpu dispatcher compiled in (plain
# make_stub, no marker) → must FAIL. This is the case that matters most:
# without it, a binary that predates the dispatcher entirely would sail
# through smoke.sh exactly like it did before this feature existed.
d="$(mktemp -d)"; make_stub "$d" ffmpeg 8.1.1 0; make_stub "$d" ffprobe 8.1.1 0
bash "$SMOKE" "$d" 8.1.1 linux-x86_64 >/dev/null 2>&1; rc=$?; [[ $rc -ne 0 ]] && rc=1; expect "no dispatcher marker fails" 1 $rc

# Case 8: dispatcher marker present, but the binary bricks itself when
# NOMERCY_GGML_CPU is set → must FAIL. Proves cpu_variant_startup_ok's own
# failure path actually fires, not just the presence check's.
d="$(mktemp -d)"; make_dispatcher_stub "$d" ffmpeg 8.1.1 0 1; make_dispatcher_stub "$d" ffprobe 8.1.1 0 0
bash "$SMOKE" "$d" 8.1.1 linux-x86_64 >/dev/null 2>&1; rc=$?; [[ $rc -ne 0 ]] && rc=1; expect "crash-on-override fails" 1 $rc

echo "----"; echo "passed=$PASS failed=$FAIL"
[[ $FAIL -eq 0 ]]
