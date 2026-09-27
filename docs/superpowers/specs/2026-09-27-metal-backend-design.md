# Metal backend for darwin-arm64 — design

Issue: [#69](https://github.com/NoMercy-Entertainment/nomercy-ffmpeg/issues/69), phase 3.
Date: 2026-09-27. Status: draft, awaiting the owner's review.
Research: `docs/superpowers/research/2026-09-27-metal-backend-findings.md`.
Supersedes §9 of `docs/superpowers/specs/2026-09-23-ggml-gpu-backends-design.md` where they differ.

## Purpose

macOS currently gets **no** GPU acceleration for `whisper` or `stemsplit`. Vulkan
shipped for the other platforms and darwin was deliberately excluded
(`NM_VULKAN=0`), and CUDA was measured on 2026-09-26 and is slower than Vulkan
on every workload while costing +820 MB, so it is not the answer anywhere.
Metal is the only route by which macOS gains anything.

## It builds — that part is settled

`libggml-metal.a` builds, `whisper-cli` links, and `cmake --install` succeeds for
darwin-arm64 through the existing osxcross toolchain with
`GGML_METAL_EMBED_LIBRARY=ON`, in a container built from the first 157 lines of
`ffmpeg-darwin-arm64.dockerfile` verbatim. `Foundation`, `Metal` and `MetalKit`
are all present in MacOSX15.1.sdk, osxcross clang 18.1.3 compiles `.m`, and the
embed step is two `sed`s plus `.incbin` — **no Apple shader compiler is needed at
build time**, exactly as the earlier design predicted.

### One thing the earlier design got wrong

§9.1 said there was no blocker. There is one, and it is small. clang 18 can
neither parse ggml's `visionOS` `@available` clauses nor link the
`__isPlatformVersionAtLeast` they lower to. One anchored `sed` clears both by
taking the pre-macOS-15 path that upstream already supports and ships an env
switch for (`GGML_METAL_NO_RESIDENCY`):

```
#define GGML_METAL_HAS_RESIDENCY_SETS 1   →   #undef GGML_METAL_HAS_RESIDENCY_SETS
```

The plan must anchor that `sed` precisely and fail the build if it matches
nothing, so a whisper.cpp bump cannot silently skip it.

## Cost: +767 KB

Stripped `whisper-cli` goes from 2,193,144 to 2,960,552 bytes, of which
**609,531 B is the embedded shader source**, confirmed from the
`__DATA,__ggml_metallib` section header. Vulkan added +62 MB; Metal is about 80
times cheaper. Nothing extra ships — there is no `.metallib`.

## The decision this design exists to make

**ggml compiles the shaders when the backend registry is constructed**, and this
codebase reaches registry construction through `nm_ggml_gpu_usable()`, which
`af_whisper.c:153` calls **unconditionally, on its own line, before `use_gpu` is
read**. So with Metal enabled, *every* macOS whisper or stemsplit run pays the
first-use shader compilation — including `use_gpu=0`, and `NOMERCY_GGML_GPU=0`
does not buy it back either.

That unconditional call is not an accident. It is the fix for a crash: on Linux
the call used to sit behind `use_gpu &&`, which short-circuited the ICD guard
away on exactly the option a user reaches for when a GPU is causing trouble, and
the process then died in `ggml_backend_load_all()`.

**But the reason does not apply on darwin.** There is no ICD guard there, no
hostile third-party drivers, and no crash to prevent — the guard is compiled out
for non-Windows, non-Apple targets. So on darwin the unconditional call buys
nothing and costs seconds.

**Decision, superseded 2026-09-28: build macOS with Metal and accept the
compile.** This section originally decided to "defer registry construction on
darwin until `use_gpu` is known", and required that `use_gpu=0` and
`NOMERCY_GGML_GPU=0` both avoid the shader compilation entirely. That decision was
withdrawn by the owner, for the plainest possible reason: **the cost it optimises
away has never been measured.** Every statement about it in this document and in
the research is reasoned, not timed. An optimisation for an unmeasured cost is not
a requirement.

It was also partly unachievable as written. Verified against the pinned sources
and recorded in
`.superpowers/sdd/2026-09-27-metal-backend/registry-construction-findings.md`:
`ggml_backend_cpu_init()` does not construct the registry, so a CPU-only stemsplit
run could avoid the compile — but `whisper_backend_init()` walks
`ggml_backend_dev_count()` ungated by `params.use_gpu` (`whisper.cpp:1339`), so for
the whisper filter no change of ours avoids it. The only lever that would is
ggml's own process-wide `GGML_METAL_DEVICES=0`, which latches on first use and
could take the GPU from a second filter in the same filtergraph.

**What this means for the build: nothing.** Metal is on for darwin-arm64 either
way. The one-off compile is accepted, documented in the README, and **timed** by
the Task 4 verification script on Apple hardware. If that number turns out to
matter, this decision gets revisited with the number in hand.

The warning that produced the original decision still stands for anyone editing
the other platforms: the unconditional call on Linux and Windows is a crash fix,
it used to sit behind `use_gpu &&`, and short-circuiting the ICD guard away killed
the process in `ggml_backend_load_all()`. Do not unify darwin with them.

## Scope: darwin-arm64 only

**darwin-x86_64 stays off**, and the earlier design's assumption was wrong here
too. It assumed a 10.15 deployment floor; the dockerfile's floor is **10.13**,
while ggml uses unguarded 10.15 APIs. On top of that, Intel and AMD GPUs report
neither `Apple7` nor `Metal3`, so they would take ggml's slow paths — on the
oldest machines we support. Building it is free; shipping it is not.

Windows, Linux and FreeBSD are untouched.

## What changes

`scripts/48-whisper.sh` only. No dockerfile edit is strictly required: pkg-config
passes `-framework` flags through a `Libs:` line intact, which was verified.
Adding them to the darwin `ENV LDFLAGS` is the house style and is free because of
`-dead_strip_dylibs`; the plan may do either, but must say which and why.

- per-arch `-DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON` for arm64;
- the residency-sets `sed`, anchored and guarded;
- `-lggml-metal` in `whisper.pc`, in the slot Vulkan occupies on other platforms
  — before `-lggml-cpu`, with a trailing `-lggml-base`;
- `-framework Foundation -framework Metal -framework MetalKit`;
- a guard on the embedded blob's size, so an empty or truncated shader section
  fails the build rather than shipping;
- the darwin arm in `tests/lib/cpu-variant.sh`. **`vulkan_platform_has_backend()`
  skips darwin today, so Metal would otherwise be asserted by nothing at all** —
  and this project has already produced seven checks that passed while testing
  nothing.

The filters and the dispatcher need no change. Note the metadata value will be
**`mtl`**, not `metal`, because `GGML_METAL_NAME` is `"MTL"` — the README and any
assertion must use the real string.

## What cannot be verified without the owner's Mac

Nothing Metal has actually run. These are the release gates, and "it builds and
it is 767 KB" is a green light for the spec, not for a release:

1. the embedded MSL compiles at all on a real device;
2. first-use compilation time — the earlier design expects a few seconds, which
   is negligible for a media server transcoding a library and is not nothing for
   a one-shot invocation;
3. a device is selected in a **daemon or SSH context**, not just an interactive
   login — the media server runs as a service;
4. output matches the CPU path, to the same standard the Vulkan work used;
5. it actually beats the fixed-level NEON CPU build. If it does not, this whole
   phase is not worth shipping.

## Testing

Everything the Vulkan work asserted, adapted: the backend is linked, the filters
report `mtl`, and a machine without Metal falls back cleanly. The assertions must
be written against **`MTL`**, not `metal`: ggml compiles in a table of every
backend name, so a case-insensitive search for `metal` matches twice even in a
build with Metal off — measured, and it would have made the check useless.

**No test asserts that `use_gpu=0` skips shader compilation**, because no such
behaviour exists — see the withdrawn decision above. What replaces it is a
measurement, not an assertion: Task 4 gate 2 times the compile on the owner's Mac.

## Out of scope

- darwin-x86_64, as above.
- CUDA, measured and worse on every axis; the decision is the owner's and is
  deferred.
- Any change to the Linux or Windows GPU path.
