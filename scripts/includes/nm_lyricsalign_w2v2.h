/*
 * nm_lyricsalign_w2v2.h - wav2vec2-xlsr-53-espeak-cv-ft (Wav2Vec2ForCTC, large)
 * on ggml, for the lyricsalign filter (nomercy-ffmpeg #126): the GGUF loader,
 * the compute graph of one window, and the spec's windowed emissions.
 *
 * The GGUF comes from tools/wav2vec2-gguf (tensor names and shapes are
 * documented there and in its README). Every size the graph needs is read
 * from the file's metadata; nothing is hard-coded except the tensor names.
 *
 * Layouts, in ggml's ne order (innermost first): activations are [C, T]
 * (channels innermost) except around the convolutions, which ggml_conv_1d
 * wants as [L, C]; a Linear stored as ne [in, out] is applied with
 * ggml_mul_mat(w, x); a Conv1d stored as ne [K, IC, OC] with ggml_conv_1d.
 * The model's GELU is the erf one (ggml_gelu_erf); the tanh approximation
 * shifts emissions and is never used here. Weights are cast to f32 in the
 * graph: see nm_w2v2_w() for the measurement behind that.
 *
 * Header-only, ggml only (no FFmpeg): tools/lyricsalign-lab/emit.c runs it
 * standalone against the JFK fixture (gate (a) of the issue), the filter
 * includes it with its allocator macros pointed at av_malloc.
 */
#ifndef NM_LYRICSALIGN_W2V2_H
#define NM_LYRICSALIGN_W2V2_H

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include <ggml.h>
#include <ggml-alloc.h>
#include <ggml-backend.h>
#include <ggml-cpu.h>
#include <gguf.h>

#ifndef NM_W2V2_MALLOC
#include <stdlib.h>
#define NM_W2V2_MALLOC(n) malloc(n)
#define NM_W2V2_FREE(p)   free(p)
#endif

#include "nm_lyricsalign_align.h"

#define NM_W2V2_MAX_CONV 16
#define NM_W2V2_MAX_LAYERS 64
#define NM_W2V2_GRAPH_SIZE 8192

/* The spec's windowing: 20 s cores with 1 s of context on each side at
 * 16 kHz, 50 context frames dropped per side, a last core under 1 s padded
 * to 1 s before the model sees it. */
#define NM_W2V2_CORE_SAMPLES (20 * NM_LA_RATE)
#define NM_W2V2_CONTEXT_SAMPLES NM_LA_RATE
#define NM_W2V2_CONTEXT_FRAMES (NM_W2V2_CONTEXT_SAMPLES / NM_LA_HOP)
#define NM_W2V2_MIN_CORE_SAMPLES NM_LA_RATE

typedef struct NMW2V2Layer {
    struct ggml_tensor *ln1_w, *ln1_b, *ln2_w, *ln2_b;
    struct ggml_tensor *q_w, *q_b, *k_w, *k_b, *v_w, *v_b, *o_w, *o_b;
    struct ggml_tensor *ffn_in_w, *ffn_in_b, *ffn_out_w, *ffn_out_b;
} NMW2V2Layer;

typedef struct NMW2V2 {
    struct gguf_context *gguf;           /* kept: the vocabulary strings live in it */
    struct ggml_context *weights;        /* tensor metadata; data in weights_buf */
    ggml_backend_buffer_t weights_buf;
    ggml_backend_t backends[2];
    int n_backends;
    ggml_backend_sched_t sched;

    /* hyperparameters, from the metadata */
    int sample_rate, hop, blank, n_conv, hidden, heads, ffn, n_layers, pos_kernel, pos_groups;
    int conv_dim[NM_W2V2_MAX_CONV], conv_kernel[NM_W2V2_MAX_CONV], conv_stride[NM_W2V2_MAX_CONV];
    int receptive;                       /* samples the conv stack needs for one frame */
    float ln_eps, norm_floor;
    int vocab_n;
    int64_t vocab_key;
    char name[128];

    /* tensors */
    struct ggml_tensor *conv_w[NM_W2V2_MAX_CONV], *conv_b[NM_W2V2_MAX_CONV];
    struct ggml_tensor *conv_ln_w[NM_W2V2_MAX_CONV], *conv_ln_b[NM_W2V2_MAX_CONV];
    struct ggml_tensor *proj_ln_w, *proj_ln_b, *proj_w, *proj_b;
    struct ggml_tensor *pos_w, *pos_b;
    NMW2V2Layer layers[NM_W2V2_MAX_LAYERS];
    struct ggml_tensor *enc_ln_w, *enc_ln_b, *head_w, *head_b;
} NMW2V2;

