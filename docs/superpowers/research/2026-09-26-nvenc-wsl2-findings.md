# Issue #42 — one linux-x86_64 ffmpeg that does NVENC everywhere: research findings

Date: 2026-09-26. Research only: no repo code was changed and nothing was committed to `dev`.
Everything ran in throwaway containers and a scratch directory.

**How to read this.** Claims are labelled *measured* or *reasoned*. Measured means a command ran
in this session and its output is quoted. Reasoned means it follows from a measured fact but was
not itself executed.

**What was built.** A full 67-component stack was built from `origin/dev` (`56a9644`) inside the
unchanged base image `nomercyentertainment/ffmpeg-base:latest`
(`nvidia/cuda:12.9.1-devel-ubuntu24.04`, `gcc (Ubuntu 13.3.0-6ubuntu2~24.04) 13.3.0`,
`ldd (Ubuntu GLIBC 2.39-0ubuntu8.9) 2.39`), then ffmpeg was linked from that prefix twice —
once with the minimal change, once with the proposed fix. This was the only way to get a
trustworthy floor: the reduced-scope experiments understated it by a full glibc release, and the
real build surfaced four problems no smaller experiment showed.

---

## 0. The question, restated

Produce **one** `linux-x86_64` artifact that:

* is a **dynamically linked executable** (so the WSL2 libcuda shim's second-stage load succeeds —
  cause already settled, not re-derived here),
* keeps **all ~60 third-party libraries statically linked**, with **no runtime dependency beyond
  glibc**,
* has a glibc floor low enough to be a non-issue,
* builds **inside the existing base image**, unchanged.

---

## 1. What makes today's binary static, and the minimal change

### 1.1 Where the `-static` comes from — measured

The 67 component scripts never pass `-static`. `scripts/init/init.sh`, `scripts/init/helpers.sh`
and every `scripts/NN-*.sh` build their library with `--enable-static --disable-shared`, which
only controls whether **that library** produces a `.a` or a `.so`.
`git grep -n -- '-static\b' origin/dev -- scripts/` returns only `--enable-static`,
`--disable-shared` and zlib's `--static` *configure* options — nothing that reaches `LDFLAGS`.

The fully static **executable** comes from exactly two places, both in
`ffmpeg-linux-x86_64.dockerfile`, in the `RUN` that configures ffmpeg:

```
    --extra-cflags="-static -static-libgcc -static-libstdc++" \
    --extra-ldflags="-static -static-libgcc -static-libstdc++" \
```

The container-level `ENV CFLAGS/CXXFLAGS/LDFLAGS` carry `-static-libgcc -static-libstdc++` but
**not** `-static`.

### 1.2 The minimal change

Delete the bare `-static` from those two lines:

```
    --extra-cflags="-static-libgcc -static-libstdc++" \
    --extra-ldflags="-static-libgcc -static-libstdc++" \
```

Third-party libraries stay static because `${PREFIX}/lib` holds `.a` files — with one exception
found below. `--pkg-config-flags=--static` stays as is.

### 1.3 What the minimal change actually produces — measured on the full build

That change alone does **not** produce a working artifact. Three separate things go wrong, all
measured on the real 67-component prefix:

**(i) The link fails outright.** `-static` implies non-PIE; without it gcc defaults to `-pie`,
and one of our own static libraries cannot go into a PIE:

```
/usr/bin/ld: /ffmpeg_build/linux/lib/libdavs2.a(blockcopy8.o): relocation R_X86_64_32S
  against hidden symbol `davs2_pb_1' can not be used when making a PIE object
