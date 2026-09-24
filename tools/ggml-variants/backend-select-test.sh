#!/bin/bash
# Every no-GPU condition nm_ggml_backend_init() has to survive, each in the
# container that reproduces it - including the two the first review caught.
#
# Why a separate script from vulkan-shim-test.sh: the conditions differ by which
# Vulkan packages are INSTALLED and by how the host process behaves, and a
# single container can only be in one of those states. vulkan-shim-test.sh
# builds the probe (and needs libvulkan-dev to do it); this runs that
# already-built static binary in freshly provisioned containers.
#
# Usage, from the repo root on the Windows host (Git Bash + Docker Desktop):
#   bash tools/ggml-variants/backend-select-test.sh [--build]
#
# --build re-runs vulkan-shim-test.sh first. Without it the probe already in
# vkshim-vol is used, which is what you want while iterating on the container
# conditions rather than on the code.
set -eu
REPO="${REPO:-$(cd "$(dirname "$0")/../.." && pwd)}"
VOL="${VOL:-vkshim-vol}"
IMAGE="${IMAGE:-ubuntu:24.04}"

run() {   # run <label> <setup-commands> <probe-args...>
    local label="$1" setup="$2"; shift 2
    echo
    echo "=================================================================="
    echo "== ${label}"
    echo "=================================================================="
    MSYS_NO_PATHCONV=1 docker run --rm -v "${VOL}":/vol "${IMAGE}" bash -c "
set -u
${setup}
start=\$(date +%s)
\${RUNNER:-} /vol/vulkan-probe $*
rc=\$?
echo \"exit=\${rc} elapsed=\$(( \$(date +%s) - start ))s\"
" || true
}

if [[ "${1:-}" == "--build" ]]; then
    echo "== rebuilding the probe =="
    MSYS_NO_PATHCONV=1 docker run --rm -v "$(cygpath -w "${REPO}")":/repo -v "${VOL}":/vol \
        -e WORK=/vol "${IMAGE}" bash /repo/tools/ggml-variants/vulkan-shim-test.sh elf
fi

APT="apt-get update -qq >/dev/null 2>&1"
CC_SETUP="${APT}; apt-get install -y -qq --no-install-recommends gcc libc6-dev >/dev/null 2>&1"
LOADER="${APT}; apt-get install -y -qq --no-install-recommends libvulkan1 >/dev/null 2>&1"
MESA="${APT}; apt-get install -y -qq --no-install-recommends mesa-vulkan-drivers >/dev/null 2>&1
echo 'ICD manifests installed:'; ls /usr/share/vulkan/icd.d/"

# Three ICDs whose negotiate entry point never returns. Used twice below.
HANG="${LOADER}
${CC_SETUP}
printf '%s\n' '#include <unistd.h>' \
  'int vk_icdNegotiateLoaderICDInterfaceVersion(unsigned *v) { (void) v; for (;;) pause(); }' \
  'void *vk_icdGetInstanceProcAddr(void *i, const char *n) { (void) i; (void) n; for (;;) pause(); }' \
  > /tmp/hang.c
gcc -shared -fPIC -o /usr/lib/x86_64-linux-gnu/libvulkan_hang.so /tmp/hang.c
mkdir -p /usr/share/vulkan/icd.d
for i in 1 2 3; do
  printf '%s' '{\"file_format_version\":\"1.0.0\",\"ICD\":{\"library_path\":\"libvulkan_hang.so\",\"api_version\":\"1.2.0\"}}' > /usr/share/vulkan/icd.d/hang\${i}_icd.json
done
ls /usr/share/vulkan/icd.d/"

# ---------------------------------------------------------------- the basics

# No Vulkan loader at all. A bare image installs nothing; the probe is static,
# so it runs anyway.
run "no loader at all" "true" select

# The loader exists but names a driver manifest that does not.
run "loader present, no usable driver" \
    "${LOADER}
export VK_ICD_FILENAMES=/nonexistent.json" \
    select

# Mesa's software Vulkan installed, which is what this whole guard exists for.
# Run it twice - once with the guard, once with NOMERCY_VK_ICD_GUARD=0 - so the
# before and after are one environment variable apart and nobody has to take the
# crash on trust.
run "mesa present, guard DISABLED (reproduces the original crash)" \
    "${MESA}
export NOMERCY_VK_ICD_GUARD=0" \
    select

run "mesa present, guard enabled (must be cpu, exit 0)" "${MESA}" select

