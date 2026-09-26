# ggml Vulkan Backend Implementation Plan (phase 1)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the `whisper` and `stemsplit` filters GPU acceleration through ggml's Vulkan backend, linked statically, on the six platforms that can have it — without changing how anything ships and without any risk to machines that have no usable GPU.

**Architecture:** ggml's Vulkan backend needs exactly three symbols from the Vulkan loader. A small shim of our own supplies them and opens the system loader (`libvulkan.so.1` / `vulkan-1.dll`) lazily at first use, so the binary stays fully static and Vulkan stays entirely optional at runtime. Backend choice moves into the file that already answers "what should this filter run on": GPU first via ggml's registry, software rasterisers skipped, otherwise the best CPU instruction-set variant exactly as today.

**Tech Stack:** C (the shim and the dispatcher), CMake/ggml (whisper.cpp v1.9.1, ggml 0.15.1), bash build scripts, glslc for shader compilation, Docker for local verification, mingw-w64 and llvm-mingw cross toolchains.

**Spec:** `docs/superpowers/specs/2026-09-23-ggml-gpu-backends-design.md`

## Global Constraints

- **Nothing may regress for a user without a GPU.** This outranks every performance goal here. No crash, no slowdown, no failure to start.
- Binaries stay **fully static**: no new file in any archive, no new runtime dependency, no import of the Vulkan loader in the binary's import table.
- **No patch to ggml or whisper.cpp sources.** Build system, our own shim, and the two filter sources this repo already maintains.
- **Only ggml's registry path** may be used to reach Vulkan (`ggml_backend_dev_by_type`, `ggml_backend_vk_reg`). The legacy `ggml_backend_vk_init()` / `ggml_backend_vk_get_device_count()` terminate the process when a loader is present without a usable driver — measured, exit 134.
- **The shim never returns NULL** from `vkGetInstanceProcAddr`. It returns stub functions reporting `VK_ERROR_INCOMPATIBLE_DRIVER`, because a NULL is called unconditionally inside `vulkan.hpp`'s dispatcher and segfaults.
- **Software rasterisers are skipped.** Mesa llvmpipe segfaults inside a static binary, and a headless Linux server advertises exactly such a device.
- Platforms getting Vulkan: linux-x86_64, windows-x86_64, linux-aarch64, windows-aarch64, freebsd-x86_64 (gated on its own verification). Both darwin targets: no Vulkan — Metal is phase 3.
- GPU is **on by default** with automatic CPU fallback; `use_gpu=0` remains the hard override.
- Metadata keys: `lavfi.whisper.backend`, `lavfi.stemsplit.backend`, alongside the existing `cpu_variant` keys. Log at `AV_LOG_INFO`.
- Conventional Commits. **NEVER** add self-attribution, "Co-Authored-By" or "Generated with" lines to a commit message — absolute rule of this repository's owner.
- Budget: ~63 MB per binary, +3-5 min build time per platform. Record real numbers.

---

### Task 1: The Vulkan loader shim

**Files:**
- Create: `scripts/includes/vk_loader_shim.c`
- Create: `tools/ggml-variants/vulkan-shim-test.sh`
- Create: `tools/ggml-variants/vulkan-probe.c`

**Interfaces:**
- Produces: definitions of `vkGetInstanceProcAddr`, `vkCmdCopyBuffer` and `vkGetPhysicalDeviceFeatures2` with the loader opened lazily. Nothing else in the repo calls these directly; ggml-vulkan links against them.

- [ ] **Step 1: Write the failing test**

`tools/ggml-variants/vulkan-probe.c` — asks ggml's registry for a GPU through the same path production will use, prints what it finds, and runs a matmul on it:

```c
/* Probe: what does ggml's registry offer, and does it compute correctly?
 * Exits 0 whether or not a GPU exists - "no GPU" is a valid, expected answer.
 * Exits non-zero only on a crash or a wrong result, which is what we test for. */
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <string.h>
#include <ggml.h>
#include <ggml-alloc.h>
#include <ggml-backend.h>

#define M 256
#define K 256
#define N 64

static float *run_on(ggml_backend_t be, const char *label, float *a_src, float *b_src)
{
    struct ggml_init_params ip = { ggml_tensor_overhead() * 8 + ggml_graph_overhead(), NULL, true };
    struct ggml_context *ctx = ggml_init(ip);
    struct ggml_tensor *a = ggml_new_tensor_2d(ctx, GGML_TYPE_F16, K, M);
    struct ggml_tensor *b = ggml_new_tensor_2d(ctx, GGML_TYPE_F32, K, N);
    struct ggml_tensor *c = ggml_mul_mat(ctx, a, b);
    struct ggml_cgraph *gf = ggml_new_graph(ctx);
    ggml_build_forward_expand(gf, c);

    ggml_backend_buffer_t buf = ggml_backend_alloc_ctx_tensors(ctx, be);
    if (!buf) { printf("FAIL: %s: buffer alloc\n", label); ggml_free(ctx); return NULL; }

    ggml_fp16_t *a16 = malloc((size_t) M * K * sizeof(ggml_fp16_t));
    ggml_fp32_to_fp16_row(a_src, a16, (size_t) M * K);
    ggml_backend_tensor_set(a, a16, 0, ggml_nbytes(a));
    free(a16);
    ggml_backend_tensor_set(b, b_src, 0, ggml_nbytes(b));

    if (ggml_backend_graph_compute(be, gf) != GGML_STATUS_SUCCESS) {
        printf("FAIL: %s: compute\n", label);
        ggml_free(ctx); ggml_backend_buffer_free(buf); return NULL;
    }
    float *out = malloc(ggml_nbytes(c));
    ggml_backend_tensor_get(c, out, 0, ggml_nbytes(c));
    ggml_free(ctx);
    ggml_backend_buffer_free(buf);
    return out;
}

int main(void)
{
    float *a = malloc(sizeof(float) * M * K), *b = malloc(sizeof(float) * K * N);
    srand(99);
    for (size_t i = 0; i < (size_t) M * K; i++) a[i] = (rand() / (float) RAND_MAX) - 0.5f;
    for (size_t i = 0; i < (size_t) K * N; i++) b[i] = (rand() / (float) RAND_MAX) - 0.5f;

    /* registry path only - the legacy API terminates the process when a loader
     * exists without a usable driver */
    ggml_backend_dev_t gpu = ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_GPU);
    ggml_backend_dev_t cpu = ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU);
    if (!cpu) { printf("FAIL: no CPU device at all\n"); return 1; }

    printf("gpu_device=%s\n", gpu ? ggml_backend_dev_name(gpu) : "(none)");
    printf("gpu_description=%s\n", gpu ? ggml_backend_dev_description(gpu) : "(none)");

    ggml_backend_t cpu_be = ggml_backend_dev_init(cpu, NULL);
    float *cpu_out = run_on(cpu_be, "cpu", a, b);
    if (!cpu_out) return 1;

    if (gpu) {
        ggml_backend_t gpu_be = ggml_backend_dev_init(gpu, NULL);
        if (!gpu_be) { printf("FAIL: gpu device present but init returned NULL\n"); return 1; }
        float *gpu_out = run_on(gpu_be, "gpu", a, b);
        if (!gpu_out) return 1;
        double maxrel = 0, sum = 0;
        size_t n = (size_t) M * N;
        for (size_t i = 0; i < n; i++) sum += fabs(cpu_out[i]);
        for (size_t i = 0; i < n; i++) {
            double d = fabs(cpu_out[i] - gpu_out[i]) / (sum / n);
            if (d > maxrel) maxrel = d;
        }
        printf("gpu_vs_cpu_max_relative=%.3g\n", maxrel);
        if (!(maxrel < 1e-2)) { printf("FAIL: gpu result disagrees with cpu\n"); return 1; }
        ggml_backend_free(gpu_be);
    }
    ggml_backend_free(cpu_be);
    printf("PASS\n");
    return 0;
}
```

