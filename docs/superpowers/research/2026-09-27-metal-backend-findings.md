# Metal for the whisper and stemsplit ggml backends (phase 3 feasibility)

**Date:** 2026-09-27
**Issue:** #69 (phase 3, Metal)
**Spec this answers:** `docs/superpowers/specs/2026-09-23-ggml-gpu-backends-design.md` §9 —
"The blocker everyone expects is not there ... phase 3 therefore starts with
darwin-arm64, and darwin-x86_64 only follows if it can be done without moving the
deployment target."

**Recommendation up front: yes, build it — for darwin-arm64 only, and do not ship it
until it has run on the owner's Mac.** `ggml-metal` compiles and links for darwin-arm64
through the existing osxcross toolchain with `GGML_METAL_EMBED_LIBRARY=ON`, and it costs
**+767 KB** — roughly 1/80th of Vulkan's +62 MB. §9.1 of the design is right that the
Metal shader compiler is not the blocker. But there *is* a blocker it did not predict,
one line of clang: osxcross's clang 18 cannot parse ggml's `visionOS` availability
clauses and has no `__isPlatformVersionAtLeast` to link them against. One anchored
one-line `sed` — the same shape as the mingw `ggml-cpu.c` sed already in
`48-whisper.sh` — clears both, by taking the pre-macOS-15 code path upstream already
supports. There is also a design consequence in §6 that phase 3 must decide before it
writes any code: on macOS the shaders get compiled when ggml's registry is built, which
is *before* `use_gpu` is consulted, so a CPU-only macOS user pays for them too.

Every line below is labelled **measured** (I ran it and read the output) or **reasoned**
(I read the pinned source and concluded). Nothing here ran on Apple hardware — §7 lists
exactly which claims that leaves open.

---

## 1. What was built, and how

A throwaway image, `nm-metal-spike:probe`, built from the **first 157 lines of
`ffmpeg-darwin-arm64.dockerfile`, copied verbatim** — through the osxcross `build.sh`
step, the cross `ENV CC/CXX/...`, `ENV PATH`, `CFLAGS/CXXFLAGS/LDFLAGS`,
`CMAKE_COMMON_ARG` and the tool symlinks — with spike-only steps appended after it.

Copying that prefix unchanged was deliberate. The known trap here is that osxcross's
`build.sh` runs *before* the cross `ENV CC/CXX` and before `${PREFIX}/osxcross/bin`
joins `ENV PATH`; a harness that hoists the ENV up front breaks it, which is why an
earlier local darwin attempt failed while CI was green. Taking the file's own first 157
lines reproduces that ordering rather than re-deriving it. Nothing from `/scripts` is
copied, so the gitignored `scripts/patches/` problem never arises: this spike never runs
`init.sh`, never builds libbluray, and never builds ffmpeg.

| | |
|---|---|
| Base | `nomercyentertainment/ffmpeg-base:latest` (local, the base the darwin dockerfile uses) |
| osxcross SDK | `MacOSX15.1.sdk`, `OSX_VERSION_MIN=11.0`, `MACOSX_DEPLOYMENT_TARGET=11.0.0` — untouched |
| Cross compiler | `arm64-apple-darwin24.1-clang` → **Ubuntu clang 18.1.3**, target `arm64-apple-darwin24.1` (measured) |
| whisper.cpp | tag `v1.9.1`, the pin in `scripts/48-whisper.sh` (ggml 0.15.1) |
| Not built | ffmpeg itself, and the other 59 dependency scripts |

**Why not a full build.** The question is whether `ggml-metal` compiles and links for
darwin-arm64 through this toolchain; that needs the toolchain, the SDK and whisper.cpp,
not x265 or a three-hour dependency chain. Where a claim would have needed the real
ffmpeg link, it is marked reasoned, and §7 says so.

---

## 2. Do the pieces exist? (measured)

**The frameworks are all in the SDK the darwin dockerfiles already download.** Listed
directly in `${OSX_FRAMEWORKS}` of `MacOSX15.1.sdk`:

```
OK   Foundation.framework      OK   Metal.framework       OK   MetalKit.framework
OK   MetalPerformanceShaders.framework   OK   Accelerate.framework   OK   CoreFoundation.framework
```

`Metal.framework` carries `Headers/` (85 headers, `MTLDevice.h`, `MTLLibrary.h`,
`MTLComputePipeline.h`, …), `Modules/` and a 46,951-byte `Metal.tbd` stub — everything a
cross link needs.