/* ---------------------------------------------------------------------------
 * Loading
 * ------------------------------------------------------------------------- */

static inline void nm_w2v2_seterr(char *err, size_t err_len, const char *msg, const char *what)
{
    if (err && err_len)
        snprintf(err, err_len, "%s%s%s", msg, what ? ": " : "", what ? what : "");
}

static inline int nm_w2v2_meta_u32(const NMW2V2 *m, const char *key, int *out)
{
    int64_t k = gguf_find_key(m->gguf, key);
    if (k < 0)
        return -1;
    *out = (int) gguf_get_val_u32(m->gguf, k);
    return 0;
}

static inline int nm_w2v2_meta_f32(const NMW2V2 *m, const char *key, float *out)
{
    int64_t k = gguf_find_key(m->gguf, key);
    if (k < 0)
        return -1;
    *out = gguf_get_val_f32(m->gguf, k);
    return 0;
}

static inline int nm_w2v2_meta_ints(const NMW2V2 *m, const char *key, int *out, int max, int *n)
{
    int64_t k = gguf_find_key(m->gguf, key);
    enum gguf_type t;
    const void *data;
    size_t count;

    if (k < 0)
        return -1;
    t = gguf_get_arr_type(m->gguf, k);
    if (t != GGUF_TYPE_UINT32 && t != GGUF_TYPE_INT32)
        return -1;
    count = gguf_get_arr_n(m->gguf, k);
    if ((int) count > max)
        return -1;
    data = gguf_get_arr_data(m->gguf, k);
    for (size_t i = 0; i < count; i++)
        out[i] = (int) ((const int32_t *) data)[i];
    *n = (int) count;
    return 0;
}

static inline struct ggml_tensor *nm_w2v2_tensor(NMW2V2 *m, const char *name, int64_t ne0, int64_t ne1, int64_t ne2,
                                                 char *err, size_t err_len)
{
    struct ggml_tensor *t = ggml_get_tensor(m->weights, name);
    char what[160];

    if (!t) {
        nm_w2v2_seterr(err, err_len, "tensor missing from the model", name);
        return NULL;
    }
    if (t->ne[0] != ne0 || t->ne[1] != ne1 || t->ne[2] != ne2 || t->ne[3] != 1) {
        snprintf(what, sizeof(what), "%s has ne [%lld, %lld, %lld], expected [%lld, %lld, %lld]", name,
                 (long long) t->ne[0], (long long) t->ne[1], (long long) t->ne[2],
                 (long long) ne0, (long long) ne1, (long long) ne2);
        nm_w2v2_seterr(err, err_len, "tensor shape", what);
        return NULL;
    }
    return t;
}

static inline void nm_w2v2_free(NMW2V2 *m)
{
    if (!m)
        return;
    if (m->sched)
        ggml_backend_sched_free(m->sched);
    if (m->weights_buf)
        ggml_backend_buffer_free(m->weights_buf);
    if (m->weights)
        ggml_free(m->weights);
    if (m->gguf)
        gguf_free(m->gguf);
    NM_W2V2_FREE(m);
}

/* Load the GGUF at path. The weights live on `device` when one is given,
 * else on `cpu`; the graph runs on the scheduler over {device, cpu}, so an
 * op the device cannot do falls back to the CPU. cpu is required. Returns 0,
 * or -1 with err filled. The caller sets the CPU thread count. */
