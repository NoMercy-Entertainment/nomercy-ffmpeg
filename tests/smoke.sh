#!/usr/bin/env bash
# Minimal CI smoke gate: assert the freshly-built binary runs, reports the
# expected version, and exits cleanly. This is NOT the full codec suite — that
# is tests/tests.sh, run manually on real hardware by a contributor.
#
# Usage: smoke.sh <workspace_dir> <expected_version> [platform]
#
# Cross-exec note: a platform built for a different CPU arch OR OS than its
# smoke-test runner cannot be executed there, and HOW execution fails is not
# predictable: a different-arch ELF (linux-aarch64 on x86_64) is rejected by
# the kernel with "Exec format error" (126), but a same-arch foreign-OS ELF
# (freebsd-x86_64 on Linux) LOADS fine and then segfaults (139) because the
# syscall ABI differs. So for known cross-exec platforms we never execute at
# all — we validate the ELF header (magic + machine + OSABI branding) instead,
# which also catches a mislabeled or truncated artifact. Native platforms are
# always executed, so a broken native binary can never slip through.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/cpu-variant.sh
source "${HERE}/lib/cpu-variant.sh"

WORKSPACE="${1:?workspace dir required}"
EXPECTED_VERSION="${2:?expected version required}"
PLATFORM="${3:-}"

fail() { echo "❌ $*" >&2; exit 1; }
note() { echo "ℹ️  $*"; }
ok()   { echo "✅ $*"; }

# ggml CPU variant dispatcher: two checks. Defined up here, before the
# cross-exec early-return below, because the first of them needs no
# execution at all and must run even for a binary this runner cannot execute
# — see the call sites for why.
#
# 1. The binary must actually carry the dispatcher. This is what makes the
#    check below able to fail at all: a binary that never reads
#    NOMERCY_GGML_CPU "starts cleanly" with it set to anything, trivially, so
#    a check built only on process exit codes can never distinguish a
#    dispatcher-enabled build from an old one that predates this feature --
#    it would always pass, manufacturing confidence rather than catching a
#    regression. cpu_variant_dispatcher_compiled_in greps the binary for the
#    literal env-var name instead (see its comment in lib/cpu-variant.sh for
#    why that's reliable even stripped, and the empirical before/after
#    counts). Skipped on darwin: it legitimately never contains that string.
#    It is a grep over the file, not an execution, so unlike the startup
#    check below it also runs for cross-exec platforms (linux-aarch64,
#    freebsd-x86_64) that this runner cannot execute at all — windows-aarch64
#    is the same story on the PowerShell side. Those are exactly the
#    platforms with the least evidence behind them otherwise (aarch64 in
#    particular has never actually been executed by any CI runner here), so
#    skipping this check there would leave them with zero automated
#    dispatcher coverage.
#
# 2. NOMERCY_GGML_CPU must never stop the binary from starting, unset, forced
#    to the platform baseline (old hardware keeps working), or forced to
#    garbage (a bad override can't brick a machine). Needs no model, so
#    unlike tests/tests.sh's fuller, model-gated check (run manually, on real
#    hardware, with a real model) this runs on every CI build that can
#    actually execute the binary.
assert_cpu_variant_dispatcher_present() {  # bin, platform
  local bin="$1" platform="$2"

  if cpu_variant_is_darwin "${platform}"; then
    note "$(basename "${bin}"): ${platform} carries no ggml cpu dispatcher (fixed instruction level); dispatcher-presence check skipped"
    return
  fi

  if cpu_variant_dispatcher_compiled_in "${bin}"; then
    ok "$(basename "${bin}"): carries the ggml cpu dispatcher (NOMERCY_GGML_CPU compiled in)"
  else
    fail "$(basename "${bin}"): does not carry the ggml cpu dispatcher (NOMERCY_GGML_CPU not found in the binary)"
  fi
}

assert_cpu_variant_startup() {  # bin, platform
  local bin="$1" platform="$2" baseline

  if cpu_variant_is_darwin "${platform}"; then
    note "$(basename "${bin}"): ${platform} carries no ggml cpu dispatcher (fixed instruction level); NOMERCY_GGML_CPU startup check skipped"
    return
  fi

  baseline="$(cpu_variant_baseline "${platform}")"
  local diag
  if diag="$(cpu_variant_startup_ok "${bin}" "${baseline}")"; then
    ok "$(basename "${bin}"): starts cleanly with NOMERCY_GGML_CPU unset, forced to baseline (${baseline}), and forced to a nonsense value"
  else
    echo "${diag}" >&2
    fail "$(basename "${bin}"): NOMERCY_GGML_CPU startup guarantee failed (baseline ${baseline})"
  fi
}