**osxcross clang compiles Objective-C.** A `.m` file importing all three frameworks and
calling `MTLCreateSystemDefaultDevice`, `-newCommandQueue`, `MTLCompileOptions` and
`-newLibraryWithSource:options:error:` compiles with **today's darwin `CFLAGS`,
unchanged**.

**Today's `LDFLAGS` cannot link it — measured, not assumed:**

```
Undefined symbols for architecture arm64:
  "_MTLCreateSystemDefaultDevice", referenced from: _nm_probe in probe.o
  "_OBJC_CLASS_$_MTLCompileOptions", referenced from: objc-class-ref in probe.o
  "_OBJC_CLASS_$_NSString", referenced from: objc-class-ref in main.o
```

Adding `-framework Foundation -framework Metal -framework MetalKit` links it and produces
a `Mach-O 64-bit arm64 executable, flags:<NOUNDEFS|DYLDLINK|TWOLEVEL|PIE>`. Note the
third framework: the design doc names Metal and MetalKit as the missing ones, but
darwin's `LDFLAGS` has **CoreFoundation, not Foundation**, and the `NSString` line above
is that gap. It is three frameworks, not two.

Also measured, and worth keeping: `-Wl,-dead_strip_dylibs` (already in darwin's
`LDFLAGS`) drops a framework that nothing references — `MetalKit` is absent from the
final binary's load commands even though it was on the link line. Naming these
frameworks on a build that does not use them therefore costs nothing.

---

## 3. Does it build? (measured)

### 3.1 The embed path itself is fine

`cmake` with `${CMAKE_COMMON_ARG}` + `-DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON`
configures cleanly:

```
-- The ASM compiler identification is Clang with GNU-like command-line
-- Metal framework found
-- Including METAL backend
```

`find_library(… Foundation/Metal/MetalKit REQUIRED)` resolves against the sysroot with no
help, and `enable_language(ASM)` resolves to the same cross clang. The build then does
exactly what §9.1 predicted:

```
Embedding Metal library
[ 94%] Building ASM object ggml/src/ggml-metal/CMakeFiles/ggml-metal.dir/autogenerated/ggml-metal-embed.s.o
```

and the generated stub is six lines of assembler over a file produced by two `sed`s:

```asm
.section __DATA,__ggml_metallib
.globl _ggml_metallib_start
_ggml_metallib_start:
.incbin "/build/b-metal/ggml/src/ggml-metal/autogenerated/ggml-metal-embed.metal"
.globl _ggml_metallib_end
_ggml_metallib_end:
```

No Apple shader compiler is invoked at any point. `libggml-metal.a` is produced **with
the `lib` prefix** (Mach-O, unlike the COFF cross builds), so darwin needs none of the
windows-style archive renaming in `48-whisper.sh`.

### 3.2 The blocker the design did not predict

The first build **failed**, in `ggml-metal-device.m`, three times:

```
ggml/src/ggml-metal/ggml-metal-device.m:1455:53: error: unrecognized platform name visionOS
```

(at lines 593, 1423 and 1455 — every `@available(macOS 15.0, iOS 18.0, tvOS 18.0,
visionOS 2.0, *)` in the file), plus a warning that
`newResidencySetWithDescriptor:error:` is macOS 15 while the deployment target is 11.0.

Root cause, measured directly rather than inferred: **Ubuntu clang 18.1.3 does not know
the `visionOS` availability platform at all** — it rejects `visionOS` and `visionos`
alike, and the same `@available` line without that clause compiles. A newer clang does
know it — `clang 20.1.8` from apt.llvm.org accepts `visionOS 2.0` in a syntax-only check
(measured, in a throwaway `ubuntu:24.04` container) — but that only fixes half the
problem; see §5.1.

Removing just the `visionOS` clause then exposes the *second* half of the problem at link
time:

```
Undefined symbols for architecture arm64:
  "___isPlatformVersionAtLeast", referenced from:
      ___ggml_metal_rsets_init_block_invoke in libggml-metal.a(ggml-metal-device.m.o)
```

`@available` lowers to a call into clang's darwin compiler runtime (`libclang_rt.osx.a`),
which osxcross does not install. So the Metal backend cannot use a *runtime* OS version
check at all in this toolchain, by either spelling.

