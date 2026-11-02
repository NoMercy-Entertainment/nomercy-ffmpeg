# The Vulkan loader and the host's glibc — design

**Date:** 2026-11-02
**Trigger:** the v1.0.45 release candidate's linux-x86_64 smoke job (run 41368486061) died
with SIGFPE in the first whisper run, before the filter had logged a line. It was the first
time any CI job ran a ggml filter with a model on a GitHub runner. The same artifact ran
clean on an Intel build host, with and without Mesa's software Vulkan driver.

## What happens

gdb on the runner (run 41374434056, workflow `diag-whisper-fpe.yml`, since deleted):

```
Thread 3 "af#0:0" received signal SIGFPE, Arithmetic exception.
=> 0x7ffff4d9f56f:  div    %r8          r8 = 0
0x00007ffff4c28000-0x00007ffff4dc5000  r-xp  /usr/lib/x86_64-linux-gnu/libc.so.6
0x00007ffff4f5c000-0x00007ffff4fb6000  r-xp  /usr/lib/x86_64-linux-gnu/libvulkan.so.1.4.341
```

The crash is inside the **host's** `libc.so.6`, mapped into our statically linked binary.
`vk_loader_shim.c` opens `libvulkan.so.1` with `dlopen`; the loader needs `libc.so.6`, so
glibc's static-dlopen support maps a second C library into the process. glibc supports that
only when the second library is the exact version the binary was linked with. With any other
version, the loaded libc's `_rtld_global_ro` is not initialised the way its code expects: its
page size reads as zero, and the first allocation that goes through a thread arena
(`alloc_new_heap`, which aligns on the page size with a division) raises SIGFPE. The filter
thread is the first thread to allocate there, so the crash lands in `af#0:0`, after the
filter has been created and before it logs anything.

Measured with the RC binary (linked against glibc 2.39, the Ubuntu 24.04 base):

| host | glibc | loader installed | drivers | result |
|---|---|---|---|---|
| ubuntu-latest runner (26.04) | 2.43 | yes (1.4.341) | none | SIGFPE, every run with a model |
| ubuntu:26.04 container | 2.43 | yes | none | SIGFPE |
| debian:12 container | 2.36 | yes | none | SIGFPE |
| ubuntu:24.04 container | 2.39 | yes | none | runs |
| ubuntu:24.04 container | 2.39 | yes | Mesa (llvmpipe) | runs; the child probe dies, the guard pins the drivers |
| Intel build host (Ubuntu 24.04 containers) | 2.39 | — | — | runs |

On the runner the crash was the same for every CPU variant, with `NOMERCY_GGML_GPU=0`, with
the loader pointed at nothing (`VK_ICD_FILENAMES=/nonexistent.json`), with the guard off, and
for the **v1.0.44 release** (`ref`, `ref-baseline`, `ref-nogpu`). So:

- it is not a regression of this release: every Linux release so far dies the same way on a
  host with `libvulkan1` installed and a glibc other than the build's;
- no driver is needed: the loader alone brings the second libc;
- the existing guard cannot see it. Its child probe survives: a freshly forked child is
  single-threaded, allocates from the main arena, and never reaches the thread-arena path.
  It reports "nothing scary" and the parent opens the loader and dies;
- pinning `VK_ICD_FILENAMES` does not help, because the crash is not in a driver.

## Decisions

**D1. The host's glibc version is read from the file, and nothing is loaded.** Before any
probe is forked, `nm_vk_make_safe` reads the banner of the host's `libc.so.6` ("GNU C Library
... release version 2.43.") from the standard paths, in 64 KB pieces, and compares it with
the binary's own `gnu_get_libc_version()`. The first cut did this in the probe child with a
`dlopen("libc.so.6")`: the child died on that dlopen, which turned into a "driver crash"
verdict that pinned the drivers and still opened the loader, so the parent died as before
(measured on ubuntu:26.04). Reading the file touches nothing. A host without a libc at a
standard path answers "no comparison", not "fine". Measured on 22.04, 24.04, 26.04 and
Debian 12: 2.35, 2.39, 2.43, 2.36.