static inline int nm_w2v2_load(const char *path, ggml_backend_t device, ggml_backend_t cpu, NMW2V2 **out,
                               char *err, size_t err_len)
{
    NMW2V2 *m = (NMW2V2 *) NM_W2V2_MALLOC(sizeof(*m));
    struct gguf_init_params gp;
    int64_t k, n_tensors;
    int n_kernel = 0, n_stride = 0, inp;
    FILE *f = NULL;
    unsigned char *bounce = NULL;
    size_t bounce_cap = 0, data_offset;
    const char *name;

    *out = NULL;
    if (!m) {
        nm_w2v2_seterr(err, err_len, "out of memory", NULL);
        return -1;
    }
    memset(m, 0, sizeof(*m));
    if (!cpu) {
        nm_w2v2_seterr(err, err_len, "no CPU backend", NULL);
        goto fail;
    }

    gp.no_alloc = true;
    gp.ctx = &m->weights;
    m->gguf = gguf_init_from_file(path, gp);
    if (!m->gguf || !m->weights) {
        nm_w2v2_seterr(err, err_len, "not a GGUF file", path);
        goto fail;
    }

    /* metadata */
    k = gguf_find_key(m->gguf, "lyricsalign.arch");
    if (k < 0 || strcmp(gguf_get_val_str(m->gguf, k), "wav2vec2-ctc")) {
        nm_w2v2_seterr(err, err_len, "lyricsalign.arch is not \"wav2vec2-ctc\"", path);
        goto fail;
    }
    k = gguf_find_key(m->gguf, "general.name");
    name = k >= 0 ? gguf_get_val_str(m->gguf, k) : "?";
    snprintf(m->name, sizeof(m->name), "%s", name);
    if (nm_w2v2_meta_u32(m, "lyricsalign.sample_rate", &m->sample_rate) || nm_w2v2_meta_u32(m, "lyricsalign.hop", &m->hop) ||
        nm_w2v2_meta_u32(m, "lyricsalign.blank_id", &m->blank) || nm_w2v2_meta_u32(m, "lyricsalign.hidden", &m->hidden) ||
        nm_w2v2_meta_u32(m, "lyricsalign.heads", &m->heads) || nm_w2v2_meta_u32(m, "lyricsalign.ffn", &m->ffn) ||
        nm_w2v2_meta_u32(m, "lyricsalign.layers", &m->n_layers) || nm_w2v2_meta_u32(m, "lyricsalign.pos_kernel", &m->pos_kernel) ||
        nm_w2v2_meta_u32(m, "lyricsalign.pos_groups", &m->pos_groups) ||
        nm_w2v2_meta_f32(m, "lyricsalign.layer_norm_eps", &m->ln_eps) ||
        nm_w2v2_meta_f32(m, "lyricsalign.input_norm_floor", &m->norm_floor) ||
        nm_w2v2_meta_ints(m, "lyricsalign.conv_dim", m->conv_dim, NM_W2V2_MAX_CONV, &m->n_conv) ||
        nm_w2v2_meta_ints(m, "lyricsalign.conv_kernel", m->conv_kernel, NM_W2V2_MAX_CONV, &n_kernel) ||
        nm_w2v2_meta_ints(m, "lyricsalign.conv_stride", m->conv_stride, NM_W2V2_MAX_CONV, &n_stride)) {
        nm_w2v2_seterr(err, err_len, "lyricsalign.* metadata missing or malformed", path);
        goto fail;
    }
    if (m->n_conv < 1 || n_kernel != m->n_conv || n_stride != m->n_conv || m->n_layers < 1 ||
        m->n_layers > NM_W2V2_MAX_LAYERS || m->heads < 1 || m->hidden % m->heads || m->pos_groups < 1 ||
        m->hidden % m->pos_groups || m->sample_rate != NM_LA_RATE || m->hop != NM_LA_HOP) {
        nm_w2v2_seterr(err, err_len, "lyricsalign.* metadata inconsistent (sample rate, hop, layers, heads, groups)", path);
        goto fail;
    }
    {
        int total = 1, field = 1;
        for (int i = 0; i < m->n_conv; i++)
            total *= m->conv_stride[i];
        for (int i = m->n_conv - 1; i >= 0; i--)
            field = (field - 1) * m->conv_stride[i] + m->conv_kernel[i];
        if (total != m->hop) {
            nm_w2v2_seterr(err, err_len, "the conv strides do not multiply to the hop", path);
            goto fail;
        }
        m->receptive = field;
    }
    m->vocab_key = gguf_find_key(m->gguf, "lyricsalign.vocab");
    if (m->vocab_key < 0 || gguf_get_arr_type(m->gguf, m->vocab_key) != GGUF_TYPE_STRING) {
        nm_w2v2_seterr(err, err_len, "lyricsalign.vocab missing", path);
        goto fail;
    }
    m->vocab_n = (int) gguf_get_arr_n(m->gguf, m->vocab_key);
    if (m->vocab_n < 2 || m->blank < 0 || m->blank >= m->vocab_n) {
        nm_w2v2_seterr(err, err_len, "lyricsalign.vocab or blank_id out of range", path);
        goto fail;
    }

    /* tensors, by name and shape */
#define NM_W2V2_T(dst, nm, a, b, c) do { if (!((dst) = nm_w2v2_tensor(m, nm, a, b, c, err, err_len))) goto fail; } while (0)
    inp = 1;
    for (int i = 0; i < m->n_conv; i++) {
        char nm[64];
        snprintf(nm, sizeof(nm), "enc.conv.%d.weight", i);
        NM_W2V2_T(m->conv_w[i], nm, m->conv_kernel[i], inp, m->conv_dim[i]);
        snprintf(nm, sizeof(nm), "enc.conv.%d.bias", i);
        NM_W2V2_T(m->conv_b[i], nm, m->conv_dim[i], 1, 1);
        snprintf(nm, sizeof(nm), "enc.conv.%d.ln.weight", i);
        NM_W2V2_T(m->conv_ln_w[i], nm, m->conv_dim[i], 1, 1);
        snprintf(nm, sizeof(nm), "enc.conv.%d.ln.bias", i);
        NM_W2V2_T(m->conv_ln_b[i], nm, m->conv_dim[i], 1, 1);
        inp = m->conv_dim[i];
    }
    NM_W2V2_T(m->proj_ln_w, "proj.ln.weight", inp, 1, 1);
    NM_W2V2_T(m->proj_ln_b, "proj.ln.bias", inp, 1, 1);
    NM_W2V2_T(m->proj_w, "proj.weight", inp, m->hidden, 1);
    NM_W2V2_T(m->proj_b, "proj.bias", m->hidden, 1, 1);
    NM_W2V2_T(m->pos_w, "pos.weight", m->pos_kernel, m->hidden / m->pos_groups, m->hidden);
    NM_W2V2_T(m->pos_b, "pos.bias", m->hidden, 1, 1);
    for (int l = 0; l < m->n_layers; l++) {
        NMW2V2Layer *L = &m->layers[l];
        char nm[64];
#define NM_W2V2_L(dst, suffix, a, b) do { snprintf(nm, sizeof(nm), "layers.%d.%s", l, suffix); NM_W2V2_T(dst, nm, a, b, 1); } while (0)
        NM_W2V2_L(L->ln1_w, "ln1.weight", m->hidden, 1);
        NM_W2V2_L(L->ln1_b, "ln1.bias", m->hidden, 1);
        NM_W2V2_L(L->ln2_w, "ln2.weight", m->hidden, 1);
        NM_W2V2_L(L->ln2_b, "ln2.bias", m->hidden, 1);
        NM_W2V2_L(L->q_w, "attn.q.weight", m->hidden, m->hidden);
        NM_W2V2_L(L->q_b, "attn.q.bias", m->hidden, 1);
        NM_W2V2_L(L->k_w, "attn.k.weight", m->hidden, m->hidden);
        NM_W2V2_L(L->k_b, "attn.k.bias", m->hidden, 1);
        NM_W2V2_L(L->v_w, "attn.v.weight", m->hidden, m->hidden);
        NM_W2V2_L(L->v_b, "attn.v.bias", m->hidden, 1);
        NM_W2V2_L(L->o_w, "attn.o.weight", m->hidden, m->hidden);
        NM_W2V2_L(L->o_b, "attn.o.bias", m->hidden, 1);
        NM_W2V2_L(L->ffn_in_w, "ffn.in.weight", m->hidden, m->ffn);
        NM_W2V2_L(L->ffn_in_b, "ffn.in.bias", m->ffn, 1);
        NM_W2V2_L(L->ffn_out_w, "ffn.out.weight", m->ffn, m->hidden);
        NM_W2V2_L(L->ffn_out_b, "ffn.out.bias", m->hidden, 1);
#undef NM_W2V2_L
    }
    NM_W2V2_T(m->enc_ln_w, "enc.ln.weight", m->hidden, 1, 1);
    NM_W2V2_T(m->enc_ln_b, "enc.ln.bias", m->hidden, 1, 1);
    NM_W2V2_T(m->head_w, "head.weight", m->hidden, m->vocab_n, 1);
    NM_W2V2_T(m->head_b, "head.bias", m->vocab_n, 1, 1);
#undef NM_W2V2_T

    /* backends and the weight buffer */
    m->n_backends = 0;
    if (device)
        m->backends[m->n_backends++] = device;
    m->backends[m->n_backends++] = cpu;
    m->weights_buf = ggml_backend_alloc_ctx_tensors(m->weights, m->backends[0]);
    if (!m->weights_buf) {
        nm_w2v2_seterr(err, err_len, "could not allocate the weights on the backend", path);
        goto fail;
    }

    /* the data, tensor by tensor, through a bounce buffer */
    f = ggml_fopen(path, "rb");
    if (!f) {
        nm_w2v2_seterr(err, err_len, "cannot open", path);
        goto fail;
    }
    data_offset = gguf_get_data_offset(m->gguf);
    n_tensors = gguf_get_n_tensors(m->gguf);
    for (int64_t i = 0; i < n_tensors; i++) {
        const char *tn = gguf_get_tensor_name(m->gguf, i);
        struct ggml_tensor *t = ggml_get_tensor(m->weights, tn);
        size_t nbytes;

        if (!t)
            continue;
        nbytes = ggml_nbytes(t);
        if (nbytes > bounce_cap) {
            NM_W2V2_FREE(bounce);
            bounce_cap = nbytes;
            bounce = (unsigned char *) NM_W2V2_MALLOC(bounce_cap);
            if (!bounce) {
                nm_w2v2_seterr(err, err_len, "out of memory reading", tn);
                goto fail;
            }
        }
        if (fseek(f, (long) (data_offset + gguf_get_tensor_offset(m->gguf, i)), SEEK_SET) ||
            fread(bounce, 1, nbytes, f) != nbytes) {
            nm_w2v2_seterr(err, err_len, "short read of tensor", tn);
            goto fail;
        }
        ggml_backend_tensor_set(t, bounce, 0, nbytes);
    }
    fclose(f);
    f = NULL;
    NM_W2V2_FREE(bounce);
    bounce = NULL;

    m->sched = ggml_backend_sched_new(m->backends, NULL, m->n_backends, NM_W2V2_GRAPH_SIZE, false, true);
    if (!m->sched) {
        nm_w2v2_seterr(err, err_len, "could not create the backend scheduler", path);
        goto fail;
    }
    *out = m;
    return 0;
fail:
    if (f)
        fclose(f);
    NM_W2V2_FREE(bounce);
    nm_w2v2_free(m);
    return -1;
}

