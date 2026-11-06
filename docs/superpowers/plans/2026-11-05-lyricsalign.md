# lyricsalign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A new `lyricsalign` audio filter that places known lyric text on a vocal stem with CTC forced alignment (wav2vec2 phoneme model on ggml, espeak-ng phonemes), writes JSON Lines, and never writes a time it is not sure of; shipped in every platform tarball with its model on a public models repo.

**Architecture:** Three header-only pieces that a plain C compiler can test (`nm_lyricsalign_align.h`: star column, Viterbi, verdict, walk-back; `nm_lyricsalign_phones.h`: espeak IPA parsing and the vocabulary mapping chain; `nm_lyricsalign_w2v2.h`: the wav2vec2 ggml graph and the windowed emissions) and one thin filter (`af_lyricsalign.c`: options, two inputs, swresample, espeak-ng calls, JSON output) that glues them, built the way `whisper` and `trailingsilence` are. A Docker lab under `tools/lyricsalign-lab/` builds a minimal ffmpeg with only this filter in minutes, so every task is verified against the real JFK fixture before the hours-long platform builds run once at the end.

**Tech Stack:** FFmpeg 9.0 libavfilter, ggml 0.15.x from whisper.cpp v1.9.1 (`scripts/48-whisper.sh`), GGUF, espeak-ng 1.52.0 (static, cmake), swresample, bash + PowerShell test suites, Python 3.12 + numpy for checks, PyTorch for the converter.

