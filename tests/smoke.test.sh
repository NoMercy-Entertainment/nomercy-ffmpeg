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

expect() {  # description, expected_rc, actual_rc
  if [[ "$2" == "$3" ]]; then echo "✅ $1"; ((PASS++)); else echo "❌ $1 (expected rc $2, got $3)"; ((FAIL++)); fi
}

# Case 1: correct version → pass (rc 0)
d="$(mktemp -d)"; make_stub "$d" ffmpeg 8.1.1 0; make_stub "$d" ffprobe 8.1.1 0
bash "$SMOKE" "$d" 8.1.1 >/dev/null 2>&1; expect "correct version passes" 0 $?

# Case 2: wrong version → fail (rc != 0)
d="$(mktemp -d)"; make_stub "$d" ffmpeg 7.0.0 0; make_stub "$d" ffprobe 7.0.0 0
bash "$SMOKE" "$d" 8.1.1 >/dev/null 2>&1; rc=$?; [[ $rc -ne 0 ]] && rc=1; expect "wrong version fails" 1 $rc

# Case 3: non-zero ffmpeg exit (not exec-format) → fail
d="$(mktemp -d)"; make_stub "$d" ffmpeg 8.1.1 3; make_stub "$d" ffprobe 8.1.1 0
bash "$SMOKE" "$d" 8.1.1 >/dev/null 2>&1; rc=$?; [[ $rc -ne 0 ]] && rc=1; expect "non-zero ffmpeg exit fails" 1 $rc

# Case 4: missing binary → fail
d="$(mktemp -d)"; make_stub "$d" ffprobe 8.1.1 0
bash "$SMOKE" "$d" 8.1.1 >/dev/null 2>&1; rc=$?; [[ $rc -ne 0 ]] && rc=1; expect "missing ffmpeg fails" 1 $rc

echo "----"; echo "passed=$PASS failed=$FAIL"
[[ $FAIL -eq 0 ]]