`tools/ggml-variants/vulkan-shim-test.sh` builds ggml with Vulkan plus the shim and runs the probe under three conditions:

```bash
#!/bin/bash
# Build ggml-vulkan + our shim into a static probe and check the three runtime
# conditions that matter. Usage: vulkan-shim-test.sh [elf|coff]
set -eu
FORMAT="${1:-elf}"
REPO="${REPO:-/repo}"
WORK="${WORK:-/tmp/nm-vkshim}"
WHISPER_VERSION=1.9.1

apt-get update -qq >/dev/null
PKGS="cmake ninja-build git gcc g++ binutils ca-certificates glslc libvulkan-dev spirv-headers"
[[ ${FORMAT} == coff ]] && PKGS="${PKGS} mingw-w64"
apt-get install -y -qq --no-install-recommends ${PKGS} >/dev/null

mkdir -p "${WORK}" && cd "${WORK}"
[[ -d whisper.cpp ]] || git clone -q --depth 1 --branch "v${WHISPER_VERSION}" \
    https://github.com/ggml-org/whisper.cpp.git

# find_package(Vulkan) must be satisfiable without a real loader: ggml-vulkan is
# built as a static archive, so Vulkan_LIBRARY is never actually linked - it only
# has to exist as a path. Give it an empty archive and an isolated header dir.
mkdir -p "${WORK}/vkinc"
cp -r /usr/include/vulkan /usr/include/vk_video "${WORK}/vkinc/" 2>/dev/null || true
cp -r /usr/include/spirv "${WORK}/vkinc/" 2>/dev/null || true
: > "${WORK}/empty.c"
gcc -c "${WORK}/empty.c" -o "${WORK}/empty.o" && ar rcs "${WORK}/libvulkan-stub.a" "${WORK}/empty.o"

if [[ ${FORMAT} == coff ]]; then
    CC=x86_64-w64-mingw32-gcc; CXX=x86_64-w64-mingw32-g++
    CROSS="-DCMAKE_SYSTEM_NAME=Windows -DCMAKE_SYSTEM_PROCESSOR=x86_64 -DCMAKE_C_COMPILER=${CC} -DCMAKE_CXX_COMPILER=${CXX}"
    EXTRA="-lstdc++ -lm -lpthread -lws2_32 -fstack-protector-strong"
    BIN="${WORK}/vulkan-probe.exe"
    sed -i 's|#if _WIN32_WINNT >= 0x0602|#if 0|' whisper.cpp/ggml/src/ggml-cpu/ggml-cpu.c
else
    CC=gcc; CXX=g++
    CROSS="-DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=x86_64 -DCMAKE_C_COMPILER=${CC} -DCMAKE_CXX_COMPILER=${CXX}"
    EXTRA="-lstdc++ -lm -lpthread -ldl"
    BIN="${WORK}/vulkan-probe"
fi

cmake -S "${WORK}/whisper.cpp" -B "${WORK}/build" -G Ninja ${CROSS} \
    -DCMAKE_INSTALL_PREFIX="${WORK}/inst" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_LIBDIR=lib \
    -DBUILD_SHARED_LIBS=OFF -DGGML_NATIVE=OFF -DGGML_VULKAN=ON \
    -DVulkan_INCLUDE_DIR="${WORK}/vkinc" -DVulkan_LIBRARY="${WORK}/libvulkan-stub.a" \
    -DVulkan_GLSLC_EXECUTABLE="$(command -v glslc)" \
    -DWHISPER_BUILD_TOOLS=OFF -DWHISPER_BUILD_SERVER=OFF -DWHISPER_BUILD_TESTS=OFF \
    -DWHISPER_BUILD_EXAMPLES=OFF > "${WORK}/configure.log" 2>&1
ninja -j"$(nproc)" -C "${WORK}/build" > "${WORK}/build.log" 2>&1
ninja -C "${WORK}/build" install >> "${WORK}/build.log" 2>&1

echo "== undefined vulkan symbols in the built archive (expect exactly 3):"
nm --undefined-only "${WORK}/inst/lib/libggml-vulkan.a" 2>/dev/null | grep -oE '\bvk[A-Za-z]+' | sort -u

L="${WORK}/inst/lib"
${CC} -O2 -I"${WORK}/inst/include" -I"${WORK}/vkinc" -static \
    "${REPO}/tools/ggml-variants/vulkan-probe.c" "${REPO}/scripts/includes/vk_loader_shim.c" \
    "${L}/libggml-vulkan.a" "${L}/libggml-cpu.a" "${L}/libggml-base.a" ${EXTRA} -o "${BIN}"
echo "built ${BIN}"

if [[ ${FORMAT} == elf ]]; then
    echo "== linkage (must say statically linked):"; file "${BIN}"
    echo "== case A: no loader present at all"; "${BIN}"; echo "exit=$?"
fi
exit 0
```