**Spec:** `docs/superpowers/specs/2026-11-05-lyricsalign-design.md` (issue #126, verbatim). The prototype it was measured with is `eval/lyrics_eval/{ctc_align,ctc_pipeline,phonemes,onset,audio}.py` in `F:\DevProjects\NoMercyEntertainment-Developement\nomercy-lyrics-creator-plugin` (534 lines of Python; the port reproduces it number for number). The JFK fixture is `eval/fixtures/jfk/` there.

## Global Constraints

- Filter name `lyricsalign`, source `libavfilter/af_lyricsalign.c`, two audio inputs (`vocals`, `backing`), one output = input 0 unchanged.
- Exactly nine options, in this order with these defaults: `model` (required), `text_file` (required), `language` (required), `espeak_data` `""`, `blend` `0.5`, `destination` `""`, `threads` `0`, `use_gpu` `0`, `gpu_device` `0`.
- Constants, verbatim from the spec: 16 kHz mono, hop 320 (20 ms), window 20 s core + 1 s context each side (352 000 samples), 50 context frames dropped per side, per-window zero mean unit variance with floor `1e-7`, star weight `0.3`, line blank penalty `0.05`, disagree `> 0.3 s`, first gap `> 0.5 s`, stray prefix `6` phones / gap `> 0.8 s` / posterior `< 0.2`, walk-back after a pause `>= 1.0 s`, envelope hop 10 ms, `20·log10(rms + 1e-9)`, within `10 dB`, floor `-45 dBFS`, at most `0.8 s`, never before `previous_end + 0.05 s`.
- Times in the JSON are seconds, 3 decimals. Every output line parses as JSON; text goes through `nm_json_escape` (invalid UTF-8 repaired).
- The filter exits non-zero only on bad input (missing model, unknown voice, missing espeak data, unreadable or empty `text_file`). No alignment path is exit 0 with `written:0`.
- Model: `facebook/wav2vec2-xlsr-53-espeak-cv-ft`, Apache-2.0, f16 GGUF about 630 MB, released on the org repo `nomercy-lyricsalign-models`, never in a tarball or in git.
- espeak-ng 1.52.0, GPL-3.0-or-later (the configure line already has `--enable-gpl --enable-version3`); `espeak-ng-data` ships next to the binary in all seven tarballs.
- The ggml thread default and the GPU path follow `whisper`/`stemsplit`: `nm_ggml_backend_init`, `NOMERCY_GGML_GPU=0`, the `-filter_threads` rule of af_whisper.c (#115).
- Repository rules: commits on `dev` only, conventional commits, no self-attribution lines of any kind, push only on the owner's explicit word, all seven platforms built locally before that word is asked for ([[feedback-local-build-before-push]]), Linux stays fully static. Questions to the owner go through AskUserQuestion.
- Test rule of this repository: a check is assumed to lie until it has been watched failing. Every test task ends with a mutation step.

## Calls the plan makes (where it reads the spec, not changes it)

1. **Walk-back floor uses the prototype's line end.** The spec defines a line's `end` as the last phone's *run end*; the prototype's `previous_end` for the walk-back is the last phone's *first frame* (`LinePlacement.end()`). The JSON `end` follows the spec; the walk-back floor and the `>= 1.0 s` pause test follow the prototype, because the benchmark criterion (every written line within 40 ms of the prototype) is only reachable that way. The fixture test pins it.
2. **Step numbers.** `62-espeak-ng.sh` in the spec is `65-espeak-ng.sh` here and the filter step is `66-lyricsalign.sh`: 62, 63 and 64 are taken since the issue was written (libjxl, libsnappy, liboapv).
3. **Pass-through is streamed.** Input-0 frames are forwarded as they arrive; the filter keeps 16 kHz mono copies and aligns once both inputs ended, before it forwards EOF. Same output as "buffer then pass through", a third of the memory.
4. **An infinite backing ends with the vocals.** `anullsrc` has no EOF; once input 0 ends, input 1 is no longer requested, further backing frames are dropped, and the check signal runs over the common length (`min`), as the spec says.
5. **An all-zero backing is not aligned twice.** With `blend=0`, or when every backing sample is 0, the check placement is the vocals placement (header `check` is `none` for `blend=0`, `backing` otherwise); same result as the spec, half the model time, which keeps the CI gate to one model pass.
6. **Integer frame rules.** All spec thresholds become frame counts (20 ms): disagree `|Δ| >= 16`, first gap `>= 26`, stray-prefix gap `>= 41`, pause `>= 50`; envelope hops (10 ms): max walk 80, margin 5. These are exactly what the prototype's float comparisons decide (its starts are multiples of 0.02 rounded to 3 decimals).
7. **espeak-ng data check is the filter's.** `espeak_Initialize` silently falls back to `ESPEAK_DATA_PATH`, the registry and a compiled-in path when the given directory is missing, so the filter stats `<espeak_data>/phontab` itself and fails init with the path. `espeak_data` may name the `espeak-ng-data` directory or its parent (espeak accepts both).
8. **Gate (a) runs through the filter**, with the undocumented environment variable `NOMERCY_LYRICSALIGN_EMISSIONS=<file>` (raw little-endian f32, `T×392`, vocals only), so no tenth option is needed. The lab additionally has a standalone emitter for fast iteration.
9. **Log-softmax on the CPU in double.** Logits come back from ggml as f32; the filter computes log-softmax per frame itself (the spec's "`ggml_log_soft_max`" does not exist in ggml).
10. **The thread rule is shared, not copied.** `nm_whisper_physical_cores`/`nm_whisper_threads` move from af_whisper.c into `scripts/includes/nm_ggml_threads.h` as `nm_ggml_physical_cores`/`nm_ggml_filter_threads`; af_whisper.c's behaviour is unchanged (its CI tests pin it).
11. **The models repo needs the owner.** Creating a public repository on the GitHub org and publishing a release is outward-facing; Task 12 asks before doing it.

## Review Focus

1. **Windows text files**: CRLF line endings, a UTF-8 BOM, whitespace-only lines. `\r` must never reach espeak as text, the BOM is not part of line 0, a whitespace-only line is an `empty` line. Test in Task 9.
2. **More phones than frames** (text longer than the audio, or a 2 s clip with a verse): `no_alignment` for every line, header `written:0`, exit 0, no crash in the Viterbi. Test in Task 4 (unit) and Task 9 (end to end).
3. **Audio shorter than one window edge**: 0 samples, 300 samples (under the 400-sample receptive field), 0.5 s. No division by zero in the normalisation, `T = len / 320` frames, exit 0. Test in Task 8.
4. **Backing not the vocals' length**: shorter by 1 s, longer (a file), infinite (`anullsrc` without `duration`). The run ends, the check uses the common length. Test in Task 9.
5. **Lines espeak cannot speak**: punctuation only (`...`), a line of emoji, a line with an invalid UTF-8 byte. `no_phones` or a placed line, and the JSON line still parses. Test in Task 9.

---

### Task 1: The lab, and the spec in the repo

A Docker lab that builds a minimal ffmpeg with the whisper filter and (from Task 10 on) `lyricsalign`, in minutes, against the real FFmpeg 9.0 source and the real `scripts/includes` files. Later tasks' verification steps run in it.

**Files:**
- Create: `tools/lyricsalign-lab/Dockerfile`, `tools/lyricsalign-lab/README.md`, `tools/lyricsalign-lab/build.sh`, `tools/lyricsalign-lab/suite.sh`
- Already written: `docs/superpowers/specs/2026-11-05-lyricsalign-design.md` (committed in this task)

**Interfaces:**
- Produces: image `lyricsalign-lab` (ubuntu:24.04, gcc 13, cmake, nasm, python3 + numpy, FFmpeg 9.0 source at `/build/ffmpeg`, whisper.cpp v1.9.1 built static CPU-only with `-DGGML_NATIVE=OFF -DGGML_AVX=ON -DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON -DGGML_OPENMP=OFF`, installed to `PREFIX=/opt/nm` with a `whisper.pc` whose `Libs:` names `-lwhisper -lggml -lggml-base -lggml-cpu-variants`, where `libggml-cpu-variants.a` is `ggml_cpu_dispatch.c` compiled with `-DNM_GGML_CPU_FIXED='"haswell"' -DNM_NO_VULKAN=1` plus the stock `libggml-cpu.a` objects merged in, so `nm_ggml_backend_init` and friends resolve the way darwin's fixed mode does).
- `build.sh [--fresh]`: runs in the container with the repo mounted at `/repo` and a named volume `lyricsalign-lab-prefix` on `/opt/nm`; exports `TARGET_OS=linux ARCH=x86_64 PREFIX=/opt/nm CMAKE_COMMON_ARG="-DCMAKE_INSTALL_PREFIX=/opt/nm -DBUILD_SHARED_LIBS=OFF -DCMAKE_BUILD_TYPE=Release"`, sources `/repo/scripts/init/helpers.sh`, runs `/repo/scripts/65-espeak-ng.sh` when `/opt/nm/lib/libespeak-ng.a` is absent or `--fresh`, runs `/repo/scripts/66-lyricsalign.sh`, then configures ffmpeg with `--disable-everything --enable-avfilter --enable-swresample --enable-whisper --enable-gpl --enable-version3 --enable-filter=lyricsalign,whisper,anullsrc,aresample,aformat,atrim,asetnsamples,sine,aevalsrc,amix,volume --enable-demuxer=wav --enable-decoder=pcm_s16le,pcm_f32le --enable-muxer=null,wav --enable-encoder=pcm_s16le --enable-protocol=file,pipe --extra-cflags=-I/opt/nm/include --extra-ldflags=-L/opt/nm/lib --extra-libs="$(cat /build/extra_libflags.txt) -lpthread -lm -lstdc++"` and runs `make -j$(nproc) ffmpeg`. Until Task 10 exists, the script skips 65/66 when the files are absent and the filter list drops `lyricsalign`.
- `suite.sh`: runs `/repo/tests/unit/run.sh`, then every function of `/repo/tests/lib/lyricsalign.sh` with `FFMPEG=/build/ffmpeg/ffmpeg` and `LYRICSALIGN_ASSETS_DIR=/assets` (a host directory mounted read-only: the GGUF from Task 2, `jfk.wav`, `espeak-ng-data` is found next to the binary by a symlink the script makes).
- Host entry points (README): `docker build -t lyricsalign-lab tools/lyricsalign-lab`, `tools/lyricsalign-lab/run.sh build`, `tools/lyricsalign-lab/run.sh suite`, `tools/lyricsalign-lab/run.sh shell` (from Git Bash with `MSYS_NO_PATHCONV=1`).

- [ ] **Step 1: Write the Dockerfile and the three scripts** as specified above. The FFmpeg source comes from `https://ffmpeg.org/releases/ffmpeg-9.0.tar.xz` (same version `ffmpeg-base.dockerfile` pins; copy its digest line). whisper.cpp from the v1.9.1 tag, with `scripts/includes/whisper-dtw-median-filter.patch` applied the way 48-whisper.sh does (so the lab's whisper filter is the shipped one).
- [ ] **Step 2: Build the image and run `build.sh`**

Run: `docker build -t lyricsalign-lab tools/lyricsalign-lab && tools/lyricsalign-lab/run.sh build`
Expected: ends with `/build/ffmpeg/ffmpeg` present and `ffmpeg -hide_banner -filters | grep whisper` printing the whisper line.
- [ ] **Step 3: Run the existing whisper unit tests through `suite.sh`**

Run: `tools/lyricsalign-lab/run.sh suite`
Expected: `1 unit test program(s), 0 failed` (only `test_nm_whisper_words` exists yet) and `lyricsalign.sh: not present yet` printed, exit 0.
- [ ] **Step 4: Commit**

```bash
git add tools/lyricsalign-lab docs/superpowers/specs/2026-11-05-lyricsalign-design.md docs/superpowers/plans/2026-11-05-lyricsalign.md
git commit -m "chore(lyricsalign): design, plan and a Docker lab for the filter (#126)"
```

---

### Task 2: The converter, `tools/wav2vec2-gguf`

**Files:**
- Create: `tools/wav2vec2-gguf/convert.py`, `tools/wav2vec2-gguf/Dockerfile`, `tools/wav2vec2-gguf/README.md`, `tools/wav2vec2-gguf/requirements.txt` (`torch==2.11.0` CPU index, `gguf==0.17.1`, `numpy==2.4.6`; pin what resolves on 2026-11-05)

**Interfaces:**
- `python convert.py <checkpoint_dir> <out.gguf>`: reads `pytorch_model.bin` with `torch.load(map_location="cpu")` (the 2021 checkpoint, keys `wav2vec2.*` and `lm_head.*`; no transformers dependency), `config.json` and `vocab.json`; writes the GGUF; prints every tensor name, ggml shape and type; runs `verify(path)` at the end and exits 1 if it fails.
- GGUF tensor names and ggml shapes (ne, innermost first; torch row-major memory is kept, no transpose):
  - `enc.conv.{i}.weight` F16 `[k_i, in_i, 512]` (in_0 = 1), `enc.conv.{i}.bias` F32 `[512]`, `enc.conv.{i}.ln.weight`/`.bias` F32 `[512]`, i = 0..6
  - `proj.ln.weight`/`.bias` F32 `[512]`, `proj.weight` F16 `[512, 1024]`, `proj.bias` F32 `[1024]`
  - `pos.weight` F16 `[128, 64, 1024]` (weight norm folded: `w = g · v / ‖v‖` with the norm over torch dims (0, 1) for each of the 128 kernel positions, since HF uses `weight_norm(conv, "weight", dim=2)`), `pos.bias` F32 `[1024]`
  - `layers.{l}.attn.q.weight`, `.k.`, `.v.`, `.o.` F16 `[1024, 1024]` + `.bias` F32 `[1024]`; `layers.{l}.ln1.weight`/`.bias`, `layers.{l}.ln2.weight`/`.bias` F32 `[1024]`; `layers.{l}.ffn.in.weight` F16 `[1024, 4096]` + `.bias` `[4096]`; `layers.{l}.ffn.out.weight` F16 `[4096, 1024]` + `.bias` `[1024]`; l = 0..23
  - `enc.ln.weight`/`.bias` F32 `[1024]`; `head.weight` F16 `[1024, 392]`, `head.bias` F32 `[392]`
- Metadata: `general.architecture="wav2vec2-ctc"`, `general.name="wav2vec2-xlsr-53-espeak-cv-ft"`, `general.license="apache-2.0"`, `lyricsalign.arch="wav2vec2-ctc"`, `lyricsalign.sample_rate=16000` (u32), `lyricsalign.hop=320`, `lyricsalign.blank_id=0`, `lyricsalign.vocab` (array of 392 strings in id order), `lyricsalign.conv_dim`/`conv_kernel`/`conv_stride` (u32 arrays of 7), `lyricsalign.hidden=1024`, `lyricsalign.heads=16`, `lyricsalign.ffn=4096`, `lyricsalign.layers=24`, `lyricsalign.pos_kernel=128`, `lyricsalign.pos_groups=16`, `lyricsalign.layer_norm_eps=1e-5` (f32), `lyricsalign.input_norm_floor=1e-7` (f32).
- `verify(path) -> None` raises on: a tensor missing or extra, a wrong shape or type, `vocab` not 392 entries with `<pad>` at 0, and a weight-norm fold error: it recomputes `pos.weight` from `weight_g`/`weight_v` with `torch.nn.utils.parametrizations`-free math and compares (max abs diff `< 1e-6` before the f16 cast, exact after casting both). Also `verify({})`-style unit use: `verify_tensors(dict)` is the inner function the README's red/green check calls on an empty dict.

- [ ] **Step 1: Write `verify_tensors` and its red check first**

Run: `python -I tools/wav2vec2-gguf/convert.py --verify-only /nonexistent.gguf`
Expected: exits 1 with `verify: ... not found`; and `python -I -c "import sys; sys.path.insert(0,'tools/wav2vec2-gguf'); import convert; convert.verify_tensors({}, {})"` raises `AssertionError: missing tensor enc.conv.0.weight`.
- [ ] **Step 2: Write the converter** (`load_checkpoint`, `fold_pos_conv`, `write_gguf`, `verify`). Biases and norms F32, everything else F16. Keep it under 250 lines.
- [ ] **Step 3: Convert the local checkpoint**

Run (this machine has torch 2.11 and the checkpoint): `python -I tools/wav2vec2-gguf/convert.py F:/DevProjects/NoMercyEntertainment-Developement/nomercy-lyrics-creator-plugin/build/tools/models/wav2vec2-xlsr-53-espeak-cv-ft F:/DevProjects/NoMercyEntertainment-Developement/lyricsalign-assets/wav2vec2-xlsr-53-espeak-cv-ft-f16.gguf`
Expected: `verify: ok, 1 + 7·4 + 5 + 2 + 24·16 + 2 + 2 = 423 tensors`, file size between 620 and 640 MB; write the sha256 to `wav2vec2-xlsr-53-espeak-cv-ft-f16.gguf.sha256` next to it (that file is what Task 12 uploads).
- [ ] **Step 4: Build the Docker image and convert once through it**

Run: `docker build -t wav2vec2-gguf tools/wav2vec2-gguf && MSYS_NO_PATHCONV=1 docker run --rm -v F:/DevProjects/NoMercyEntertainment-Developement/lyricsalign-assets:/out wav2vec2-gguf /work/checkpoint /out/docker.gguf`
Expected: `verify: ok`; `sha256sum` of `docker.gguf` equals the Step 3 digest (the conversion is deterministic). Delete `docker.gguf`. The Dockerfile downloads the checkpoint at image build (`huggingface.co/facebook/wav2vec2-xlsr-53-espeak-cv-ft/resolve/main/pytorch_model.bin` + `config.json` + `vocab.json`), the way `spleeter-gguf` does.
- [ ] **Step 5: Commit**

```bash
git add tools/wav2vec2-gguf
git commit -m "feat(lyricsalign): wav2vec2-xlsr-53-espeak-cv-ft to GGUF converter with built-in verify"
```

---

### Task 3: espeak-ng 1.52.0 as a static library, `scripts/65-espeak-ng.sh`

**Files:**
- Create: `scripts/65-espeak-ng.sh`
- Modify: `scripts/init/package.sh` (copy `${PREFIX}/share/espeak-ng-data` into `/ffmpeg/${TARGET_OS}/${ARCH}/espeak-ng-data` before the "Pre Cleaning up" `rm -rf ${PREFIX}`, failing the step if `phontab` is then missing)
- Modify: `README.md` licence table (one row: espeak-ng 1.52.0, GPL-3.0-or-later, "phonemes for `lyricsalign`")

**Interfaces:**
- Produces `${PREFIX}/lib/libespeak-ng.a`, `${PREFIX}/lib/libucd.a`, `${PREFIX}/include/espeak-ng/*.h`, `${PREFIX}/include/espeak/speak_lib.h`, `${PREFIX}/share/espeak-ng-data/` (phontab, phonindex, phondata, intonations, every `*_dict`, `lang/`, `voices/!v`; no `mbrola_ph`), and `add_extralib "-lespeak-ng -lucd"`; pins `espeak-ng 1.52.0 <tarball sha256>` to `/ffmpeg_build_pins.log`.
- Build shape: source tarball `https://github.com/espeak-ng/espeak-ng/releases/download/1.52.0/espeak-ng-1.52.0.tar.gz`, digest pinned in the script. Two cmake builds: (1) a **native** build with the host compiler (no `CMAKE_COMMON_ARG`) whose only purpose is `cmake --build . --target data` (cmake/data.cmake runs the just-built `espeak-ng` binary to compile phonemes and dictionaries, which a cross binary cannot do); (2) the **target** build with `${CMAKE_COMMON_ARG} -DBUILD_SHARED_LIBS=OFF -DUSE_ASYNC=OFF -DUSE_MBROLA=OFF -DUSE_LIBSONIC=OFF -DUSE_LIBPCAUDIO=OFF -DUSE_KLATT=OFF -DUSE_SPEECHPLAYER=OFF -DESPEAK_COMPAT=OFF`, building only `--target espeak-ng ucd` (never the binary, never `data`, never the tests). Install by copying: the two archives, the headers, and the native build's `espeak-ng-data`. On Windows add `-DCMAKE_SYSTEM_NAME=Windows`; the script must not depend on `cmake --install` (it would try the binary).
- Skips nothing: exit 255 is not used; every platform needs it.

- [ ] **Step 1: Write the script** with the same `log`/verify discipline as `61-trailing-silence.sh`: after both builds, assert the archives exist, assert `nm` (`${NM_NM:-nm}`) finds `espeak_TextToPhonemes` in `libespeak-ng.a`, assert `espeak-ng-data/phontab`, `en_dict` and `nl_dict` exist, assert the data directory is under 20 MB.
- [ ] **Step 2: Run it in the lab**

Run: `tools/lyricsalign-lab/run.sh build --fresh`
Expected: the pin line `📌 espeak-ng 1.52.0 ...` on stdout, `/opt/nm/lib/libespeak-ng.a` present, `du -sh /opt/nm/share/espeak-ng-data` between 10 and 20 MB.
- [ ] **Step 3: Prove the library speaks the fixture's phones.** Compile `tools/lyricsalign-lab/espeak-check.c` (20 lines: `espeak_Initialize(AUDIO_OUTPUT_SYNCHRONOUS, 0, argv[1], 0)`, `espeak_SetVoiceByName(argv[2])`, loop `espeak_TextToPhonemes(&p, espeakCHARS_UTF8, espeakPHONEMES_IPA | ('_' << 8))`, print clauses joined by a space) in the lab and run it on the JFK sentence with `en-us`.

Run: `tools/lyricsalign-lab/run.sh shell -c 'gcc -I/opt/nm/include tools/lyricsalign-lab/espeak-check.c -L/opt/nm/lib -lespeak-ng -lucd -lm -lpthread -o /tmp/ec && /tmp/ec /opt/nm/share/espeak-ng-data en-us "And so my fellow Americans, ask not what your country can do for you, ask what you can do for your country."'`
Expected: a line starting `ˈænd sˌoʊ maɪ fˈɛloʊ ɐmˈɛɹɪkənz` whose words, split on `_` with stress marks removed, equal `espeak_ipa_words` in the fixture JSON (compare with a 5-line python one-liner in the step). If the library output differs from the CLI's `--ipa --sep=_` (it should not; both are `espeakPHONEMES_IPA` with a separator), record the difference in the README and stop: the spec's parsing rules were measured on the CLI output.
- [ ] **Step 4: `espeak_SetVoiceByName("xx-nope")` returns non-OK** — extend `espeak-check.c` to print the return code; run with `xx-nope`.

Expected: `EE_NOT_FOUND` (exit 1 from the tool), nothing crashes.
- [ ] **Step 5: package.sh change** plus the README row. Verify by reading `package.sh` back: the copy sits before `rm -rf ${PREFIX}`.
- [ ] **Step 6: Commit**

```bash
git add scripts/65-espeak-ng.sh scripts/init/package.sh README.md tools/lyricsalign-lab/espeak-check.c
git commit -m "feat(build): espeak-ng 1.52.0 as a static library with its data in every tarball"
```

---

### Task 4: `nm_lyricsalign_align.h`: star, Viterbi, verdict, walk-back, with the JFK fixture

**Files:**
- Create: `scripts/includes/nm_lyricsalign_align.h`
- Create: `tests/unit/test_nm_lyricsalign_align.c`
- Create: `tests/unit/fixtures/jfk/jfk-logprobs-f16.npy`, `tests/unit/fixtures/jfk/jfk-alignment.json` (copied from the plugin repo, 440 KB), `tests/unit/fixtures/jfk/README.md` (where they come from, how to regenerate), `tests/unit/fixtures/jfk/make_fixture_h.py` and its output `tests/unit/fixtures/jfk/jfk_fixture.h` (the JSON turned into C arrays: `JFK_TOKENS[69]`, `JFK_FIRST_FRAMES[69]`, `JFK_POSTERIORS[69]`, `JFK_WORD_PHONES[22]` (phones per word), `JFK_WORD_STARTS[22]`, `JFK_START_SPIKE 0.36`, `JFK_END 10.34`, `JFK_START_WRITTEN 0.34`, `JFK_STAR_FRAMES`, `JFK_FRAMES 550`, `JFK_VOCAB 392`, `JFK_BLANK 0`)
- Modify: `tests/unit/run.sh` (compile with `-lm`; the loop already picks up new `test_*.c`)

**Interfaces** (all `static inline`, prefix `nm_la_`, memory through `NM_LA_MALLOC/NM_LA_FREE` defaulting to the C library, as `nm_whisper_words.h`):

```c
#define NM_LA_RATE 16000
#define NM_LA_HOP 320
#define NM_LA_ENV_HOP 160
#define NM_LA_STAR_WEIGHT 0.3
#define NM_LA_LINE_BLANK_PENALTY 0.05f
#define NM_LA_NEG (-1e9f)
enum NMLaReason { NM_LA_OK = 0, NM_LA_EMPTY, NM_LA_NO_PHONES, NM_LA_DISAGREE, NM_LA_FIRST_GAP,
                  NM_LA_STRAY_PREFIX, NM_LA_CHECK_FAILED, NM_LA_NO_ALIGNMENT };
static inline const char *nm_la_reason_name(enum NMLaReason r); /* "empty", "no_phones", ... */
typedef struct { int first, last; float post; } NMLaPlace;   /* frames; last inclusive; posterior at first */
static inline void nm_la_log_softmax(const float *logits, int frames, int vocab, float *logp); /* double per frame */
static inline float *nm_la_add_star(const float *logp, int frames, int vocab);  /* frames x (vocab+1), NULL on alloc */
static inline int nm_la_viterbi(const float *logp, int frames, int cols, const int *tokens, int n_tokens,
                                int blank, int star, float line_penalty, NMLaPlace *out); /* 1 placed, 0 no path, -1 alloc */
static inline enum NMLaReason nm_la_verdict(const NMLaPlace *line, int n, const NMLaPlace *check);
                                /* check == NULL -> NM_LA_CHECK_FAILED; else disagree/first_gap/stray_prefix/OK in that order */
static inline float *nm_la_envelope_db(const float *samples, int n, int *n_env);
static inline int nm_la_walk_back(const float *env, int n_env, int spike_frame, int prev_end_frame /* -1 = none */);
                                /* returns the 10 ms hop index k; caller writes k * 0.01 */
static inline int nm_la_pause_before(int start_frame, int prev_end_frame); /* prev < 0 || start - prev >= 50 */
```

Viterbi contract (what the fixture pins): states `blank, t1, blank, ..., tn, blank`; candidates checked in the order stay, s−1, s−2, s−3, s−4 with strict `>` so ties go to the earliest candidate exactly as `numpy.argmax` does; float32 scores, `score = max + emit` in float32; int8 back-pointers; start in state 0 or 1; end in `2n` unless `score[2n-1] > score[2n]`; a best end score `<= NM_LA_NEG / 2` is "no path"; `first` = earliest frame of the token's run, `last` = latest, `post = exp(logp[first][token])`. The s−2 rule needs a different token at s−2 and `s != 1`; s−3 needs a star at s−2; s−4 needs a star at s−2 and a different token at s−4. The penalty applies to a blank state whose two neighbours are both non-star tokens.

- [ ] **Step 1: Generate `jfk_fixture.h`** with `make_fixture_h.py` (python -I, numpy only) and copy the two fixture files in. The header also gets `JFK_LOGP` as a path, not data: the test reads the `.npy` itself (header is a fixed 128-byte v1.0 header, `<f2`, shape (550, 392)) and widens f16 → f32 with a 10-line converter in the test.
- [ ] **Step 2: Write the failing tests** in `test_nm_lyricsalign_align.c` (same `CHECK` macro as the whisper test):
  - `test_log_softmax_rows_sum_to_one`: three frames of made-up logits; `exp` of each row sums to 1 ± 1e-6; a row of equal logits gives `-log(4)` each.
  - `test_star_column`: `p_blank = 1` (logp 0) gives `NM_LA_NEG`; `logp_blank = log(0.5)` gives `log(0.5) + log(0.3)` ± 1e-6.
  - `test_viterbi_three_tokens_known_path`: 10 frames × 4 columns (blank, a, b, c), emissions hand-built so the best path is `a` at 2, `b` at 5, `c` at 8; `first == {2, 5, 8}`, `last == {3, 6, 8}`.
  - `test_viterbi_repeat_rule`: tokens `a a` on emissions where `a` is loud at every frame; the second `a` starts at least one frame after the first ends with a blank between (`first[1] > last[0] + 1`).
  - `test_viterbi_star_skip`: tokens `star a` with the star column at `NM_LA_NEG` everywhere; returns 1, `a` is placed, and the star, never visited, has `first == -1` and `last == -1` (pin: a token the path skips gets −1 in both).
  - `test_viterbi_penalty_changes_path`: an emission where a blank between two phones of one line is marginally better than staying on the phone; `line_penalty = 0` places phone 2 later than `line_penalty = 0.05` does.
  - `test_viterbi_no_path`: 3 frames, 5 tokens → returns 0.
  - `test_viterbi_jfk_exact`: the fixture's 69 tokens on the fixture's emissions with star appended, penalty 0.05: every `first` equals `JFK_FIRST_FRAMES`, every `post` within 1e-3 of `JFK_POSTERIORS`, and the number of placed stars equals `JFK_STAR_FRAMES`.
  - `test_verdict_each_reason`: hand-built `NMLaPlace` arrays for `check == NULL` → `CHECK_FAILED`; check start 16 frames away → `DISAGREE` and 15 frames → not; gap 26 between phone 1 and 2 → `FIRST_GAP` and 25 → not; 3 phones at posterior 0.1 then a gap of 41 → `STRAY_PREFIX`, same with posterior 0.3 → `OK`, same gap at phone 7 → `OK`.
  - `test_envelope_db`: 1600 samples of 0.5 amplitude square → 10 hops, each `20·log10(0.5)` ± 0.01; 1599 samples → 9 hops; silence → `-180` dB.
  - `test_walk_back_stops_at_each_limit`: an envelope at −20 dB from hop 50 to 100 and −60 dB before: spike at frame 30 (hop 60) walks to hop 50 (floor −45 dBFS); same envelope at −25 dB from hop 0: walks to hop 60−80 → 0 (max 0.8 s, clamp); with `prev_end_frame = 20` (hop 40) walks to 45 (margin 5); a step of 11 dB at hop 55 stops at 55 (within 10 dB).
  - `test_walk_back_jfk`: envelope from `jfk.wav` samples (test reads the WAV from `JFK_WAV` env var, skips with a message if unset) from spike frame 18 and no previous line gives hop 34 (`0.34 s`), `lead_in 0.02`.
  - `test_pause_before`: `(50, 0) == 1`, `(49, 0) == 0`, `(10, -1) == 1`.
- [ ] **Step 3: Run to verify they fail**

Run: `bash tests/unit/run.sh`
Expected: `test_nm_lyricsalign_align: does not compile cleanly` (header missing).
- [ ] **Step 4: Implement the header** (about 300 lines). Viterbi memory: `scores` 2 × states floats, back-pointers `frames × states` int8 in one allocation.
- [ ] **Step 5: Run to verify they pass**

Run: `bash tests/unit/run.sh` (on this machine with gcc from Git Bash or in the lab: `tools/lyricsalign-lab/run.sh shell -c 'JFK_WAV=/assets/jfk.wav bash tests/unit/run.sh'`)
Expected: `2 unit test program(s), 0 failed`.
- [ ] **Step 6: Mutation**: flip the strict `>` in the candidate loop to `>=` and run; `test_viterbi_jfk_exact` must fail. Change `0.05f` to `0` in the star-column log and `test_star_column` must fail. Revert both.
- [ ] **Step 7: Commit**

```bash
git add scripts/includes/nm_lyricsalign_align.h tests/unit/test_nm_lyricsalign_align.c tests/unit/fixtures/jfk tests/unit/run.sh
git commit -m "feat(lyricsalign): CTC star Viterbi, agreement verdict and onset walk-back, pinned to the JFK fixture"
```

---

### Task 5: `nm_lyricsalign_phones.h`: espeak IPA parsing and the vocabulary mapping chain

**Files:**
- Create: `scripts/includes/nm_lyricsalign_phones.h`, `scripts/includes/nm_lyricsalign_unicode.inc` (generated: decomposition table for U+00C0–U+024F and U+1E00–U+1EFF → base code points, from Python's `unicodedata`; plus the Mn and Cf ranges as `{lo, hi}` pairs)
- Create: `tools/lyricsalign-lab/make_unicode_inc.py`, `tools/lyricsalign-lab/make_phone_fixture.py`
- Create: `tests/unit/test_nm_lyricsalign_phones.c`, `tests/unit/fixtures/lyricsalign-vocab.txt` (392 lines, id order, from `vocab.json`), `tests/unit/fixtures/lyricsalign-phones.tsv` (`phone<TAB>expected_id_or_-1`, about 600 rows), `tests/unit/fixtures/jfk/jfk-ipa.txt` (the raw CLI output `espeak-ng -q --ipa --sep=_ -v en-us` for the JFK sentence)

**Interfaces** (prefix `nm_lp_`, `NM_LP_MALLOC/FREE`):

```c
typedef struct { char **phones; int n; } NMLpWord;
static inline int  nm_lp_parse_ipa(const char *ipa, NMLpWord **words, int *n_words);
       /* strips (xx) and (xx-yy) markers, splits on ASCII whitespace, each word on '_', drops U+02C8 and U+02CC, drops empty phones and empty words; 0 ok, -1 alloc */
static inline void nm_lp_free_words(NMLpWord *w, int n);
static inline int  nm_lp_map_phone(const char *phone, const char *const *vocab, int n_vocab);
       /* -1 on a miss; candidates in order: phone; nearest-neighbour table; NFD with Mn/Cf dropped; that without U+02D0; first code point */
static inline int  nm_lp_strip_marks(const char *phone, char *out, size_t cap); /* candidate 3 */
```

The nearest-neighbour table, verbatim: `ʏ→ʊ ɒ→ɔ ɵ→ø ʉ→u ɨ→ɪ ɫ→l ɱ→m ʌʊ→aʊ œy→ɔø`.

- [ ] **Step 1: Generate the fixtures.** `make_phone_fixture.py` runs the installed espeak-ng (`C:/Program Files/eSpeak NG/espeak-ng.exe`, 1.52.0) with `--ipa --sep=_` over a short built-in corpus per voice (`en-us`, `en-gb`, `nl`, `de`, `fr`, `es`, `it`, `pt`, `ja`, `ru`, `pl`, `sv`: five sentences each, written in the script), parses it with the prototype's rules (reimplemented in the script, 20 lines, including `unicodedata.normalize("NFD")`), maps every distinct phone with the prototype's `_candidates` chain against `vocab.json`, and writes the TSV plus the hand cases: the nine table entries, `ɛ̃`, `ãː`, `ʰ`, `ˈ` alone (→ dropped before mapping, so not in the TSV), `ɔːɹ`, `oʊ`, a phone of only combining marks (→ −1). `make_unicode_inc.py` writes the `.inc`. Both committed with their outputs.
- [ ] **Step 2: Write the failing tests**:
  - `test_parse_jfk_ipa`: `jfk-ipa.txt` parses to exactly the 22 words / 69 phones of `JFK_WORD_PHONES` with the same strings (the fixture header from Task 4 gains `JFK_PHONE_STRINGS[69]`).
  - `test_parse_strips_language_switch`: `"(nl)hˈɛloʊ_wɜːld (en-us)x"` → words `{hɛloʊ, wɜːld}`, `{x}`.
  - `test_parse_drops_empty`: `"_ˈ_ a__b  "` → one word `{a, b}`.
  - `test_map_fixture_rows`: every row of the TSV maps to its id (the vocab read from `lyricsalign-vocab.txt`).
  - `test_map_chain_order`: `ʌʊ` → id of `aʊ` (table before NFD, since NFD would give `ʌʊ` unchanged and then `ʌ`); `ɛ̃` → id of `ɛ`; `ãː` → id of `a`; `ʰ` → −1.
- [ ] **Step 3: Run to verify they fail** (`bash tests/unit/run.sh` → does not compile).
- [ ] **Step 4: Implement the header** (about 250 lines plus the generated `.inc`). UTF-8 decode/encode helpers live here (`nm_lp_utf8_decode`, `nm_lp_utf8_encode`).
- [ ] **Step 5: Run to verify they pass**: `3 unit test program(s), 0 failed`.
- [ ] **Step 6: Mutation**: remove the `ʌʊ` table row → `test_map_chain_order` and at least one TSV row fail; swap candidate 2 and 3 → `test_map_chain_order` fails. Revert.
- [ ] **Step 7: Commit**

```bash
git add scripts/includes/nm_lyricsalign_phones.h scripts/includes/nm_lyricsalign_unicode.inc tools/lyricsalign-lab/make_unicode_inc.py tools/lyricsalign-lab/make_phone_fixture.py tests/unit/test_nm_lyricsalign_phones.c tests/unit/fixtures/lyricsalign-vocab.txt tests/unit/fixtures/lyricsalign-phones.tsv tests/unit/fixtures/jfk/jfk-ipa.txt tests/unit/fixtures/jfk/jfk_fixture.h tests/unit/fixtures/jfk/make_fixture_h.py
git commit -m "feat(lyricsalign): espeak IPA parsing and the five-step phone-to-vocabulary mapping, pinned to a 12-voice corpus"
```

---

### Task 6: Share the ggml thread rule, `nm_ggml_threads.h`

**Files:**
- Create: `scripts/includes/nm_ggml_threads.h`
- Modify: `scripts/includes/af_whisper.c` (lines 200-331: delete `nm_whisper_physical_cores` and `nm_whisper_threads`, include the header, call `nm_ggml_physical_cores()` / `nm_ggml_filter_threads(ctx)`)
- Modify: `scripts/48-whisper.sh` (copy the header next to af_whisper.c, the way `nm_whisper_words.h` is copied)

**Interfaces:**
```c
static inline int nm_ggml_physical_cores(void);           /* moved body, av_malloc -> NM_GT_MALLOC macro */
static inline int nm_ggml_filter_threads(AVFilterContext *ctx); /* the #115 rule, unchanged */
```
The header includes `libavfilter/avfilter.h`, `libavutil/cpu.h` and `libavfilter/filters.h` (for `ff_filter_get_nb_threads`); it is FFmpeg-only, not for `tests/unit`.

- [ ] **Step 1: Move the two functions**, nothing else changes in af_whisper.c.
- [ ] **Step 2: Build in the lab** (`run.sh build`) and run the whisper thread test through it: `tools/lyricsalign-lab/run.sh shell -c 'FFMPEG=/build/ffmpeg/ffmpeg WHISPER_TEST_MODEL=/assets/ggml-base.en.bin WHISPER_TEST_AUDIO=/assets/jfk.wav bash -c "source tests/lib/whisper.sh; test_whisper_default_threads"'` (fetch `ggml-base.en.bin` into the assets dir by the digest main.yml pins).

Expected: exit 0 and the log line `whisper: N ggml threads` with N = half the container's physical cores.
- [ ] **Step 3: Commit**

```bash
git add scripts/includes/nm_ggml_threads.h scripts/includes/af_whisper.c scripts/48-whisper.sh
git commit -m "refactor(whisper): move the ggml thread rule into nm_ggml_threads.h for the next ggml filter"
```

---

### Task 7: `nm_lyricsalign_w2v2.h`: the model on ggml, gate (a)

**Files:**
- Create: `scripts/includes/nm_lyricsalign_w2v2.h`
- Create: `tools/lyricsalign-lab/emit.c` (standalone: loads the GGUF on the CPU backend, reads a 16-bit mono 16 kHz WAV, writes the emissions as raw f32 and prints `frames`), `tools/lyricsalign-lab/gate_a.py` (compares a raw f32 `T×392` file with `jfk-logprobs-f16.npy`: argmax agreement and mean |Δ|)

**Interfaces** (prefix `nm_w2v2_`, memory `NM_W2V2_MALLOC/FREE`; ggml headers `ggml.h`, `ggml-backend.h`, `ggml-cpu.h`, `gguf.h`):

```c
typedef struct NMW2V2 NMW2V2;   /* gguf ctx, weights ctx + buffer, hyperparameters, vocab pointers, backend(s), sched */
static inline int  nm_w2v2_load(const char *path, ggml_backend_t device /* NULL = none */, ggml_backend_t cpu,
                                NMW2V2 **out, char *err, size_t err_len);   /* 0 ok, -1 with err text */
static inline void nm_w2v2_free(NMW2V2 *m);
static inline int  nm_w2v2_vocab_n(const NMW2V2 *m);
static inline const char *nm_w2v2_vocab(const NMW2V2 *m, int id);
static inline int  nm_w2v2_blank(const NMW2V2 *m);
static inline const char *nm_w2v2_name(const NMW2V2 *m);                     /* general.name */
static inline int  nm_w2v2_frames_for(int samples);                          /* n < 400 ? 0 : (n - 400) / 320 + 1 */
static inline int  nm_w2v2_logits(NMW2V2 *m, const float *samples, int n, float *logits); /* one window, already normalised; logits frames x vocab, row per frame */
static inline int  nm_w2v2_emissions(NMW2V2 *m, const float *samples, int n, float **logp, int *frames);
       /* the spec's windowing: pad 16000 zeros each side, cores of 320000, keep frames [50, 50 + core/320), a core under 16000 samples padded to 16000; normalise each window (mean, var, floor 1e-7); log-softmax via nm_la_log_softmax; *frames = n / 320 */
```

Graph, with x as `[C, T]` (ne[0] = channels) unless stated: conv stack: `ggml_conv_1d(w_i, x_LC, stride_i, 0, 1)` on `x_LC = [L, C]`, then `ggml_cont(ggml_transpose())` to `[C, L]`, `ggml_norm(eps 1e-5)`, `ggml_mul`/`ggml_add` with the LN affine, `ggml_gelu_erf`, back to `[L, C]` for the next conv. Projection: `ggml_norm` + affine on `[512, T]`, `ggml_mul_mat(proj_w, x)` + bias. Positional conv: 16 views of 64 output channels of `pos.weight` and 64 input channels of `x_LC` (`ggml_view_2d`, rows are contiguous), `ggml_conv_1d(w_g, x_g, 1, 64, 1)` → `[T+1, 64]`, `ggml_view_2d` dropping the last time step, `ggml_concat` over dim 1 → `[T, 1024]`, transpose, `ggml_gelu_erf`, add to x. Each layer (pre-LN): `h = ln1(x)`; `q,k,v = mul_mat + bias`, reshaped `[64, 16, T]`, permuted to `[64, T, 16]`; `kq = mul_mat(k, q)`; `ggml_soft_max_ext(kq, NULL, 0.125f, 0.0f)`; `v` permuted to `[T, 64, 16]` (cont); `kqv = mul_mat(v, kq)` → `[64, T, 16]`, permute to `[64, 16, T]`, cont, reshape `[1024, T]`; `x = x + o(kqv)`; `x = x + ffn_out(gelu_erf(ffn_in(ln2(x))))`. After layer 23: `ln(x)`, `logits = head(x)` → `[392, T]`; `ggml_backend_tensor_get` and transpose into the caller's rows. Compute through `ggml_backend_sched` over `{device, cpu}` (CPU alone when `device == NULL`), a graph per window, `ggml_backend_sched_reset` before each. Weights: `gguf_init_from_file(no_alloc = true)`, `ggml_backend_alloc_ctx_tensors(ctx, device ? device : cpu)`, each tensor read from the file at `gguf_get_data_offset + gguf_get_tensor_offset` through `ggml_fopen` into a bounce buffer and `ggml_backend_tensor_set`. Threads: `ggml_backend_cpu_set_n_threads(cpu, threads)` is the caller's business.

- [ ] **Step 1: Write `emit.c` and `gate_a.py`** (they are the test of this task; no ffmpeg involved). `emit.c` takes `<gguf> <wav> <out.f32> [threads]`, uses `nm_ggml_backend_init(0, 0)` from the lab's dispatch archive for the CPU backend.
- [ ] **Step 2: Run emit on jfk.wav before the header exists**

Run: `tools/lyricsalign-lab/run.sh shell -c 'gcc -O2 -I scripts/includes -I /opt/nm/include tools/lyricsalign-lab/emit.c -L/opt/nm/lib $(pkg-config --libs whisper) -lstdc++ -lm -lpthread -o /tmp/emit'`
Expected: fails to compile (`nm_lyricsalign_w2v2.h: No such file`).
- [ ] **Step 3: Implement the header** (about 500 lines). Metadata is read from the GGUF (`lyricsalign.*`), nothing hard-coded except the tensor name patterns.
- [ ] **Step 4: Gate (a)**

Run: compile as in Step 2, then `/tmp/emit /assets/wav2vec2-xlsr-53-espeak-cv-ft-f16.gguf /assets/jfk.wav /tmp/jfk.f32 && python3 -I tools/lyricsalign-lab/gate_a.py /tmp/jfk.f32 tests/unit/fixtures/jfk/jfk-logprobs-f16.npy`
Expected: `frames 550`, `argmax agreement >= 99.0 %`, `mean |delta| < 0.05 nats`, exit 0. Record both numbers in `tools/lyricsalign-lab/README.md`. If the mean difference is above 0.05, the first suspects in order: tanh GELU used somewhere, the positional conv's dropped sample, the LayerNorm axis, f16 im2col in the first conv (then store `enc.conv.0.weight` as F32 in the converter and let the loader take the type from the file).
- [ ] **Step 5: Short inputs (Review Focus 3)**: `nm_w2v2_emissions` on 0 samples → `frames 0`, non-NULL pointer or NULL with `frames 0` (pin: `*logp = NULL, *frames = 0, return 0`); on 300 samples → `frames 0`; on 8000 samples → `frames 25`; add these three as `emit.c --self-test` and run it.

Expected: `self-test ok`.
- [ ] **Step 6: Determinism and time**: run emit twice on jfk at 4 threads; `cmp` the two `.f32` files (identical); note the wall time in the README.
- [ ] **Step 7: Commit**

```bash
git add scripts/includes/nm_lyricsalign_w2v2.h tools/lyricsalign-lab/emit.c tools/lyricsalign-lab/gate_a.py tools/lyricsalign-lab/README.md
git commit -m "feat(lyricsalign): wav2vec2-xlsr-53 phoneme CTC model on ggml, emissions within the fixture gate"
```

---

### Task 8: `af_lyricsalign.c` part 1: options, inputs, espeak, model load, output plumbing

**Files:**
- Create: `scripts/includes/af_lyricsalign.c`
- Create: `scripts/66-lyricsalign.sh` (the registration step: copies `af_lyricsalign.c`, `nm_lyricsalign_align.h`, `nm_lyricsalign_phones.h`, `nm_lyricsalign_unicode.inc`, `nm_lyricsalign_w2v2.h`, `nm_ggml_threads.h` into `libavfilter/`; `extern const FFFilter ff_af_lyricsalign;` after `ff_af_volumedetect`; `OBJS-$(CONFIG_LYRICSALIGN_FILTER) += af_lyricsalign.o` after `ABENCH`; `lyricsalign_filter_deps="whisper swresample"` after `whisper_filter_deps=`; the Step-4 throwaway configure of `61-trailing-silence.sh` asserting `Disabled lyricsalign_filter` is absent)

**Interfaces:**
- `LyricsAlignContext`: the nine options; `SwrContext *swr[2]`; `float *pcm[2]` + `int n[2]` (16 kHz mono); `int eof[2]`; `NMW2V2 *model`; `ggml_backend_t device, cpu`; `int gpu_active, threads_used`; lines: `char **text; int n_lines;` `NMLpWord **words; int *n_words;` `int **ids; int *n_ids;` (per line, mapped phone ids, word boundaries kept); `int mapping_misses`; `AVIOContext *out`.
- Filter pads: inputs `vocals` (`config_props = config_vocals`: loads the model once, like whisper's `config_input`, so ffmpeg's double graph init does not load it twice) and `backing`; output `default` with `config_props = config_output` copying input 0's rate, format and layout.
- `query_formats`: planar or packed float/s16/s32 at any rate and layout on both inputs is accepted; the filter converts with swresample. Simplest correct choice: let both inputs be `AV_SAMPLE_FMT_FLTP` at any rate/layout (`ff_set_common_formats_from_list`), and set the output to input 0's rate and layout; swr then only downmixes and resamples.
- `activate`: `FF_FILTER_FORWARD_STATUS_BACK_ALL`; consume frames from input 0 (append the resampled copy, set the three metadata keys, forward the frame), from input 1 (append, free; drop when `eof[0]`); when `eof[0] && (eof[1] || pcm[1] cannot grow)`, run `align_and_write()` once, then `ff_outlink_set_status(outlink, AVERROR_EOF, pts)`. Request frames on whichever input is not at EOF (input 1 only while `!eof[0]`).
- `init`: reads `text_file` through avio (BOM dropped, `\r\n` and `\r` normalised, trailing whitespace per line dropped; every line kept, blank ones included; a file with no non-blank line fails with `AVERROR(EINVAL)` "text_file has no lyric line"), checks `espeak_data` (default `<exe dir>/espeak-ng-data` via `nm_la_exe_dir()`: `/proc/self/exe`, `KERN_PROC_PATHNAME`, `_NSGetExecutablePath`, `GetModuleFileNameW`), stats `phontab`, initialises espeak under a static `AVMutex` with a refcount, `espeak_SetVoiceByName(language)` failing with `"lyricsalign: espeak-ng has no voice named '%s'"`, phonemizes every line (clauses joined by a space, `nm_lp_parse_ipa`), opens `destination` (`-` → `pipe:1`).
- Phone mapping needs the vocabulary, which is in the model: it happens in `config_vocals` right after the load; `mapping_misses` counted there.
- `config_vocals` device order, copied from whisper's `config_input`: `nm_ggml_gpu_usable()` is called first and unconditionally (never behind `use_gpu &&`), then `ff_thread_once(ggml_backend_load_all)`, then `nm_ggml_backend_notice()` logged once, then `device = use_gpu ? nm_ggml_backend_init(1, gpu_device) : NULL` (a `gpu_device >= nm_ggml_gpu_count()` logs the stemsplit-style "running on the CPU" line), `cpu = nm_ggml_backend_init(0, 0)`. Threads: `threads` option `0` → `nm_ggml_filter_threads(ctx)`, otherwise `FFMIN(threads, av_cpu_count())`; set with `ggml_backend_cpu_set_n_threads(cpu, n)` and logged once as `lyricsalign: N ggml threads.`; the count never changes the output.
- JSON writer: `write_header()`, `write_line(index, ...)`; all through `nm_json_escape`; numbers with `%.3f`; `null` literal for absent times.

- [ ] **Step 1: Write the filter skeleton** with `align_and_write()` writing the header (`written:0`, `check` per the blend/zero rule) and one line per text line with reason `no_alignment` (the real alignment comes in Task 9). Write `66-lyricsalign.sh`.
- [ ] **Step 2: Build in the lab** (`run.sh build`).

Expected: `ffmpeg -h filter=lyricsalign` prints the nine options in the spec's order with the spec's defaults and `Inputs: #0: vocals (audio) #1: backing (audio)`.
- [ ] **Step 3: Init failures** (each a one-line ffmpeg run in the lab shell, cwd `/assets`, relative paths):
  - missing model file → exit 1, message names the path;
  - `text_file=empty.txt` (0 bytes) and `text_file=blank.txt` (`"\n \n"`) → exit 1, "no lyric line";
  - `language=xx-nope` → exit 1, message contains `xx-nope`;
  - `espeak_data=/nowhere` → exit 1, message contains `/nowhere/phontab`;
  - all four present → exit 0 and a header line plus N `no_alignment` lines on stdout with `destination=-`.
- [ ] **Step 4: Pass-through**: `ffmpeg -i jfk.wav -filter_complex "[0:a]asplit[v][b];[v][b]lyricsalign=...:destination=out.jsonl" -f wav passthrough.wav` and `ffmpeg -i jfk.wav -f wav plain.wav`; `cmp` the two WAVs (identical: the output is input 0 unchanged). Also `-f null -` with `anullsrc` as backing (no `duration`) must end (Review Focus 4): `timeout 120 ffmpeg -i jfk.wav -filter_complex "anullsrc=r=16000:cl=mono[b];[0:a][b]lyricsalign=..." -f null -` exits 0.
- [ ] **Step 5: Commit**

```bash
git add scripts/includes/af_lyricsalign.c scripts/66-lyricsalign.sh
git commit -m "feat(lyricsalign): filter skeleton with two inputs, espeak-ng phonemes, model load and JSON Lines output"
```

---

### Task 9: `af_lyricsalign.c` part 2: the alignment, gate (c), the behaviours

**Files:**
- Modify: `scripts/includes/af_lyricsalign.c` (`align_and_write()` becomes real)

**Interfaces:**
- `align_and_write()`: emissions on vocals (`nm_w2v2_emissions`), star column, token sequence `[star] (phones [star])*`, `nm_la_viterbi` → per-line `NMLaPlace` slices (no path at all → header `written:0`, every line `no_alignment`); check signal `vocals + blend × backing` over `min(n[0], n[1])` samples (skipped per call 5), its own Viterbi (no path → header `check:"failed"`, every placed line `check_failed`); `nm_la_verdict` per line; envelope of vocals; walk-back when `nm_la_pause_before(start, prev_end)` where `prev_end` is the previous placed line's last phone `first` frame (call 1); JSON per spec: `start` written (walk-back or spike), `end` = last phone `last + 1` frames × 0.02, `score` = mean posterior, `lead_in`, `words` with each word's phones' first/last+1 and mean posterior (a word with no mapped phones: `start:null, end:null, score:0`); skipped lines carry `vocals_start`, `check_start` (null where the check had no placement or the line had none).
- Metadata on every forwarded frame: `lavfi.lyricsalign.backend` (`cpu`, or the device name from `nm_ggml_backend_name`), `lavfi.lyricsalign.cpu_variant`, `lavfi.lyricsalign.version` (`#define LA_VERSION "1.0.0"`).
- `NOMERCY_LYRICSALIGN_EMISSIONS=<path>`: when set, the vocals' `T×392` log-probs are written there as raw little-endian f32 before the star column.

- [ ] **Step 1: Write `tests/lib/lyricsalign.sh` first** (the test library of Task 11, but its gate functions are what this task is verified by): `_lyricsalign_inputs` (LYRICSALIGN_ASSETS_DIR or `lyricsalign-assets/` next to the binary: `wav2vec2-xlsr-53-espeak-cv-ft-f16.gguf`, `jfk.wav`, `jfk.txt` (the sentence, one line), `jfk-alignment.json`; python3 with numpy; SKIP otherwise), `_lyricsalign_run <out> <err> <text> <backing-filter> <opts>` (cwd = assets dir, `use_gpu=0`, `-filter_threads 1`, `-nostdin`), and these functions with run_custom_test's protocol:
  - `test_lyricsalign_shape`: header first, exactly one line per text line, every line valid JSON, `start <= word.start <= word.end <= end`, word starts non-decreasing, `index` 0..N−1 in order.
  - `test_lyricsalign_jfk_gate_c`: anullsrc backing, every word's `start` within 0.040 of `words[].start` in the fixture; the line's `start` equals `start_written` ± 0.02; `lead_in` equals the fixture's ± 0.02.
  - `test_lyricsalign_gate_a`: `NOMERCY_LYRICSALIGN_EMISSIONS` set; the python check of Task 7 (`gate_a.py` logic inlined: argmax ≥ 99 %, mean |Δ| < 0.05).
  - `test_lyricsalign_deterministic`: two runs byte-identical.
  - `test_lyricsalign_init_failures`: the four failures of Task 8 Step 3, message content asserted.
  - `test_lyricsalign_destination_pipe`: `destination=-` and `destination=pipe\\:1` give the same bytes; `destination=` (empty) prints nothing on stdout and the lines appear in stderr at `-loglevel info`.
  - `test_lyricsalign_empty_line`: text `"<sentence>\n\n<sentence>"` → three lines, line 1 has `reason:"empty"`, `start:null`, `words:[]`, lines 0 and 2 placed.
  - `test_lyricsalign_blend_zero`: `blend=0` with `asplit` backing (the vocals themselves) writes every line and the header says `check:"none"`; `blend=0.5` with the same backing says `check:"backing"` and still writes every line (identical signals agree).
  - `test_lyricsalign_no_alignment`: text = the sentence repeated 40 times on a 2 s `atrim` of jfk → header `written:0`, every line `reason:"no_alignment"`, exit 0 (Review Focus 2).
  - `test_lyricsalign_text_forms`: the sentence as CRLF with a BOM and a trailing space → same word starts as the plain file; a whitespace-only middle line is `empty` (Review Focus 1).
  - `test_lyricsalign_odd_lines`: text lines `...`, `🎵🎵`, and `caf\xff\xe9` → all three lines valid JSON, the first two `reason:"no_phones"`, the third either placed or `no_phones`, never a crash (Review Focus 5).
  - `test_lyricsalign_backing_lengths`: backing = jfk trimmed to 9 s, backing = jfk padded to 15 s (`apad`), both exit 0 with the header `check:"backing"` (Review Focus 4).
  - `test_lyricsalign_short_audio`: 0.5 s of jfk → exit 0, `written:0` or lines placed, never a crash (Review Focus 3).
  - `test_lyricsalign_metadata`: `ametadata=print` after the filter shows the three keys on the first frame; `lavfi.lyricsalign.backend=cpu`.
  - `test_lyricsalign_gpu`: only when `LYRICSALIGN_TEST_GPU=1`: `use_gpu=1` word starts within 0.040 of the CPU run's; otherwise SKIP.
- [ ] **Step 2: Run the library against the Task 8 build**: `tools/lyricsalign-lab/run.sh suite`.

Expected: `test_lyricsalign_init_failures`, `test_lyricsalign_no_alignment` pass (the skeleton writes `no_alignment`); `shape`, `gate_c`, `gate_a`, `empty_line`, `blend_zero`, `text_forms`, `metadata` fail. Any of those passing now is a check that lies: fix the check before going on.
- [ ] **Step 3: Implement `align_and_write()`**.
- [ ] **Step 4: Run the suite**: all functions pass, `gpu` SKIPs.
- [ ] **Step 5: Mutation**, three one-line breaks, each watched failing then reverted: the walk-back returns the spike → `gate_c` fails on `start_written`; `end` written from `first` instead of `last + 1` → `shape` fails on `word.end`; the `empty` reason spelled `blank` → `empty_line` fails.
- [ ] **Step 5b: `check:"failed"`**: force the check Viterbi to return 0 (one-line mutation) → every placed line is `check_failed` with `vocals_start` set and `check_start` null, header `check:"failed"`, exit 0. Revert.
- [ ] **Step 6: Measure**: the wall time of `test_lyricsalign_jfk_gate_c` at 1 thread and at the default thread count in the lab; write both into the lab README.
- [ ] **Step 7: Commit**

```bash
git add scripts/includes/af_lyricsalign.c tests/lib/lyricsalign.sh
git commit -m "feat(lyricsalign): place the text with the star Viterbi, the agreement check and the onset walk-back; JFK gates a, b, c pass"
```

---

### Task 10: Test suite wiring: bash, PowerShell, assets, smoke, CI

**Files:**
- Create: `tests/lib/lyricsalign-assets.sh` (`<dir>`: fetches the GGUF by digest from the models release (URL and digest placeholders until Task 12; until then it prints `SKIP`-shaped failure when the URL is unset), `jfk.wav` by digest, writes `jfk.txt` and copies `tests/unit/fixtures/jfk/jfk-alignment.json`; prints `LYRICSALIGN_ASSETS_DIR=<dir>` like `stemsplit-assets.sh`)
- Create: `tests/lib/lyricsalign.ps1` (delegates every function to `lyricsalign.sh` through Git Bash exactly as `stemsplit.ps1` does; CRLF on disk like its siblings)
- Modify: `tests/tests.sh`, `tests/tests.ps1` (one `run_test "lyricsalign" "-hide_banner -filters | grep lyricsalign" "lyricsalign"` plus `run_custom_test` per function), `tests/smoke.sh`, `tests/smoke.ps1` (after "Unpack": `espeak-ng-data/phontab`, `en_dict`, `nl_dict`, `lang/` present in the unpacked tarball on every platform, cross-exec ones included, `LYRICSALIGN_TEST_REQUIRED=1` turns a SKIP into a failure like the whisper checks; the model gates run where `LYRICSALIGN_ASSETS_DIR` is set)
- Modify: `.github/workflows/main.yml` (a "Fetch lyricsalign test assets (Linux x64 variants)" step next to the whisper one, setting `LYRICSALIGN_ASSETS_DIR` and `LYRICSALIGN_TEST_REQUIRED=1`; the unit-tests job needs nothing new; `tests/unit/run.sh` needs `-lm`, already done in Task 4)

- [ ] **Step 1: Write the assets fetcher and the PowerShell twin.**
- [ ] **Step 2: Wire tests.sh / tests.ps1 / smoke.sh / smoke.ps1 / main.yml.**
- [ ] **Step 3: Run the manual suite without assets** in the lab: `FFMPEG=... bash tests/tests.sh --platform linux-x86_64` style invocation the file documents.

Expected: `LYRICSALIGN` passes (the `-filters` line), every `lyricsalign_*` custom test SKIPs with the asset instruction, 0 failed.
- [ ] **Step 4: Run smoke.sh in the lab against a fake tarball layout** (binary + `espeak-ng-data` dir): the data check passes; remove `nl_dict` → it fails with the file name. Restore.
- [ ] **Step 5: Windows PowerShell 5.1 twin**: on this machine, with the Windows build from Task 13 not yet there, run `tests/lib/lyricsalign.ps1`'s `Get-GitBash` path and one function against any `ffmpeg.exe` (e.g. the v1.0.45 release binary): it must return `Skip` with the "no lyricsalign in this build" reason, not throw. (Full pass is Task 13.)
- [ ] **Step 6: Commit**

```bash
git add tests/lib/lyricsalign-assets.sh tests/lib/lyricsalign.ps1 tests/tests.sh tests/tests.ps1 tests/smoke.sh tests/smoke.ps1 .github/workflows/main.yml
git commit -m "test(lyricsalign): real-model gates in the suites and the Linux smoke job; espeak-ng data checked in every tarball"
```

---

### Task 11: README

**Files:**
- Modify: `README.md`: feature-table row (`**lyricsalign**` | Audio filter | one line), a `#### 🎤 lyricsalign — time-synced lyrics by forced alignment` section after the `trailingsilence` one: what it does and does not do (never invents a time), the two inputs and the `anullsrc` form, the nine options table (copied from the spec), the JSON shape (header, a written line, a skipped line), the seven reasons, the model download line (models repo URL from Task 12), the espeak-ng data location and the `espeak_data` option, the measured speed line (from Task 13 on this machine: track length, CPU, threads, seconds), the GPL note (`espeak-ng` row already added in Task 3), and the test commands (`tests/lib/lyricsalign-assets.sh`, `LYRICSALIGN_ASSETS_DIR`).

- [ ] **Step 1: Write it.** Keep the measured numbers as placeholders `(measured in Task 13)` until they exist; Task 13 fills them.
- [ ] **Step 2: Commit** `docs(readme): lyricsalign filter, options, JSON shape, skip reasons`.

---

### Task 12: The models repo and release (owner gate)

- [ ] **Step 1: Ask the owner with AskUserQuestion**: create public `NoMercy-Entertainment/nomercy-lyricsalign-models` now (yes / no, do it yourself / later). Include: the asset name `wav2vec2-xlsr-53-espeak-cv-ft-f16.gguf` (about 630 MB) + `.sha256`, release tag `v2026.11.05` (the `nomercy-stemsplit-models` date pattern), licence Apache-2.0 with the model card, and that the CI gate downloads it on every linux-x86_64 smoke run.
- [ ] **Step 2: On yes**: `gh repo create NoMercy-Entertainment/nomercy-lyricsalign-models --public` with a README (source checkpoint, licence, converter path `tools/wav2vec2-gguf` in nomercy-ffmpeg, the digest), `gh release create v2026.11.05` with both assets; verify the download digest from a fresh `curl`.
- [ ] **Step 3: Pin URL and digest** in `tests/lib/lyricsalign-assets.sh` and the README; run `tests/lib/lyricsalign-assets.sh /tmp/x` once from a clean directory (fetches 630 MB, digest matches).
- [ ] **Step 4: Commit** `test(lyricsalign): pin the model release`.

---

### Task 13: All seven platforms, locally, then the real suites

Per [[feedback-local-build-before-push]]: one platform at a time, commit only on success, no push.

- [ ] **Step 1: linux-x86_64 (cpu)**: `docker compose build ffmpeg-linux-x86_64` with a tag; in the finished image: `ffmpeg -h filter=lyricsalign`, the pin line for espeak-ng, `espeak-ng-data` in the tarball, then `tests/smoke.sh` with `LYRICSALIGN_ASSETS_DIR` set (the gates on the real static binary) in an `ubuntu:22.04` container (the glibc floor), and the full `tests/lib/lyricsalign.sh` in `ubuntu:26.04`.
- [ ] **Step 2: linux-x86_64-hardware**: build; `tests/lib/lyricsalign.sh` in the RTX 3070 lab (`tools/gpu-container`) with `LYRICSALIGN_TEST_GPU=1`: `test_lyricsalign_gpu` passes (every word within 40 ms of the CPU run) or its failure is written down verbatim.
- [ ] **Step 3: windows-x86_64**: build; on this machine run `tests/tests.ps1` (PowerShell 5.1 and pwsh 7) with the assets: every `lyricsalign_*` passes; measure the README speed line here (jfk.wav and a 4-minute stereo track through `asplit`, `threads=0` and `threads=8`, i7 of this machine).
- [ ] **Step 4: linux-aarch64, windows-aarch64, darwin-x86_64, darwin-arm64, freebsd-x86_64**: build each; header/type checks of the binary; tarball contains `espeak-ng-data`; the arm64 Linux binary runs `ffmpeg -h filter=lyricsalign` under the emulation the repo already uses for that check (no model run there; CI's Lima guest and the M4 runner do the executing).
- [ ] **Step 5: Fill the README numbers, commit** `docs(readme): lyricsalign measured speed`.
- [ ] **Step 6: Ask the owner** (AskUserQuestion): push `dev` now? The push triggers nothing by itself; the first CI run of the gates is the next dev → master release PR, where the darwin and Windows smoke jobs execute the gates for the first time.

---

### Task 14: Hand-over to the plugin workspace

- [ ] **Step 1: Write `docs/superpowers/plans/2026-11-05-lyricsalign.md` → "Done" section** with: build tag, measured gates, the eight numbers the benchmark needs, and the exact filter graph the `ffmpeg-lyricsalign` pipeline in `nomercy-lyrics-creator-plugin` must run (`stemsplit=...:stem=all[v][a];[v][a]lyricsalign=model=...:text_file=...:language=...:destination=-`), and that the benchmark (last acceptance box) runs there, on the owner's machine, with the plugin's `python -m lyrics_eval bench`.
- [ ] **Step 2: Save a memory note** for this project: state, lab path, asset dir, the calls made, what the owner still decides.

---

## Done (2026-11-06)

**Build.** Every platform image was built locally from this tree, one at a
time, as `nomercy-ffmpeg-<platform>:lyricsalign` (linux-x86_64 cpu and
hardware, linux-aarch64, windows-x86_64, windows-aarch64, darwin-x86_64,
darwin-arm64, freebsd-x86_64); every archive carries `espeak-ng-data`
(18 MB, 114 dictionaries) next to the binary. Two cross-build facts came out
of it: espeak-ng's header declares its API `dllimport` on Windows unless
`LIBESPEAK_NG_EXPORT` is set (the filter sets it), and the osxcross `nm` has
no `--defined-only` (script 65 reads plain `nm` output).

**Measured gates.** (a) emissions: argmax agreement 100 %, mean |delta|
0.0032 nats against the prototype (bar 0.05), on the lab binary and the
Windows binary; (b) every phone of the JFK fixture on the prototype's frame
(unit test, exact); (c) every JFK word within 0.000 s of the prototype, line
start and lead-in within 0.010 s; determinism: two runs give the same bytes;
`use_gpu=1` on an RTX 3070 (Dozen under Linux, native Vulkan on Windows):
every word within 0.000 s of the CPU run. Suites: lab 15/15, `tests/smoke.sh`
in ubuntu:22.04 with `LYRICSALIGN_TEST_REQUIRED=1`, `tests/tests.ps1` under
pwsh 7 and Windows PowerShell 5.1 (46 passed, lyricsalign 14 pass + gpu
skipped by design).

**The eight numbers for the benchmark** (CPU, `use_gpu=0`, model load
included; a run with a backing makes two model passes):

| clip | where | threads | wall clock |
|---|---|---|---|
| jfk 11 s, one pass | lab (haswell, Docker) | 1 | 29.9 s |
| jfk 11 s, one pass | lab | 4 | 12.4 s |
| jfk 11 s, two passes | lab | 4 | 22.6 s |
| jfk 11 s, two passes (`asplit`) | i7-10700K, Windows build | 0 (= 4) | 15.3 s |
| jfk 11 s, two passes | i7-10700K | 8 | 9.2 s |
| 253 s stereo (jfk x22), two passes | i7-10700K | 0 (= 4) | 304 s (1.2x length) |
| 253 s stereo, two passes | i7-10700K | 8 | 194 s (0.77x length) |
| model file | — | — | 632 378 944 B, f16, sha256 b1474de6…38b4 |

**The pipeline `ffmpeg-lyricsalign` in `nomercy-lyrics-creator-plugin` must run:**

```
ffmpeg -nostdin -hide_banner -i song.flac -filter_complex \
  "[0:a]stemsplit=preset=full:model_dir=<models>:stem=all[v][a];\
   [v][a]lyricsalign=model=<models>/wav2vec2-xlsr-53-espeak-cv-ft-f16.gguf:text_file=lyrics.txt:language=en-us:destination=-" \
  -f null - > lines.jsonl
```

`stem=all` yields the vocals pad first, then the accompaniment; the
accompaniment is the backing the check signal needs (`blend` default). The
JSON Lines arrive on stdout (`destination=-`), one header then one line per
written text line; skipped lines carry their reason. `espeak-ng-data` is
found next to the binary, so `espeak_data` is only needed when the binary is
moved without it. A Windows path with a drive colon inside the graph must be
quoted the FFmpeg way (`model='C\:/models/...gguf'`), or the plugin runs
from the models directory with relative names. The model comes from
`NoMercy-Entertainment/nomercy-lyricsalign-models` release `v2026.11.05`.

**The benchmark** (the last acceptance box of the spec) runs in the plugin
repository on the owner's machine: `python -m lyrics_eval bench`. It is not
part of this repository's gates.
