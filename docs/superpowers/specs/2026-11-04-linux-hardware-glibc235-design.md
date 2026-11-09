# Linux x86_64 hardware variant: glibc 2.35 floor

The hardware variant (`linux-x86_64-hardware`, see
[2026-11-04-linux-gpu-runtime-design.md](2026-11-04-linux-gpu-runtime-design.md))
links the host's glibc dynamically. The glibc it is compiled and linked
against is therefore the oldest glibc it can start on. Built on the Ubuntu
24.04 base image that floor was 2.39, which shuts out Ubuntu 22.04 (2.35)
and Debian 12 (2.36), the two distributions most media servers still run,
including the `nomercymediaserver` container image (Debian 12). The owner
asked for the floor to come down as far as it honestly can.

## What set the floor at 2.39

The 2.39 archive imported sixteen names above GLIBC_2.35. All of them come
from the build host, none from anything FFmpeg needs:

| names | version | origin |
| --- | --- | --- |
| `__isoc23_strtol`, `strtoul`, `strtoull`, `strtoll`, `strtoll_l`, `strtoull_l`, `sscanf`, `fscanf`, `vsscanf` | 2.38 | glibc 2.38+ headers redirect `strto*`/`*scanf` to C23 variants under `_GNU_SOURCE` |
| `strlcpy`, `strlcat`, `wcslcpy`, `wcslcat` | 2.38 | dependencies' configure scripts detect them in 2.38+ headers and drop their bundled fallbacks |
| `pidfd_getpid`, `pidfd_spawnp` | 2.39 | glib's spawn code, detected at configure time |
| `arc4random` | 2.36 | libstdc++'s `std::random_device`, detected when gcc 13 was built |
| `fmod`, `fmodf` | 2.38 | symbol version bump only; the same functions exist as GLIBC_2.2.5 |

Compiling against 2.35 headers removes every row but one. The exception is
the toolchain's own prebuilt static archives: gcc 13's `libstdc++.a`
(`eh_alloc.o`, `debug.o`, `random.o`) and `libgomp.a` were compiled on
24.04 and name `__isoc23_strtol`, `__isoc23_strtoul`, `__isoc23_strtoull`
and `arc4random`. These are linked statically into every C++ or OpenMP
program, so the link fails against a 2.35 `libc.so.6` unless something
defines those four names.

The 2.34 wall below this (the #42 ladder: `__libc_start_main` from
`crt1.o`, `pthread_*` folded into libc) is real, but every distribution on
2.34 that matters (EL9, Amazon Linux 2023) also ships glibc 2.34 exactly,
and Ubuntu 20.04 / Debian 11 (2.31) are out of standard support. 2.35 is
the floor this build promises; 2.34 is not pursued.

## Design

**A glibc 2.35 sysroot, nothing else.** `ffmpeg-linux-x86_64.dockerfile`
gains a stage from `ubuntu:22.04` (pinned by digest) that installs
`libc6-dev`, `linux-libc-dev`, `libcrypt-dev` and the X development packages
the base image installs from apt (`libxext-dev`, `libxau-dev`, `libxdmcp-dev`,
`xtrans-dev`, `xutils-dev`), and copies `/usr/include`, `/usr/lib` and
`/usr/lib64` to `/opt/glibc235`. The X packages are there because the libxcb
that `08-libdrm.sh` builds includes `X11/Xauth.h` and links libXau, which no
script builds; the first full build stopped exactly there. Every codec,
xproto, libxcb and libX11 are built from source by the numbered scripts, and
the build prefix's copies win over the sysroot's because the wrappers add
their `-L=` directories after the caller's own `-L` flags. The base image
stays on 24.04 and every other platform is untouched.

**Compiler wrappers, not flags in scripts.** Ubuntu's gcc is not built with
a sysroot: `--sysroot` moves the headers but the driver still hands ld its
own library directory first, so `libc.so` would still be the host's 2.39
(verified with `-Wl,-t`). `scripts/includes/glibc235_sysroot_setup.sh`
writes wrappers into `/usr/local/bin` for `x86_64-linux-gnu-{gcc,g++,cpp}`
and `gcc`, `g++`, `cpp`, `cc`, `c++` that add `--sysroot=/opt/glibc235`
and, after the caller's options, sysroot-relative
`-L=/usr/lib/x86_64-linux-gnu -L=/lib/x86_64-linux-gnu`.
A linker script found in a sysrooted directory has its absolute member
paths prefixed with the sysroot too, so `libc.so.6`, `libm.so.6`,
`libmvec.so.1` and `ld-linux` all resolve inside `/opt/glibc235`. CMake,
Meson, autotools, cargo and nvcc all go through `CC`/`CXX` or `cc`, so no
script changes. The start files (`crt1.o`, `crti.o`, `crtn.o`) still come
from the host; their only import is `__libc_start_main` (GLIBC_2.34), and
the gates reject anything above 2.35 regardless.

