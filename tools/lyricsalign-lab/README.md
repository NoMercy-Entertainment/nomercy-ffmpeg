# lyricsalign lab

A Docker lab that builds a minimal FFmpeg 9.0 with the `whisper` and
`lyricsalign` filters in minutes, against the real `scripts/includes` sources
and the real build steps (`scripts/65-espeak-ng.sh`, `scripts/66-lyricsalign.sh`).
The platform dockerfiles take hours per iteration; this is where the filter is
developed and where its gates are run before those builds.

Nothing from here is shipped. The ggml inside is whisper.cpp v1.9.1 built for
the CPU at the haswell level, in the fixed-level shape the darwin platforms use.

## Use

```bash
tools/lyricsalign-lab/run.sh image            # once; builds whisper.cpp inside
tools/lyricsalign-lab/run.sh build            # espeak-ng once, then ffmpeg
tools/lyricsalign-lab/run.sh suite            # unit tests + tests/lib/lyricsalign.sh
tools/lyricsalign-lab/run.sh suite gate_c     # one function (substring match)
tools/lyricsalign-lab/run.sh shell            # look around
```

Two named volumes persist between runs: `lyricsalign-lab-prefix` (`/opt/nm`:
ggml, espeak-ng and its data) and `lyricsalign-lab-build` (`/build`: the ffmpeg
tree and its objects). `run.sh build --fresh` rebuilds espeak-ng and
reconfigures ffmpeg. `docker volume rm lyricsalign-lab-prefix lyricsalign-lab-build`
starts over.

Assets are mounted read-only at `/assets` from `LYRICSALIGN_LAB_ASSETS`
(default: `../lyricsalign-assets` next to the checkout):

| file | from |
|---|---|
| `wav2vec2-xlsr-53-espeak-cv-ft-f16.gguf` | `tools/wav2vec2-gguf` (or the models release) |
| `jfk.wav` | whisper.cpp v1.9.1 `samples/jfk.wav`, sha256 `59dfb9a4…7860e` |
| `jfk.txt` | the JFK sentence, one line |
| `jfk-alignment.json` | `tests/unit/fixtures/jfk/` |

Inside the container the repository is at `/repo` (read-write: the unit tests
and the suite are run from it), ffmpeg at `/build/ffmpeg/ffmpeg`, and
`espeak-ng-data` is symlinked next to the binary, where the filter looks by
default.

## Helpers

- `espeak-check.c`: prints the espeak-ng IPA phones of a sentence through the
  library, to compare with the CLI's `--ipa --sep=_` output.
- `emit.c` + `gate_a.py`: run the GGUF model on a WAV without ffmpeg and compare
  the emissions with the JFK fixture (gate (a) of #126).
- `make_phone_fixture.py`, `make_unicode_inc.py`: generators for the unit-test
  fixtures of `nm_lyricsalign_phones.h`.

## Measured

Filled in by the plan's tasks (`docs/superpowers/plans/2026-11-05-lyricsalign.md`).