static inline int nm_w2v2_vocab_n(const NMW2V2 *m) { return m->vocab_n; }
static inline int nm_w2v2_blank(const NMW2V2 *m) { return m->blank; }
static inline const char *nm_w2v2_name(const NMW2V2 *m) { return m->name; }
static inline const char *nm_w2v2_vocab(const NMW2V2 *m, int id)
{
    return gguf_get_arr_str(m->gguf, m->vocab_key, (size_t) id);
}

/* Frames the conv stack gives for n samples: floor((n - field) / hop) + 1,
 * 0 when n is under the receptive field. */
static inline int nm_w2v2_frames_for(const NMW2V2 *m, int n)
{
    return n < m->receptive ? 0 : (n - m->receptive) / m->hop + 1;
}

/* ---------------------------------------------------------------------------
 * The graph of one window
 * ------------------------------------------------------------------------- */

/* A weight as the graph uses it: cast to f32 inside the graph. The file
 * stays f16 (630 MB), the arithmetic is f32.
 *
 * Measured on the JFK fixture (tools/lyricsalign-lab/README.md): with the
 * weights used as f16, ggml's CPU matmul rounds the activations to f16 as
 * well, and the emissions land 0.095 nats from the prototype's on average
 * (99.45 % argmax agreement), over the issue's 0.05 gate; cast to f32 they
 * land 0.0032 nats away with 100 % agreement, at the same speed (6.4 s
 * against 6.1 s per 22 s window on 4 cores). NM_W2V2_MATMUL_F16 restores
 * the f16 path for measurements only. */