/usr/bin/ld: failed to set dynamic section sizes: bad value
ERROR: davs2 >= 1.6.0 not found using pkg-config
```

libdavs2's hand-written x86 assembly is not PIC-clean. The fix used here is **`-no-pie` in
`--extra-ldflags`** — one word, costing the main executable's ASLR (shared libraries, heap and
stack are still randomised; `relro`, `now`, stack-protector and `_FORTIFY_SOURCE` are untouched).
This is *not* the rejected "disable SIMD" trade: no assembly is turned off. The alternative is
upstream work in libdavs2.

**(ii) With `-no-pie` it links, and the floor is GLIBC_2.39** — measured:

```
/root/ffmpeg-dyn: ELF 64-bit LSB executable, x86-64, dynamically linked,
  interpreter /lib64/ld-linux-x86-64.so.2      size = 278,005,024
  floor  = GLIBC_2.39
  NEEDED = libm.so.6 libXau.so.6 libXdmcp.so.6 libomnidrive.so libc.so.6
           ld-linux-x86-64.so.2 libmvec.so.1 libgomp.so.1
  above 2.34:
    pidfd_getpid@2.39  pidfd_spawnp@2.39
    __isoc23_{fscanf,sscanf,strtol,strtoll,strtoll_l,strtoul,strtoull,strtoull_l,vsscanf}@2.38
    fmod@2.38  fmodf@2.38  strlcat@2.38  strlcpy@2.38
    arc4random@2.36
    _dl_find_object@2.35  hypot@2.35  hypotf@2.35
    _ZGVbN2v_log2@2.35  _ZGVbN2vv_atan2@2.35