- [ ] **Step 2: Run it to verify it fails**

```bash
docker run --rm -v "$PWD:/repo" ubuntu:24.04 bash /repo/tools/ggml-variants/vulkan-shim-test.sh elf
```

Expected: FAIL — `scripts/includes/vk_loader_shim.c: No such file or directory` at the link step.

- [ ] **Step 3: Write the shim**

`scripts/includes/vk_loader_shim.c`. This is the spike's proven source, promoted to production with its reasoning kept:

```c
/*
 * A stand-in for the Vulkan loader's few link-time symbols.
 *
 * Why this file exists: ggml's Vulkan backend links against three loader
 * symbols, and linking the real loader would make our fully static binaries
 * depend on a shared library that most machines do not have. FFmpeg's own
 * Vulkan code already solves this by opening the loader at runtime; this does
 * the same for ggml. Opening a shared library from a static executable works;
 * it is the reverse - a loaded module calling back into the executable - that
 * does not, which is why ggml's own backend modules are not an option here.
 *
 * The three symbols are not a guess: they are what `nm --undefined-only` reports
 * on the built libggml-vulkan.a. Everything else ggml needs it fetches itself
 * through vkGetInstanceProcAddr.
 *
 * The one subtlety worth knowing: when no loader is present we must NOT return
 * NULL from vkGetInstanceProcAddr. vulkan.hpp's dispatcher stores whatever it
 * gets and calls through it unconditionally, so a NULL is a null-pointer call -
 * a segfault, not a catchable error. Returning small stubs that report
 * VK_ERROR_INCOMPATIBLE_DRIVER keeps every call landing on a valid function, so
 * "no driver" surfaces as an ordinary Vulkan error that ggml already handles.
 */

#include <vulkan/vulkan_core.h>
#include <stdio.h>
#include <string.h>

#if defined(_WIN32)
#include <windows.h>
static HMODULE g_vk_lib = 0;
static int g_vk_tried = 0;
static void ensure_loaded(void)
{
    if (!g_vk_tried) {
        g_vk_tried = 1;
        g_vk_lib = LoadLibraryA("vulkan-1.dll");
    }
}
static void *vk_sym(const char *name)
{
    ensure_loaded();
    if (!g_vk_lib) return 0;
    return (void *) GetProcAddress(g_vk_lib, name);
}
#else
#include <dlfcn.h>
static void *g_vk_lib = 0;
static int g_vk_tried = 0;
static void ensure_loaded(void)
{
    if (!g_vk_tried) {
        g_vk_tried = 1;
        g_vk_lib = dlopen("libvulkan.so.1", RTLD_NOW | RTLD_LOCAL);
        if (!g_vk_lib) g_vk_lib = dlopen("libvulkan.so", RTLD_NOW | RTLD_LOCAL);
    }
}
static void *vk_sym(const char *name)
{
    ensure_loaded();
    if (!g_vk_lib) return 0;
    return dlsym(g_vk_lib, name);
}
#endif

/* Used only when the loader could not be opened at all. */

static VKAPI_ATTR VkResult VKAPI_CALL stub_vkCreateInstance(
    const VkInstanceCreateInfo *pCreateInfo, const VkAllocationCallbacks *pAllocator, VkInstance *pInstance)
{
    (void) pCreateInfo; (void) pAllocator; (void) pInstance;
    return VK_ERROR_INCOMPATIBLE_DRIVER;
}

static VKAPI_ATTR VkResult VKAPI_CALL stub_vkEnumerateInstanceExtensionProperties(
    const char *pLayerName, uint32_t *pPropertyCount, VkExtensionProperties *pProperties)
{
    (void) pLayerName; (void) pProperties;
    if (pPropertyCount) *pPropertyCount = 0;
    return VK_SUCCESS;
}

static VKAPI_ATTR VkResult VKAPI_CALL stub_vkEnumerateInstanceLayerProperties(
    uint32_t *pPropertyCount, VkLayerProperties *pProperties)
{
    (void) pProperties;
    if (pPropertyCount) *pPropertyCount = 0;
    return VK_SUCCESS;
}

static VKAPI_ATTR VkResult VKAPI_CALL stub_vkEnumerateInstanceVersion(uint32_t *pApiVersion)
{
    if (pApiVersion) *pApiVersion = VK_API_VERSION_1_0;
    return VK_SUCCESS;
}

VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL vkGetInstanceProcAddr(VkInstance instance, const char *pName)
{
    static PFN_vkGetInstanceProcAddr real = 0;
    static int tried = 0;
    if (!tried) {
        tried = 1;
        real = (PFN_vkGetInstanceProcAddr) vk_sym("vkGetInstanceProcAddr");
    }
    if (real)
        return real(instance, pName);
    if (!pName)
        return 0;
    if (!strcmp(pName, "vkCreateInstance"))
        return (PFN_vkVoidFunction) stub_vkCreateInstance;
    if (!strcmp(pName, "vkEnumerateInstanceExtensionProperties"))
        return (PFN_vkVoidFunction) stub_vkEnumerateInstanceExtensionProperties;
    if (!strcmp(pName, "vkEnumerateInstanceLayerProperties"))
        return (PFN_vkVoidFunction) stub_vkEnumerateInstanceLayerProperties;
    if (!strcmp(pName, "vkEnumerateInstanceVersion"))
        return (PFN_vkVoidFunction) stub_vkEnumerateInstanceVersion;
    return 0;
}

VKAPI_ATTR void VKAPI_CALL vkCmdCopyBuffer(VkCommandBuffer commandBuffer, VkBuffer srcBuffer,
                                           VkBuffer dstBuffer, uint32_t regionCount,
                                           const VkBufferCopy *pRegions)
{
    static PFN_vkCmdCopyBuffer real = 0;
    static int tried = 0;
    if (!tried) {
        tried = 1;
        real = (PFN_vkCmdCopyBuffer) vk_sym("vkCmdCopyBuffer");
    }
    /* Only reachable once a real device and queue exist, so the loader was found. */
    if (real)
        real(commandBuffer, srcBuffer, dstBuffer, regionCount, pRegions);
}

VKAPI_ATTR void VKAPI_CALL vkGetPhysicalDeviceFeatures2(VkPhysicalDevice physicalDevice,
                                                        VkPhysicalDeviceFeatures2 *pFeatures)
{
    static PFN_vkGetPhysicalDeviceFeatures2 real = 0;
    static int tried = 0;
    if (!tried) {
        tried = 1;
        real = (PFN_vkGetPhysicalDeviceFeatures2) vk_sym("vkGetPhysicalDeviceFeatures2");
    }
    if (real)
        real(physicalDevice, pFeatures);
}
```