static inline struct ggml_tensor *nm_w2v2_w(struct ggml_context *g, struct ggml_tensor *w)
{
#ifndef NM_W2V2_MATMUL_F16
    if (w->type != GGML_TYPE_F32)
        return ggml_cast(g, w, GGML_TYPE_F32);
#else
    (void) g;
#endif
    return w;
}

/* ggml_conv_1d, but honouring the kernel's type: ggml's own always builds an
 * f16 im2col and asserts an f16 kernel, so an f32 kernel (a measurement
 * model, or a cast weight) needs the f32 im2col path. a is [K, IC, OC],
 * b is [L, IC]; the result is [OL, OC]. */
static inline struct ggml_tensor *nm_w2v2_conv1d(struct ggml_context *g, struct ggml_tensor *a, struct ggml_tensor *b,
                                                 int s0, int p0)
{
    const enum ggml_type t = a->type == GGML_TYPE_F16 ? GGML_TYPE_F16 : GGML_TYPE_F32;
    struct ggml_tensor *im2col = ggml_im2col(g, a, b, s0, 0, p0, 0, 1, 0, false, t);          /* [IC*K, OL, N] */
    struct ggml_tensor *r = ggml_mul_mat(g, ggml_reshape_2d(g, im2col, im2col->ne[0], im2col->ne[2] * im2col->ne[1]),
                                         ggml_reshape_2d(g, a, a->ne[0] * a->ne[1], a->ne[2]));
    return ggml_reshape_3d(g, r, im2col->ne[1], a->ne[2], im2col->ne[2]);
}