# Platforms whose binary is built for a different arch OR OS than its
# smoke-test runner and therefore cannot be executed there. Maps platform to
# the expected ELF e_machine (2 bytes LE at offset 18) and EI_OSABI (1 byte at
# offset 7, "any" to skip). Keep in sync with the build matrix if another
# cross-arch/cross-OS target is added.
cross_exec_spec() {
  case "$1" in
    linux-aarch64)   echo "b700:any" ;;  # EM_AARCH64; OSABI is SysV(00) or Linux(03)
    freebsd-x86_64)  echo "3e00:09"  ;;  # EM_X86_64;  ELFOSABI_FREEBSD
    *)               return 1 ;;
  esac
}

elf_bytes() {  # file, offset, length → lowercase hex string
  od -An -tx1 -j "$2" -N "$3" -- "$1" | tr -d ' \n'
}

assert_elf_header() {  # bin, machine_le_hex, osabi_hex|any
  local bin="$1" machine="$2" osabi="$3" got
  got="$(elf_bytes "${bin}" 0 4)"
  [[ "${got}" == "7f454c46" ]] || fail "$(basename "${bin}"): not an ELF file (magic=${got})"
  got="$(elf_bytes "${bin}" 18 2)"
  [[ "${got}" == "${machine}" ]] || fail "$(basename "${bin}"): ELF machine=${got}, expected ${machine}"
  if [[ "${osabi}" != "any" ]]; then
    got="$(elf_bytes "${bin}" 7 1)"
    [[ "${got}" == "${osabi}" ]] || fail "$(basename "${bin}"): ELF OSABI=${got}, expected ${osabi}"
  fi
}

# ggml Vulkan GPU backend: the same two-part shape as the CPU dispatcher
# above, and for the same reason. The presence checks are greps, so they run
# for the cross-exec platforms this runner cannot execute — linux-aarch64 and
# freebsd-x86_64 here, windows-aarch64 on the PowerShell side — and those are
# precisely the platforms with the least other evidence behind them. The
# startup check needs execution, so it runs past the early return.
assert_vulkan_backend_present() {  # bin, platform
  local bin="$1" platform="$2" diag

  if ! vulkan_platform_has_backend "${platform}"; then
    note "vulkan: skipped on ${platform} — it carries no Vulkan by design (darwin gets Metal in a later phase; freebsd's static dlopen cannot open a loader at all)"
    return 0
  fi

  if vulkan_backend_compiled_in "${bin}"; then
    ok "vulkan: ggml Vulkan backend and loader shim are both linked in"
  else
    fail "vulkan: ${bin} does not carry the ggml Vulkan backend (or the loader shim it needs)"
  fi

  # The guard is a separate question from the backend, with the OPPOSITE
  # expectation on Windows, so it is asserted in both directions rather than
  # only where it should be present. A guard appearing in a Windows build
  # would be as much of a regression as one vanishing from Linux, and only an
  # assertion that can fail both ways catches both.
  if vulkan_platform_has_guard "${platform}"; then
    vulkan_guard_compiled_in "${bin}" \
      || fail "vulkan: the ICD guard is missing from ${platform}, which needs it"
    if ! diag="$(vulkan_guard_vocabulary_intact "${bin}")"; then
      echo "${diag}"
      fail "vulkan: the ICD guard's verdict vocabulary has been lost on ${platform}"
    fi
    ok "vulkan: ICD guard present, and all four verdict messages plus both escape hatches survive in the binary (that the arms still USE them is asserted in the Mesa block of build-linux-x86_64.sh, which needs a machine with drivers)"
  else
    vulkan_guard_compiled_in "${bin}" \
      && fail "vulkan: the ICD guard is compiled into ${platform}, which must not have it"
    ok "vulkan: ICD guard correctly absent on ${platform}"
  fi
}

