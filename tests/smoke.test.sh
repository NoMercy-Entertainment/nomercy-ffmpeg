#!/usr/bin/env bash
# Tests tests/smoke.sh against stub ffmpeg/ffprobe binaries (shell scripts).
set -uo pipefail
# Each startup test supplies its own override; ignore the caller's choice.
unset NOMERCY_GGML_CPU
HERE="$(cd "$(dirname "$0")" && pwd)"
SMOKE="${HERE}/smoke.sh"
PASS=0; FAIL=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The smoke gate checks these literal markers before executing a Linux
# binary. Stub them independently of the code under test.
add_backend_markers() {
  cat >> "$1" <<'EOF'
# ggml_vulkan vkGetInstanceProcAddr
# crash a statically linked
# vulkan disabled for this process
# could not finish identifying which
# not a report that anything is broken
# the loader configuration is unchanged
# NOMERCY_VK_GUARD_MS NOMERCY_VK_ICD_GUARD
EOF
}

add_codec_stub() {
  cat >> "$1" <<'EOF'
if [[ "$*" == *libjxl* && "${SMOKE_STUB_NO_JXL:-0}" == 1 ]]; then exit 55; fi
if [[ "$*" == *libjxl_anim* && "${SMOKE_STUB_NO_JXL_ANIM:-0}" == 1 ]]; then exit 55; fi
out="${!#}"; input=""; frames=1
args=("$@")
if [[ "$*" == *libjxl* && "$*" != *-distance* && "$out" == */image.jxl && "${SMOKE_STUB_DEFAULT_JXL_CRASH:-0}" == 1 ]]; then exit 56; fi
for ((i=0; i<${#args[@]}-1; i++)); do
  [[ "${args[i]}" == -i ]] && input="${args[i+1]}"
  [[ "${args[i]}" == -frames:v ]] && frames="${args[i+1]}"
done
if [[ "$input" == testsrc2=size=128x64* ]]; then
  if [[ "${SMOKE_STUB_ALPHA_CODEC:-}" == hap && "$out" == *.mov || "${SMOKE_STUB_ALPHA_CODEC:-}" == liboapv && "$out" == *.mkv ]]; then
    [[ "${SMOKE_STUB_ALPHA_FAULT:-}" == missing ]] && exit 57
  fi
  : > "$out"
  exit 0
fi
if [[ "$*" == *alphaextract* ]]; then
  scale=1; codec=hap
  [[ "$input" == *.mkv ]] && { scale=4; codec=liboapv; }
  low=0; high=$((250*scale)); mean=$((126*scale)); count=3
  if [[ "${SMOKE_STUB_ALPHA_CODEC:-}" == "$codec" ]]; then
    case "${SMOKE_STUB_ALPHA_FAULT:-}" in
      opaque) low=$((255*scale)); high=$low; mean=$low ;;
      flat) low=$((127*scale)); high=$low; mean=$low ;;
      truncated) count=2 ;;
      empty) exit 0 ;;
      malformed) mean=invalid ;;
      decode) exit 58 ;;
    esac
  fi
  for ((frame=0; frame<count; frame++)); do
    printf 'lavfi.signalstats.YMIN=%s\nlavfi.signalstats.YMAX=%s\nlavfi.signalstats.YAVG=%s\n' "$low" "$high" "$mean"
  done
  exit 0
fi
if [[ "$input" == testsrc=size=64x48* ]]; then
  dd if=/dev/zero of="$out" bs=12288 count="$frames" 2>/dev/null
  exit $?
fi
if [[ "$out" != - && -f "$input" ]]; then
  cp "$input" "$out" || exit 1
  if [[ "$out" == */decoded.rgba && "${SMOKE_STUB_CORRUPT_JXL:-0}" == 1 ]]; then
    printf '\001' | dd of="$out" bs=1 seek=3 conv=notrunc 2>/dev/null
  fi
  exit 0