- [ ] **Step 4: Run the ELF case and verify it passes**

```bash
docker run --rm -v "$PWD:/repo" ubuntu:24.04 bash /repo/tools/ggml-variants/vulkan-shim-test.sh elf
```

Expected: the undefined-symbol list prints exactly `vkCmdCopyBuffer`, `vkGetInstanceProcAddr`, `vkGetPhysicalDeviceFeatures2`; `file` says "statically linked"; case A prints `gpu_device=(none)` and `PASS` with exit 0. A container has no Vulkan driver, so "no GPU" is the correct answer — what is being tested is that it does not crash.

- [ ] **Step 5: Test the two remaining absence cases**

Both inside the same container, after Step 4's build:

```bash
# loader file present but zero usable drivers - the case that crashes the legacy API
apt-get install -y -qq --no-install-recommends libvulkan1 >/dev/null
VK_ICD_FILENAMES=/nonexistent.json /tmp/nm-vkshim/vulkan-probe; echo "exit=$?"
# a software rasteriser, which must be skipped rather than used
apt-get install -y -qq --no-install-recommends mesa-vulkan-drivers >/dev/null
/tmp/nm-vkshim/vulkan-probe; echo "exit=$?"
```

Expected: the first prints `gpu_device=(none)`, `PASS`, exit 0. The second may report a llvmpipe device at this stage — the probe has no filter yet, and Task 3 adds it. Record exactly what it prints and whether it crashes; that output is the input to Task 3's filter design.

- [ ] **Step 6: Build and run the Windows case on the real GPU**

```bash
docker run --rm -v "$PWD:/repo" -v "$TMP/nm-vkshim:/tmp/nm-vkshim" ubuntu:24.04 \
    bash /repo/tools/ggml-variants/vulkan-shim-test.sh coff
"$TMP/nm-vkshim/vulkan-probe.exe"
```

Expected: `gpu_device` naming the NVIDIA GeForce RTX 3070 on this host, `gpu_vs_cpu_max_relative` well under 1e-2, and `PASS`. Also confirm the exe does not import the loader:

```bash
docker run --rm -v "$TMP/nm-vkshim:/w" ubuntu:24.04 bash -c \
  'apt-get update -qq >/dev/null && apt-get install -y -qq --no-install-recommends binutils-mingw-w64 >/dev/null
   x86_64-w64-mingw32-objdump -p /w/vulkan-probe.exe | grep "DLL Name"'
```

Expected: no `vulkan-1.dll` among the DLL names.

- [ ] **Step 7: Commit**

```bash
git add scripts/includes/vk_loader_shim.c tools/ggml-variants/vulkan-probe.c tools/ggml-variants/vulkan-shim-test.sh
git commit -m "feat(ggml): add a lazy Vulkan loader shim so the backend can link statically"
```

---

### Task 2: Build ggml with Vulkan for linux-x86_64

**Files:**
- Modify: `scripts/48-whisper.sh`
- Modify: `ffmpeg-base.dockerfile` (only if `glslc` is missing — check first)
- Modify: `tools/ggml-variants/build-common.sh` (so the harness can build a Vulkan-enabled ffmpeg)

**Interfaces:**
- Consumes: `scripts/includes/vk_loader_shim.c` from Task 1.
- Produces: `libggml-cpu-variants.a` additionally containing `ggml-vulkan` and the compiled shim; `whisper.pc` naming them; the ggml Vulkan backend registered in the built `ffmpeg`.

- [ ] **Step 1: Check what the base image already has**

```bash
docker run --rm nomercyentertainment/ffmpeg-base:latest bash -c \
  'command -v glslc || echo "NO glslc"; ls /usr/include/vulkan/vulkan_core.h 2>/dev/null || echo "NO vulkan headers"'
```

The spike found `glslc` absent and installable with `apt-get install -y glslc libvulkan-dev spirv-headers`. `scripts/45-vulkan.sh` builds shaderc from source for libplacebo, which *links* it; ggml only needs the `glslc` binary as a build tool, so the apt package is enough. Record what you find; if `glslc` is present, skip the dockerfile change entirely.

- [ ] **Step 2: Write the failing check**

Add to `tools/ggml-variants/build-linux-x86_64.sh`, after the existing assertions:

```bash
echo "== ggml vulkan backend present in the binary?"
if "${WORK}/ffmpeg" -hide_banner -v verbose -nostats -f lavfi -i "anullsrc=r=16000:cl=mono" \
      -t 0.1 -c:a pcm_s16le -f null - 2>&1 | grep -qi "vulkan"; then
    echo "  ok: vulkan mentioned by the binary"
else
    echo "  FAIL: no vulkan backend in this build"; fail=1
fi
echo "== still static?"
if file "${WORK}/ffmpeg" | grep -q "statically linked"; then echo "  ok: static"; else echo "  FAIL: not static"; fail=1; fi
echo "== does it import a vulkan loader (it must not)?"
if ldd "${WORK}/ffmpeg" 2>&1 | grep -qi vulkan; then echo "  FAIL: links the loader"; fail=1; else echo "  ok: no loader dependency"; fi
```

- [ ] **Step 3: Run it to verify it fails**

Expected: `FAIL: no vulkan backend in this build` — the build script does not enable Vulkan yet.