# Nothing may regress for a user without a GPU — the constraint that outranks
# every performance goal on this branch. A CI runner has no GPU, which makes it
# the most representative machine available for the case that produced every
# crash found here so far.
#
# This instantiates a real ggml filter rather than running `ffmpeg -version`.
# -version never builds a filtergraph and so never reaches the backend
# registry that actually crashes: it exits 0 even in configurations measured
# to segfault a real filter on the same machine. See vulkan_startup_ok.
#
# Three outcomes, not two. "Could not instantiate the filter here" is reported
# as exactly that and never as a pass — the whole reason this check was
# rewritten is that it used to claim coverage it did not have.
assert_vulkan_startup() {  # bin, platform
  local bin="$1" platform="$2" diag rc

  if ! vulkan_platform_has_backend "${platform}"; then
    note "vulkan: startup check skipped on ${platform} (no Vulkan linked)"
    return 0
  fi
  diag="$(vulkan_startup_ok "${bin}")"; rc=$?
  case ${rc} in
  0) ok "vulkan: a ggml filter initialises and returns with no driver, with the loader pointed at nothing, and with either escape hatch set" ;;
  1) echo "${diag}"
     fail "vulkan: the binary crashes initialising a ggml filter on a machine with no usable GPU driver" ;;
  *) echo "${diag}"
     note "vulkan: could not instantiate a ggml filter on this build — the no-GPU guarantee is NOT asserted here" ;;
  esac
}

ffmpeg_bin="${WORKSPACE}/ffmpeg"
ffprobe_bin="${WORKSPACE}/ffprobe"

[[ -f "${ffmpeg_bin}"  ]] || fail "ffmpeg binary not found at ${ffmpeg_bin}"
[[ -f "${ffprobe_bin}" ]] || fail "ffprobe binary not found at ${ffprobe_bin}"
[[ -s "${ffmpeg_bin}"  ]] || fail "ffmpeg binary is empty"
[[ -s "${ffprobe_bin}" ]] || fail "ffprobe binary is empty"
chmod +x "${ffmpeg_bin}" "${ffprobe_bin}" 2>/dev/null || true

# Runs regardless of whether this runner can execute the binary at all — see
# the comment on assert_cpu_variant_dispatcher_present above for why it has
# to come before the cross-exec early-return, not after it.
assert_cpu_variant_dispatcher_present "${ffmpeg_bin}" "${PLATFORM}"
assert_vulkan_backend_present "${ffmpeg_bin}" "${PLATFORM}"

# Cross-exec platforms: never execute — validate ELF headers and stop here.
if spec="$(cross_exec_spec "${PLATFORM}")"; then
  machine="${spec%%:*}"; osabi="${spec##*:}"
  assert_elf_header "${ffmpeg_bin}"  "${machine}" "${osabi}"
  assert_elf_header "${ffprobe_bin}" "${machine}" "${osabi}"
  note "Cross-exec (${PLATFORM}): binaries cannot run on this runner — validated ELF headers instead (machine=${machine}, osabi=${osabi})."
  ok "Smoke (presence + ELF header) passed for cross-exec binaries."
  exit 0
fi

assert_version() {  # bin, banner
  local bin="$1" banner="$2" out code
  out="$("${bin}" -version 2>&1)"; code=$?
  if [[ ${code} -ne 0 ]]; then
    echo "${out}"; fail "$(basename "${bin}") -version exited ${code}"
  fi
  echo "${out}" | grep -q "${banner}" || { echo "${out}"; fail "missing '${banner}' banner"; }
  echo "${out}" | grep -q "${EXPECTED_VERSION}" || { echo "${out}"; fail "expected version ${EXPECTED_VERSION} not found"; }
  ok "$(basename "${bin}") reports version ${EXPECTED_VERSION} and exits 0"
}

assert_version "${ffmpeg_bin}" "ffmpeg version"
assert_version "${ffprobe_bin}" "ffprobe version"

# Needs to actually execute the binary, so only reachable here, past the
# cross-exec early-return.
assert_cpu_variant_startup "${ffmpeg_bin}" "${PLATFORM}"
assert_vulkan_startup "${ffmpeg_bin}" "${PLATFORM}"

# trailingsilence: assert it reports a real value on a generated fixture, not
# just that the command exited 0. 6s of tone padded with 5s of silence,
# trimmed to 11s, must detect the tail at the filter's own default duration=2
# threshold. -nostats (not -v error): ametadata's mode=print writes at
# AV_LOG_INFO, which -v error would silence along with everything else.
ts_out=$("${ffmpeg_bin}" -hide_banner -nostats -f lavfi -i "sine=frequency=440:duration=6" \
    -af "apad=pad_dur=5,atrim=end=11,trailingsilence,ametadata=mode=print" -f null - 2>&1 \
  | sed -n 's/^.*lavfi\.trailingsilence\.detected=//p' | tail -1)
# Guard the extraction itself: an empty string must fail loudly here, not
# compare quietly false against "1" a few lines down.
[[ -n "${ts_out}" ]] || fail "trailingsilence: empty metadata extraction"
[[ "${ts_out}" == "1" ]] || fail "trailingsilence did not detect the tail (got '${ts_out}')"
ok "trailingsilence detected the padded tail (detected=${ts_out})"
ok "Smoke test passed."