### 3.3 What makes it build

Both errors live behind one upstream feature flag. `ggml-metal-device.m:17-22` enables
residency sets purely from **SDK** macros:

```c
// create residency sets only on macOS >= 15.0
#if !TARGET_CPU_X86_64 && TARGET_OS_OSX && __MAC_OS_X_VERSION_MAX_ALLOWED >= 150000 || ...
#define GGML_METAL_HAS_RESIDENCY_SETS 1
#endif
```

and all four macOS-15 sites are `#if defined(GGML_METAL_HAS_RESIDENCY_SETS)`. SDK 15.1
turns it on; the deployment target of 11.0 is then why the runtime check exists.
Neutralising that one `#define` is enough:

```bash
# in 48-whisper.sh, darwin/arm64 branch, before cmake:
f=ggml/src/ggml-metal/ggml-metal-device.m
grep -q '^#define GGML_METAL_HAS_RESIDENCY_SETS 1$' "$f" \
  || { log "Error: whisper ${whisper_version} residency-set guard not found in ${f}"; exit 1; }
sed -i 's|^#define GGML_METAL_HAS_RESIDENCY_SETS 1$|#undef GGML_METAL_HAS_RESIDENCY_SETS|' "$f"
```

**Measured result: `ggml-metal` builds, `whisper-cli` links, and `cmake --install`
succeeds** for darwin-arm64 from a clean `v1.9.1` clone with that single `sed` applied and
nothing else changed. The installed prefix contains

```
libggml-base.a 1021440   libggml-blas.a 20816   libggml-cpu.a 976000
libggml-metal.a 896544   libggml.a 40240        libwhisper.a 529392
```

so `-lggml-metal` in `whisper.pc` resolves against a real file, and `-lggml-blas` — which
darwin's `whisper.pc` branch already names — is still produced with Metal on.

The anchored-`grep`-then-`sed`-then-fail shape is copied from the existing mingw
`ggml-cpu.c` power-throttling patch in the same script, for the same reason: a whisper
bump that moves this line must break the build loudly, not silently re-enable a path that
cannot link.

**What that costs, reasoned from the source:** residency sets are a macOS 15+ memory
optimisation that keeps GPU buffers wired, and ggml already ships an off switch for them
(`getenv("GGML_METAL_NO_RESIDENCY")`), so "off" is a configuration upstream supports
rather than a mutilation. With the macro off, `ggml_metal_buffer_rset_init()` returns
`true` with `rset = nil`, `..._rset_free()` is a no-op, and the heartbeat block compiles
to an empty dispatch — i.e. exactly the path an older SDK would take. The
`use_residency_sets = true` default at line 827 then only reaches a log line and those
two no-ops. What Apple Silicon loses in practice is unmeasured, and needs the Mac.

---

## 4. Size cost (measured)

Same methodology as the CUDA findings doc (§4 there): `whisper-cli` from the pinned tag,
cross-built for darwin-arm64 both ways, stripped with the cross `strip`.