static inline struct ggml_tensor *nm_w2v2_layer_norm(struct ggml_context *g, struct ggml_tensor *x,
                                                     struct ggml_tensor *w, struct ggml_tensor *b, float eps)
{
    x = ggml_norm(g, x, eps);
    x = ggml_mul(g, x, w);
    return ggml_add(g, x, b);
}

/* x [C, T] -> [C, T] through one pre-LN transformer layer. */
static inline struct ggml_tensor *nm_w2v2_layer(struct ggml_context *g, const NMW2V2 *m, const NMW2V2Layer *L,
                                                struct ggml_tensor *x, int T)
{
    const int H = m->heads, D = m->hidden / m->heads;
    struct ggml_tensor *h, *q, *k, *v, *kq, *kqv, *o;

    h = nm_w2v2_layer_norm(g, x, L->ln1_w, L->ln1_b, m->ln_eps);
    q = ggml_add(g, ggml_mul_mat(g, nm_w2v2_w(g, L->q_w), h), L->q_b);
    k = ggml_add(g, ggml_mul_mat(g, nm_w2v2_w(g, L->k_w), h), L->k_b);
    v = ggml_add(g, ggml_mul_mat(g, nm_w2v2_w(g, L->v_w), h), L->v_b);
    /* [hidden, T] -> [D, H, T] -> [D, T, H] */
    q = ggml_cont(g, ggml_permute(g, ggml_reshape_3d(g, q, D, H, T), 0, 2, 1, 3));
    k = ggml_cont(g, ggml_permute(g, ggml_reshape_3d(g, k, D, H, T), 0, 2, 1, 3));
    /* v -> [T, D, H] */
    v = ggml_cont(g, ggml_permute(g, ggml_reshape_3d(g, v, D, H, T), 1, 2, 0, 3));
    kq = ggml_mul_mat(g, k, q);                                        /* [T_k, T_q, H] */
    kq = ggml_soft_max_ext(g, kq, NULL, 1.0f / sqrtf((float) D), 0.0f);
    kqv = ggml_mul_mat(g, v, kq);                                      /* [D, T_q, H] */
    kqv = ggml_cont(g, ggml_permute(g, kqv, 0, 2, 1, 3));              /* [D, H, T] */
    kqv = ggml_reshape_2d(g, kqv, m->hidden, T);
    o = ggml_add(g, ggml_mul_mat(g, nm_w2v2_w(g, L->o_w), kqv), L->o_b);
    x = ggml_add(g, x, o);

    h = nm_w2v2_layer_norm(g, x, L->ln2_w, L->ln2_b, m->ln_eps);
    h = ggml_add(g, ggml_mul_mat(g, nm_w2v2_w(g, L->ffn_in_w), h), L->ffn_in_b);
    h = ggml_gelu_erf(g, h);
    h = ggml_add(g, ggml_mul_mat(g, nm_w2v2_w(g, L->ffn_out_w), h), L->ffn_out_b);
    return ggml_add(g, x, h);
}

/* Build the graph for n normalised samples. *inp and *logits receive the
 * input and output tensors; the logits are [vocab, T]. */
static inline struct ggml_cgraph *nm_w2v2_build(struct ggml_context *g, const NMW2V2 *m, int n, int *frames,
                                                struct ggml_tensor **inp, struct ggml_tensor **logits)
{
    struct ggml_cgraph *gf = ggml_new_graph_custom(g, NM_W2V2_GRAPH_SIZE, false);
    struct ggml_tensor *x, *pos, *cat = NULL;
    int T, L = n;
    const int G = m->pos_groups, GC = m->hidden / m->pos_groups, P = m->pos_kernel / 2;

