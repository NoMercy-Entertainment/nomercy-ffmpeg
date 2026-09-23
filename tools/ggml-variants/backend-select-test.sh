#!/bin/bash
# The four no-GPU conditions nm_ggml_backend_init() has to survive, each in the
# container that actually reproduces it.
#
# Why a separate script from vulkan-shim-test.sh: the conditions differ by which
# Vulkan packages are INSTALLED, and a single container can only be in one of
# those states. vulkan-shim-test.sh builds the probe (and needs libvulkan-dev to
# do it); this runs that already-built static binary in freshly provisioned
# containers.
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
fail=0

run() {   # run <label> <setup-commands> <probe-args...>
    local label="$1" setup="$2"; shift 2
    echo
    echo "=================================================================="
    echo "== ${label}"
    echo "=================================================================="
    MSYS_NO_PATHCONV=1 docker run --rm -v "${VOL}":/vol "${IMAGE}" bash -c "
set -u
${setup}
/vol/vulkan-probe $*
echo \"exit=\$?\"
" || true
}

if [[ "${1:-}" == "--build" ]]; then
    echo "== rebuilding the probe =="
    MSYS_NO_PATHCONV=1 docker run --rm -v "$(cygpath -w "${REPO}")":/repo -v "${VOL}":/vol \
        -e WORK=/vol "${IMAGE}" bash /repo/tools/ggml-variants/vulkan-shim-test.sh elf
fi

# Case 2 of the brief: no Vulkan loader at all. A bare image installs nothing;
# the probe is static, so it runs anyway.
run "no loader at all" "true" select

# Case 3: the loader exists but names a driver manifest that does not.
run "loader present, no usable driver" \
    "apt-get update -qq >/dev/null 2>&1; apt-get install -y -qq --no-install-recommends libvulkan1 >/dev/null 2>&1
export VK_ICD_FILENAMES=/nonexistent.json" \
    select

# Case 1, the one this whole task exists for: Mesa's software Vulkan installed.
# Run twice - once with the guard, once with NOMERCY_VK_ICD_GUARD=0 - so the
# before/after is one command apart and nobody has to take the crash on trust.
MESA="apt-get update -qq >/dev/null 2>&1; apt-get install -y -qq --no-install-recommends mesa-vulkan-drivers >/dev/null 2>&1
echo 'ICD manifests installed:'; ls /usr/share/vulkan/icd.d/"

run "mesa-vulkan-drivers present, guard DISABLED (reproduces the Task 1 crash)" \
    "${MESA}
export NOMERCY_VK_ICD_GUARD=0" \
    select

run "mesa-vulkan-drivers present, guard enabled (must be cpu, exit 0)" \
    "${MESA}" select

echo
echo "Read the blocks above: every guarded case must print selected_backend=cpu,"
echo "PASS and exit=0. The guard-disabled Mesa case is expected to die (139)."
exit ${fail}