| build | stripped | delta |
|---|---|---|
| CPU only (today's darwin-arm64 config) | 2,193,144 B (2.09 MiB) | — |
| **+ Metal, embedded library** | **2,960,552 B (2.82 MiB)** | **+767,408 B (+0.73 MiB, +35 %)** |

Of which the embedded shader source is **609,531 bytes**, confirmed three ways: the
merged `ggml-metal-embed.metal` is 609,531 B; the `ggml-metal-embed.s.o` object is
610,048 B; and the linked binary's section header reads

```
sectname __ggml_metallib   segname __DATA   size 0x94cfb   (= 609,531)
```

The remaining ~158 KB is the backend's own code. `libggml-metal.a` is 900,512 B in total
(7 members). Running the two `sed`s from ggml's CMakeLists by hand on the pinned tag gives
the same 609,531 bytes, so the number is not an artefact of this toolchain.

**Against Vulkan: +0.73 MB vs +62 MB, about 80x cheaper**, because there is no compiled
shader archive — the binary carries shader *text*, and the user's machine compiles it.
(The Vulkan figure is this project's own: 2.67 → 65.75 MB stripped, reproduced
independently at +61.9 MB in the CUDA spike.)

**Reasoned, not measured:** the delta in the real ffmpeg binary should be the same
~767 KB, because it is one archive and one data section, and darwin's `LDFLAGS` uses
`-dead_strip_dylibs` (which prunes unused *dylibs*), not `-dead_strip`. It was not
verified against a real ffmpeg link. `rcodesign sign` on the stripped Metal binary
succeeds and adds 3,496 bytes (measured); whether macOS accepts that signature is §7.6.

---

## 5. What changes, concretely

### 5.1 `scripts/48-whisper.sh` — cmake args and the residency-set sed

Today, one line covers both arches:

```bash
if [[ ${TARGET_OS} == "darwin" ]]; then
    WHISPER_CMAKE_COMMON_ARG="${WHISPER_CMAKE_COMMON_ARG} -DGGML_METAL=OFF -DGGML_ACCELERATE=OFF"
    if [[ ${ARCH} == "x86_64" ]]; then
```

`GGML_METAL` becomes per-arch: `x86_64` keeps `-DGGML_METAL=OFF` (§8), and the arm64
branch gets `NM_METAL=1` plus

```bash
-DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON
```

and the residency-set `sed` from §3.3, guarded by its anchor. `GGML_METAL_EMBED_LIBRARY`
is passed explicitly even though ggml defaults it to `${GGML_METAL}`
(`ggml/CMakeLists.txt:242`, checked in the pinned tag): without the embed path cmake
shells out to `xcrun metal`, which osxcross has no answer for, so the whole phase rests
on this flag and it must not ride on an upstream default.

Nothing else in that branch changes — the fixed-instruction-level CPU build,
`NM_GGML_CPU_FIXED_NAME` and `NM_SKIP_VARIANTS` all stay as they are. Metal is an
additional backend; the CPU path is still what runs when there is no GPU.

**Why not a newer clang instead?** Because it fixes only the parse error. Measured: clang
20.1.8 (apt.llvm.org, in a throwaway `ubuntu:24.04` container) accepts a
`visionOS 2.0` availability clause that clang 18.1.3 rejects — but
`__isPlatformVersionAtLeast` is a compiler-*runtime* symbol, not a parser feature, so a
clang that parses `visionOS` still needs osxcross's `build_compiler_rt.sh` (present in the
checkout, unused today) to link it. That is two moving parts in the toolchain every darwin dependency is
built with — and the reward is a macOS 15 memory optimisation. The `sed` touches one
`#define` in one file and changes nothing for any other dependency. If someone later
wants residency sets back, `build_compiler_rt.sh` + a newer clang is the path, and it is
a task of its own with its own risk.

### 5.2 `scripts/48-whisper.sh` — frameworks and `whisper.pc`

Inside whisper's cmake the frameworks are already handled — `ggml-metal`'s own
`CMakeLists.txt` does `find_library` + `target_link_libraries`, and cmake propagates them
to in-tree consumers. Measured on the `whisper-cli` link line:
`... libggml-metal.a ../../ggml/src/libggml-base.a -lm -framework Foundation -framework
Metal -framework MetalKit`. It is ffmpeg's **out-of-tree** link that must be told, and
there are two ways:

1. **`whisper.pc`** — measured: `pkg-config 1.8.1` passes `-framework Foundation
   -framework Metal -framework MetalKit` through a `Libs:` line **unchanged and in
   order**, for both `--libs` and `--libs --static`. So the frameworks can live in the
   same generated file as `-lggml-metal`, which keeps the whole Metal decision inside
   `48-whisper.sh`.
2. **`ffmpeg-darwin-arm64.dockerfile`'s `ENV LDFLAGS`** — how every other framework here
   is done (VideoToolbox, OpenCL, Accelerate…), and harmless on a build that does not use
   them thanks to `-dead_strip_dylibs` (§2). There is also `add_ldflag` in
   `scripts/init/helpers.sh`, which appends to `/build/ldflags.txt` and reaches ffmpeg's
   link — a third route that needs no dockerfile edit at all.

Recommendation: **both** — `whisper.pc` because that is what ffmpeg's `pkg-config` check
consumes, and the dockerfile `LDFLAGS` because it is where a darwin framework is expected
to be found and it costs nothing. Pick one only if the phase-3 spec argues why.

And `whisper.pc`'s darwin branch grows the archive. Today:

```bash
elif [[ ${TARGET_OS} == "darwin" ]]; then
    lib_flags+=" -lggml-blas"
    lib_private_flags+=" -lz"
```

