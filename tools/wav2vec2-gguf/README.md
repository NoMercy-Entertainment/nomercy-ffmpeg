# wav2vec2-gguf

Converts [`facebook/wav2vec2-xlsr-53-espeak-cv-ft`](https://huggingface.co/facebook/wav2vec2-xlsr-53-espeak-cv-ft)
(Xu, Baevski, Auli 2021, Apache-2.0) into `wav2vec2-xlsr-53-espeak-cv-ft-f16.gguf`, the model file the `lyricsalign`
FFmpeg audio filter loads (nomercy-ffmpeg #126).

**The `.gguf` output is a release asset of
[nomercy-lyricsalign-models](https://github.com/NoMercy-Entertainment/nomercy-lyricsalign-models). It is never
committed to this repository** (about 630 MB) and never shipped in a platform tarball.

## What is converted

`Wav2Vec2ForCTC`, large: a 7-layer conv feature encoder (512 channels, kernels 10,3,3,3,3,2,2, strides 5,2,2,2,2,2,2,
LayerNorm after every conv, erf-GELU), feature projection (LayerNorm 512 → Linear 1024), a grouped positional conv
(kernel 128, 16 groups, weight-normalised in the checkpoint), 24 pre-LN transformer layers (16 heads of 64, FFN 4096),
a final LayerNorm and an `lm_head` of 392 outputs. 423 tensors in the GGUF; the checkpoint's `masked_spec_embed` is
training-only and dropped.

- Weights are **F16**, biases and LayerNorm parameters **F32**.
- The positional conv's weight norm is folded: HF applies `weight_norm(conv, "weight", dim=2)`, so `weight_g` has one
  value per kernel position and the norm runs over the (out, in) dims; `pos.weight = g · v / ‖v‖` is stored as a plain
  weight. `verify()` recomputes it with `torch._weight_norm` and compares.
- Shapes are torch's row-major layout handed to the gguf writer, which records them in ggml's `ne` order (innermost
  first): a Linear `[out, in]` is `ne [in, out]`, a Conv1d `[out, in, k]` is `ne [k, in, out]`. The C graph builder
  uses them as `ggml_mul_mat(w, x)` and `ggml_conv_1d(w, x, …)` without transposes.

Tensor names: `enc.conv.{i}.{weight,bias,ln.weight,ln.bias}`, `proj.{ln.weight,ln.bias,weight,bias}`,
`pos.{weight,bias}`, `layers.{l}.attn.{q,k,v,o}.{weight,bias}`, `layers.{l}.{ln1,ln2}.{weight,bias}`,
`layers.{l}.ffn.{in,out}.{weight,bias}`, `enc.ln.{weight,bias}`, `head.{weight,bias}`.

Metadata: `general.architecture = "wav2vec2-ctc"`, `general.name`, `general.license`, `lyricsalign.arch`,
`lyricsalign.sample_rate = 16000`, `lyricsalign.hop = 320`, `lyricsalign.blank_id = 0`, `lyricsalign.vocab` (392
strings in id order; the filter reads the vocabulary from the model), `lyricsalign.conv_dim/conv_kernel/conv_stride`,
`lyricsalign.hidden/heads/ffn/layers/pos_kernel/pos_groups`, `lyricsalign.layer_norm_eps`,
`lyricsalign.input_norm_floor`.

## Build and run

```bash
docker build -t wav2vec2-gguf tools/wav2vec2-gguf        # downloads the 1.26 GB checkpoint into the image
docker run --rm -v "$PWD/out:/out" wav2vec2-gguf /work/checkpoint /out/wav2vec2-xlsr-53-espeak-cv-ft-f16.gguf
```

Or on a machine with the checkpoint and `requirements.txt` installed:

```bash
python -I tools/wav2vec2-gguf/convert.py <checkpoint_dir> <out.gguf>
python -I tools/wav2vec2-gguf/convert.py --verify-only <file.gguf>
```

The conversion is deterministic: the same checkpoint gives the same bytes, so the digest in the models release can be
reproduced.

## Verify (red/green)

The converter's test is built into `convert.py` as `verify()`: the written file is read back and every tensor name,
shape and type is compared with the list derived from `config.json`, the metadata is compared, the vocabulary must
have 392 entries with `<pad>` at 0 (the CTC blank), and the folded positional weight is compared with torch's own
weight norm. Confirm it fails on nothing first:

```bash
python -I -c "import sys; sys.path.insert(0, 'tools/wav2vec2-gguf'); import convert; convert.verify_tensors({}, {})"
# AssertionError: missing tensor enc.conv.0.weight
```