**The four toolchain symbols live in `libc_nonshared.a`.**
`scripts/includes/glibc235_compat.c` defines `__isoc23_strtol/strtoul/strtoull`
(`strto*` plus the C23 `0b` prefix for base 0 and 2, glibc's semantics) and
`arc4random`/`arc4random_buf`/`arc4random_uniform` (over `getrandom(2)`,
which glibc has had since 2.25 and which, like glibc's own, aborts rather
than fails). The setup script compiles it against the sysroot (it refuses
2.38+ headers, which would make the functions recurse) and appends it to
the sysroot's `libc_nonshared.a`, the archive glibc's `libc.so` linker
script pulls into every link. Every C++ or OpenMP program in the build,
including host tools such as ggml's `vulkan-shaders-gen`, then links
without a flag anywhere. A program running on glibc 2.38+ carries its own
copies; nothing changes at run time.

**Shared C++/OpenMP requests resolve to the static archives.** Every C++
and OpenMP runtime in this build is static, but rustc does not read
CFLAGS/LDFLAGS: librsvg's `rsvg-convert` (a host tool, through a C++
dependency) passes a plain `-lstdc++`, which found gcc 13's shared
`libstdc++.so`. That library needs `arc4random` and `__isoc23_strtoul` from
libc, which a 2.35 `libc.so.6` cannot supply, and lld refuses the link
("disallowed by --no-allow-shlib-undefined"); the second full build stopped
there, 52 components in. The setup script now writes `libstdc++.so` and
`libgomp.so` linker scripts (`INPUT(-l:libstdc++.a)`) into the sysroot's
library directory, which the wrappers search before gcc's own, so a shared
request becomes the static archive and step one's four symbols cover it. The
probe links the rustc shape with both bfd and rust's lld and rejects a
program that still needs the shared runtime.

**Proven before the first dependency builds.** The setup script links and
runs a C++/OpenMP probe (exceptions, `std::string`, `std::random_device`,
threads, `fmod`) in the shape of the final link, with `-Wl,-t`, and fails
the image build unless the headers and every glibc file the linker opened
came from the sysroot, the probe imports nothing above GLIBC_2.35, and none
of the four names is left dynamic. `scripts/includes/verify_linux_runtime.sh`
then enforces the same floor on the final `ffmpeg`, `ffprobe` and `ffplay`
(maximum GLIBC_2.35, previously 2.39), and `tests/unit/test_linux_runtime.sh`
proves that gate rejects a 2.36 import.

## Measured before the full build

In a clean `ubuntu:24.04` container with the base image's gcc 13 and the
same sysroot: the setup script passes, a C probe imports at most
GLIBC_2.34, a C++/OpenMP probe at most GLIBC_2.35, and both run unchanged
on Debian 12 (2.36), Ubuntu 22.04 (2.35) and Ubuntu 24.04 (2.39).
`libcudart_static.a` and the other CUDA 12.9 static archives name nothing
above 2.35.

## Verification of the full archive (2026-11-04)

The full hardware build ran three times. The first stopped at libdrm
(`X11/Xauth.h` missing from the sysroot), the second at librsvg (rustc and
the shared `libstdc++.so`); both fixes are in the design above. The third
built all 70 components and packaged `ffmpeg-9.0-linux-x86_64-hardware.tar.gz`
(315 MB). Evidence under `output/glibc235/` (not committed).

**ELF gate.** The build's own gate reported "hardware glibc base runtime only"
for `ffmpeg`, `ffprobe` and `ffplay`. An independent `readelf` pass on the
extracted archive: interpreter `/lib64/ld-linux-x86-64.so.2`, NEEDED exactly
`libm.so.6 libc.so.6 ld-linux-x86-64.so.2 libmvec.so.1`, highest version
GLIBC_2.35, none of the sixteen names of the problem table imported. The only
two post-2.35 names that remain are `pidfd_getpid` and `pidfd_spawnp`, as
unversioned weak references: glib declares them weak so a 2.35 loader binds
them to null and glib takes its fork path. The four compat symbols are defined
inside the binary.

**Hosts.** `tests/lib/hardware-hosts.sh`, all 28 checks pass: on Ubuntu 22.04
(glibc 2.35), Debian 12 (2.36), Ubuntu 24.04 (2.39, eight Mesa ICDs) and
Ubuntu 26.04 (2.43), the archive starts, transcribes with whisper on the CPU
backend for `use_gpu=0`, `use_gpu=1` and `NOMERCY_GGML_GPU=0`, separates with
stemsplit on the CPU backend with and without `use_gpu=1`, and encodes
H.264 with libx264; no foreign-glibc notice anywhere. The first run of the
script failed its own encode check (it demanded stdout from the null muxer);
the check now streams the encode to stdout.

**RTX 3070 lab** (`tools/gpu-container`, image `nomercy-gpu-check:linux-runtime-fixed`,
Ubuntu 24.04 / glibc 2.39): identical to the 2.39 archive's record. GPU
visible (driver 621.01), `cuInit` 0, Vulkan device "Microsoft Direct3D12
(NVIDIA GeForce RTX 3070)", H.264 NVENC 3 frames; the Vulkan
upload/scale/download path exits 218 (`-ENOSYS`) through Dozen, the same
`VkFormatProperties3` limitation as before. Inside the same container:
H.264 and HEVC NVENC 3 frames each, CUDA decode of the NVENC stream
downloaded 1,036,800 bytes (3 NV12 frames), and whisper with `use_gpu=1`
ran on the `vulkan` backend on the RTX and transcribed the clip.

**Smoke.** `tests/smoke.sh` for `linux-x86_64-hardware` in an `ubuntu:24.04`
container with the stemsplit release gates and the whisper option tests
(`STEMSPLIT_TEST_REQUIRED=1`, `WHISPER_TEST_REQUIRED=1`): all 21 gates pass.
That includes the Vulkan backend, loader shim and ICD guard presence checks,
the JPEG XL and HAP/APV round-trips, the ggml CPU dispatcher startups, the
whisper option tests with default output byte-identical to v1.0.44, the
stemsplit v1.1.0 suite (410 passed, 0 failed, 10 skipped for want of a GPU
and the full RoFormer weights, as in CI), 20/20 clean exits for Spleeter
and RoFormer, and 30/30 Spleeter stems byte-identical with v1.0.44.

The hardware-hosts check is now a CI step of the smoke job for the hardware
platform, next to the static archive's foreign-glibc step.