`-lggml-metal` must **not** be appended there. `lib_flags` is assembled left to right and
a static linker resolves left to right, so the Metal archive has to come *before* the CPU
archive (`-l${nm_cpu_lib}`) and be followed by one more `-lggml-base` pass — exactly what
`nm_vk_lib` / `nm_vk_trailer` already do for Vulkan. Reuse that machinery rather than
inventing a second one:

```bash
# beside the existing nm_vk_lib block
if [[ ${NM_METAL} == 1 ]]; then
    nm_gpu_lib="-lggml-metal "
    nm_gpu_trailer=" -lggml-base"
fi
```

`-lggml-blas` stays where it is (darwin keeps its BLAS backend; `GGML_BLAS` defaults ON
on Apple and the script already links it — the Metal configure log still says "Including
BLAS backend").

### 5.3 A build-time guard for the blob — because this repo has shipped checks that lie

The failure mode of an embedded-source design is a **valid build with an empty blob**: the
two `sed`s produce a zero-length `ggml-metal-embed.metal`, `.incbin` embeds nothing,
everything links, and the first user's Mac gets `newLibraryWithSource:` on an empty
string. That is the same shape as the Vulkan shader-blob bug this script already guards
against (`nm_vk_blobs`, "0 missing on a good build, 3710 missing on the broken
linux-aarch64 one"), and it deserves the same treatment: assert the blob's *size*, since
`${NM}` on Mach-O does not list the `.incbin` symbols usefully (measured: it printed
nothing for `_ggml_metallib_start`). The cheap, honest check is on the generated file and
the object:

```bash
embed=$(find build -name ggml-metal-embed.metal | head -1)
[[ -s ${embed} ]] && (( $(wc -c < "${embed}") > 400000 )) \
  || { log "Error: the embedded Metal shader source is missing or truncated"; exit 1; }
```

(609,531 B on a good build of this pin; the 400 KB floor is slack for future bumps.)

### 5.4 `tests/lib/cpu-variant.sh` + `.ps1` — or the smoke test keeps lying

`vulkan_platform_has_backend()` returns false for `*darwin*`, and `smoke.sh` prints
*"vulkan: skipped on darwin — it carries no Vulkan by design (darwin gets Metal in a
later phase…)"*. Ship Metal without touching this and darwin's GPU backend is asserted by
nothing at all. The Metal assertion is greppable exactly like the Vulkan one, and on
darwin it is *stronger*, because the shader source is in the binary. Measured on the
linked binary (matching lines, metal vs cpu):

| marker | metal | cpu |
|---|---|---|
| `kernel void kernel_mul_mm` (the MSL source itself) | 4 | 0 |
| `using embedded metal library` (the log line only the embed path has) | 1 | 0 |
| `MTLCreateSystemDefaultDevice` | 2 | 0 |

A `metal_backend_compiled_in()` requiring the first two is enough, and it works on a host
that cannot execute the binary.

### 5.5 What does NOT change — and this is the useful part

`scripts/includes/ggml_cpu_dispatch.c`, `af_whisper.c` and `af_stemsplit.c` need **no
change** (reasoned, from reading all three), with one cosmetic exception below:

- `nm_vk_scan()` walks `ggml_backend_dev_count()` / `..._dev_get()` and accepts
  `GGML_BACKEND_DEVICE_TYPE_GPU` and `..._IGPU`; `ggml-metal.cpp:667` returns
  `..._TYPE_GPU`, so the device is found with no new code.
- `nm_ggml_backend_init(use_gpu, gpu_device)`, the CPU fallback, `NOMERCY_GGML_GPU=0` and
  the filters' `use_gpu` / `gpu_device` options are all backend-agnostic.
- `nm_device_is_software()`'s markers are `llvmpipe / swiftshader / lavapipe / softpipe /
  "software rasteri(s|z)er"`. No Apple GPU name contains any of them.
- The fork-and-probe ICD guard is already `#if !defined(_WIN32) && !defined(__APPLE__) &&
  !defined(NM_NO_VULKAN)`, so it stays compiled out. `NM_NO_VULKAN=1` should **stay** set
  on darwin: it is about Vulkan, not about GPUs.
- ggml registers the backend itself in a static build
  (`ggml/src/ggml-backend-reg.cpp:119`, `#ifdef GGML_USE_METAL
  register_backend(ggml_backend_metal_reg())`) — the same mechanism Vulkan relies on. The
  `whisper-cli` compile line confirms `-DGGML_USE_METAL` is set project-wide.

**The cosmetic exception: the metadata will say `mtl`, not `metal`.**
`nm_backend_discover()` lower-cases `ggml_backend_reg_name()`, and ggml's Metal registry
name is `GGML_METAL_NAME`, defined as **`"MTL"`** (`ggml-metal.cpp:13`) — not `"Metal"`.
So `lavfi.whisper.backend` / `lavfi.stemsplit.backend` and the log line would read `mtl`,
and `nm_ggml_backend_device()` would return the device's own name (`"MTL0"`'s
description, e.g. "Apple M4 Pro"). Phase 3 must either accept `mtl` in the metadata
contract or fold it to `metal` in `nm_backend_discover()` — a three-line change next to
the existing comment that already explains folding ggml's `"Vulkan"`.

---

## 6. The consequence phase 3 must design for: *when* the shaders are compiled

Reasoned from the pinned sources, not measured — and the most important thing in this
document after "it builds".

`ggml_backend_metal_reg()` builds its devices **eagerly, at registry construction**:
`ggml_backend_metal_device_init()` → `ggml_metal_device_get()` → `ggml_metal_device_init()`,
which ends at `ggml-metal-device.m:861` with `dev->library = ggml_metal_library_init(dev)`
— the `newLibraryWithSource:` call on the 609 KB of embedded MSL. The result is cached on
the device and reused by the context (`ggml-metal-context.m:113`), so it is once per
process, not per filter. ggml logs it (`"using embedded metal library"`, then
`"loaded in %.3f sec"`), which is also how the Mac measurement in §7.2 should be read.

But "once per process" lands *earlier than `use_gpu` is consulted*:

1. This project funnels every path to ggml's registry through `nm_ggml_gpu_usable()`.
   `af_whisper.c` calls it unconditionally, on its own line, before
   `ggml_backend_load_all()` — deliberately, so the Vulkan guard cannot be
   short-circuited away. On darwin that first registry call is what compiles the shaders.
   So **every `ffmpeg` run that instantiates `whisper` or `stemsplit` on macOS pays the
   compile, including with `use_gpu=0`** — and the owner runs `stemsplit` with
   `use_gpu=0` today.
2. `NOMERCY_GGML_GPU=0` is checked *inside* `nm_backend_discover()`, after
   `nm_vk_make_safe()`. **Correction, 2026-09-28: the claim that followed here was
   wrong.** It said the off switch "does not buy the time back either", but the
   `getenv` block `return`s *before* `nm_vk_scan()`, so our own code does not construct
   the registry on that path at all. For **stemsplit** the switch does buy the time back,
   because `ggml_backend_cpu_init()` never reaches `get_reg()` either (verified in
   `.superpowers/sdd/2026-09-27-metal-backend/registry-construction-findings.md`). For
   **whisper** it does not, but for a different reason than this paragraph gave:
   `whisper_backend_init()` walks `ggml_backend_dev_count()` itself at `whisper.cpp:1339`,
   ungated by `params.use_gpu`.
3. On darwin, `nm_vk_scan(&n, !verified)` also runs with `verified = 0` (the
   `NM_VK_ICD_GUARD` block that sets it to 1 is compiled out under `__APPLE__`), so
   discovery additionally calls `ggml_backend_dev_init()` to prove device 0 opens. Cheap
   next to the compile — the library is already cached by then — but it is a second Metal
   object graph per process.

If "macOS users who do not want the GPU must not pay for it" is a requirement, the
levers that exist without patching ggml are *don't link Metal at all*, *accept the cost*,
or — found later, and not known when this was written — ggml's own
`GGML_METAL_DEVICES=0`, which is process-wide and latches on first use
(`ggml-metal.cpp:914-916`). **The owner's decision on 2026-09-28 was to accept the cost**
and to measure it before considering anything else. Phase 3 should say which, and the number that decides it is one subtraction on the
owner's Mac: `ffmpeg -version` (never builds a filtergraph, so never touches the registry)
against a one-second `stemsplit` run with `use_gpu=0`.

---

## 7. What cannot be verified here

There is no Apple hardware in this environment, and these arm64 binaries cannot run on
this host at all. **No line of Metal code in this spike was ever executed.**

**Build-time facts — established here, no Mac needed:**

1. `Foundation`, `Metal`, `MetalKit` (and MPS) are present in `MacOSX15.1.sdk` with
   headers and `.tbd` stubs (§2).
2. osxcross clang 18.1.3 compiles `.m` with today's `CFLAGS` and links against those
   stubs once the three frameworks are named (§2).
3. `GGML_METAL_EMBED_LIBRARY=ON` needs no Apple shader compiler: two `sed`s, six lines of
   assembler, `.incbin` (§3.1).
4. ggml's `visionOS` `@available` clauses cannot be compiled *or* linked by this
   toolchain, and one anchored `sed` on `GGML_METAL_HAS_RESIDENCY_SETS` fixes both (§3.2,
   §3.3).
5. `libggml-metal.a` builds and `whisper-cli` links for darwin-arm64; the archive keeps
   its `lib` prefix, so no windows-style rename is needed (§3).
6. The size cost is +767,408 B, of which 609,531 B is the embedded source, confirmed by
   the `__DATA,__ggml_metallib` section header (§4).
7. `pkg-config` passes `-framework` flags through a `.pc` `Libs:` line intact (§5.2).
8. The selection layer, the filters and the ICD guard need no changes; the metadata string
   will be `mtl` (§5.5).

**Runtime claims — these need the owner's Apple Silicon Mac, and phase 3 must not assert
any of them before then:**

1. **That the embedded MSL actually compiles.** Nothing in this pipeline runs a Metal
   compiler — that is the point of the embed path. The 595 KiB in the binary is *text*,
   and the first thing that ever parses it is `newLibraryWithSource:` on the user's
   machine. It is the pinned upstream source that upstream's own macOS builds compile, so
   the risk is low, but "it built" says nothing about it.
2. **First-use compile time**, and whether repeat runs hit Apple's compiler cache. Per §6
   this is not a nice-to-have: it decides whether Metal can be on by default for CPU-only
   macOS users. ggml prints `loaded in %.3f sec` itself.
3. **That a device is selected at all** — `MTLCreateSystemDefaultDevice()` returning
   non-nil in the context the media server actually runs in (a launchd daemon or an SSH
   session, not a logged-in GUI app). If it returns nil, `dev->library` is never built,
   `ggml_backend_dev_init()` fails, `nm_vk_scan()` reports `NM_VK_NO_GPU`, and the CPU
   path runs. That fallback is reasoned from the code and looks safe; it has not been
   seen.
4. **That output matches the CPU path** — identical transcript for `whisper`, identical
   stem checksums for `stemsplit`, CPU vs Metal, same input. A backend that is fast
   because it did nothing is this repo's recurring failure mode.
5. **That it is faster than the CPU path at all.** No speedup is claimed in this
   document. Apple Silicon's CPU backend here is NEON + fp16 + dotprod at a fixed
   instruction level, which is not a weak baseline, and the CUDA spike is a standing
   reminder that a GPU backend can lose.
6. **That the stripped, `rcodesign`-signed binary still launches.** `package.sh` strips
   and then re-signs because strip invalidates ld64's signature; `rcodesign sign`
   succeeded here on the Metal binary, but only macOS can say whether the kernel accepts
   it.
7. **What dropping residency sets costs** (§3.3) — reasoned to be a macOS 15+ memory
   optimisation with an upstream off switch, measured by nobody.
8. **The `gpu_device` index and multi-GPU behaviour** on a Mac with an eGPU or more than
   one Metal device.

---

## 8. darwin-x86_64

**Nearly free to *build*, not nearly free to *ship*. Keep it off, and make it its own
decision with its own evidence.**

- Build-wise it genuinely is the same one flag plus the same `sed`: same SDK 15.1, same
  frameworks, same osxcross clang, same embed step. No second toolchain problem.
- **The deployment target is worse than §9.2 assumed.** The design says 10.15;
  `ffmpeg-darwin-x86_64.dockerfile` says `MACOSX_DEPLOYMENT_TARGET=10.13.0`, and it is
  `48-whisper.sh` that raises *just the whisper subtree* to 10.15. So ggml objects are
  already built to a newer floor than the binary they land in.
  `-[MTLDevice supportsFamily:]` and `hasUnifiedMemory`, both used unguarded in
  `ggml-metal-device.m`, are 10.15 APIs: fine in a 10.15 subtree, not fine for a binary
  that advertises 10.13. Enabling Metal here means accepting that split or moving the real
  floor — the thing §9.2 refused to do. (Note the residency-set `#if` starts with
  `!TARGET_CPU_X86_64`, so the §3.2 blocker never fires on Intel — which is exactly why
  nobody would notice the deployment-target split until a user did.)