- [ ] **Step 4: Add the Vulkan step to `scripts/48-whisper.sh`**

Insert alongside the existing CPU-variant work, gated so darwin never takes it:

```bash
# --- Vulkan GPU backend ----------------------------------------------------
#
# ggml's Vulkan backend needs three symbols from the Vulkan loader. Linking the
# real loader would make these static binaries depend on a shared library most
# machines do not have, so scripts/includes/vk_loader_shim.c supplies those three
# and opens the system loader at first use instead. The binary stays static and
# Vulkan stays optional: no driver simply means the CPU backend is used.
#
# find_package(Vulkan) still has to be satisfied at configure time. ggml-vulkan is
# built as a static archive, so Vulkan_LIBRARY is never linked - it only has to
# exist as a path, hence the empty stub archive.
NM_VULKAN=0
if [[ ${TARGET_OS} != darwin ]]; then
    NM_VULKAN=1
fi

if [[ ${NM_VULKAN} == 1 ]]; then
    nm_vk_dir=/build/vulkan-stub
    mkdir -p ${nm_vk_dir}/include
    # Copy only the architecture-independent Vulkan headers. Pointing
    # Vulkan_INCLUDE_DIR at /usr/include drags glibc's stdint.h ahead of the cross
    # toolchain's own and breaks the mingw build.
    for d in vulkan vk_video spirv; do
        [[ -d /usr/include/${d} ]] && cp -r /usr/include/${d} ${nm_vk_dir}/include/
    done
    : > ${nm_vk_dir}/empty.c
    gcc -c ${nm_vk_dir}/empty.c -o ${nm_vk_dir}/empty.o
    ar rcs ${nm_vk_dir}/libvulkan-stub.a ${nm_vk_dir}/empty.o

    WHISPER_CMAKE_COMMON_ARG="${WHISPER_CMAKE_COMMON_ARG} -DGGML_VULKAN=ON"
    WHISPER_CMAKE_COMMON_ARG="${WHISPER_CMAKE_COMMON_ARG} -DVulkan_INCLUDE_DIR=${nm_vk_dir}/include"
    WHISPER_CMAKE_COMMON_ARG="${WHISPER_CMAKE_COMMON_ARG} -DVulkan_LIBRARY=${nm_vk_dir}/libvulkan-stub.a"
    WHISPER_CMAKE_COMMON_ARG="${WHISPER_CMAKE_COMMON_ARG} -DVulkan_GLSLC_EXECUTABLE=$(command -v glslc)"
    log "Vulkan backend enabled for ${TARGET_OS}-${ARCH}"
fi
```

and, where the variants archive is assembled, compile the shim and add both it and `ggml-vulkan` to the archive:

```bash
if [[ ${NM_VULKAN} == 1 ]]; then
    ${CC:-cc} ${CFLAGS} -I${nm_vk_dir}/include -c /scripts/includes/vk_loader_shim.c \
        -o ${nm_variant_dir}/vk_loader_shim.o 2>&1 | log -a
    if [ ${PIPESTATUS[0]} -ne 0 ]; then log "Error: vulkan shim build failed"; exit 1; fi
    nm_vk_archive=$(find ${PREFIX}/lib -name 'libggml-vulkan.a' -o -name 'ggml-vulkan.a' | head -1)
    if [[ -z ${nm_vk_archive} ]]; then log "Error: GGML_VULKAN=ON but no ggml-vulkan archive was produced"; exit 1; fi
    nm_objects="${nm_objects} ${nm_variant_dir}/vk_loader_shim.o"
fi
```

The Vulkan archive itself is added to `whisper.pc`'s `Libs:` next to the variants archive rather than merged, because it is large and unmodified:

```bash
if [[ ${NM_VULKAN} == 1 ]]; then
    lib_flags="${lib_flags} -lggml-vulkan"
fi
```

- [ ] **Step 5: Run the harness and verify the checks pass**

```bash
docker run --rm -v "$PWD:/repo" -v ffblas-vol:/vol ubuntu:24.04 bash /repo/tools/ggml-variants/build-linux-x86_64.sh
```

Expected: PASS, including the three new assertions, plus the CPU-variant assertions from the previous plan still passing.

- [ ] **Step 6: Record the size cost**

```bash
ls -la "${WORK}/ffmpeg"
```

Compare against the same harness's binary from before this task and note the delta; the spec budgets ~63 MB.

- [ ] **Step 7: Commit**

```bash
git add scripts/48-whisper.sh tools/ggml-variants/build-common.sh tools/ggml-variants/build-linux-x86_64.sh
git commit -m "build(ggml): build the Vulkan backend with a static loader shim on linux-x86_64"
```

---

### Task 3: Backend selection, software-device filter, and filter reporting

**Files:**
- Modify: `scripts/includes/ggml_cpu_dispatch.c`
- Modify: `scripts/includes/nm_ggml_cpu.h`
- Modify: `scripts/includes/af_whisper.c`
- Modify: `scripts/includes/af_stemsplit.c`

**Interfaces:**
- Consumes: the Vulkan-enabled build from Task 2.
- Produces, declared in `nm_ggml_cpu.h`:
  - `ggml_backend_t nm_ggml_backend_init(int use_gpu);` — returns a ready backend: a usable GPU when `use_gpu` is non-zero and one exists, otherwise the best CPU variant. Never returns NULL unless even the CPU backend fails.
  - `int nm_ggml_gpu_usable(void);` — 1 when a non-software GPU device exists. This is what `af_whisper.c` needs; see the note below.
  - `const char *nm_ggml_backend_name(void);` — `"vulkan"` or `"cpu"`, for metadata.
  - `const char *nm_ggml_backend_device(void);` — the device description, e.g. `"NVIDIA GeForce RTX 3070"`, or the CPU variant name when running on CPU.
  - the existing `nm_ggml_cpu_variant_name()` is unchanged.