```

2.39 is the build image's own glibc — i.e. the minimal change produces an artifact that runs
**only** on Ubuntu 24.04-class hosts. It would not start in the media-server's Debian 12
container.

**(iii) Five unwanted shared dependencies appear.** In a dynamic link the linker prefers a
system `.so` over a static archive whenever both are visible:

| NEEDED entry | why | fix |
|---|---|---|
| `libomnidrive.so` | `scripts/56-omnidrive.sh` installs **both** `libomnidrive.a` and `libomnidrive.so` into `${PREFIX}/lib`; `-lomnidrive` picked the `.so` | stop installing the `.so` (or delete it after install) |
| `libgomp.so.1` | `libggml-base.a` / `libggml-cpu-variants.a` reference `GOMP_*`; only the shared libgomp is on the search path | stage `libgomp.a` into `${PREFIX}/lib` so `-lgomp` finds it first |
| `libXau.so.6`, `libXdmcp.so.6` | `libxcb.a` references `XdmcpWrap` etc.; only the `.so` was reachable | stage `libXau.a` / `libXdmcp.a` into `${PREFIX}/lib` (both exist in the image) |
| `libmvec.so.1` | `libm.so` is a linker script that pulls in libmvec when vector-math symbols are used | **acceptable** — libmvec is part of glibc itself and was verified present on debian:11, debian:12, ubuntu:22.04 and almalinux:9 |

Earlier, on a reduced build, `libxcb.so.1` and `libz.so.1` crept in the same way and the binary
died in `debian:bookworm-slim` with
`error while loading shared libraries: libxcb.so.1` — before any glibc check was reached. So this
class of regression is real and silent. A **link guard** is required (§4c).

---

## 2. Which glibc symbols force the floor, and who references them

### 2.1 Our own C code is not the problem — measured

A C program using `strtol`, `strtoul`, `sscanf`, `strtod`, `dlopen`, `pow`, compiled with the
project's exact flags on the base image:

```
C-only floor = GLIBC_2.34; the only symbol at that level is __libc_start_main@GLIBC_2.34
```

`__isoc23_*` do **not** appear. `features.h` leaves `__GLIBC_USE_ISOC2X` at 0 unless
`_ISOC2X_SOURCE` / `_GNU_SOURCE` / `-std=c2x` is requested. Cross-checked with `-std=gnu17` —
identical.

### 2.2 The floor is set by prebuilt archives and by third-party components — measured

Scanning every `.a` in `${PREFIX}/lib` plus GCC 13's own archives for each offending symbol:

| symbol | version | referenced by |
|---|---|---|
| `pidfd_spawnp`, `pidfd_getpid` | **2.39** | `librsvg-2.a` (glib's `gspawn` on glibc ≥ 2.39) |
| `__isoc23_strtol` | 2.38 | 38 archives — SDL2, X11, ass, cairo, crypto, drm, fontconfig, freetype, gcrypt, **ggml-base, ggml-cpu-variants, ggml-vulkan**, glib, glslang, harfbuzz, mp3lame, pango, rsvg, shaderc, srt, tesseract, vmaf, vpl, x264, **x265**, xavs2, zvbi … |
| `__isoc23_sscanf` | 2.38 | X11, ass, cairo, drm, fontconfig, gio, pciaccess, placebo, rsvg, srt, tesseract, va, vmaf, x264 |
| `__isoc23_fscanf`, `__isoc23_vsscanf`, `__isoc23_strtoll_l`, `__isoc23_strtoull_l`, `__isoc23_strtoul`, `__isoc23_strtoll`, `__isoc23_strtoull` | 2.38 | SDL2, drm, glib, rsvg, and GCC's `libstdc++.a` (`eh_alloc.o`, `debug.o`) |
| `strlcpy`, `strlcat` | 2.38 | `libSDL2.a`, `libglib-2.0.a`, `librsvg-2.a` |
| `fmod` | 2.38 | SDL2, cairo, rsvg, tesseract, xml2, and the CUDA static libs (`libcublasLt_static.a`, `libnvrtc_static.a`, `libcupti_static.a`, `libnvJitLink_static.a`, `libnvperf_host_static.a`) |
| `fmodf` | 2.38 | SDL2, harfbuzz-raster, rsvg, tesseract |
| `arc4random` | 2.36 | GCC's `libstdc++.a` (`random.o`) |
| `hypot`, `hypotf` | 2.35 | cairo, harfbuzz, rsvg **and 16 + 12 ffmpeg objects of our own** |
| `_dl_find_object` | 2.35 | GCC's `libgcc_eh.a` — **strong** undefined (`nm` prints `U`, not `w`), the C++ unwinder's FDE lookup |
| `_ZGVbN2v_log2`, `_ZGVbN2vv_atan2` | 2.35 | `libx265.a` (libmvec vector math) |
| `pthread_*`, `__libc_single_threaded`, `stat/lstat/fstat64` | 2.34 / 2.32 / 2.33 | GCC's `libstdc++.a` |
| `__libc_start_main` | 2.34 | the image's `crt1.o` |

The important structural point: archive members carry **unversioned** undefined symbols, so the
version is chosen at link time from the build image's `libc.so.6` defaults. That is why the floor
tracks the build image, and why no compile flag applied to *our* sources can move it.

### 2.3 The floor ladder — measured

Verified with real links, each binary executed afterwards:

| what is done | floor | what sets the new floor |
|---|---|---|
| minimal change only | **2.39** | `pidfd_spawnp` (librsvg) |
| + `pidfd_*`, `strlc*`, `__isoc23_*`, `fmod*` handled | **2.36** | `arc4random` (libstdc++.a) |
| + `arc4random`, `arc4random_buf` | **2.35** | `_dl_find_object` (libgcc_eh.a), `hypot`, libmvec pair |
| + **null stub** for `_dl_find_object` | 2.34 | — but **aborts on the first throw** (measured: `Aborted (core dumped)`) |
| + **real `_dl_find_object`** over `dl_iterate_phdr`, `hypot*`, libmvec pair | **2.34** | `__libc_start_main` (crt1.o), `pthread_*` (libstdc++.a) |
| below 2.34 | — | needs different startfiles **and** version-forcing ~10 `pthread_*` references that live in a prebuilt archive: a different toolchain, not a flag |

The null-stub row matters: it is the obvious thing to try, it links, it lowers the number, and it
silently breaks C++ exception handling. The working version reimplements what libgcc itself did
before glibc 2.35 — walk `dl_iterate_phdr`, take the `PT_LOAD` span and the `PT_GNU_EH_FRAME`
address. Measured: 1001 throws caught, including one from a second thread.

`-shared-libgcc` instead of `-static-libgcc` also reaches 2.34 with exceptions intact (measured),
but adds `libgcc_s.so.1` to `NEEDED` — ruled out by the constraints.

**2.34 is a hard wall on this toolchain**: `__libc_start_main@2.34` comes from the image's
`crt1.o` and the `pthread_*@2.34` set from `libstdc++.a`, both prebuilt.

---

## 3. The three routes the brief asked about — each with a real build

### 3.1 `.symver` header (`glibc_version_header` or equivalent) — does not work here

`force_link_glibc_2.17.h` (3727 lines) applied with `-include` to the C and C++ tests on the
unchanged base image:

```
C   floor = GLIBC_2.34  (only __libc_start_main@2.34)   -- unchanged
C++ floor = GLIBC_2.38                                   -- unchanged
      still requires __isoc23_strtol/strtoul, arc4random, _dl_find_object,
      pthread_*@2.34, fstat64@2.33 …
