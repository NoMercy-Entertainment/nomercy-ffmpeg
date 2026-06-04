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

expect() {  # description, expected_rc, actual_rc
  if [[ "$2" == "$3" ]]; then echo "✅ $1"; ((PASS++)); else echo "❌ $1 (expected rc $2, got $3)"; ((FAIL++)); fi
}

# Case 1: correct version on a native platform → pass (rc 0)
d="$(mktemp -d)"; make_stub "$d" ffmpeg 8.1.1 0; make_stub "$d" ffprobe 8.1.1 0
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

echo "----"; echo "passed=$PASS failed=$FAIL"
[[ $FAIL -eq 0 ]]