**The two filters are NOT symmetrical, and getting this wrong would make the whisper
reporting a lie.** `af_stemsplit.c` creates its own ggml backend, so it calls
`nm_ggml_backend_init()` and uses what it gets. `af_whisper.c` does not: it calls
`whisper_init_from_file_with_params()`, and whisper.cpp selects the backend internally
from `params.use_gpu`. So for whisper the job is different — decide with
`nm_ggml_gpu_usable()` whether a GPU is worth allowing (which is also what keeps
whisper.cpp away from a software rasteriser, since it would happily take one), pass the
result into `params.use_gpu`, and report accordingly. Do not report a device whisper was
never told to use.

- [ ] **Step 1: Write the failing test**

Extend `tools/ggml-variants/vulkan-probe.c` with a second mode that exercises the production selector rather than the registry directly, so the filter and the probe share one code path:

```c
/* invoked as: vulkan-probe select
 * Prints what nm_ggml_backend_init() actually chose. This is the function the
 * filters call, so this is the thing that must be right. */
#include "nm_ggml_cpu.h"

static int mode_select(int use_gpu)
{
    ggml_backend_t be = nm_ggml_backend_init(use_gpu);
    if (!be) { printf("FAIL: no backend at all\n"); return 1; }
    printf("selected_backend=%s\n", nm_ggml_backend_name());
    printf("selected_device=%s\n", nm_ggml_backend_device());
    ggml_backend_free(be);
    return 0;
}
```

with `main` dispatching on `argv[1]` and the existing matmul comparison kept for the default mode.

- [ ] **Step 2: Run it to verify it fails**

Expected: compile error — `nm_ggml_backend_init` is not declared.

- [ ] **Step 3: Add the selector to `ggml_cpu_dispatch.c`**

```c
/* Which device should a filter run on?
 *
 * GPU first when the caller allows it, then the best CPU instruction-set
 * variant. Two rules here are not preferences but measured requirements:
 *
 *   - Only the registry path may be used. ggml's legacy Vulkan entry points
 *     (ggml_backend_vk_init, ggml_backend_vk_get_device_count) do not catch
 *     Vulkan's exceptions, so on the very ordinary "loader present, no usable
 *     driver" they terminate the process.
 *   - Software rasterisers are skipped. Mesa's llvmpipe segfaults inside a
 *     static binary because of its nested dlopen of LLVM, and a headless Linux
 *     server advertises exactly such a device.
 *
 * Anything unexpected falls back to the CPU. A machine without a usable GPU must
 * behave exactly as it did before this code existed.
 */
static const char *nm_backend_name   = "cpu";
static const char *nm_backend_device = NULL;

**AMENDED AFTER TASK 1 — read this before writing the selector.** Task 1 measured that a
machine with Mesa's software Vulkan does not merely offer a bad device: the process dies at
exit 139 *inside the Vulkan loader's own ICD probing*, before any of our code runs. Filtering
devices after enumeration therefore cannot work, because the enumerating call is the one that
crashes. So the selector must FIRST neutralise software ICDs, and only then touch ggml's
registry:

```c
/* Keep the Vulkan loader away from software ICDs before it ever probes them.
 *
 * Mesa's llvmpipe nested-dlopens LLVM, which a static binary cannot survive - and the
 * crash happens inside the loader's ICD probe, i.e. inside the very call that would
 * otherwise hand us a device list to filter. So the guard has to come first: read the
 * manifests ourselves, keep the hardware ones, and point the loader at those. When none
 * are hardware we point it at a path that does not exist, which Task 1 proved the loader
 * reports cleanly as "no device".
 *
 * Linux and FreeBSD only: Windows did not reproduce the crash, and its loader has no
 * manifest directory of this shape.
 */
static void nm_vk_restrict_to_hardware_icds(void);
```

Implement it by scanning `/usr/share/vulkan/icd.d/*.json` plus anything already named by
`VK_ICD_FILENAMES` or `VK_DRIVER_FILES`, reading each manifest's `library_path`, and treating
a path containing `lvp`, `llvmpipe`, `swiftshader` or `lavapipe` as software. Set
`VK_ICD_FILENAMES` to the surviving manifests joined by the platform separator, or to
`/nonexistent.json` when the survivor list is empty. Call it once, before the first registry
access, guarded so it never runs on Windows.

The device-level check below stays as a second line of defence — it costs nothing and catches
a software device that reaches us through a manifest we did not classify.

static int nm_device_is_software(ggml_backend_dev_t dev)
{
    const char *name = ggml_backend_dev_name(dev);
    const char *desc = ggml_backend_dev_description(dev);
    static const char *markers[] = { "llvmpipe", "swiftshader", "lavapipe", "software", NULL };

    for (int i = 0; markers[i]; i++) {
        if (name && strstr(name, markers[i])) return 1;
        if (desc && strstr(desc, markers[i])) return 1;
    }
    return 0;
}

ggml_backend_t nm_ggml_backend_init(int use_gpu)
{
    if (use_gpu) {
        size_t n = ggml_backend_dev_count();
        for (size_t i = 0; i < n; i++) {
            ggml_backend_dev_t dev = ggml_backend_dev_get(i);
            if (!dev || ggml_backend_dev_type(dev) != GGML_BACKEND_DEVICE_TYPE_GPU)
                continue;
            if (nm_device_is_software(dev))
                continue;
            ggml_backend_t be = ggml_backend_dev_init(dev, NULL);
            if (be) {
                nm_backend_name   = ggml_backend_dev_backend_reg(dev)
                                  ? ggml_backend_reg_name(ggml_backend_dev_backend_reg(dev)) : "gpu";
                nm_backend_device = ggml_backend_dev_description(dev);
                return be;
            }
        }
    }
    nm_backend_name   = "cpu";
    nm_backend_device = nm_ggml_cpu_variant_name();
    return ggml_backend_cpu_init();
}

const char *nm_ggml_backend_name(void)   { return nm_backend_name; }
const char *nm_ggml_backend_device(void) { return nm_backend_device ? nm_backend_device
                                                                    : nm_ggml_cpu_variant_name(); }
```

Declare all three in `nm_ggml_cpu.h` with the same comment voice as the existing declaration.

- [ ] **Step 4: Run the probe's select mode in all four conditions**

In the container, with the builds from Task 1:

```bash
/tmp/nm-vkshim/vulkan-probe select        # no loader at all
VK_ICD_FILENAMES=/nonexistent.json /tmp/nm-vkshim/vulkan-probe select   # loader, no driver
# with mesa-vulkan-drivers installed, i.e. a software device present:
/tmp/nm-vkshim/vulkan-probe select
```

Expected: `selected_backend=cpu` in all three, no crash, exit 0 — including the software case, which is the one Task 1 Step 5 recorded as previously selectable.

- [ ] **Step 5: Use the selector in both filters**

In `af_stemsplit.c`, replace the direct CPU init:

```c
    /* GPU when one is usable, otherwise the best CPU variant. */
    s->backend = nm_ggml_backend_init(s->use_gpu);
    av_log(ctx, AV_LOG_INFO, "stemsplit: ggml backend '%s' (%s).\n",
           nm_ggml_backend_name(), nm_ggml_backend_device());