```

It rewrites references emitted by the translation units it is included into. Almost everything
that sets this build's floor comes from archives that are not recompiled. **It buys nothing on
its own.** The *technique* is still needed, but applied inside our own compat object, where a
`.symver` on an undefined alias lets one definition capture every reference in the link (§4a).

Maintenance note: upstream publishes only some versions — `2.28` and `2.31` both returned 404
during this test; `2.17` exists.

### 3.2 `zig cc --target x86_64-linux-gnu.<ver>` — works technically, largest blast radius

Zig 0.15.2, same two test programs:

| target | C floor | C++ floor | runs? |
|---|---|---|---|
| `x86_64-linux-gnu.2.17` | **2.2.5** | **2.16** | yes, exceptions caught |
| `x86_64-linux-gnu.2.28` | **2.2.5** | **2.27** | yes |
| `x86_64-linux-gnu.2.31` | **2.2.5** | **2.27** | yes |

Best floor by far, and real. The costs:

* `zig c++` links **libc++**, not libstdc++. `-static-libstdc++` and `-static-libgcc` are
  *silently ignored* (`zig: warning: argument unused during compilation`). Every C++ component
  (x265, libvmaf, chromaprint, tesseract, whisper/ggml, shaderc, spirv-cross, libplacebo) would
  have to be rebuilt with `zig c++` **consistently** — mixing a gcc-built `.a` with a libc++ link
  is an ABI mismatch, not a warning.
* It replaces `CC`/`CXX` for all 67 scripts (autotools, cmake, meson, cargo) plus `ar`/`ranlib`.
* `scripts/44-cuda.sh` enables `--enable-cuda-nvcc`; nvcc with a clang-in-zig host compiler was
  **not** validated (§8).
* A pinned ~350 MB toolchain in the image, and a new upgrade treadmill.

Verdict: the only route below 2.34, and the only one requiring re-validation of all 67
components. Not proportionate to the gap it closes (§6).

### 3.3 Old glibc sysroot installed into the existing image — collapses into the shim anyway

Test image: `ubuntu:20.04` glibc (verified in the sysroot,
`GNU C Library (Ubuntu GLIBC 2.31-0ubuntu9.18) … version 2.31`) staged into `/opt/sr` inside the
unchanged `ubuntu:24.04` + gcc-13 environment.

* **`--sysroot=/opt/sr` alone does nothing.** Measured: C floor still 2.34, C++ still 2.38 — gcc
  kept using host headers and host libc. A knob whose "on" position silently does nothing is
  itself a hazard.
* **Explicit `-nostdinc -isystem … -B … -L …` without `--sysroot`**:
  `undefined reference to __libc_csu_init / __libc_csu_fini` — the sysroot's `libc.so` linker
  script names absolute paths that resolve back to the host libc.
* **Both together** finally link against the old glibc, and the cost list appears:

```
undefined reference to `__isoc23_strtoul'        (2.38, libstdc++.a)
undefined reference to `arc4random'              (2.36, libstdc++.a)
undefined reference to `_dl_find_object'         (2.35, libgcc_eh.a)
undefined reference to `__libc_single_threaded'  (2.32, libstdc++.a)
undefined reference to `pthread_create/join/detach/once'  (pre-2.34: libpthread)
undefined reference to `dlopen'                  (pre-2.34: libdl)
```

Adding the same `__isoc23_*` + `arc4random` shims cleared the first two. The rest is structural:
gcc 13's `libstdc++.a` / `libgcc_eh.a` were built against glibc 2.39. A 2.31 sysroot therefore
needs **the same compat object as §4, plus** `__libc_single_threaded` (a *data* symbol — getting
it wrong changes libstdc++'s threading fast paths), **plus** a real `_dl_find_object`, **plus**
restoring `-ldl -lpthread -lrt` to the link line of all 67 component builds.

Verdict: buys nothing the compat object does not already buy, and costs a sysroot in the image,
include/lib plumbing through 67 build systems, and a correctness footgun. Rejected on evidence.

---

## 4. The recommended mechanism, concretely

### (a) One compat object, `nmcompat.c` (~120 lines)

Compiled once with `gcc -O2 -fPIC -fvisibility=hidden -fno-builtin -c` and appended to ffmpeg's
`--extra-libs`. A `.o` (not a `.a`) contributes all its definitions unconditionally, so link
order does not matter and it satisfies references from `libstdc++.a`, `libgcc_eh.a` and every
component archive alike. It defines:

* `__isoc23_strtol/strtoul/strtoll/strtoull/strtoll_l/strtoull_l`,
  `__isoc23_sscanf/fscanf/scanf/vsscanf/vfscanf/vscanf` — thin forwards;
* `strlcpy`, `strlcat` — 8-line BSD implementations;
* `arc4random`, `arc4random_buf` — `/dev/urandom` with a `rand()` fallback;
* `_dl_find_object` — the `dl_iterate_phdr` reimplementation;
* `_ZGVbN2v_log2`, `_ZGVbN2vv_atan2` — scalar loops over a `vector_size(16)` double pair;
* `pidfd_spawnp` (`posix_spawnp` + `SYS_pidfd_open`) and `pidfd_getpid`
  (reads `Pid:` from `/proc/self/fdinfo/<fd>`);
* `hypot`, `hypotf`, `fmod`, `fmodf` — forwards through a `.symver`'d undefined alias:

```c
__asm__(".symver __nm_hypot_old, hypot@GLIBC_2.2.5");
extern double __nm_hypot_old(double, double);
double hypot(double x, double y){ return __nm_hypot_old(x,y); }
```

This is the one place the `.symver` technique earns its keep: it lets a single definition in the
executable capture *every* reference in the link, including the ones from prebuilt archives that
§3.1 could not touch.

### Two traps that this file walks into if written naively

**1. `_GNU_SOURCE` turns the shim into an infinite loop.** `_GNU_SOURCE` implies
`_ISOC2X_SOURCE`, so inside `nmcompat.c` a plain call to `strtoul()` or `vsscanf()` is rewritten
by the headers into a call to `__isoc23_strtoul()` / `__isoc23_vsscanf()` — the function being
defined. It links cleanly and hangs the process the first time the symbol is actually reached.
Measured, on the real artifact: `ffmpeg -version` produced no output and never exited; `strace`
showed the last syscall was `brk` and then nothing; gdb on the unstripped `ffmpeg_g` gave

```
#0  __isoc23_vsscanf ()
#1  __isoc23_sscanf ()
#2  _GLOBAL__sub_I_socketconfig.cpp ()
#3  __libc_start_main ()
```

The fix is to name the real entry points with asm labels:

```c
extern unsigned long int nm_strtoul(const char*, char**, int) __asm__("strtoul");
unsigned long int __isoc23_strtoul(const char *p, char **e, int b){ return nm_strtoul(p,e,b); }
```

The general lesson: **a compat shim must be exercised at runtime, not merely linked.** A tiny
self-test program that calls every shimmed symbol once and prints its result caught this in
seconds and belongs in the build.

**2. Visibility.** Built without `-fvisibility=hidden`, all the shim symbols land in the
executable's `.dynsym` (measured). ffmpeg `dlopen`s `libcuda.so.1`, `libnvidia-encode.so.1`, the
OpenCL and Vulkan loaders; an exported `_dl_find_object` or `arc4random` would **interpose** on
those libraries' own calls — the NVIDIA driver's unwinder would silently start using our
`dl_iterate_phdr` reimplementation. With `-fvisibility=hidden` the static-link references still
resolve and nothing is exported (measured: `objdump -T` finds none of them).

Note when iterating: forcing a relink needs `rm -f ffmpeg ffmpeg_g` — deleting only `ffmpeg`
re-strips the stale `ffmpeg_g` and hides the change.

### (b) Make the four stray `.so` dependencies unreachable

* stop installing `libomnidrive.so` (`scripts/56-omnidrive.sh`),
* stage `libgomp.a`, `libXau.a`, `libXdmcp.a` into `${PREFIX}/lib` so `-lgomp`, `-lXau`,
  `-lXdmcp` resolve to archives (all three exist in the image).

`libmvec.so.1` stays and is fine: it ships with glibc (verified present on debian:11, debian:12,
ubuntu:22.04, almalinux:9) and its only remaining reference is `_ZGVbN2v_log@GLIBC_2.22`, well
below the floor.

### (c) `-no-pie` in `--extra-ldflags`

Required by libdavs2 (§1.3). State the ASLR trade explicitly in the spec.

### (d) A link guard in the dockerfile, right after `make`

```sh
floor=$(objdump -T ${PREFIX}/bin/ffmpeg | grep -oE 'GLIBC_[0-9.]+' | sort -V -u | tail -1)
[ "$floor" = "GLIBC_2.34" ] || { echo "glibc floor moved to $floor"; exit 1; }

