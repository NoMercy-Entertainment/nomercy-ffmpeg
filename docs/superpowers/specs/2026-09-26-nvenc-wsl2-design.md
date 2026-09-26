# One linux-x86_64 ffmpeg that does NVENC everywhere — design

Issue: [#42](https://github.com/NoMercy-Entertainment/nomercy-ffmpeg/issues/42).
Date: 2026-09-26. Status: approved by the owner, ready for an implementation plan.
Research this argues from: `docs/superpowers/research/2026-09-26-nvenc-wsl2-findings.md`.

## Purpose

`h264_nvenc` fails in our linux-x86_64 build under WSL2 with
`cuInit(0) -> CUDA_ERROR_OPERATING_SYSTEM`. WSL2's `/usr/lib/wsl/lib/libcuda.so.1`
is a shim that loads the real driver behind it, and **a statically linked
executable cannot complete that second-stage load**. Self-hosters running the
media-server container under Docker Desktop on Windows with an NVIDIA card
therefore get no hardware encoding.

The cause is not inferred. Same source compiled twice, one machine, one libcuda:

```
DYNAMIC caller   dlopen ok · dlsym ok · cuInit(0) rc=0   (CUDA_SUCCESS) · deviceCount n=1
STATIC  caller   dlopen ok · dlsym ok · cuInit(0) rc=304 (CUDA_ERROR_OPERATING_SYSTEM)
```

Reproduced with the shipped binary on an RTX 3070 / driver 617.14, where the
issue was filed on a 2080 SUPER / 595.79 — not card- or driver-specific.

## The decision this rests on

**One artifact, not two.** The owner chose this on 2026-09-26 with the cost in
front of them: a dynamically linked binary loses musl and every distro older
than the 2.34 floor. A second, dynamic-only artifact was offered and declined.

That decision is what makes the rest of this design coherent, and it is the one
thing a future reader should not quietly reverse: the tension between "one
artifact" and "never break existing users" is real and was resolved
deliberately, not overlooked.

## What changes

The executable gains an ELF interpreter. **Every third-party library stays
statically linked** — this is not a move to dynamic dependencies, and the only
new runtime requirement is glibc itself.

Four parts, all in the linux-x86_64 build:

### 1. Drop `-static`, add `-no-pie`

Remove the bare `-static` from the two `--extra-cflags` / `--extra-ldflags`
entries in `ffmpeg-linux-x86_64.dockerfile`. Add `-no-pie`, which libdavs2's
hand-written asm requires — it cannot go into a PIE.

**`-no-pie` costs executable ASLR.** That is a real security trade and is
accepted here rather than glossed over; the alternative is making libdavs2's asm
PIC-clean, which is larger work for a separate decision.

### 2. One compat object, `nmcompat.c`

Compiled `gcc -O2 -fPIC -fvisibility=hidden -fno-builtin -c` and appended to
`--extra-libs`. A `.o` rather than a `.a`, so it contributes every definition
unconditionally and link order cannot matter.

It defines the ~20 glibc symbols that GCC 13's prebuilt `libstdc++.a` /
`libgcc_eh.a` and the component archives reference above the floor:

| group | symbols |
|---|---|
| C23 renames | `__isoc23_strtol/strtoul/strtoll/strtoull/strtoll_l/strtoull_l`, `__isoc23_sscanf/fscanf/scanf/vsscanf/vfscanf/vscanf` |
| BSD string | `strlcpy`, `strlcat` |
| randomness | `arc4random`, `arc4random_buf` |
| unwinder | `_dl_find_object`, reimplemented over `dl_iterate_phdr` |
| libmvec | `_ZGVbN2v_log2`, `_ZGVbN2vv_atan2` |
| pidfd | `pidfd_spawnp`, `pidfd_getpid` |
| versioned forwards | `hypot`, `hypotf`, `fmod`, `fmodf` via `.symver` to `@GLIBC_2.2.5` |

`_dl_find_object` is what buys 2.34 rather than 2.35 — see "Why 2.34" below.

**Two traps this file walks into if written naively**, both measured, both of
which the plan must guard against:

- **`_GNU_SOURCE` makes the shim call itself.** It implies `_ISOC2X_SOURCE`, so
  a plain `strtoul()` inside `nmcompat.c` is rewritten by the headers into
  `__isoc23_strtoul()` — the function being defined. It **links cleanly** and
  then hangs forever the first time the symbol is reached. Observed: `ffmpeg
  -version` produced no output and never exited. The fix is asm labels on the
  real entry points. The general lesson is the binding one: **a compat shim must
  be exercised at runtime, not merely linked.**
- **Visibility.** Without `-fvisibility=hidden` the shim's symbols land in
  `.dynsym` and **interpose** on libraries ffmpeg `dlopen`s — libcuda,
  libnvidia-encode, the OpenCL and Vulkan loaders. The NVIDIA driver's unwinder
  would silently start using our `dl_iterate_phdr` reimplementation.

### 3. Remove the four stray shared dependencies

Stop installing `libomnidrive.so` (`scripts/56-omnidrive.sh`), and stage
`libgomp.a`, `libXau.a`, `libXdmcp.a` into `${PREFIX}/lib` so `-lgomp`, `-lXau`
and `-lXdmcp` resolve to archives. All three exist in the image.

`libmvec.so.1` stays and is fine: it ships with glibc and its only remaining
reference is `_ZGVbN2v_log@GLIBC_2.22`, far below the floor.

### 4. A link guard, in the dockerfile, right after `make`

Three assertions, all of which must fail the build:

- the highest `GLIBC_` symbol version is **exactly** `GLIBC_2.34`;
- `NEEDED` contains nothing beyond `libc`, `libm`, `libmvec`, `libdl`,
  `libpthread`, `librt` and the loader;
- `ffmpeg -version` runs and exits 0.

Pinning the floor to an exact string is deliberate: a floor that moves in
**either** direction means something changed. Without this the floor silently
follows the base image's glibc at the next image rebuild, and a stray `.so` can
reappear from any component upgrade. The third assertion is what catches the
recursion trap, which no link-time check can see.

## What this costs, stated plainly

The current artifact is `statically linked … for GNU/Linux 3.2.0` and runs on
any x86-64 Linux with a 3.2+ kernel regardless of libc — verified, including
`alpine:latest` (musl).

| setup | glibc | after this change |
|---|---|---|
| Alpine / any musl distro | musl | **breaks hard** — measured, no interpreter |
| Debian 11, Ubuntu 20.04 | 2.31 | **breaks** — measured, `GLIBC_2.34 not found` |
| Debian 10, Ubuntu 18.04, RHEL 7/8, Leap ≤15.5, Amazon Linux 2 | ≤2.31 | breaks |
| Debian 12 (the media-server container) | 2.36 | works |
| Ubuntu 22.04 | 2.35 | works |
| RHEL/Rocky/Alma 9, Amazon Linux 2023 | 2.34 | works |
| Leap 15.6, Fedora, Ubuntu 24.04, Arch | ≥2.38 | works |

### Why 2.34, and why 2.35 is not "close enough"

2.34 is the highest floor that still covers every currently-supported mainstream
distro. The whole EL9 family and Amazon Linux 2023 sit **exactly** on 2.34, so
stopping at 2.35 — which is what you get by skipping the `_dl_find_object` work
— silently drops RHEL 9, Rocky 9, Alma 9 and AL2023. They look one step apart
and are not.

## Scope

**linux-x86_64 only.** `ffmpeg-linux-aarch64.dockerfile` carries the same
`-static` pattern and is deliberately left alone: WSL2 is an x86-64 problem, the
symbol set there differs (no libmvec, no x86 asm PIE problem, same libstdc++
story), and it has not been measured. This leaves two different linkage models
across the Linux platforms, which is a known inconsistency accepted for now
rather than an oversight. If aarch64 is later brought along it needs its own
measurement, not a copy of this.

Windows, macOS and FreeBSD are untouched.

## Testing

The research verified startup, codec enumeration, and a full `h264_nvenc` encode
that re-probes as real H.264 — from **one binary**, both inside WSL2 (Ubuntu
24.04, RTX 3070) and in `debian:bookworm-slim`.

The plan must additionally smoke-test the surfaces that were **not** exercised,
each of which touches a shimmed symbol or a newly-static library:

| surface | why it is at risk |
|---|---|
| librsvg | the `pidfd_*` path |
| whisper / stemsplit | OpenMP against static `libgomp.a` |
| tesseract OCR | newly-static link |
| libplacebo / Vulkan filters | dlopened loader, interposition risk |
| `ffplay` (SDL2) | newly-static link |
| bluray / dvdread protocols | newly-static link |

Plus a runtime self-test that calls **every** shimmed symbol once and prints its
result. That belongs in the build, not in a one-off check: it is the only thing
that catches the recursion trap, and it caught it in seconds when the research
hit it.

Distro assertions: the artifact must run on `debian:12`, `ubuntu:22.04` and
`almalinux:9` (the 2.34 boundary), and is expected to fail on `debian:11` and
`alpine` — assert the failure too, so the accepted cost stays visible rather
than becoming a surprise later.

## Known risks carried

- **`pidfd_spawnp` is not atomic** the way glibc's is: between `posix_spawnp`
  and `pidfd_open` the child could exit and its pid be reused. Almost certainly
  fine for glib's `gspawn`, but unverified.
- **`_dl_find_object` performance and re-entrancy.** Linear `dl_iterate_phdr`
  per frame against glibc's lock-free tree; 1001 throws completed instantly but
  it was not benchmarked. Behaviour when an exception propagates *through* a
  `dl_iterate_phdr` callback is unverified — glibc holds `dl_load_write_lock`
  there and our implementation would re-enter it.
- **Maintenance.** The compat object tracks GCC's and glibc's symbol choices. A
  base-image bump can move the floor or add symbols; the link guard is what
  turns that from a silent regression into a failed build.
- **musl and pre-2.34 install share is unknown.** It is the number that would
  have decided the one-artifact question on evidence rather than judgement.

## Out of scope

- aarch64, as above.
- Reaching below 2.34 (Debian 11, Ubuntu 20.04), which needs `zig cc` and a much
  larger blast radius.
- CUDA/NVENC on any platform other than linux-x86_64; Windows already does NVENC
  natively.