**D2. On a mismatch the loader is never opened, and the same for every "vulkan off".** New
`nm_vk_shim_forbid()` in `vk_loader_shim.c`: set before the first Vulkan call, the shim's
one-time init skips `dlopen` and every entry point answers as on a machine without a loader
(the stubs it already had: no instance, no devices). ggml then sees no Vulkan and the filter
runs on the CPU. The notice names both versions:

```
this machine's glibc is 2.43 and this binary was linked with glibc 2.39; a statically linked
binary can open the vulkan loader only on the glibc it was linked with, so vulkan is off for
this process and the filter runs on the CPU
```

The pin alone (`VK_ICD_FILENAMES=/nonexistent.json`) never protected against this, because
the loader itself brings the second libc. So every path that switches Vulkan off for the
process (`nm_vk_disable`: a proven driver crash, a precaution after a timeout) now also keeps
the loader shut. The pin stays, for FFmpeg's own Vulkan code, which opens the loader by
itself. A probe child that dies with no driver to blame is this very case, and it is now
handled the same way.

**D3. `NOMERCY_GGML_GPU=0` also keeps the loader shut.** Until now the switch was read after
the registry had been built, so the loader was opened regardless and the crash happened with
the GPU "off" (run 41374434056, `rc-nogpu`). The switch now forbids the shim too. The driver
check still runs before it, on purpose, as before: FFmpeg's own Vulkan code opens the loader by
itself, and the pin protects that path from crashing drivers.

**D4. The startup check transcribes when it can.** `tests/lib/cpu-variant.sh`'s probe ran
`-af whisper` without a model and took the model rejection as proof that ggml init returned.
It did return; the crash came later. With `WHISPER_TEST_MODEL` set (CI has it on
linux-x86_64) the probe now runs the model over 1.5 s of silence, in every configuration the
check already exercised, and the proof is exit 0. Without a model the old proof stands and the
pass line says so.

## What this does not do

- It does not make Vulkan work across glibc versions. A statically linked glibc binary
  cannot; that would take a dynamically linked Linux build, or a loader and drivers that do
  not need the host's libc, neither of which exists today. Vulkan on Linux needs a host whose
  glibc is the build's (2.39 at present). Documented in the README.
- It does not protect FFmpeg's own Vulkan use (`-init_hw_device vulkan`, libplacebo) on a
  mismatched host; that path opens the loader itself, on the user's explicit request.
- Windows is not affected (the shim uses `LoadLibrary`; no second C library). macOS and
  FreeBSD carry no Vulkan.

**D5. The smoke job runs on the build's glibc, and the other hosts run in containers.** The
whisper defaults check and the stemsplit A/B gate run the previous release's binary, and that
binary dies on every foreign glibc with the loader installed, which `ubuntu-latest` (26.04)
now is. So the linux-x86_64 smoke job is pinned to `ubuntu-24.04` (detect-changes.yml), and a
step after it runs `tests/lib/foreign-glibc.sh`: the new binary in `ubuntu:26.04`,
`ubuntu:22.04` and `debian:12` containers with `libvulkan1` and no driver, plus `ubuntu:24.04`
with Mesa, whisper and stemsplit with their models; each run must finish with output and, on a
foreign glibc, print the notice. Run against the unfixed RC binary it fails on all three
foreign hosts (exit 136), so it is a check that can fail. In the manual suite the two
reference checks skip with a reason when the reference dies of this (exit 136), instead of
failing on a host the reference cannot run on.

## Verification

1. `gcc -fsyntax-only` on both files, guard on and `NM_NO_VULKAN`.
2. linux-x86_64 rebuilt locally with the change; the binary run in `ubuntu:26.04`,
   `debian:12` and `ubuntu:24.04` containers with `libvulkan1` and no driver, with a whisper
   model: the first two must print the notice and finish, the third must run as before; also
   with `NOMERCY_GGML_GPU=0` and with Mesa installed on 24.04.
3. The smoke script with the whisper assets in the `ubuntu:26.04` container, where the
   startup check now transcribes.
4. `tests/lib/foreign-glibc.sh` on the fixed binary (all four hosts pass) and on the RC binary
   (the three foreign hosts fail), locally and in CI.