    x = ggml_new_tensor_2d(g, GGML_TYPE_F32, n, 1);                   /* [L, 1 channel] */
    ggml_set_name(x, "samples");
    ggml_set_input(x);
    *inp = x;

    /* feature encoder: conv -> LayerNorm over channels -> GELU, seven times */
    for (int i = 0; i < m->n_conv; i++) {
        x = nm_w2v2_conv1d(g, nm_w2v2_w(g, m->conv_w[i]), x, m->conv_stride[i], 0);  /* [OL, OC] */
        L = (L - m->conv_kernel[i]) / m->conv_stride[i] + 1;
        x = ggml_add(g, x, ggml_reshape_2d(g, m->conv_b[i], 1, m->conv_dim[i]));
        x = ggml_cont(g, ggml_transpose(g, x));                        /* [OC, OL] */
        x = nm_w2v2_layer_norm(g, x, m->conv_ln_w[i], m->conv_ln_b[i], m->ln_eps);
        x = ggml_gelu_erf(g, x);
        if (i + 1 < m->n_conv)
            x = ggml_cont(g, ggml_transpose(g, x));                    /* back to [OL, OC] for the next conv */
    }
    T = L;
    *frames = T;

    /* feature projection: LayerNorm(512) -> Linear(1024) */
    x = nm_w2v2_layer_norm(g, x, m->proj_ln_w, m->proj_ln_b, m->ln_eps);
    x = ggml_add(g, ggml_mul_mat(g, nm_w2v2_w(g, m->proj_w), x), m->proj_b);   /* [hidden, T] */

    /* positional conv: grouped, kernel pos_kernel, padding pos_kernel/2, the last output sample dropped */
    {
        struct ggml_tensor *x_lc = ggml_cont(g, ggml_transpose(g, x));  /* [T, hidden] */
        for (int gi = 0; gi < G; gi++) {
            struct ggml_tensor *w = ggml_view_3d(g, m->pos_w, m->pos_kernel, GC, GC, m->pos_w->nb[1], m->pos_w->nb[2],
                                                 (size_t) gi * GC * m->pos_w->nb[2]);
            struct ggml_tensor *xg = ggml_cont(g, ggml_view_2d(g, x_lc, T, GC, x_lc->nb[1], (size_t) gi * GC * x_lc->nb[1]));
            struct ggml_tensor *r = nm_w2v2_conv1d(g, nm_w2v2_w(g, w), xg, 1, P);   /* [T + 1, GC] */
            r = ggml_cont(g, ggml_view_2d(g, r, T, GC, r->nb[1], 0));    /* [T, GC] */
            cat = cat ? ggml_concat(g, cat, r, 1) : r;
        }
        pos = ggml_cont(g, ggml_transpose(g, cat));                     /* [hidden, T] */
        pos = ggml_add(g, pos, m->pos_b);
        pos = ggml_gelu_erf(g, pos);
        x = ggml_add(g, x, pos);
    }

    for (int l = 0; l < m->n_layers; l++)
        x = nm_w2v2_layer(g, m, &m->layers[l], x, T);
    x = nm_w2v2_layer_norm(g, x, m->enc_ln_w, m->enc_ln_b, m->ln_eps);
    x = ggml_add(g, ggml_mul_mat(g, nm_w2v2_w(g, m->head_w), x), m->head_b);   /* [vocab, T] */
    ggml_set_name(x, "logits");
    ggml_set_output(x);
    *logits = x;
    ggml_build_forward_expand(gf, x);
    return gf;
}

/* Run one window of n samples (already normalised). logits receives
 * frames x vocab, a row per frame. Returns the frame count, or -1. */
static inline int nm_w2v2_logits(NMW2V2 *m, const float *samples, int n, float *logits)
{
    struct ggml_init_params ip;
    struct ggml_context *g;
    struct ggml_cgraph *gf;
    struct ggml_tensor *inp, *out;
    int frames = 0;

    if (nm_w2v2_frames_for(m, n) <= 0)
        return 0;
    ip.mem_size = ggml_tensor_overhead() * NM_W2V2_GRAPH_SIZE + ggml_graph_overhead_custom(NM_W2V2_GRAPH_SIZE, false);
    ip.mem_buffer = NULL;
    ip.no_alloc = true;
    g = ggml_init(ip);
    if (!g)
        return -1;
    gf = nm_w2v2_build(g, m, n, &frames, &inp, &out);
    ggml_backend_sched_reset(m->sched);
    if (!ggml_backend_sched_alloc_graph(m->sched, gf)) {
        ggml_free(g);
        return -1;
    }
    ggml_backend_tensor_set(inp, samples, 0, sizeof(*samples) * (size_t) n);
    if (ggml_backend_sched_graph_compute(m->sched, gf) != GGML_STATUS_SUCCESS) {
        ggml_free(g);
        return -1;
    }
    ggml_backend_tensor_get(out, logits, 0, sizeof(*logits) * (size_t) frames * m->vocab_n);
    ggml_backend_sched_reset(m->sched);
    ggml_free(g);
    return frames;
}