- **The hardware is the part that cannot be reasoned about.** Intel Macs mean Intel iGPUs
  and AMD discrete GPUs. `has_simdgroup_reduction` is `supportsFamily:Apple7 ||
  supportsFamily:Metal3` and `has_simdgroup_mm` is Apple7 only — both false across most
  of that population, so what ggml would run there are its slow paths. A Metal backend
  that is *slower* than the AVX/F16C CPU build it displaced, on the oldest machines this
  project deliberately protects, is a regression wearing an acceleration badge.
- And it is the one population the owner cannot test: an Apple Silicon Mac proves nothing
  about a 2015 iMac's Iris Pro.

If Intel Macs are wanted later, the honest order is: measure arm64 first, then get one
before/after number from an Intel-Mac user. The build change will still be one flag then.

---

## 9. Recommended next step, stated as a recommendation

1. **Write the phase-3 spec for darwin-arm64 only**, with the §3.3 `sed` (anchored,
   fail-loud) and the §5.3 blob guard in it from the start, and with §6 answered — does a
   macOS CPU-only run pay for shader compilation, yes or no, and if yes, is that
   acceptable?
2. **Build one RC** and hand the owner four measurements, all on his Mac: first-use
   compile time (`loaded in … sec`), the `ffmpeg -version` vs `use_gpu=0` subtraction from
   §6, whisper transcript and stemsplit checksums CPU vs Metal, and the CPU-vs-Metal
   wall-clock on a real job.