fi
if [[ "$*" == *trailingsilence* ]]; then echo 'lavfi.trailingsilence.detected=1'; fi
EOF
}

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
  # These comments are visible to presence checks even after exit 126.
  echo '# NOMERCY_GGML_CPU' >> "${dir}/${name}"
  add_backend_markers "${dir}/${name}"
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
EOF
  add_backend_markers "${dir}/${name}"
  if [[ "$code" == 0 ]]; then add_codec_stub "${dir}/${name}"; fi
  printf 'echo "%s version %s Copyright (c) the FFmpeg developers"\nexit %s\n' "$name" "$ver" "$code" >> "${dir}/${name}"
  chmod +x "${dir}/${name}"
}

make_elf_stub() {  # A well-formed header for a cross-exec Linux ARM64 binary.
  {
    printf '\177ELF\002\001\001\000\000\000\000\000\000\000\000\000\002\000\267\000\001\000\000\000'
    dd if=/dev/zero bs=28 count=1 2>/dev/null
    printf '\100\000\000\000\000\000\000\000\000\000\000\000'
    printf 'NOMERCY_GGML_CPU\n'
  } > "$1/$2"
  add_backend_markers "$1/$2"
  chmod +x "$1/$2"
}

expect() {  # description, expected_rc, actual_rc
  if [[ "$2" == "$3" ]]; then echo "✅ $1"; ((PASS++)); else echo "❌ $1 (expected rc $2, got $3)"; ((FAIL++)); fi
}

# Case 1: correct version on a native platform → pass (rc 0)
# Uses make_dispatcher_stub (not make_stub): tests/smoke.sh now also asserts
# the ggml cpu dispatcher is compiled in (see Case 7), so a stub meant to
# represent an overall-passing binary has to carry that marker too.
d="$(mktemp -d "${WORK}/case.XXXXXX")"; make_dispatcher_stub "$d" ffmpeg 8.1.1 0 0; make_dispatcher_stub "$d" ffprobe 8.1.1 0 0
bash "$SMOKE" "$d" 8.1.1 linux-x86_64 >/dev/null 2>&1; expect "correct version passes" 0 $?

# Case 2: wrong version → fail (rc != 0)
d="$(mktemp -d "${WORK}/case.XXXXXX")"; make_dispatcher_stub "$d" ffmpeg 7.0.0 0 0; make_dispatcher_stub "$d" ffprobe 7.0.0 0 0
bash "$SMOKE" "$d" 8.1.1 linux-x86_64 >"${WORK}/version.log" 2>&1
rc=$?; [[ $rc -ne 0 ]] && grep -q 'expected version' "${WORK}/version.log"; expect "wrong version fails at the version gate" 0 $?

# Case 3: non-zero ffmpeg exit (not exec-format) → fail
d="$(mktemp -d "${WORK}/case.XXXXXX")"; make_dispatcher_stub "$d" ffmpeg 8.1.1 3 0; make_dispatcher_stub "$d" ffprobe 8.1.1 0 0
bash "$SMOKE" "$d" 8.1.1 linux-x86_64 >/dev/null 2>&1; rc=$?; [[ $rc -ne 0 ]] && rc=1; expect "non-zero ffmpeg exit fails" 1 $rc

# Case 4: missing binary → fail
d="$(mktemp -d "${WORK}/case.XXXXXX")"; make_stub "$d" ffprobe 8.1.1 0
bash "$SMOKE" "$d" 8.1.1 linux-x86_64 >/dev/null 2>&1; rc=$?; [[ $rc -ne 0 ]] && rc=1; expect "missing ffmpeg fails" 1 $rc

# Case 5: valid cross-arch ELF headers pass without executing the binary.
d="$(mktemp -d "${WORK}/case.XXXXXX")"; make_elf_stub "$d" ffmpeg; make_elf_stub "$d" ffprobe
bash "$SMOKE" "$d" 8.1.1 linux-aarch64 >/dev/null 2>&1; expect "valid linux-aarch64 headers pass without execution" 0 $?

# Case 6: SAME exec-format failure on a NATIVE platform → must FAIL (not masked as cross-arch)
d="$(mktemp -d "${WORK}/case.XXXXXX")"; make_execfmt_stub "$d" ffmpeg; make_execfmt_stub "$d" ffprobe
bash "$SMOKE" "$d" 8.1.1 linux-x86_64 >/dev/null 2>&1; rc=$?; [[ $rc -ne 0 ]] && rc=1; expect "exec-format on native platform fails" 1 $rc