/* ---------------------------------------------------------------------------
 * Step 2: windowed emissions over a whole track.
 *
 * Zero-pad the track by 1 s on each side, run the model on 20 s cores with
 * that second of context on each side, normalise every window to zero mean
 * and unit variance (floor 1e-7), keep the core's frames, stitch. *logp is
 * frames x vocab log-probs, *frames = n / hop. 0 on success (also for an
 * empty track: *logp = NULL, *frames = 0), -1 on failure.
 * ------------------------------------------------------------------------- */
static inline int nm_w2v2_emissions(NMW2V2 *m, const float *samples, int n, float **logp, int *frames)
{
    const int hop = m->hop, V = m->vocab_n;
    const int total = n > 0 ? n / hop : 0;
    const int max_window = NM_W2V2_CORE_SAMPLES + 2 * NM_W2V2_CONTEXT_SAMPLES;
    float *window = NULL, *logits = NULL, *out = NULL;
    int done = 0, max_frames;

    *logp = NULL;
    *frames = 0;
    if (total <= 0)
        return 0;
    max_frames = nm_w2v2_frames_for(m, max_window);
    window = (float *) NM_W2V2_MALLOC(sizeof(*window) * (size_t) max_window);
    logits = (float *) NM_W2V2_MALLOC(sizeof(*logits) * (size_t) max_frames * V);
    out = (float *) NM_W2V2_MALLOC(sizeof(*out) * (size_t) total * V);
    if (!window || !logits || !out)
        goto fail;

    for (int start = 0; start < n; start += NM_W2V2_CORE_SAMPLES) {
        int core = n - start < NM_W2V2_CORE_SAMPLES ? n - start : NM_W2V2_CORE_SAMPLES;
        int keep = core / hop;                     /* the core's frames */
        int padded_core = core < NM_W2V2_MIN_CORE_SAMPLES ? NM_W2V2_MIN_CORE_SAMPLES : core;
        int len = padded_core + 2 * NM_W2V2_CONTEXT_SAMPLES;
        int got;
        double mean = 0.0, var = 0.0, scale;

        /* the window: 1 s before the core (zeros before the track), the core, 1 s after (zeros past it) */
        for (int i = 0; i < len; i++) {
            int src = start - NM_W2V2_CONTEXT_SAMPLES + i;
            window[i] = (src >= 0 && src < n && i < core + 2 * NM_W2V2_CONTEXT_SAMPLES) ? samples[src] : 0.0f;
        }
        /* a short last core is padded with zeros to 1 s, after its own context: the 1 s after the core is
         * already zeros past the track's end, and the extra padding sits after that */
        for (int i = 0; i < len; i++)
            mean += window[i];
        mean /= len;
        for (int i = 0; i < len; i++)
            var += (window[i] - mean) * (window[i] - mean);
        var /= len;
        scale = 1.0 / sqrt(var + (double) m->norm_floor);
        for (int i = 0; i < len; i++)
            window[i] = (float) ((window[i] - mean) * scale);

        got = nm_w2v2_logits(m, window, len, logits);
        if (got < 0 || got < NM_W2V2_CONTEXT_FRAMES + keep)
            goto fail;
        if (keep > 0)
            nm_la_log_softmax(logits + (size_t) NM_W2V2_CONTEXT_FRAMES * V, keep, V, out + (size_t) done * V);
        done += keep;
    }
    if (done != total)
        goto fail;
    NM_W2V2_FREE(window);
    NM_W2V2_FREE(logits);
    *logp = out;
    *frames = total;
    return 0;
fail:
    NM_W2V2_FREE(window);
    NM_W2V2_FREE(logits);
    NM_W2V2_FREE(out);
    return -1;
}

#endif /* NM_LYRICSALIGN_W2V2_H */