3. **Do not ship it on §3's evidence alone.** "It builds and it is 767 KB" is a green
   light for the spec, not for a release. The four numbers above are the release gate, and
   two of them (identity of output, and whether it is faster at all) could still make the
   answer "no".
4. **Leave darwin-x86_64 alone** (§8), and leave `NM_NO_VULKAN=1` set on both darwin
   targets.

What would flip the recommendation: the MSL failing to compile on a real device, Metal
being no faster than the fixed-level NEON CPU build, or the §6 compile cost landing on
CPU-only users at a size they notice.

---

## 10. Reproducing this

Nothing was committed to the repo besides this file. The harness, for whoever revisits it:

```
# Dockerfile = the first 157 lines of ffmpeg-darwin-arm64.dockerfile, VERBATIM, then:
COPY spike1.sh /spike1.sh          # SDK framework probe + .m compile/link probe
RUN  bash /spike1.sh
# then, inside a container from that image:
git clone --depth 1 --branch v1.9.1 https://github.com/ggml-org/whisper.cpp /build/whisper
sed -i 's|^#define GGML_METAL_HAS_RESIDENCY_SETS 1$|#undef GGML_METAL_HAS_RESIDENCY_SETS|' \
    /build/whisper/ggml/src/ggml-metal/ggml-metal-device.m
cmake -S /build/whisper -B /build/b2 ${CMAKE_COMMON_ARG} \
      -DWHISPER_BUILD_EXAMPLES=ON -DWHISPER_SDL2=OFF -DGGML_ACCELERATE=OFF \
      -DGGML_CPU_ARM_ARCH=armv8.4-a+dotprod+fp16 \
      -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON
cmake --build /build/b2 -j"$(nproc)" --target whisper-cli   # repeat with GGML_METAL=OFF
```

Copy the dockerfile prefix; do not rewrite it. The ENV ordering around osxcross's
`build.sh` is load-bearing (§1). `whisper-cli` lives in `examples/cli`, so it needs
`WHISPER_BUILD_EXAMPLES=ON`, not `WHISPER_BUILD_TOOLS=ON`.

The embedded-blob size is reproducible without docker, from the two `sed` commands in
`ggml/src/ggml-metal/CMakeLists.txt`:

```sh
sed -e "/__embed_ggml-common.h__/r ../ggml-common.h" -e "/__embed_ggml-common.h__/d" \
    < ggml-metal.metal > tmp
sed -e '/#include "ggml-metal-impl.h"/r ggml-metal-impl.h' \
    -e '/#include "ggml-metal-impl.h"/d' < tmp | wc -c     # 609531
```
