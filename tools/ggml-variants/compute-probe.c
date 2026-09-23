/*
 * Verification-only: run a real matmul through whichever ggml CPU variant the
 * dispatcher selects, and check its numbers against a reference run.
 *
 * Why this exists alongside nm-probe: nm-probe answers "which variant would be
 * selected", which is a question about ggml_cpu_dispatch.c alone -- it never
 * enters a backend, so none of the PACKED code ever executes. On a platform
 * that can only be exercised under emulation, that leaves the thing most worth
 * proving unproven: that each variant's own compiled kernels run at all
 * (no SIGILL from an instruction the variant should not have contained) and
 * agree with the others.
 *
 * Usage: compute-probe [reference-file]
 *   With no argument, or with a path that does not exist yet, it computes and
 *   writes the reference. With a path that exists, it computes again and
 *   compares, exiting non-zero if the results disagree. So the caller runs the
 *   BASELINE variant first to lay down the reference, then every other variant
 *   against it.
 *
 * The tolerance is not zero on purpose: the armv8.2 variant does fp16
 * arithmetic where the armv8.0 one widens to fp32, so the two legitimately
 * differ in the last bits. Same 1e-2 relative bound tools/ggml-variants/
 * selftest.c uses, and for the same reason.
 *
 * Deliberately reports NO timing. Every number this can produce on this
 * workstation comes from emulation and would be meaningless.
 */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <ggml.h>
#include <ggml-alloc.h>
#include <ggml-backend.h>
/* ggml_backend_cpu_init / _set_n_threads live here, not in ggml-backend.h.
 * On a dispatch platform these names resolve to ggml_cpu_dispatch.c's
 * forwarders rather than to any one variant, which is exactly the point. */
#include <ggml-cpu.h>

#include "nm_ggml_cpu.h"

/* Small enough to stay quick under qemu, large enough that the quantised /
 * blocked kernels (which is where the instruction-set differences live) are
 * the ones doing the work. */
#define M 256
#define K 256
#define N 32

/* A fixed LCG rather than rand(): the reference file has to reproduce across
 * processes and C libraries, and rand() guarantees neither. */
static unsigned long long lcg_state = 1234567ull;
static float next_float(void)
{
    lcg_state = lcg_state * 6364136223846793005ULL + 1442695040888963407ULL;
    return (float) ((lcg_state >> 33) & 0xffffff) / (float) 0xffffff - 0.5f;
}

int main(int argc, char **argv)
{
    const char *ref_path = argc > 1 ? argv[1] : NULL;
    const char *name = nm_ggml_cpu_variant_name();
    printf("variant %s\n", name);
    fflush(stdout);

    float *a_src = malloc(sizeof(float) * M * K);
    float *b_src = malloc(sizeof(float) * K * N);
    if (!a_src || !b_src) { printf("FAIL: out of memory\n"); return 1; }
    for (size_t i = 0; i < (size_t) M * K; i++) a_src[i] = next_float();
    for (size_t i = 0; i < (size_t) K * N; i++) b_src[i] = next_float();

    /* ggml_backend_cpu_init() is the dispatcher's forwarder, so this is the
     * selected variant's own backend, not a generic one. */
    ggml_backend_t be = ggml_backend_cpu_init();
    if (!be) { printf("FAIL: backend init\n"); return 1; }
    ggml_backend_cpu_set_n_threads(be, 2);

    struct ggml_init_params ip = { ggml_tensor_overhead() * 8 + ggml_graph_overhead(), NULL, true };
    struct ggml_context *ctx = ggml_init(ip);
    struct ggml_tensor *a = ggml_new_tensor_2d(ctx, GGML_TYPE_F16, K, M);
    struct ggml_tensor *b = ggml_new_tensor_2d(ctx, GGML_TYPE_F32, K, N);
    struct ggml_tensor *c = ggml_mul_mat(ctx, a, b);
    struct ggml_cgraph *gf = ggml_new_graph(ctx);
    ggml_build_forward_expand(gf, c);

    ggml_backend_buffer_t buf = ggml_backend_alloc_ctx_tensors(ctx, be);
    if (!buf) { printf("FAIL: alloc\n"); return 1; }
    ggml_fp32_to_fp16_row(a_src, (ggml_fp16_t *) a->data, (size_t) M * K);
    ggml_backend_tensor_set(b, b_src, 0, ggml_nbytes(b));
    ggml_backend_graph_compute(be, gf);

    size_t n = (size_t) M * N;
    float *out = malloc(sizeof(float) * n);
    if (!out) { printf("FAIL: out of memory\n"); return 1; }
    ggml_backend_tensor_get(c, out, 0, ggml_nbytes(c));

    double sum = 0;
    for (size_t i = 0; i < n; i++) sum += fabs(out[i]);
    /* A non-finite or all-zero result means the kernel did not really run;
     * without this the comparison below could "agree" on garbage. */
    if (!isfinite(sum) || sum == 0.0) {
        printf("FAIL: result is not a finite non-zero matrix (sum=%.6g)\n", sum);
        return 1;
    }
    printf("mean-abs %.6f\n", sum / n);

    if (!ref_path) { printf("OK (no reference requested)\n"); return 0; }

    FILE *f = fopen(ref_path, "rb");
    if (!f) {
        f = fopen(ref_path, "wb");
        if (!f || fwrite(out, sizeof(float), n, f) != n) {
            printf("FAIL: could not write reference %s\n", ref_path);
            return 1;
        }
        fclose(f);
        printf("OK wrote reference from variant %s\n", name);
        return 0;
    }

    float *ref = malloc(sizeof(float) * n);
    if (!ref || fread(ref, sizeof(float), n, f) != n) {
        printf("FAIL: could not read reference %s\n", ref_path);
        return 1;
    }
    fclose(f);

    double maxdiff = 0, refsum = 0;
    for (size_t i = 0; i < n; i++) {
        double d = fabs((double) out[i] - (double) ref[i]);
        if (d > maxdiff) maxdiff = d;
        refsum += fabs(ref[i]);
    }
    double rel = maxdiff / (refsum / n);
    if (!isfinite(rel)) { printf("FAIL: relative difference is not finite\n"); return 1; }
    printf("max-relative-difference-vs-reference %.3g\n", rel);
    if (rel > 1e-2) { printf("FAIL: variant %s disagrees with the reference\n", name); return 1; }
    printf("OK variant %s agrees with the reference\n", name);
    return 0;
}
