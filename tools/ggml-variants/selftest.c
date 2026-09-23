/* Self-test: two packed ggml CPU variants in one static binary. */
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <time.h>
#include <ggml.h>
#include <ggml-alloc.h>
#include <ggml-backend.h>

extern ggml_backend_reg_t lo_ggml_backend_cpu_reg(void);
extern ggml_backend_reg_t hi_ggml_backend_cpu_reg(void);
extern void lo_ggml_backend_cpu_set_n_threads(ggml_backend_t, int);
extern void hi_ggml_backend_cpu_set_n_threads(ggml_backend_t, int);

#define M 1024
#define K 1024
#define N 256

static double now(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

static float *run(ggml_backend_reg_t reg, void (*setth)(ggml_backend_t, int),
                  const char *label, float *a_src, float *b_src, double *ms)
{
    ggml_backend_dev_t dev = ggml_backend_reg_dev_get(reg, 0);
    ggml_backend_t be = ggml_backend_dev_init(dev, NULL);
    if (!be) { printf("FAIL: %s backend init\n", label); return NULL; }
    setth(be, 4);

    struct ggml_init_params ip = { ggml_tensor_overhead() * 8 + ggml_graph_overhead(), NULL, true };
    struct ggml_context *ctx = ggml_init(ip);
    struct ggml_tensor *a = ggml_new_tensor_2d(ctx, GGML_TYPE_F16, K, M);
    struct ggml_tensor *b = ggml_new_tensor_2d(ctx, GGML_TYPE_F32, K, N);
    struct ggml_tensor *c = ggml_mul_mat(ctx, a, b);
    struct ggml_cgraph *gf = ggml_new_graph(ctx);
    ggml_build_forward_expand(gf, c);

    ggml_backend_buffer_t buf = ggml_backend_alloc_ctx_tensors(ctx, be);
    if (!buf) { printf("FAIL: %s alloc\n", label); return NULL; }
    ggml_fp32_to_fp16_row(a_src, (ggml_fp16_t *) a->data, (size_t) M * K);
    ggml_backend_tensor_set(b, b_src, 0, ggml_nbytes(b));

    ggml_backend_graph_compute(be, gf);
    double t0 = now();
    for (int i = 0; i < 5; i++)
        ggml_backend_graph_compute(be, gf);
    *ms = (now() - t0) * 1000.0 / 5.0;

    float *out = malloc(ggml_nbytes(c));
    ggml_backend_tensor_get(c, out, 0, ggml_nbytes(c));
    printf("  %-3s %8.2f ms/matmul\n", label, *ms);
    ggml_free(ctx);
    ggml_backend_buffer_free(buf);
    ggml_backend_free(be);
    return out;
}

int main(void)
{
    float *a = malloc(sizeof(float) * M * K), *b = malloc(sizeof(float) * K * N);
    srand(1234);
    for (size_t i = 0; i < (size_t) M * K; i++) a[i] = (rand() / (float) RAND_MAX) - 0.5f;
    for (size_t i = 0; i < (size_t) K * N; i++) b[i] = (rand() / (float) RAND_MAX) - 0.5f;

    double lo_ms = 0, hi_ms = 0;
    float *lo = run(lo_ggml_backend_cpu_reg(), lo_ggml_backend_cpu_set_n_threads, "lo", a, b, &lo_ms);
    float *hi = run(hi_ggml_backend_cpu_reg(), hi_ggml_backend_cpu_set_n_threads, "hi", a, b, &hi_ms);
    if (!lo || !hi) return 1;

    double maxdiff = 0, sum = 0;
    size_t n = (size_t) M * N;
    for (size_t i = 0; i < n; i++) {
        double d = fabs(lo[i] - hi[i]);
        if (d > maxdiff) maxdiff = d;
        sum += fabs(lo[i]);
    }
    double rel = maxdiff / (sum / n);
    printf("  relative difference %.2g, speedup %.2fx\n", rel, lo_ms / hi_ms);

    if (rel > 1e-2)   { printf("FAIL: variants disagree numerically\n"); return 1; }
    if (hi_ms >= lo_ms) { printf("FAIL: high variant is not faster - variants were merged\n"); return 1; }
    printf("PASS\n");
    return 0;
}
