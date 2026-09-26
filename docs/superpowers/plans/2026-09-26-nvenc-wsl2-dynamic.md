# NVENC under WSL2: one dynamically-linked linux-x86_64 ffmpeg — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `h264_nvenc` work inside WSL2 from the shipped linux-x86_64 artifact, by giving the executable an ELF interpreter while every third-party library stays statically linked — without losing a single feature.

**Architecture:** Drop `-static` from the two ffmpeg configure flags, add `-no-pie` (libdavs2's asm cannot go into a PIE), link one hidden-visibility compat object that defines the ~20 glibc symbols the prebuilt archives reference above `GLIBC_2.34`, make four stray `.so` dependencies unreachable, and guard the result at link time plus at runtime.

**Tech Stack:** C (one compat object), bash build scripts, Docker, `ffmpeg-linux-x86_64.dockerfile`.

**Spec:** `docs/superpowers/specs/2026-09-26-nvenc-wsl2-design.md`
**Research it argues from:** `docs/superpowers/research/2026-09-26-nvenc-wsl2-findings.md` — every measurement cited below lives there.

## Global Constraints

- **The gate (the owner's three conditions).** No feature may go missing or break; no second artifact; nothing may be switched off to make it work. If a feature cannot be made to work without disabling something, **stop and return to the owner** — do not ship a quieter ffmpeg.
- Exactly one linux-x86_64 artifact. No second build, no variant.
- Every third-party library stays statically linked. The only new runtime requirement is glibc.
- The glibc floor must be **exactly `GLIBC_2.34`** — not lower, not higher. Higher loses the EL9 family and Amazon Linux 2023, which sit exactly on 2.34; lower is impossible on this toolchain (`__libc_start_main` from `crt1.o`, `pthread_*` from `libstdc++.a`).
- `NEEDED` may contain only: `libc.so.6`, `libm.so.6`, `libmvec.so.1`, `libdl.so.2`, `libpthread.so.0`, `librt.so.1`, `ld-linux-x86-64.so.2`.
- No x86 SIMD/asm may be disabled. `-no-pie` exists to *keep* libdavs2, not to drop anything.
- linux-x86_64 only. Do not touch `ffmpeg-linux-aarch64.dockerfile` or any other platform.
- Conventional Commits. **Never** add self-attribution, `Co-Authored-By` or "Generated with" lines — absolute rule of this repository's owner.

## Review Focus

Five failure modes the spec implies that no single task's happy path exercises. Each has its test assigned to the task that owns the code.

1. **A shimmed symbol that links but hangs or crashes at runtime.** `_GNU_SOURCE` makes the shim call itself; measured, `ffmpeg -version` never returned. Link success proves nothing here. → Task 1, via the self-test.
2. **Shim symbols exported and interposing** on `dlopen`ed libcuda / libnvidia-encode / OpenCL / Vulkan loaders. → Task 1, asserted with `objdump -T`.
3. **A stray `.so` reappearing** from any component upgrade or a changed link order — previously `libxcb.so.1` and `libz.so.1` crept in and the binary died in `debian:bookworm-slim` before any glibc check ran. → Task 3, via the link guard.
4. **The floor silently following the base image** at the next image rebuild. → Task 3, by pinning the exact string.
5. **A feature that still builds but no longer runs** — the six surfaces that touch a shimmed symbol or a newly-static library. → Task 4, by running each.

---

### Task 1: The compat object and its self-test

**Files:**
- Create: `scripts/includes/nmcompat.c`
- Create: `tools/nvenc-wsl2/selftest.c`
- Create: `tools/nvenc-wsl2/build-selftest.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `nmcompat.o`, compiled `gcc -O2 -fPIC -fvisibility=hidden -fno-builtin -c`, defining the symbol set below. Task 3 appends it to ffmpeg's `--extra-libs`.

**This task is deliberately standalone.** It needs no ffmpeg build: compile the object, link the self-test against it, run it. That is minutes, not hours, and it is where the two traps get caught.

The exact symbol bodies are specified in the research doc §4(a) — read it. The symbol set:

| group | symbols |
|---|---|
| C23 renames | `__isoc23_strtol`, `__isoc23_strtoul`, `__isoc23_strtoll`, `__isoc23_strtoull`, `__isoc23_strtoll_l`, `__isoc23_strtoull_l`, `__isoc23_sscanf`, `__isoc23_fscanf`, `__isoc23_scanf`, `__isoc23_vsscanf`, `__isoc23_vfscanf`, `__isoc23_vscanf` |
| BSD string | `strlcpy`, `strlcat` |
| randomness | `arc4random`, `arc4random_buf` |
| unwinder | `_dl_find_object` |
| libmvec | `_ZGVbN2v_log2`, `_ZGVbN2vv_atan2` |
| pidfd | `pidfd_spawnp`, `pidfd_getpid` |
| versioned forwards | `hypot`, `hypotf`, `fmod`, `fmodf` |

- [ ] **Step 1: Write the self-test first**

Create `tools/nvenc-wsl2/selftest.c`. It calls **every** symbol in the table once, prints the result, and returns non-zero if any is wrong. It must include a C++ exception test — that is what `_dl_find_object` exists for and a null stub passes everything else while aborting on the first throw.

```c
/* Exercises every symbol nmcompat.c defines. Linking is not evidence:
 * a shim built with _GNU_SOURCE links cleanly and then calls itself
 * forever the first time the symbol is reached. */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

int fails = 0;
#define CHECK(label, cond) do { \
    printf("%-24s %s\n", (label), (cond) ? "ok" : "FAIL"); \
    if (!(cond)) fails++; \
} while (0)

int main(void)
{
    char buf[32];
    /* C23 renames: reached through the ordinary names, which the headers
     * rewrite. A hang here IS the recursion trap. */
    CHECK("strtoul", strtoul("42", NULL, 10) == 42UL);
    CHECK("strtoll", strtoll("-7", NULL, 10) == -7LL);
    int a = 0, b = 0;
    CHECK("sscanf", sscanf("3 4", "%d %d", &a, &b) == 2 && a == 3 && b == 4);

    CHECK("strlcpy", strlcpy(buf, "abc", sizeof buf) == 3 && !strcmp(buf, "abc"));
    CHECK("strlcat", strlcat(buf, "de", sizeof buf) == 5 && !strcmp(buf, "abcde"));

    unsigned int r1 = arc4random(), r2 = arc4random();
    CHECK("arc4random", r1 != 0 || r2 != 0);
    unsigned char rb[8] = {0};
    arc4random_buf(rb, sizeof rb);
    CHECK("arc4random_buf", memcmp(rb, "\0\0\0\0\0\0\0\0", 8) != 0);

    CHECK("hypot", hypot(3.0, 4.0) == 5.0);
    CHECK("fmod", fmod(7.0, 4.0) == 3.0);

    printf("%s\n", fails ? "SELFTEST FAILED" : "SELFTEST PASSED");
    return fails != 0;
}
```

Add a C++ translation unit in the same harness that throws and catches across a function boundary, in the main thread and in a second thread — the research measured 1001 throws including one from a second thread.

- [ ] **Step 2: Run the self-test against an empty compat object and watch it fail**

Compile an `nmcompat.c` that defines nothing, link, run. Expect link errors or failures — this proves the self-test is capable of failing before anything exists to satisfy it.

- [ ] **Step 3: Write `scripts/includes/nmcompat.c`**

Follow research §4(a). Two rules are mandatory, both measured:

**Never use `_GNU_SOURCE` in this file.** It implies `_ISOC2X_SOURCE`, so a plain `strtoul()` call inside the file is rewritten by the headers into `__isoc23_strtoul()` — the function being defined. Name the real entry points with asm labels instead:

```c
extern unsigned long int nm_strtoul(const char*, char**, int) __asm__("strtoul");
unsigned long int __isoc23_strtoul(const char *p, char **e, int b)
{ return nm_strtoul(p, e, b); }
```

**Versioned forwards** for the four math symbols, which is the one place `.symver` earns its keep — a single definition in the executable captures every reference in the link, including from prebuilt archives:

```c
__asm__(".symver __nm_hypot_old, hypot@GLIBC_2.2.5");
extern double __nm_hypot_old(double, double);
double hypot(double x, double y) { return __nm_hypot_old(x, y); }
```

**`_dl_find_object` must be the real implementation**, not a stub. Walk `dl_iterate_phdr`, take the `PT_LOAD` span and the `PT_GNU_EH_FRAME` address — what libgcc itself did before glibc 2.35. A null stub links, lowers the floor, and silently breaks C++ exception handling (measured: `Aborted (core dumped)` on the first throw).

- [ ] **Step 4: Build and run the self-test**

```bash
bash tools/nvenc-wsl2/build-selftest.sh
```

The script compiles `nmcompat.c` with the production flags (`gcc -O2 -fPIC -fvisibility=hidden -fno-builtin -c`), links the C and C++ self-tests against it, and runs them inside `nomercyentertainment/ffmpeg-base:latest` so the compiler and glibc match the real build.

Expected: every line `ok`, `SELFTEST PASSED`, exit 0, and the exception test reporting all throws caught.

- [ ] **Step 5: Assert nothing is exported (Review Focus 2)**

```bash
# in the container, after linking the self-test binary
objdump -T selftest | grep -E 'arc4random|_dl_find_object|strlc|__isoc23_' && echo "EXPORTED - FAIL" || echo "none exported - ok"
```

Expected: none exported. Without `-fvisibility=hidden` they land in `.dynsym` and interpose on libraries ffmpeg `dlopen`s, including the NVIDIA driver's own unwinder.

- [ ] **Step 6: Prove the recursion trap is caught (Review Focus 1)**

On a scratch copy, add `#define _GNU_SOURCE` at the top of `nmcompat.c`, rebuild, and run the self-test **with a timeout**:

```bash
timeout 10 ./selftest; echo "exit=$?"
```

Expected: exit 124 (timed out) or a hang the timeout kills — and the committed version passing. A guard nobody has watched trigger is not yet a guard.

- [ ] **Step 7: Commit**

```bash
git add scripts/includes/nmcompat.c tools/nvenc-wsl2/
git commit -m "feat(linux): compat object for the glibc symbols above the 2.34 floor"
```

---

### Task 2: Remove the four stray shared dependencies

**Files:**
- Modify: `scripts/56-omnidrive.sh`
- Modify: whichever script stages libraries into `${PREFIX}/lib` (find it; `scripts/init/` is the likely home)

**Interfaces:**
- Consumes: nothing.
- Produces: a prefix in which `-lomnidrive`, `-lgomp`, `-lXau` and `-lXdmcp` all resolve to `.a` files. Task 3's link guard asserts the result.

In a dynamic link the linker prefers a system `.so` over a static archive whenever both are visible. Four appear; a fifth, `libmvec.so.1`, is part of glibc and stays.

- [ ] **Step 1: Stop installing `libomnidrive.so`**

`scripts/56-omnidrive.sh` installs both `libomnidrive.a` and `libomnidrive.so` into `${PREFIX}/lib`; `-lomnidrive` picks the `.so`. Stop installing the `.so`, or delete it after install. Leave the `.a`.

- [ ] **Step 2: Stage `libgomp.a`, `libXau.a`, `libXdmcp.a` into `${PREFIX}/lib`**

All three exist in the base image. `libggml-base.a` and `libggml-cpu-variants.a` reference `GOMP_*`; `libxcb.a` references `XdmcpWrap` and friends. Copy the archives so `-lgomp`, `-lXau` and `-lXdmcp` find them before the system `.so`.

- [ ] **Step 3: Verify in the image, without a full build**

```bash
docker run --rm nomercyentertainment/ffmpeg-base:latest bash -c '
for l in gomp Xau Xdmcp; do printf "%-8s " "$l"; find / -name "lib$l.a" 2>/dev/null | head -1; done'
```

Expected: a path for each. If one is missing, that is a finding — say so rather than working around it.

- [ ] **Step 4: Commit**

```bash
git add scripts/56-omnidrive.sh scripts/init/
git commit -m "build(linux): keep gomp, Xau, Xdmcp and omnidrive resolving to archives"
```

---

### Task 3: The link change and the guard

**Files:**
- Modify: `ffmpeg-linux-x86_64.dockerfile`

**Interfaces:**
- Consumes: `nmcompat.o` from Task 1, the archive-only prefix from Task 2.
- Produces: the artifact Task 4 verifies.

**This task needs a full build and that is expected.** Copy the gitignored `scripts/patches/` from the main checkout first, or libbluray cannot build.

- [ ] **Step 1: Change the two configure flags**

In the `RUN` that configures ffmpeg:

```
-    --extra-cflags="-static -static-libgcc -static-libstdc++" \
-    --extra-ldflags="-static -static-libgcc -static-libstdc++" \
+    --extra-cflags="-static-libgcc -static-libstdc++" \
+    --extra-ldflags="-no-pie -static-libgcc -static-libstdc++" \
```

`--pkg-config-flags=--static` stays. Add a comment saying `-no-pie` is required by libdavs2's hand-written asm, which is not PIC-clean, and that it costs the executable's ASLR — otherwise someone removes it as noise.

- [ ] **Step 2: Compile and append `nmcompat.o`**

Compile it in the same `RUN`, before configure, and append it to `--extra-libs`. A `.o` rather than a `.a` so it contributes every definition unconditionally and link order cannot matter.

- [ ] **Step 3: Add the link guard immediately after `make`**

```sh
floor=$(objdump -T ${PREFIX}/bin/ffmpeg | grep -oE 'GLIBC_[0-9.]+' | sort -V -u | tail -1)
[ "$floor" = "GLIBC_2.34" ] || { echo "glibc floor moved to $floor"; exit 1; }

objdump -p ${PREFIX}/bin/ffmpeg | awk '/NEEDED/{print $2}' \
  | grep -vE '^(libc|libm|libmvec|libdl|libpthread|librt)\.so|^ld-linux' \
  && { echo "unexpected shared dependency"; exit 1; }

${PREFIX}/bin/ffmpeg -hide_banner -version >/dev/null
```

The exact-match on the floor is deliberate: a floor that moves in **either** direction means something changed. The third line is what catches the recursion trap, which no link-time check can see.

- [ ] **Step 4: Full build**

```bash
cp -r ../nomercy-ffmpeg/scripts/patches scripts/
docker compose build ffmpeg-linux-x86_64
docker compose run --rm ffmpeg-linux-x86_64
```

Expected: build completes, guard passes. Note when iterating: forcing a relink needs `rm -f ffmpeg ffmpeg_g` — deleting only `ffmpeg` re-strips the stale `ffmpeg_g` and hides the change.

- [ ] **Step 5: Prove each guard assertion can fail (Review Focus 3, 4)**

On scratch copies: change the expected floor string and confirm the build fails; re-add `libomnidrive.so` to the prefix and confirm the NEEDED check fails. Then restore.

- [ ] **Step 6: Record the measurements**

`file`, `ldd`, the floor, the full `NEEDED` list, and the artifact size against the current static one (195,348,560 bytes).

- [ ] **Step 7: Commit**

```bash
git add ffmpeg-linux-x86_64.dockerfile
git commit -m "build(linux): link ffmpeg dynamically against glibc 2.34, guarded"
```

---

### Task 4: The gate — every feature still works, and NVENC works in WSL2

**Files:**
- Create: `tools/nvenc-wsl2/verify-artifact.sh`

**Interfaces:**
- Consumes: the artifact from Task 3.
- Produces: the evidence the owner's gate requires.

**This is the task the change lives or dies by.** "It builds" is not the deliverable.

- [ ] **Step 1: NVENC end to end, from one binary, in both places**

In WSL2 (`wsl.exe -d Ubuntu-24.04`, an RTX 3070 is present) and in `debian:bookworm-slim` under Docker Desktop: a real `h264_nvenc` encode producing non-zero output that re-probes as H.264. The research measured 345,311 bytes; match the shape, not the exact number.

WSL2 quirk: each `wsl.exe -d <distro> -- bash -c ...` may start the distro fresh and wipe `/tmp`, so do a whole experiment in one invocation and persist under `/root`. `$?` read inside those invocations is unreliable — print values from the program itself.

- [ ] **Step 2: Run every feature the change could touch**

Each must **run**, not merely appear in `-filters` or `-codecs`:

| surface | minimum proof |
|---|---|
| librsvg | rasterise an SVG through the filter chain (the `pidfd_*` path) |
| whisper | transcribe a short wav, compare against the CPU-variant expectation (OpenMP against static `libgomp.a`) |
| stemsplit | a 30 s split producing audio, same reason |
| tesseract OCR | OCR a frame with known text |
| libplacebo / Vulkan filters | run one, with the Vulkan loader present and absent |
| `ffplay` (SDL2) | starts and exits cleanly |
| bluray / dvdread | open a source through each protocol |

**If any one of these cannot be made to work without disabling something, stop and report it.** That is the owner's gate, and shipping a quieter ffmpeg is not an acceptable resolution.

- [ ] **Step 3: The distro matrix, including the accepted failures**

Assert it runs on `debian:12`, `ubuntu:22.04` and `almalinux:9` (the 2.34 boundary), and assert it **fails** on `debian:11` and `alpine`. Asserting the failures keeps the accepted cost visible instead of letting it become a surprise later.

- [ ] **Step 4: Re-run the existing suites**

`tests/smoke.sh` and the CPU-variant assertions must still pass on the new artifact — the ggml variant dispatch, the Vulkan backend checks and the trailingsilence assertion all live there.

- [ ] **Step 5: Commit**

```bash
git add tools/nvenc-wsl2/verify-artifact.sh
git commit -m "test(linux): verify the dynamic artifact keeps every feature and does NVENC in WSL2"
```
