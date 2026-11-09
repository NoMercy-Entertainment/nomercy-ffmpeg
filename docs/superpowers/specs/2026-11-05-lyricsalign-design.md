# lyricsalign: CTC forced-alignment audio filter — design

> Spec for `docs/superpowers/plans/2026-11-05-lyricsalign.md`. This is the text of
> https://github.com/NoMercy-Entertainment/nomercy-ffmpeg/issues/126 as filed by the owner on
> 2026-11-05, copied verbatim so the plan can argue from it. The issue is the source of truth;
> the plan lists every point where it reads the spec differently, under "Calls the plan makes".

## Why

The Lyrics Creator plugin gives music tracks time-synced lyrics by aligning **known, correct lyric text** to the track's vocal stem. Its primary timing method is CTC forced alignment with a multilingual phoneme model; whisper (#112) is only the second opinion. A Python prototype of that method has now passed its feasibility gate on the hand-verified reference set, so the method moves into ffmpeg as a new audio filter, `lyricsalign`, built the way `whisper` and `stemsplit` are: ggml, a GGUF model from a public models repo, no new runtime dependency except a statically linked espeak-ng.

Measured 2026-11-05 with the prototype, 8 reference tracks (5 English, 3 Dutch), 396 verified lines, CTC on the vocal stem from `stemsplit`:

| | whisper DTW on the stem (#112) | prototype `ctc-align-checked` |
|---|---|---|
| lines within 0.2 s of the verified start | 41.7 % | **97.7 %** (98.8 % within 0.3 s) |
| worst written line | seconds | **0.65 s** |
| tracks with no line worse than 1 s | — | **8 / 8** |
| lines written (the rest are skipped for review, never guessed) | all | 342 / 396 |

Each number below (window sizes, penalties, thresholds) was measured on that set, round by round. They are the method, not tuning suggestions: a port that reproduces them reproduces the result.

The filter does **two things the whisper filter does not**: it takes the text as input and only places it, and it refuses to write a line it is not sure of. It never invents a time.

## Filter

`lyricsalign`, audio filter, `libavfilter/af_lyricsalign.c`. Two audio inputs, one audio output:

- input 0 `vocals`: the vocal stem (`stemsplit=...:stem=vocals`);
- input 1 `backing`: the accompaniment stem. The filter aligns a second time on `vocals + blend × backing` and writes a line only when both alignments agree (details under *Processing*). For a clip without a stem split, feed `anullsrc`: with silence as backing both alignments are identical and every line passes the agreement check.
- output: input 0, unchanged (pass-through, like `whisper`), so `-f null -` works and so does chaining.

It is an **offline filter**: it buffers both inputs to EOF, then aligns once over the whole track. Memory for a 5-minute track: two 16 kHz mono float buffers (about 40 MB) plus the model.

```bash
ffmpeg -i song.flac -filter_complex \
  "[0:a]stemsplit=model=spleeter-2stems-f16.gguf:stem=all[v][a];[v][a]lyricsalign=model=lyricsalign.gguf:text_file=lyrics.txt:language=en-us:destination=-" \
  -f null - > lyrics.jsonl
```

| Option | Type | Default | Effect |
|---|---|---|---|
| `model` | string | *required* | Path to the GGUF model. |
| `text_file` | string | *required* | UTF-8 lyric text, one lyric line per text line. An empty line is an instrumental marker: it is kept in the output, with `start:null` and reason `empty`. An empty file (no non-blank line) fails init. |
| `language` | string | *required* | espeak-ng voice name (`en-us`, `en-gb`, `nl`, `de`, `fr`, `ja`, ...). An unknown voice fails init with a message naming the voice. Never guessed: the caller handles "unsupported" (ruling R5 of the plugin spec). |
| `espeak_data` | string | `""` | Path to `espeak-ng-data`. Empty: `<dir of the ffmpeg binary>/espeak-ng-data`, the way other data files are found. Missing data fails init with the path. |
| `blend` | float | `0.5` | Share of `backing` mixed into the check signal. `0` disables the check (every line passes agreement; still subject to the other two tests). Measured: the full mix (`1.0`) drifts in loud passages; `0.5` catches the lines the stem glues to an ad-lib. |
| `destination` | string | `""` | Where the JSON Lines go. `-` is stdout (`pipe:1`), as `whisper` does it. Empty: the output is only logged at `AV_LOG_INFO`. |
| `threads` | int | `0` | ggml CPU threads, with `stemsplit`'s rule (physical cores, capped by `-filter_threads` below 16; #67, #115). |
| `use_gpu` | int | `0` | `1` allows the ggml GPU backend (Vulkan, Metal) through `nm_ggml_backend_init`, with the same fallbacks and the same `NOMERCY_GGML_GPU=0` override as `stemsplit`. Off by default because the acceptance numbers were measured on CPU emissions; a GPU run may move a time by a frame (20 ms). |
| `gpu_device` | int | `0` | As on `whisper` and `stemsplit`. |

Frame metadata on the output, for parity with the other two: `lavfi.lyricsalign.backend`, `lavfi.lyricsalign.cpu_variant`, `lavfi.lyricsalign.version`.

## Output: JSON Lines

First line, the header:

```json
{"model":"wav2vec2-xlsr-53-espeak-cv-ft","language":"en-us","lines":42,"written":39,"mapping_misses":0,"check":"backing"}
```

`mapping_misses` is the number of espeak phones that had no entry in the model's vocabulary after the fallback chain (see *Phonemes*). `check` is `backing`, `none` (`blend=0`) or `failed` (the second alignment found no path).

Then one line per lyric line, in text order, times in **seconds** (floats, 3 decimals; the player's wire format is seconds):

```json
{"index":5,"text":"ask not what your country can do for you","start":3.36,"end":7.86,"score":0.74,"lead_in":0.0,"words":[{"text":"ask","start":3.36,"end":4.02,"score":0.87},{"text":"not","start":4.02,"end":5.42,"score":0.81}]}
```

A line that is not written:

```json
{"index":6,"text":"...","start":null,"end":null,"score":0,"reason":"disagree","vocals_start":12.34,"check_start":14.02,"words":[]}
```

`reason` is one of `empty` (no text), `no_phones` (nothing mapped), `disagree`, `first_gap`, `stray_prefix`, `check_failed` (all four defined under *Processing*). For a skipped line the two candidate starts are still reported, so a review UI can show them; the plugin never writes them.

If the whole track has no alignment path (the text is longer than the audio can hold, or no voice at all), the filter logs it, writes the header with `"written":0` and every line with reason `no_alignment`, and still exits 0: an empty result is a result. It fails (non-zero) only on bad input: missing model, unknown voice, missing data, unreadable or empty `text_file`.

Every output line must parse as JSON. Use `nm_json_escape` from `scripts/includes/nm_whisper_words.h` (#112), including its invalid-UTF-8 repair; lyric text comes from the internet.

## Model: GGUF, converter, models repo

**Source checkpoint:** [`facebook/wav2vec2-xlsr-53-espeak-cv-ft`](https://huggingface.co/facebook/wav2vec2-xlsr-53-espeak-cv-ft) (Xu, Baevski, Auli 2021, *Simple and Effective Zero-shot Cross-lingual Phoneme Recognition*), **Apache-2.0**. Verified from its `config.json`:

| | |
|---|---|
| architecture | `Wav2Vec2ForCTC`, large: 24 transformer layers, hidden 1024, 16 heads of 64, FFN 4096, pre-LN (`do_stable_layer_norm=true`), final `encoder.layer_norm`, `lm_head` 1024 → 392 |
| feature encoder | 7 × conv1d, 512 channels, kernels `10,3,3,3,3,2,2`, strides `5,2,2,2,2,2,2`, bias, **LayerNorm after every conv** (`feat_extract_norm=layer`), GELU. Total stride 320 samples = **one frame per 20 ms** at 16 kHz; receptive field 400 samples |
| feature projection | LayerNorm(512) → Linear 512 → 1024 |
| positional conv | grouped conv1d, kernel 128, **16 groups** (64 channels each), padding 64, the last output sample dropped (even kernel), weight-normalised in the checkpoint, GELU, added to the hidden states |
| vocab | 392 entries, `<pad>` = id 0 is the **CTC blank**, `<s>` `</s>` `<unk>` then IPA phones (`n`, `s`, `t`, `ə`, ...) |
| input | 16 kHz mono float, **zero mean, unit variance** per window (`(x - mean) / sqrt(var + 1e-7)`) |
| size | 316 M parameters; `pytorch_model.bin` is 1.26 GB f32; **about 630 MB as f16 GGUF** |

**Converter:** `tools/wav2vec2-gguf`, Dockerised like `tools/spleeter-gguf` (torch CPU, `gguf` package, the checkpoint downloaded at image build), with `verify()` built into `convert.py`. It folds weight norm (`g·v/‖v‖`) of the positional conv into a plain weight, stores weights f16 and biases/norms f32, and writes metadata: `lyricsalign.arch = "wav2vec2-ctc"`, `lyricsalign.sample_rate = 16000`, `lyricsalign.hop = 320`, `lyricsalign.blank_id = 0`, `lyricsalign.vocab` (the 392 strings, in id order; the filter reads the vocabulary from the model, not from a sidecar), and the layer counts/sizes above so the graph builder has nothing hard-coded.

**Distribution:** release asset `wav2vec2-xlsr-53-espeak-cv-ft-f16.gguf` plus `.sha256` on a new public org repo **`nomercy-lyricsalign-models`**, the `nomercy-stemsplit-models` pattern. Not in the platform tarballs. The media server downloads it like the other models (follow-up to nomercy-media-server#620, not this issue).

**ggml ops** (ggml 0.15.x inside whisper.cpp v1.9.1, `scripts/48-whisper.sh`): `ggml_conv_1d` (im2col) for the feature encoder; `ggml_norm` + affine for every LayerNorm; the grouped positional conv has no ggml op: run 16 `ggml_conv_1d` on 64-channel views and `ggml_concat`, or a direct loop; attention is `ggml_mul_mat` + `ggml_soft_max_ext`; the checkpoint's GELU is the **erf** GELU (`ggml_gelu_erf`; the tanh `ggml_gelu` shifts emissions and must not be used silently, measure if you have to). Output: `ggml_log_soft_max` over 392 per frame.

## Phonemes: espeak-ng

**Build:** espeak-ng **1.52.0** (2024-12-12, GPL-3.0-or-later) as a static library, new step `scripts/62-espeak-ng.sh` after `61-trailing-silence.sh`; `espeak-ng-data` shipped next to the binary in every platform tarball (about 12 MB; the `*_dict` files and `phontab`/`phonindex`/`phondata` are all that is needed, no MBROLA, no audio output). The ffmpeg configure line already has `--enable-gpl --enable-version3`, which GPLv3 code requires; add a row to the README licence section. `lyricsalign_filter_deps="whisper swresample"` plus the espeak library in the filter's link line; on darwin and windows check the static link the way `48-whisper.sh` does for ggml.

**API**, one call per lyric line, matching what the prototype gets from the CLI's `--ipa --sep=_`:

```c
espeak_Initialize(AUDIO_OUTPUT_SYNCHRONOUS, 0, espeak_data, 0);   /* once; espeak_data may be NULL */
if (espeak_SetVoiceByName(language) != EE_OK) -> fail init, naming the voice
const void *p = line_utf8;
while (p) {
    const char *ipa = espeak_TextToPhonemes(&p, espeakCHARS_UTF8, espeakPHONEMES_IPA | ('_' << 8));
    append(ipa); append(" ");
}
```

`espeak_TextToPhonemes` returns one clause at a time and advances `p`; join the clauses with a space. Then, exactly as the prototype parses it:

1. remove language-switch markers `(xx)` / `(xx-yy)` (regex `\([a-z]{2,3}(-[a-z]+)?\)`);
2. split on whitespace into words, each word on `_` into phones;
3. strip the stress marks `ˈ` and `ˌ` from each phone, drop empty phones.

**Mapping each phone to a vocabulary id, first hit wins, in this order:**

1. the phone itself;
2. a fixed nearest-neighbour table: `ʏ→ʊ`, `ɒ→ɔ`, `ɵ→ø`, `ʉ→u`, `ɨ→ɪ`, `ɫ→l`, `ɱ→m`, `ʌʊ→aʊ`, `œy→ɔø` (the last two are Dutch *ou/au* and *ui* as espeak writes them, which the model never saw);
3. the phone with combining marks and format characters removed (Unicode NFD, drop categories `Mn` and `Cf`);
4. that, with the length mark `ː` removed;
5. its first character.

A phone that misses all five is **dropped and counted** (`mapping_misses`), never replaced by `<unk>`. Measured: 0 misses on the 8 English and Dutch tracks. Word boundaries are kept (they define `words` in the output); the Viterbi itself sees one phone sequence per line.

## Processing

Constants are the prototype's; the names are suggestions.

**1. Resample** both inputs to 16 kHz mono float (swresample). Build the check signal `check = vocals + blend × backing` over the common length.

**2. Emissions** (per signal): run the model in windows of **20 s core + 1 s context on each side** (22 s, 352 000 samples), zero-padded at the track's start and end, hop 20 s; normalise **each window** to zero mean, unit variance; keep the core's frames (drop `1 s / 20 ms = 50` frames on each side; a window of N samples gives `floor((N - 400) / 320) + 1` frames, take `[50 : 50 + core / 320)`). Stitch to one `[T × 392]` log-prob matrix, T = `len / 320`. A last core shorter than 1 s is padded to 1 s before the model sees it (the conv stack needs 400 samples; a tiny window gives garbage at its edge).

**3. Star column.** Append column 392, `star = log(1 − p_blank) + log(0.3)`, i.e. 30 % of the frame's non-blank mass; `−1e9` where `p_blank = 1`. The star absorbs non-lyric vocals (ad-libs, backing vocals) between lines.

**4. Token sequence:** `[star]`, then for every line that has phones: its phones, then `[star]`. A line without phones gets no tokens and is reported with `reason` `empty` or `no_phones`.

**5. Viterbi** over the blank-interleaved state chain `blank, t1, blank, t2, ..., tn, blank` (n tokens, 2n+1 states), float32 scores, int8 back-pointers (for a 5-minute track: 15 000 frames × about 4 000 states, fine). Into state `s` at frame `t` you may come from:

- `s` (stay) and `s−1`, always;
- `s−2` when `s` is a token, `s ≠ 1`, and its token differs from the one at `s−2` (CTC repeat rule);
- `s−3` when `s` is a token and the token at `s−2` is a star (skip the star and the blank before it);
- `s−4` when `s` is a token, the token at `s−2` is a star, and the token at `s−4` differs from `s`'s.

Emission for state `s` at frame `t` is `logp[t, token(s)]`, **minus `line_blank_penalty = 0.05` nats per frame on a blank state that sits between two phones of the same line** (not on blanks next to a star). This is what removed the outliers of a plain Viterbi (measured: 81.0 % → 82.3 % within 0.2 s, 19 → 14 lines over 1 s, before the check existed). Start in state 0 or 1; end in state 2n or 2n−1, whichever scores higher. If the best end score is still `−1e9`-ish (no path), that is `no_alignment`. Back-trace; for every token record the **first frame** of its run and the model's posterior `exp(logp[frame, token])` there.

A line's **spike start** = its first phone's first frame × 20 ms; its **end** = its last phone's run end × 20 ms. A word's start/end the same way over its phones. `score` = mean posterior of the line's (word's) phones.

**6. Agreement check.** Run 2–5 on `check` too (same tokens). For each line with a placement on `vocals`, in this order:

| test | condition | `reason` |
|---|---|---|
| the check has no placement for the line | | `check_failed` |
| the two spike starts differ by more than **0.3 s** | abs(check_start − start) > 0.3 | `disagree` |
| the line's first phone sits away from its second | gap between phone 1 and phone 2 > **0.5 s** | `first_gap` |
| a stray prefix | among the first **6** phones there is a `k` with the gap before phone `k+1` > **0.8 s** and the mean posterior of phones 1..k < **0.2** | `stray_prefix` |

The first two catch a line glued to an ad-lib or a backing vocal; the last two catch a short inaudible first word ("and", "I'm a") dumped seconds early. A line that fails any test is **skipped**: `start:null`, with `vocals_start` and `check_start` reported. Measured: this is what took the worst written line from 4.84 s to 0.65 s and made all 8 tracks clean, at the cost of 54 of 396 lines skipped.

**7. Onset walk-back.** The CTC spike of a line that follows a pause sits 30 to 150 ms **after** the voice begins (measured on every track; in continuous singing it does not, and walking back there runs into the previous line). So:

- envelope: RMS of `vocals` per **10 ms** hop, in dB (`20·log10(rms + 1e-9)`);
- `previous_end` = the previous *placed* line's end (placed, not written: a skipped line still ends somewhere), none for the first line;
- if `previous_end` is none or `start − previous_end ≥ 1.0 s`: from the spike frame `k0`, `level = max(env[k0 .. k0+5))`; walk back while `env[k−1] ≥ level − 10 dB` and `env[k−1] > −45 dBFS`, at most **0.8 s**, and never before `previous_end + 0.05 s`. The written `start` is `k × 10 ms`; `lead_in` = spike − written. Otherwise the written start is the spike and `lead_in` is 0.

Measured: 96.5 % → 97.7 % within 0.2 s, worst 0.65 s.

## Tests

**Unit, no ffmpeg build** (`tests/unit/`, `cc -Wall -Wextra -Werror`): put steps 3, 5, 6 and 7 in a header-only `scripts/includes/nm_lyricsalign_align.h` over plain float arrays (allocator macro, as `nm_whisper_words.h`), and test them against the fixture below plus hand-built cases: a 3-token chain on a 10-frame emission with a known best path; the repeat rule (`a a` needs a blank between); star skipping; the penalty changing a path; each of the four skip reasons; walk-back stopping at the floor, at −45 dBFS, at 0.8 s.

**Port fixture**, from the prototype on CPU, f32, in the plugin repo under `eval/fixtures/jfk/` (`FiLL/nomercy-lyrics-creator-plugin` on Forgejo; copy it into `tests/`, it is 440 KB):

- `jfk-logprobs-f16.npy`: the `[550 × 392]` log-probs of whisper.cpp's `samples/jfk.wav` (sha256 `59dfb9a4acb36fe2a2affc14bacbee2920ff435cb13cc314a08c13f66ba7860e`, 11 s, public domain), one window;
- `jfk-alignment.json`: the espeak `en-us` phones of the JFK sentence, their ids, the Viterbi's first frame and posterior per phone, per word `start` and `score`, the line's spike (0.36 s), end (10.34 s) and written start (0.34 s).

Gates for the port: (a) **emission fidelity**: the ggml model's log-probs on that clip have the same argmax as the fixture on at least 99 % of frames and a mean absolute difference below 0.05 nats (f16 weights against f32: a few hundredths is expected, a tenth is a bug); (b) **alignment fidelity**: the C Viterbi on the fixture's emissions reproduces every phone frame exactly; (c) end to end, `lyricsalign` on `jfk.wav` with the sentence as `text_file` and `anullsrc` as backing gives every word start within 40 ms (two frames) of the fixture.

**Real-model tests** (`tests/lib/lyricsalign.sh` and a `.ps1` twin, `run_custom_test` protocol, SKIP with a reason when the GGUF or the clip is absent; the GGUF fetched by digest like `stemsplit-assets.sh` does):

- header line first, then exactly one line per text line, all valid JSON; `start ≤ word.start ≤ word.end ≤ end`, word starts non-decreasing;
- gate (c) above;
- two runs are byte-identical (determinism, CPU);
- empty `text_file` fails init; unknown `language=xx-nope` fails init and the message names it; missing `espeak_data` fails with the path;
- `destination=-` and `destination=pipe\:1` give the same bytes;
- a text with an empty line in the middle keeps it as a line with `reason:"empty"`;
- `blend=0` writes every line (the check is identical to the primary);
- `use_gpu=1` on a GPU runner: every word within 40 ms of the CPU run.
- CI: unit test on ubuntu, real-model tests in the linux-x86_64 smoke job; the espeak-ng data is checked present in every platform tarball.

## Acceptance criteria

- [ ] `ffmpeg -h filter=lyricsalign` lists the nine options with the defaults above; two inputs, one output.
- [ ] `tools/wav2vec2-gguf` converts the checkpoint, `verify()` passes, and the GGUF plus `.sha256` are a release on `nomercy-lyricsalign-models`.
- [ ] espeak-ng 1.52.0 static, `espeak-ng-data` in all seven platform tarballs, licence row in the README.
- [ ] Port gates (a), (b), (c) pass on the JFK fixture.
- [ ] Tests above green in CI on linux-x86_64; the PowerShell suite passes on Windows.
- [ ] README: feature-table row, a `lyricsalign` section with the options, the JSON shape, the skip reasons, and the measured speed on the standard desktop CPU (no speed gate; it is an offline filter like `stemsplit`).
- [ ] **Benchmark**: on a release candidate, the lyrics-creator eval harness (`python -m lyrics_eval bench`, owner's machine, 8 tracks today, more as the reference set grows) measures the filter at **at least 97 % of written lines within 0.2 s, no written line over 1 s, 8 / 8 tracks clean, at least 330 of 396 lines written**, and every written line within 40 ms of the prototype's time for that line. The harness side (`ffmpeg-lyricsalign` pipeline) is added in the plugin repo as soon as a build with the filter exists.

## Out of scope

- The media server's model download and the `{alignModel}` / `{espeakData}` tokens: nomercy-media-server#620 follow-up.
- Quantised models (`q8_0`) and a speed target: measure first.
- Anything the plugin does with skipped lines (review UI): it never writes them, that is all this filter needs to know.