```

and add the metadata beside the existing `cpu_variant` key in `ss_push_outputs`:

```c
    av_dict_set(&frame->metadata, "lavfi.stemsplit.backend", nm_ggml_backend_name(), 0);
```

`af_stemsplit.c` has no `use_gpu` option today — add one matching whisper's:

```c
    { "use_gpu", "use a GPU backend when one is available", OFFSET(use_gpu), AV_OPT_TYPE_BOOL, { .i64 = 1 }, 0, 1, FLAGS },
```

In `af_whisper.c` the shape is different, per the note in the Interfaces block. Gate
whisper's own GPU use on our decision, so whisper.cpp can never pick a software
rasteriser behind our back:

```c
    /* whisper.cpp picks its own backend from this flag, so decide here whether a
     * GPU is worth allowing at all. nm_ggml_gpu_usable() skips software
     * rasterisers, which whisper.cpp would otherwise happily select - and which
     * crash inside a static binary. */
    params.use_gpu = wctx->use_gpu && nm_ggml_gpu_usable();
    params.gpu_device = wctx->gpu_device;

    wctx->ctx_wsp = whisper_init_from_file_with_params(wctx->model_path, params);
    ...
    av_log(ctx, AV_LOG_INFO, "whisper: ggml backend '%s' (%s).\n",
           params.use_gpu ? nm_ggml_backend_name() : "cpu",
           params.use_gpu ? nm_ggml_backend_device() : nm_ggml_cpu_variant_name());
```

and set the metadata beside `lavfi.whisper.text` — not inside the language branch, which
was already corrected once for `cpu_variant`:

```c
    av_dict_set(&frame->metadata, "lavfi.whisper.backend",
                params_use_gpu ? nm_ggml_backend_name() : "cpu", 0);
```

storing whatever flag you ended up passing to whisper in the filter context so the
metadata reports what actually ran rather than what was requested.

- [ ] **Step 6: Rebuild and verify end to end on linux**

Run `tools/ggml-variants/build-linux-x86_64.sh` and confirm both filters log a backend and publish the metadata key, on a machine with no GPU (so: `cpu`).

- [ ] **Step 7: Commit**

```bash
git add scripts/includes/ggml_cpu_dispatch.c scripts/includes/nm_ggml_cpu.h scripts/includes/af_whisper.c scripts/includes/af_stemsplit.c tools/ggml-variants/vulkan-probe.c
git commit -m "feat(ggml): choose a GPU backend when one is usable, skipping software devices"
```

---

### Task 4: windows-x86_64 and the real GPU

**Files:**
- Modify: `tools/ggml-variants/build-windows-x86_64.sh`

**Interfaces:**
- Consumes: Tasks 1-3.
- Produces: measured GPU numbers on the RTX 3070, and the #64 regression re-check.

- [ ] **Step 1: Build windows-x86_64 with Vulkan**

```bash
docker run --rm -v "$PWD:/repo" -v ffblas-vol:/vol ubuntu:24.04 bash /repo/tools/ggml-variants/build-windows-x86_64.sh
```

- [ ] **Step 2: Confirm it does not import the loader**

```bash
docker run --rm -v "$TMP/nm-win:/w" ubuntu:24.04 bash -c \
  'apt-get update -qq >/dev/null && apt-get install -y -qq --no-install-recommends binutils-mingw-w64 >/dev/null
   x86_64-w64-mingw32-objdump -p /w/ffmpeg.exe | grep "DLL Name"'
```

Expected: no `vulkan-1.dll`.

- [ ] **Step 3: Run whisper on the GPU and measure**

On the Windows host, with `ggml-base.en.bin` and a 60 s wav:

```powershell
.\ffmpeg.exe -hide_banner -v info -nostats -i vocals60.wav `
  -af "whisper=model=ggml-base.en.bin:language=en,ametadata=mode=print:key=lavfi.whisper.backend" `
  -f null - 2>&1 | Select-String "ggml backend|lavfi.whisper.backend"
