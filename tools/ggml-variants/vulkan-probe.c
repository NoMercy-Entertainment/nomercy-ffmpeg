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