objdump -p ${PREFIX}/bin/ffmpeg | awk '/NEEDED/{print $2}' \
  | grep -vE '^(libc|libm|libmvec|libdl|libpthread|librt)\.so|^ld-linux' \
  && { echo "unexpected shared dependency"; exit 1; }

${PREFIX}/bin/ffmpeg -hide_banner -version >/dev/null   # catches the recursion trap
```

Pinning to an exact floor string is deliberate: a floor that moves in *either* direction means
something changed. Without this guard the floor silently follows the base image's glibc on the
next image rebuild, and a stray `.so` can reappear from any component upgrade.

---

## 5. End-to-end demonstration — measured, on the real full artifact

The artifact is ffmpeg 9.0 built from `origin/dev`'s complete 67-component stack inside the
unchanged base image, with the compat object, `-no-pie`, and the `.so` fixes:

```
/root/ffmpeg-dynshim: ELF 64-bit LSB executable, x86-64, dynamically linked,
  interpreter /lib64/ld-linux-x86-64.so.2       size = 278,243,368
  floor  = GLIBC_2.34
  NEEDED = libm.so.6 libc.so.6 ld-linux-x86-64.so.2 libmvec.so.1
  symbols above GLIBC_2.34: (none)
```

**(a) Directly inside WSL2** (`Ubuntu-24.04` distro, `/usr/lib/wsl/lib/libcuda.so.1`, RTX 3070,
driver 617.14):

```
GLIBC=ldd (Ubuntu GLIBC 2.39-0ubuntu8.7) 2.39
frame=60 fps=0.0 q=21.0 Lsize=337KiB time=00:00:01.90 bitrate=1453.9kbits/s speed=3.59x
OUT_BYTES=345311
Stream #0:0 Video: h264 (High 4:4:4 Predictive) (avc1), 1280x720, 1374 kb/s, 30 fps
```

No `cuInit` failure, no `CUDA_ERROR_OPERATING_SYSTEM`, and the output re-probes as a real H.264
stream.

**(b) `debian:bookworm-slim` (glibc 2.36) under Docker Desktop / WSL2 on the same host**,
`--gpus all -e NVIDIA_DRIVER_CAPABILITIES=compute,utility,video`:

```
glibc = ldd (Debian GLIBC 2.36-9+deb12u14) 2.36
nvenc encoders = 3
frame=60 fps=0.0 q=21.0 Lsize=337KiB bitrate=1453.9kbits/s speed=3.05x
SIZE=345311
```

Same file, same byte count, in the container family the media-server ships in.

*(Gotcha for anyone repeating this: without `NVIDIA_DRIVER_CAPABILITIES=…,video` the toolkit
injects `libcuda.so.1` but not `libnvidia-encode.so.1`, and ffmpeg reports
`Cannot load libnvidia-encode.so.1` / `The minimum required Nvidia driver for nvenc is 570.0 or
newer`. That message is misleading — the driver is fine.)*

**(c) Plain hosts, no GPU** — starts and reports its codecs:

| container | glibc | starts? | nvenc encoders listed |
|---|---|---|---|
| `ubuntu:22.04` | 2.35 | yes | 3 |
| `debian:12` | 2.36 | yes | 3 |
| `almalinux:9` | 2.34 | yes | 3 |
| `amazonlinux:2023` | 2.34 | yes | 3 |
| `opensuse/leap:15.6` | 2.38 | yes | 3 |
| `debian:11` | 2.31 | **no** — `version GLIBC_2.34 not found` | — |
| `ubuntu:20.04` | 2.31 | **no** — `version GLIBC_2.34 not found` | — |
| `alpine:latest` | musl | **no** — `sh: /ffF: not found` (no ELF interpreter) | — |

---

## 6. What breaks for existing users

The current artifact is `statically linked … for GNU/Linux 3.2.0` (measured on the shipped
release binary, 195,348,560 bytes). It runs on **any** x86-64 Linux with a 3.2+ kernel regardless
of libc. Verified directly: the shipped static release runs on `alpine:latest` (musl) and lists
`av1_nvenc`, `h264_nvenc`, `hevc_nvenc`.

Moving to a dynamically linked binary with a **GLIBC_2.34** floor breaks:

| setup | glibc | breaks? | how I know |
|---|---|---|---|
| Alpine / any musl distro | musl | **yes, hard** | measured: new binary is `not found` (no interpreter); current static one runs |
| Debian 11 bullseye | 2.31 | **yes** | measured: `GLIBC_2.34 not found` |
| Ubuntu 20.04 | 2.31 | **yes** | measured: `GLIBC_2.34 not found` |
| Debian 10, Ubuntu 18.04 | 2.28 / 2.27 | yes | reasoned from the same floor |
| RHEL/CentOS 7 and 8 | 2.17 / 2.28 | yes | reasoned |
| openSUSE Leap ≤ 15.5 | 2.31 | yes | reasoned |
| Amazon Linux 2 | 2.26 | yes | reasoned |
| Debian 12 (the media-server container) | 2.36 | no | measured |
| Ubuntu 22.04 | 2.35 | no | measured |
| RHEL 9 / Rocky 9 / Alma 9 | 2.34 | no | measured |
| Amazon Linux 2023 | 2.34 | no | measured |
| openSUSE Leap 15.6 | 2.38 | no | measured |
| Fedora 40+, Ubuntu 24.04, Arch | ≥ 2.39 | no | measured / reasoned |

### Why 2.34 is the number to aim for

Measured glibc versions: `almalinux:9` 2.34, `rockylinux:9` 2.34, `amazonlinux:2023` 2.34,
`ubuntu:22.04` 2.35, `debian:12` 2.36, `opensuse/leap:15.6` 2.38, `fedora:40` 2.39,
`ubuntu:24.04` 2.39, `debian:11` 2.31, `ubuntu:20.04` 2.31.

2.34 is the **highest floor that still covers every currently-supported mainstream distro**. The
whole EL9 family and Amazon Linux 2023 sit exactly on 2.34, so stopping at 2.35 — which is what
you get if you skip the `_dl_find_object` work — silently drops RHEL 9, Rocky 9, Alma 9 and
AL2023. **2.35 and 2.34 look one step apart and are not.**

Below 2.34 the next real customers are Debian 11 and Ubuntu 20.04 (both 2.31), reachable only via
zig cc (§3.2).

### The honest framing

"Never break existing users" and "one artifact" are in direct tension, and no amount of symbol
work resolves it: **any** dynamically linked glibc binary loses musl users, and the floor only
decides how many glibc users go with them. The options are:

1. one artifact at floor 2.34, accepting the losses above;
2. keep the static artifact and publish the dynamic one alongside it — ruled out by the brief,
   but the only option with zero regression;
3. zig cc: one artifact at ~2.28, at the cost of rebuilding every C++ component against libc++.

A download-log or telemetry check of how many installs are musl or pre-2.34 would turn this from
a judgement call into a number; that data was not available to me.

---

## 7. Recommendation

**Recommended: the minimal link change, plus `-no-pie`, plus one hidden-visibility compat object,
plus the four `.so`-elimination fixes and a link guard — floor GLIBC_2.34, built entirely inside
the existing base image.** It touches one dockerfile, two build scripts and adds one ~120-line C
file; the 67 component scripts and the base image are otherwise untouched, and the resulting
single binary was demonstrated doing `h264_nvenc` both directly in WSL2 and in
`debian:bookworm-slim`, producing identical 345,311-byte output, with `NEEDED` limited to
`libc.so.6`, `libm.so.6`, `libmvec.so.1` and the loader.

I recommend **against** zig cc and against the sysroot: the sysroot needs the same compat object
plus more and buys nothing extra; zig cc buys 2.34 → ~2.28 in exchange for rebuilding every C++
component against a different standard library.

I recommend the spec treat the **musl / pre-2.34 regression as a product decision, not an
implementation detail**, and require the link guard and the runtime self-test as part of the
change rather than as follow-ups. Without the guard the floor silently follows the base image's
glibc; without the self-test a shim bug of exactly the kind found here (§4, trap 1) ships as a
binary that links, passes `--version` in CI only if CI runs it, and hangs on a user's machine.

---

## 8. What remains unknown

* **Runtime coverage of the artifact beyond nvenc.** I verified startup, codec enumeration and a
  full `h264_nvenc` encode + re-probe. I did **not** exercise librsvg (the `pidfd_*` path),
  whisper/stemsplit (OpenMP with static libgomp), tesseract OCR, libplacebo/Vulkan filters, SDL2
  (`ffplay`), or the bluray/dvdread protocols on the new binary. Each of those touches a shimmed
  symbol or a newly-static library, and each should be smoke-tested before release.
* **`pidfd_spawnp` semantics.** My implementation is `posix_spawnp` + `pidfd_open(2)`, which is
  not atomic the way glibc's is: between spawn and `pidfd_open` the child could exit and its pid
  be reused. Correct enough for glib's `gspawn`, almost certainly, but unverified — and an
  alternative worth considering is building librsvg against older glib or patching that call out.
* **`_dl_find_object` performance.** Linear `dl_iterate_phdr` per frame vs glibc's lock-free
  tree. 1001 throws completed instantly and the process loads very few objects, but this was not
  benchmarked. Also unverified: behaviour if an exception propagates *through* a
  `dl_iterate_phdr` callback (glibc holds `dl_load_write_lock` there; our implementation would
  re-enter it).
* **`-no-pie` and the security review.** Whether losing executable ASLR is acceptable, and
  whether making libdavs2's asm PIC-clean is worth doing instead.
* **`libmvec.so.1` on unusual glibc builds.** Verified present on four distros; assumed present
  wherever glibc ≥ 2.22 is.
* **nvcc with a non-GCC host compiler** (only relevant if zig cc is revisited).
* **The `dev/init/dev.sh` debug path** was not exercised (it exits unless `DEBUG=true`).
* **musl / pre-2.34 install share** — unknown, and it is the number that should decide §6.
* **aarch64.** Everything here is x86-64. `ffmpeg-linux-aarch64.dockerfile` carries the same
  `-static` pattern and needs its own measurement; the symbol set will differ (no libmvec, no
  x86 asm PIE problem, but the same libstdc++/libgcc story).

---

## 9. Reproduction notes

* Base image used as-is: `nomercyentertainment/ffmpeg-base:latest`. The local copy was missing
  the `spirv-headers` package that `scripts/48-whisper.sh` needs
  (`/usr/include/spirv/unified1/spirv.hpp`); installing it via apt was enough. Worth confirming
  the CI base image still carries it.
* The meson cross file (`/build/cross_file.txt`) and `/build/enable.txt` etc. are created by the
  dockerfile, not by `init.sh`; a container-based reproduction must create them first or
  `libdrm` fails immediately.
* `init.sh` is **not** re-runnable: each component script `rm -rf`s its own source tree after a
  successful build, so a failure mid-way requires resuming from that script rather than
  restarting. A `docker commit` checkpoint after the apt step saves a lot of time.
* All scratch artifacts (the compat object, the self-test, the built binaries, the per-route
  logs) are under the session scratchpad in `issue42-res/`.
