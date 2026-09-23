/* Probe: what does ggml's registry offer, and does it compute correctly?
 * Exits 0 whether or not a GPU exists - "no GPU" is a valid, expected answer.
 * Exits non-zero only on a crash or a wrong result, which is what we test for.
 *
 * Three modes:
 *   (no argument)      the registry/matmul probe this file started as.
 *   select [ug] [dev]  exercise the PRODUCTION selector, nm_ggml_backend_init(),
 *                      so the filters and this probe share one code path and a
 *                      machine that crashes here would have crashed FFmpeg.
 *   whisper-init [ug]  reproduce af_whisper.c's init() ORDERING, which is a
 *                      different thing from the selector and is where the
 *                      use_gpu=0 short circuit lived. */
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <string.h>
#include <ggml.h>
#include <ggml-alloc.h>
#include <ggml-backend.h>
#include <ggml-cpu.h>   /* ggml_backend_is_cpu */
#include "nm_ggml_cpu.h"

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

/* What nm_ggml_backend_init() actually chose. This is the function both filters
 * call, so this is the thing that has to be right. Reporting is deliberately
 * done the same way the filters do it - the request AND'ed with what is
 * available - so a "cpu" here means a "cpu" there. */
static int mode_select(int use_gpu, int gpu_device)
{
    ggml_backend_t be;
    int usable;

    /* Ask before creating anything: this is the call that runs the software-ICD
     * guard, and on a Mesa machine the process died right here before it
     * existed. */
    usable = nm_ggml_gpu_usable();
    printf("gpu_usable=%d\n", usable);
    if (nm_ggml_backend_notice())
        printf("guard_notice=%s\n", nm_ggml_backend_notice());
    /* Printed AFTER the guard has run, because the guard may rewrite these for
     * the whole process - which FFmpeg's own Vulkan code reads too. On a
     * healthy machine they must come back exactly as the caller set them; a
     * "(unset)" here that turns into "/nonexistent.json" is the whole of
     * finding C2. */
    {
        const char *icd = getenv("VK_ICD_FILENAMES");
        const char *drv = getenv("VK_DRIVER_FILES");

        printf("vk_icd_filenames=%s\n", icd && *icd ? icd : "(unset)");
        printf("vk_driver_files=%s\n", drv && *drv ? drv : "(unset)");
    }

    be = nm_ggml_backend_init(use_gpu, gpu_device);
    if (!be) {
        printf("FAIL: no backend at all\n");
        return 1;
    }

    printf("requested_gpu=%d\n", use_gpu);
    printf("gpu_count=%d\n", nm_ggml_gpu_count());
    printf("gpu_device=%d\n", gpu_device);
    /* Indexed, so that asking for a device this machine does not have reports
     * the CPU rather than naming device 0 - which is what it used to do, and
     * would have been believed. */
    printf("selected_backend=%s\n", (use_gpu && usable) ? nm_ggml_backend_name(gpu_device) : "cpu");
    printf("selected_device=%s\n", (use_gpu && usable) ? nm_ggml_backend_device(gpu_device)
                                                       : nm_ggml_cpu_variant_name());
    printf("is_cpu=%d\n", ggml_backend_is_cpu(be) ? 1 : 0);

    /* A selection that cannot compute is not a selection. Runs the same matmul
     * the default mode does, on whatever was chosen. */
    {
        float *a = malloc(sizeof(float) * M * K), *b = malloc(sizeof(float) * K * N);
        float *out;
        size_t i;

        srand(99);
        for (i = 0; i < (size_t) M * K; i++) a[i] = (rand() / (float) RAND_MAX) - 0.5f;
        for (i = 0; i < (size_t) K * N; i++) b[i] = (rand() / (float) RAND_MAX) - 0.5f;
        out = run_on(be, "selected", a, b);
        free(a); free(b);
        if (!out) { ggml_backend_free(be); return 1; }
        free(out);
    }

    ggml_backend_free(be);
    printf("PASS\n");
    return 0;
}

static int mode_registry(void)
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

    /* "No GPU" is a valid answer on most machines, so it's not a FAIL by
     * default - but on a machine known to have one, silence here would mean
     * the shim quietly lost it. NM_VK_EXPECT_GPU=1 turns that into an
     * assertion for exactly those runs (this host's RTX 3070, and later the
     * fleet's GPU hardware) without changing behaviour anywhere else. */
    if (!gpu && getenv("NM_VK_EXPECT_GPU") && !strcmp(getenv("NM_VK_EXPECT_GPU"), "1")) {
        printf("FAIL: NM_VK_EXPECT_GPU=1 but no GPU device was found\n");
        return 1;
    }

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

/* af_whisper.c's init() ordering, reduced to the lines that matter.
 *
 * This mode exists because of a shipped bug no other mode could see: the guard
 * used to be the right-hand side of `use_gpu && nm_ggml_gpu_usable()`, so
 * use_gpu=0 short-circuited it away and the ggml_backend_load_all() on the next
 * line built the registry unguarded - exit 139 on a Mesa machine. `select 0`
 * cannot catch that: it calls nm_ggml_gpu_usable() unconditionally, which is
 * precisely what the filter failed to do. So this mode reproduces the FILTER's
 * control flow, not the selector's. */
static int mode_whisper_init(int use_gpu)
{
    int gpu_usable, gpu_active;

    printf("use_gpu=%d\n", use_gpu);

    /* The line under test: it must not be guarded by use_gpu. */
    gpu_usable = nm_ggml_gpu_usable();
    gpu_active = use_gpu && gpu_usable;
    printf("gpu_usable=%d gpu_active=%d\n", gpu_usable, gpu_active);

    /* What af_whisper.c does next, and what kills an unguarded process. */
    ggml_backend_load_all();
    printf("survived ggml_backend_load_all(), devices=%zu\n", ggml_backend_dev_count());
    printf("PASS\n");
    return 0;
}

int main(int argc, char **argv)
{
    if (argc > 1 && !strcmp(argv[1], "select"))
        return mode_select(argc > 2 ? atoi(argv[2]) : 1, argc > 3 ? atoi(argv[3]) : 0);
    if (argc > 1 && !strcmp(argv[1], "whisper-init"))
        return mode_whisper_init(argc > 2 ? atoi(argv[2]) : 1);
    return mode_registry();
}