# Case 7: correct version, but no ggml cpu dispatcher compiled in (plain
# make_stub, no marker) → must FAIL. This is the case that matters most:
# without it, a binary that predates the dispatcher entirely would sail
# through smoke.sh exactly like it did before this feature existed.
d="$(mktemp -d "${WORK}/case.XXXXXX")"; make_stub "$d" ffmpeg 8.1.1 0; make_stub "$d" ffprobe 8.1.1 0
bash "$SMOKE" "$d" 8.1.1 linux-x86_64 >"${WORK}/dispatcher.log" 2>&1
rc=$?; [[ $rc -ne 0 ]] && grep -q 'does not carry the ggml cpu dispatcher' "${WORK}/dispatcher.log"; expect "no dispatcher marker fails at the presence gate" 0 $?

# Case 8: dispatcher marker present, but the binary bricks itself when
# NOMERCY_GGML_CPU is set → must FAIL. Proves cpu_variant_startup_ok's own
# failure path actually fires, not just the presence check's.
d="$(mktemp -d "${WORK}/case.XXXXXX")"; make_dispatcher_stub "$d" ffmpeg 8.1.1 0 1; make_dispatcher_stub "$d" ffprobe 8.1.1 0 0
bash "$SMOKE" "$d" 8.1.1 linux-x86_64 >"${WORK}/override.log" 2>&1
rc=$?; [[ $rc -ne 0 ]] && grep -q 'did not start with NOMERCY_GGML_CPU' "${WORK}/override.log"; expect "crash-on-override fails at the startup gate" 0 $?

# A binary that starts and reports the right version must still fail if the
# codec is missing, or returns success while damaging the decoded alpha.
d="$(mktemp -d "${WORK}/case.XXXXXX")"; make_dispatcher_stub "$d" ffmpeg 8.1.1 0 0; make_dispatcher_stub "$d" ffprobe 8.1.1 0 0
SMOKE_STUB_NO_JXL=1 bash "$SMOKE" "$d" 8.1.1 linux-x86_64 >"${WORK}/missing.log" 2>&1
rc=$?; [[ $rc -ne 0 ]] && grep -q 'JPEG XL round-trip' "${WORK}/missing.log"; expect "missing JPEG XL fails at the codec gate" 0 $?
SMOKE_STUB_NO_JXL_ANIM=1 bash "$SMOKE" "$d" 8.1.1 linux-x86_64 >"${WORK}/missing-animation.log" 2>&1
rc=$?; [[ $rc -ne 0 ]] && grep -q 'JPEG XL round-trip: test_jpegxl_animation' "${WORK}/missing-animation.log"; expect "missing animated JPEG XL fails at the animation gate" 0 $?
SMOKE_STUB_CORRUPT_JXL=1 bash "$SMOKE" "$d" 8.1.1 linux-x86_64 >"${WORK}/corrupt.log" 2>&1
rc=$?; [[ $rc -ne 0 ]] && grep -q 'changed pixels, alpha or frame count' "${WORK}/corrupt.log"; expect "corrupted alpha fails despite successful commands" 0 $?
SMOKE_STUB_DEFAULT_JXL_CRASH=1 bash "$SMOKE" "$d" 8.1.1 linux-x86_64 >"${WORK}/defaults.log" 2>&1
rc=$?; [[ $rc -ne 0 ]] && grep -q 'JPEG XL round-trip: test_jpegxl_defaults' "${WORK}/defaults.log"; expect "crashing default encoder settings fail at the defaults gate" 0 $?

for codec in hap liboapv; do
  gate=test_hap_alpha
  [[ "$codec" == liboapv ]] && gate=test_apv_alpha
  for fault in missing opaque flat truncated empty malformed decode; do
    SMOKE_STUB_ALPHA_CODEC="$codec" SMOKE_STUB_ALPHA_FAULT="$fault" bash "$SMOKE" "$d" 8.1.1 linux-x86_64 >"${WORK}/alpha.log" 2>&1
    rc=$?
    [[ $rc -ne 0 ]] && grep -q "Alpha codec round-trip: $gate" "${WORK}/alpha.log"
    expect "$codec $fault fails at its alpha gate" 0 $?
  done
done

echo "----"; echo "passed=$PASS failed=$FAIL"
[[ $FAIL -eq 0 ]]
