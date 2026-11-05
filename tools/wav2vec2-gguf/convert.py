"""Convert facebook/wav2vec2-xlsr-53-espeak-cv-ft (Wav2Vec2ForCTC, 2021 pytorch_model.bin) into the f16 GGUF the
`lyricsalign` FFmpeg filter loads (nomercy-ffmpeg #126).

    python -I convert.py <checkpoint_dir> <out.gguf>      convert, then verify the file that was written
    python -I convert.py --verify-only <file.gguf> [<checkpoint_dir>]
                                                          verify an existing file; with the checkpoint, the fold too

No transformers dependency: the checkpoint is read with torch.load, so the tensor names below are the checkpoint's own.
Weights are stored F16, biases and norms F32. The positional conv's weight norm (HF: weight_norm(conv, "weight", dim=2),
so g has one value per kernel position and the norm runs over the (out, in) dims) is folded into a plain weight.
Shapes are written as numpy arrays in torch's row-major layout; the gguf writer reverses them into ggml's ne order
(innermost first), which is exactly what the C graph builder expects: a Linear [out, in] becomes ne [in, out], a Conv1d
[out, in, k] becomes ne [k, in, out].

The test of this converter is verify(): the written file is read back and every tensor name, ne shape and type is
compared with the list derived from config.json, the metadata is checked, and the folded positional weight is recomputed
from weight_g/weight_v with torch's own _weight_norm and compared. A missing or extra tensor fails the conversion.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np

ARCH = "wav2vec2-ctc"
NAME = "wav2vec2-xlsr-53-espeak-cv-ft"
LICENSE = "apache-2.0"
F16, F32 = "F16", "F32"


def expected_tensors(cfg: dict) -> dict[str, tuple[tuple[int, ...], str]]:
    """GGUF tensor name -> (ggml ne shape, type), from config.json. The 2021 checkpoint has conv_bias=true."""
    dims, kernels = cfg["conv_dim"], cfg["conv_kernel"]
    hidden, ffn, layers, vocab = cfg["hidden_size"], cfg["intermediate_size"], cfg["num_hidden_layers"], cfg["vocab_size"]
    pos_k, pos_g = cfg["num_conv_pos_embeddings"], cfg["num_conv_pos_embedding_groups"]
    out: dict[str, tuple[tuple[int, ...], str]] = {}
    inp = 1
    for i, (dim, k) in enumerate(zip(dims, kernels)):
        out[f"enc.conv.{i}.weight"] = ((k, inp, dim), F16)
        out[f"enc.conv.{i}.bias"] = ((dim,), F32)
        out[f"enc.conv.{i}.ln.weight"] = ((dim,), F32)
        out[f"enc.conv.{i}.ln.bias"] = ((dim,), F32)
        inp = dim
    out["proj.ln.weight"] = ((inp,), F32)
    out["proj.ln.bias"] = ((inp,), F32)
    out["proj.weight"] = ((inp, hidden), F16)
    out["proj.bias"] = ((hidden,), F32)
    out["pos.weight"] = ((pos_k, hidden // pos_g, hidden), F16)
    out["pos.bias"] = ((hidden,), F32)
    for l in range(layers):
        for p in ("q", "k", "v", "o"):
            out[f"layers.{l}.attn.{p}.weight"] = ((hidden, hidden), F16)
            out[f"layers.{l}.attn.{p}.bias"] = ((hidden,), F32)
        for n in ("ln1", "ln2"):
            out[f"layers.{l}.{n}.weight"] = ((hidden,), F32)
            out[f"layers.{l}.{n}.bias"] = ((hidden,), F32)
        out[f"layers.{l}.ffn.in.weight"] = ((hidden, ffn), F16)
        out[f"layers.{l}.ffn.in.bias"] = ((ffn,), F32)
        out[f"layers.{l}.ffn.out.weight"] = ((ffn, hidden), F16)
        out[f"layers.{l}.ffn.out.bias"] = ((hidden,), F32)
    out["enc.ln.weight"] = ((hidden,), F32)
    out["enc.ln.bias"] = ((hidden,), F32)
    out["head.weight"] = ((hidden, vocab), F16)
    out["head.bias"] = ((vocab,), F32)
    return out


def expected_metadata(cfg: dict, vocab: list[str]) -> dict:
    return {
        "general.architecture": ARCH, "general.name": NAME, "general.license": LICENSE,
        "lyricsalign.arch": ARCH, "lyricsalign.sample_rate": 16000, "lyricsalign.hop": int(np.prod(cfg["conv_stride"])),
        "lyricsalign.blank_id": int(cfg["pad_token_id"]), "lyricsalign.vocab": vocab,
        "lyricsalign.conv_dim": list(cfg["conv_dim"]), "lyricsalign.conv_kernel": list(cfg["conv_kernel"]),
        "lyricsalign.conv_stride": list(cfg["conv_stride"]),
        "lyricsalign.hidden": cfg["hidden_size"], "lyricsalign.heads": cfg["num_attention_heads"],
        "lyricsalign.ffn": cfg["intermediate_size"], "lyricsalign.layers": cfg["num_hidden_layers"],
        "lyricsalign.pos_kernel": cfg["num_conv_pos_embeddings"], "lyricsalign.pos_groups": cfg["num_conv_pos_embedding_groups"],
        "lyricsalign.layer_norm_eps": float(cfg["layer_norm_eps"]), "lyricsalign.input_norm_floor": 1e-7,
    }


def verify_tensors(tensors: dict[str, tuple[tuple[int, ...], str]], meta: dict, cfg: dict | None = None,
                   vocab: list[str] | None = None) -> None:
    """Raise AssertionError on the first thing wrong with a tensor list and a metadata dict."""
    if cfg is None:
        cfg = DEFAULT_CONFIG
    want = expected_tensors(cfg)
    for name, (shape, dtype) in want.items():
        assert name in tensors, f"missing tensor {name}"
        got_shape, got_type = tensors[name]
        assert tuple(got_shape) == shape, f"{name}: ne {tuple(got_shape)}, expected {shape}"
        assert got_type == dtype, f"{name}: type {got_type}, expected {dtype}"
    extra = sorted(set(tensors) - set(want))
    assert not extra, f"unexpected tensors: {extra}"
    if vocab is not None:
        want_meta = expected_metadata(cfg, vocab)
        for key, value in want_meta.items():
            assert key in meta, f"missing metadata {key}"
            got = meta[key]
            if isinstance(value, float):
                assert abs(float(got) - value) <= 1e-9 * max(1.0, abs(value)), f"{key}: {got}, expected {value}"
            else:
                assert got == value, f"{key}: {got!r}, expected {value!r}"
        assert len(vocab) == cfg["vocab_size"], f"vocab has {len(vocab)} entries, expected {cfg['vocab_size']}"
        assert vocab[cfg["pad_token_id"]] == "<pad>", f"vocab[{cfg['pad_token_id']}] is {vocab[0]!r}, expected '<pad>' (the CTC blank)"


# config.json of facebook/wav2vec2-xlsr-53-espeak-cv-ft, the values the tensor list depends on.
DEFAULT_CONFIG = {
    "conv_dim": [512] * 7, "conv_kernel": [10, 3, 3, 3, 3, 2, 2], "conv_stride": [5, 2, 2, 2, 2, 2, 2],
    "hidden_size": 1024, "intermediate_size": 4096, "num_hidden_layers": 24, "num_attention_heads": 16,
    "num_conv_pos_embeddings": 128, "num_conv_pos_embedding_groups": 16, "vocab_size": 392, "pad_token_id": 0,
    "layer_norm_eps": 1e-5,
}


def load_checkpoint(ckpt: Path):
    import torch

    cfg = json.loads((ckpt / "config.json").read_text(encoding="utf-8"))
    assert cfg.get("architectures") == ["Wav2Vec2ForCTC"], cfg.get("architectures")
    assert cfg["feat_extract_norm"] == "layer" and cfg["do_stable_layer_norm"] is True and cfg["conv_bias"] is True
    assert cfg["feat_extract_activation"] == "gelu" and cfg["hidden_act"] == "gelu"
    vocab_map = json.loads((ckpt / "vocab.json").read_text(encoding="utf-8"))
    vocab = [None] * len(vocab_map)
    for token, idx in vocab_map.items():
        vocab[idx] = token
    assert all(v is not None for v in vocab), "vocab.json ids are not 0..N-1"
    sd = torch.load(ckpt / "pytorch_model.bin", map_location="cpu", weights_only=True)
    return cfg, vocab, sd


def fold_pos_conv(g, v):
    """weight_norm with dim=2: w = g * v / ||v||, the norm over (out, in) for each kernel position."""
    import torch

    norm = torch.sqrt((v * v).sum(dim=(0, 1), keepdim=True))
    return g * v / norm


def map_tensors(cfg: dict, sd: dict) -> dict[str, np.ndarray]:
    """GGUF name -> numpy array in torch layout, with the dtype it is stored as."""
    pre = "wav2vec2."
    out: dict[str, np.ndarray] = {}

    def take(name: str, dtype):
        t = sd.pop(name)
        return t.detach().to(torch_dtype(dtype)).numpy() if dtype == F16 else t.detach().float().numpy()

    for i in range(len(cfg["conv_dim"])):
        base = f"{pre}feature_extractor.conv_layers.{i}."
        out[f"enc.conv.{i}.weight"] = take(base + "conv.weight", F16)
        out[f"enc.conv.{i}.bias"] = take(base + "conv.bias", F32)
        out[f"enc.conv.{i}.ln.weight"] = take(base + "layer_norm.weight", F32)
        out[f"enc.conv.{i}.ln.bias"] = take(base + "layer_norm.bias", F32)
    out["proj.ln.weight"] = take(pre + "feature_projection.layer_norm.weight", F32)
    out["proj.ln.bias"] = take(pre + "feature_projection.layer_norm.bias", F32)
    out["proj.weight"] = take(pre + "feature_projection.projection.weight", F16)
    out["proj.bias"] = take(pre + "feature_projection.projection.bias", F32)
    g = sd.pop(pre + "encoder.pos_conv_embed.conv.weight_g")
    v = sd.pop(pre + "encoder.pos_conv_embed.conv.weight_v")
    out["pos.weight"] = fold_pos_conv(g, v).to(torch_dtype(F16)).numpy()
    out["pos.bias"] = take(pre + "encoder.pos_conv_embed.conv.bias", F32)
    for l in range(cfg["num_hidden_layers"]):
        base = f"{pre}encoder.layers.{l}."
        for p, hf in (("q", "q_proj"), ("k", "k_proj"), ("v", "v_proj"), ("o", "out_proj")):
            out[f"layers.{l}.attn.{p}.weight"] = take(f"{base}attention.{hf}.weight", F16)
            out[f"layers.{l}.attn.{p}.bias"] = take(f"{base}attention.{hf}.bias", F32)
        out[f"layers.{l}.ln1.weight"] = take(base + "layer_norm.weight", F32)
        out[f"layers.{l}.ln1.bias"] = take(base + "layer_norm.bias", F32)
        out[f"layers.{l}.ffn.in.weight"] = take(base + "feed_forward.intermediate_dense.weight", F16)
        out[f"layers.{l}.ffn.in.bias"] = take(base + "feed_forward.intermediate_dense.bias", F32)
        out[f"layers.{l}.ffn.out.weight"] = take(base + "feed_forward.output_dense.weight", F16)
        out[f"layers.{l}.ffn.out.bias"] = take(base + "feed_forward.output_dense.bias", F32)
        out[f"layers.{l}.ln2.weight"] = take(base + "final_layer_norm.weight", F32)
        out[f"layers.{l}.ln2.bias"] = take(base + "final_layer_norm.bias", F32)
    out["enc.ln.weight"] = take(pre + "encoder.layer_norm.weight", F32)
    out["enc.ln.bias"] = take(pre + "encoder.layer_norm.bias", F32)
    out["head.weight"] = take("lm_head.weight", F16)
    out["head.bias"] = take("lm_head.bias", F32)
    leftover = sorted(k for k in sd if k != pre + "masked_spec_embed")  # masked_spec_embed is training-only
    assert not leftover, f"checkpoint tensors not converted: {leftover}"
    return out


def torch_dtype(dtype: str):
    import torch

    return torch.float16 if dtype == F16 else torch.float32


def write_gguf(path: Path, cfg: dict, vocab: list[str], tensors: dict[str, np.ndarray]) -> None:
    import gguf

    w = gguf.GGUFWriter(str(path), ARCH)
    meta = expected_metadata(cfg, vocab)
    w.add_name(NAME)
    w.add_string("general.license", LICENSE)
    w.add_string("lyricsalign.arch", ARCH)
    for key in ("lyricsalign.sample_rate", "lyricsalign.hop", "lyricsalign.blank_id", "lyricsalign.hidden", "lyricsalign.heads",
                "lyricsalign.ffn", "lyricsalign.layers", "lyricsalign.pos_kernel", "lyricsalign.pos_groups"):
        w.add_uint32(key, int(meta[key]))
    for key in ("lyricsalign.conv_dim", "lyricsalign.conv_kernel", "lyricsalign.conv_stride"):
        w.add_array(key, [int(x) for x in meta[key]])
    w.add_float32("lyricsalign.layer_norm_eps", float(meta["lyricsalign.layer_norm_eps"]))
    w.add_float32("lyricsalign.input_norm_floor", float(meta["lyricsalign.input_norm_floor"]))
    w.add_array("lyricsalign.vocab", vocab)
    for name, arr in tensors.items():
        arr = np.ascontiguousarray(arr)
        w.add_tensor(name, arr)
        print(f"{name:32s} ne={tuple(arr.shape[::-1])!s:20s} {str(arr.dtype)}")
    w.write_header_to_file()
    w.write_kv_data_to_file()
    w.write_tensors_to_file()
    w.close()


def read_gguf(path: Path):
    """tensors: name -> (ne, type name); meta: key -> python value."""
    import gguf

    r = gguf.GGUFReader(str(path))
    tensors = {}
    for t in r.tensors:
        tensors[t.name] = (tuple(int(x) for x in t.shape), t.tensor_type.name)  # reader gives ne order already
    meta = {}
    for key, field in r.fields.items():
        if key.startswith("GGUF."):
            continue
        meta[key] = _field_value(field, gguf)
    return tensors, meta, r


def _field_value(field, gguf):
    types = field.types
    if not types:
        return None
    if types[0] == gguf.GGUFValueType.ARRAY:
        inner = types[-1]
        if inner == gguf.GGUFValueType.STRING:
            return [bytes(field.parts[i]).decode("utf-8") for i in field.data]
        return [field.parts[i].tolist()[0] if hasattr(field.parts[i], "tolist") else field.parts[i] for i in field.data]
    if types[0] == gguf.GGUFValueType.STRING:
        return bytes(field.parts[field.data[0]]).decode("utf-8")
    return field.parts[field.data[0]].tolist()[0]


def verify(path: Path, cfg: dict | None = None, vocab: list[str] | None = None, fold=None) -> None:
    assert path.is_file(), f"verify: {path} not found"
    tensors, meta, r = read_gguf(path)
    if vocab is None:
        vocab = meta.get("lyricsalign.vocab")
    if cfg is None:
        cfg = dict(DEFAULT_CONFIG)
        cfg.update({"conv_dim": meta["lyricsalign.conv_dim"], "conv_kernel": meta["lyricsalign.conv_kernel"],
                    "conv_stride": meta["lyricsalign.conv_stride"], "hidden_size": meta["lyricsalign.hidden"],
                    "intermediate_size": meta["lyricsalign.ffn"], "num_hidden_layers": meta["lyricsalign.layers"],
                    "num_attention_heads": meta["lyricsalign.heads"], "num_conv_pos_embeddings": meta["lyricsalign.pos_kernel"],
                    "num_conv_pos_embedding_groups": meta["lyricsalign.pos_groups"], "vocab_size": len(vocab),
                    "pad_token_id": meta["lyricsalign.blank_id"], "layer_norm_eps": meta["lyricsalign.layer_norm_eps"]})
    verify_tensors(tensors, meta, cfg, vocab)
    if fold is not None:
        import torch

        g, v = fold
        reference = torch._weight_norm(v, g, dim=2).to(torch.float16).numpy()
        # GGUFReader hands the data back in numpy (row-major, torch) order already; a flat view is reshaped the same way.
        stored = np.asarray(next(t for t in r.tensors if t.name == "pos.weight").data).reshape(reference.shape)
        mine = fold_pos_conv(g, v)
        torch_fold = torch._weight_norm(v, g, dim=2)
        assert float((mine - torch_fold).abs().max()) < 1e-6, "weight-norm fold differs from torch"
        assert np.array_equal(stored.astype(np.float16), mine.to(torch.float16).numpy()), "stored pos.weight is not the folded weight"
        # Two f32 computations 5e-7 apart round to different f16 values at a rounding boundary (measured: 6945 of
        # 8 388 608 elements), so against torch's own fold the test is "within one f16 ulp", not bit equality.
        assert np.allclose(stored.astype(np.float32), torch_fold.numpy(), rtol=2 ** -10, atol=1e-7),             "stored pos.weight is more than an f16 ulp away from torch's weight norm"
    print(f"verify: ok, {len(tensors)} tensors, vocab {len(vocab)}, blank {meta['lyricsalign.blank_id']}"
          + ("" if fold is not None else " (no checkpoint: weight-norm fold not re-checked)"))


def main(argv: list[str]) -> int:
    if len(argv) in (3, 4) and argv[1] == "--verify-only":
        fold = None
        if len(argv) == 4:  # with the checkpoint, the weight-norm fold is re-checked too
            import torch

            pre = "wav2vec2.encoder.pos_conv_embed.conv."
            sd = torch.load(Path(argv[3]) / "pytorch_model.bin", map_location="cpu", weights_only=True)
            fold = (sd[pre + "weight_g"], sd[pre + "weight_v"])
        try:
            verify(Path(argv[2]), fold=fold)
        except AssertionError as e:
            print(f"verify: FAIL: {e}", file=sys.stderr)
            return 1
        return 0
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    ckpt, out = Path(argv[1]), Path(argv[2])
    cfg, vocab, sd = load_checkpoint(ckpt)
    pre = "wav2vec2.encoder.pos_conv_embed.conv."
    fold = (sd[pre + "weight_g"].clone(), sd[pre + "weight_v"].clone())
    tensors = map_tensors(cfg, sd)
    out.parent.mkdir(parents=True, exist_ok=True)
    write_gguf(out, cfg, vocab, tensors)
    try:
        verify(out, cfg, vocab, fold)
    except AssertionError as e:
        print(f"verify: FAIL: {e}", file=sys.stderr)
        return 1
    print(f"wrote {out} ({out.stat().st_size / 1e6:.1f} MB)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
