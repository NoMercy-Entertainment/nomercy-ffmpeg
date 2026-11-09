"""Gate (a) of nomercy-ffmpeg #126: compare the ggml port's emissions with the prototype's JFK fixture.

    python -I tools/lyricsalign-lab/gate_a.py <emissions.f32> <jfk-logprobs-f16.npy> [frames-per-row=392]

The .f32 file is raw little-endian float32, T x 392 log-probs, one row per 20 ms frame (what emit.c and the filter's
NOMERCY_LYRICSALIGN_EMISSIONS dump write). Passes (exit 0) when the frame count matches, the argmax agrees on at least
99 % of frames and the mean absolute difference is under 0.05 nats; prints both numbers either way.
"""
import sys

import numpy as np

ARGMAX_MIN = 0.99
MEAN_ABS_MAX = 0.05


def main(f32_path: str, npy_path: str, vocab: int = 392) -> int:
    got = np.fromfile(f32_path, dtype="<f4")
    ref = np.load(npy_path).astype(np.float32)
    if got.size % vocab:
        print(f"gate a: {f32_path} holds {got.size} floats, not a multiple of {vocab}")
        return 1
    got = got.reshape(-1, vocab)
    print(f"frames {got.shape[0]} (fixture {ref.shape[0]})")
    if got.shape != ref.shape:
        print("gate a: FAIL: frame count differs")
        return 1
    agree = float((got.argmax(axis=1) == ref.argmax(axis=1)).mean())
    mean_abs = float(np.abs(got - ref).mean())
    max_abs = float(np.abs(got - ref).max())
    print(f"argmax agreement {agree * 100:.2f} % (gate >= {ARGMAX_MIN * 100:.0f} %)")
    print(f"mean |delta| {mean_abs:.4f} nats (gate < {MEAN_ABS_MAX}), max |delta| {max_abs:.3f}")
    ok = agree >= ARGMAX_MIN and mean_abs < MEAN_ABS_MAX
    print("gate a:", "ok" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    if len(sys.argv) not in (3, 4):
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1], sys.argv[2], int(sys.argv[3]) if len(sys.argv) == 4 else 392))