# ------------------------------------------------- regressions with evidence

# C1. The guard used to hang off the right-hand side of "use_gpu && ..." in
# af_whisper.c, so use_gpu=0 skipped it and the next line, ggml_backend_load_all,
# killed the process. "select 0" cannot see this, because it calls
# nm_ggml_gpu_usable() unconditionally; only the filter's own ordering can, which
# is what the whisper-init mode reproduces. Both values must survive.
run "C1: whisper init ordering, use_gpu=1, mesa present" "${MESA}" whisper-init 1
run "C1: whisper init ordering, use_gpu=0, mesa present" "${MESA}" whisper-init 0

# C2. A host that ignores SIGCHLD auto-reaps its children, so waitpid() fails
# with ECHILD. The verdict used to be derived from waitpid, so every probe read
# "unsafe" on a perfectly healthy machine, the bisect kept nothing, and
# VK_ICD_FILENAMES/VK_DRIVER_FILES were pinned to /nonexistent.json for the whole
# process - taking FFmpeg's own vulkan hwaccel and libplacebo with them. The
# verdict now arrives on a pipe. The two vk_* lines the probe prints after the
# guard must both say (unset).
run "C2: healthy machine, host ignores SIGCHLD (both vk_* must stay unset)" \
    "${LOADER}
${CC_SETUP}
printf '%s\n' '#include <signal.h>' '#include <unistd.h>' \
  'int main(int argc, char **argv) { (void) argc; signal(SIGCHLD, SIG_IGN); execv(argv[1], argv + 1); return 127; }' \
  > /tmp/ign.c
gcc -O0 -o /tmp/ign /tmp/ign.c
echo 'running under a SIGCHLD-ignoring parent:'
RUNNER=/tmp/ign" \
    select

# N1. A TIMEOUT is not a crash. The guard used to return the same verdict for
# "the child died" and "the deadline expired with the child still alive", so a
# machine we merely failed to test in time was announced as one whose drivers
# crash, and had VK_ICD_FILENAMES/VK_DRIVER_FILES pinned to /nonexistent.json
# process-wide - the C2 outcome by another route. Nothing in this container
# crashes; the budget is simply made impossible. Both vk_* must stay unset.
run "N1: healthy machine, impossible budget (must not pin)"     "${LOADER}
export NOMERCY_VK_GUARD_MS=1"     select

run "N1: healthy machine, impossible per-probe cap (must not pin)"     "${LOADER}
export NOMERCY_VK_PROBE_MS=1"     select

# N1, second half: the same must hold with real, hanging drivers present. We
# learn nothing about them, so we must change nothing - not pin on the strength
# of the one manifest we managed to look at.
run "N1: hung ICDs plus a tight budget (must not pin on a partial look)" \
    "${HANG}
export NOMERCY_VK_GUARD_MS=1500" \
    select

# I4. NixOS, Flatpak, Snap and Guix put the real driver in a directory reached
# only through XDG_DATA_DIRS. The scan used to miss those, so the bisect could
# never rescue a GPU there and the machine was pinned off instead. Move Mesa's
# manifests somewhere only XDG_DATA_DIRS names and check the guard still sees
# and classifies them.
run "I4: drivers visible only through XDG_DATA_DIRS" \
    "${MESA}
mkdir -p /opt/xdg/vulkan/icd.d
mv /usr/share/vulkan/icd.d/*.json /opt/xdg/vulkan/icd.d/
export XDG_DATA_DIRS=/opt/xdg
echo 'manifests now only under /opt/xdg:'; ls /opt/xdg/vulkan/icd.d/ | head -3" \
    select

# I1. One hung driver used to hang every probe in turn - one whole-set, N
# per-manifest, one confirm - for 30 s each. Measured at 124 s with three hung
# ICDs, with an analytic bound of 33 minutes at NM_VK_MAX_ICDS=64. The whole
# guard now shares one wall-clock budget. Three ICDs whose negotiate entry point
# sleeps forever; the elapsed time run() prints is the assertion.
run "I1: three ICDs that hang forever (must stay inside the budget)" \
    "${HANG}" \
    select

echo
echo "Read the blocks above. Every guarded case must print selected_backend=cpu,"
echo "PASS and exit=0; the guard-disabled Mesa case is expected to die (139); the"
echo "hang case must finish in well under a minute; and C2 must leave both vk_*"
echo "variables unset."
exit 0