```

Expected: the backend line names `vulkan` and the RTX 3070. Time it against `use_gpu=0` and record both.

- [ ] **Step 4: Run stemsplit on the GPU and check the output**

Compare a 30 s accompaniment split GPU vs `use_gpu=0`, with the RMS difference at least 60 dB below the signal (the spec's tolerance — GPU and CPU are not bit-identical).

- [ ] **Step 5: Force the fallback and confirm it still runs**

```powershell
$env:VK_ICD_FILENAMES="C:\nonexistent.json"
.\ffmpeg.exe ... 2>&1 | Select-String "ggml backend"
```

Expected: backend `cpu`, run completes.

- [ ] **Step 6: Re-run the #64 exit-hang reproduction**

20 consecutive stemsplit runs, each must exit within seconds. Vulkan adds driver threads at exit, which is exactly the class of problem #64 was about.

- [ ] **Step 7: Commit**

```bash
git add tools/ggml-variants/build-windows-x86_64.sh
git commit -m "build(ggml): enable the Vulkan backend on windows-x86_64"
```

---

### Task 5: The remaining four platforms

**Files:**
- Modify: `scripts/48-whisper.sh` (only if a platform needs an exception)
- Modify: `tools/ggml-variants/build-aarch64.sh`

**Interfaces:**
- Consumes: Tasks 1-4.
- Produces: linux-aarch64, windows-aarch64 and freebsd-x86_64 built with Vulkan, or a documented reason why one of them does not get it.

- [ ] **Step 1: Build linux-aarch64 and windows-aarch64 with Vulkan**

Both use the same code paths already verified; what is unverified is the toolchain's handling of the Vulkan build. Confirm the three undefined symbols and no loader dependency on each, exactly as Task 1 Step 4 and Task 4 Step 2 did.

- [ ] **Step 2: Run the aarch64 probe under emulation**

```bash
docker run --rm --platform linux/arm64 -v "$TMP/nm-arm:/w" ubuntu:24.04 /w/vulkan-probe select
```

Expected: `selected_backend=cpu` (qemu offers no GPU), no crash. Emulated timing is meaningless and must not be quoted.

- [ ] **Step 3: Build freebsd-x86_64 with Vulkan**

This is the gated one: FreeBSD uses clang with libc++ and its static `dlopen` behaviour is unproven. Build it and report exactly what happens. If the build fails or the probe cannot be made to fall back cleanly, **do not force it** — set `NM_VULKAN=0` for freebsd with a comment explaining what was tried, and report it.

- [ ] **Step 4: Record per-platform status**

Write a short table into the report: platform, Vulkan enabled yes/no, what was verified, what remains for real hardware.

- [ ] **Step 5: Commit**

```bash
git add scripts/48-whisper.sh tools/ggml-variants/build-aarch64.sh
git commit -m "build(ggml): extend the Vulkan backend to the remaining platforms"
```

---

### Task 6: CI assertions and documentation

**Files:**
- Modify: `tests/smoke.sh`, `tests/smoke.ps1`, `tests/lib/cpu-variant.sh`, `tests/lib/cpu-variant.ps1`
- Modify: `README.md`

**Interfaces:**
- Consumes: Tasks 1-5.
- Produces: a CI guard that a Vulkan-enabled binary really carries the backend and still starts without a driver.

- [ ] **Step 1: Write the failing CI assertion**

Add to `tests/lib/cpu-variant.sh` (and its PowerShell twin), reusing the darwin check already there:

```bash
# Vulkan lands in five of the seven platforms; darwin gets Metal later and must skip.
cpu_variant_platform_has_vulkan() {
    case "$1" in
    *darwin*) return 1 ;;
    *)        return 0 ;;
    esac
}

# The backend's presence is greppable, so this works even for the platforms a CI
# runner cannot execute - which are exactly the ones with the least other evidence.
assert_vulkan_backend_present() {
    local platform="$1" bin="$2"
    if ! cpu_variant_platform_has_vulkan "${platform}"; then
        note "vulkan: skipped on ${platform} (Metal is a later phase)"
        return 0
    fi
    if grep -aq "ggml_vulkan" "${bin}" || grep -aq "vkGetInstanceProcAddr" "${bin}"; then
        ok "vulkan: backend present"
        return 0
    fi
    fail "vulkan: ${bin} does not carry the ggml Vulkan backend"
    return 1
}

# A machine with a loader but no usable driver is the case that used to crash.
assert_vulkan_absence_is_safe() {
    local bin="$1"
    if VK_ICD_FILENAMES=/nonexistent.json "${bin}" -hide_banner -version >/dev/null 2>&1; then
        ok "vulkan: starts with no usable driver"
        return 0
    fi
    fail "vulkan: binary fails to start when no driver is usable"
    return 1
}
```

Wire `assert_vulkan_backend_present` in before the cross-exec early return (it needs no execution) and `assert_vulkan_absence_is_safe` after it, alongside the existing startup check.

- [ ] **Step 2: Prove it can fail**

Run it against the pre-Vulkan binary from the shipped release at `output/ffmpeg-9.0-windows-x86_64/ffmpeg.exe`. Expected: FAIL. A check that cannot fail is worthless.

- [ ] **Step 3: Prove it passes on a Vulkan build**

- [ ] **Step 4: Document it in the README**

Extend the CPU instruction-set section written in the previous plan with a GPU subsection: what is used and when, the `use_gpu` option, the metadata keys, that software rasterisers are deliberately skipped, that output is numerically equivalent but not bit-identical to the CPU path, and which platforms have it. Quote only measured numbers.

- [ ] **Step 5: Commit**

```bash
git add tests/ README.md
git commit -m "test: assert the vulkan backend is present and falls back cleanly"
```

---

### Task 7: Evidence for the PR

**Files:** none changed.

- [ ] **Step 1: Collect the numbers**

Per platform where it could be measured: whisper and stemsplit wall time on GPU vs `use_gpu=0`, the selected device, the archive size before and after, and the build-time delta.

- [ ] **Step 2: Collect the safety evidence**

For every platform: the no-driver case, the software-device case where applicable, and the CPU-variant dispatcher still choosing correctly with no GPU present.

- [ ] **Step 3: Write the summary**

A table of what was verified where, and an explicit list of what remains unverified and needs real hardware or the full CI run. Do not describe an emulated result as a measurement.

---

## Deliberately not in this plan

- **CUDA (phase 2) and Metal (phase 3)** each get their own spec and plan. Metal is the
  one that makes macOS benefit, and the spec establishes it is feasible with this
  toolchain because ggml can embed the shader source and compile it on the user's
  machine — no Apple shader compiler at build time.
- **The double filter instantiation.** Both filters are constructed twice per ffmpeg
  invocation, so whisper loads its model twice. The spec flags this as something that
  should be fixed before or with this work, because on a GPU it wastes VRAM rather than
  RAM. The owner has scheduled it after issue #25, so it is not a task here — but if GPU
  testing shows doubled VRAM, say so immediately rather than working around it.

## Notes for whoever executes this

- **The two crash modes in the Global Constraints are not theoretical.** Both were reproduced during the spike. If you find yourself "simplifying" the shim to return NULL, or calling `ggml_backend_vk_init()` because it is shorter, you are re-introducing a measured crash.
- **A container is a perfectly good "no GPU" test** and the cheapest one available. Use it constantly.
- **Never quote a qemu timing.** Emulated ARM numbers are meaningless; they prove only that code runs.
- **The GPU is not obliged to be faster.** If a measured GPU path is slower than the CPU one for a given workload, report it — that is a finding, not a failure, and it changes whether the default should stay on for that case.
