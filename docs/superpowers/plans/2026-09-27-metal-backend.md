# Metal backend for darwin-arm64 — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give macOS on Apple Silicon GPU acceleration for `whisper` and `stemsplit`, via ggml's Metal backend with the shader source embedded and compiled on the user's machine.

**Architecture:** Turn Metal on for darwin-arm64 in `scripts/48-whisper.sh` (which currently forces it off), work around a clang 18 parse failure with one anchored `sed`, link three frameworks, defer registry construction on darwin so `use_gpu=0` does not pay for shader compilation, and assert all of it in the CPU-variant test library, which today skips darwin entirely.

**Tech Stack:** bash build scripts, CMake, osxcross clang 18.1.3, Objective-C (`ggml-metal.m`), Docker.

**Spec:** `docs/superpowers/specs/2026-09-27-metal-backend-design.md`
**Research:** `docs/superpowers/research/2026-09-27-metal-backend-findings.md` — every measurement below comes from there.

## Global Constraints

- **darwin-arm64 only.** Do not enable Metal for darwin-x86_64: that dockerfile's floor is 10.13 while ggml uses unguarded 10.15 APIs, and Intel/AMD GPUs report neither `Apple7` nor `Metal3`, so they would take ggml's slow paths on the oldest machines we support.
- **Do not change the Linux or Windows GPU path.** The unconditional `nm_ggml_gpu_usable()` call there is a crash fix and must stay unconditional.
- The metadata value is **`mtl`**, not `metal` — `GGML_METAL_NAME` is `"MTL"`. Use the real string everywhere, including the README.
- No Apple shader compiler at build time, and nothing extra ships: no `.metallib`.
- Binaries stay static; no new runtime dependency beyond the system frameworks.
- Conventional Commits. **Never** add self-attribution, `Co-Authored-By` or "Generated with" lines — absolute rule of this repository's owner.
- **Nothing here proves Metal runs.** Four release gates need the owner's Apple Silicon Mac; Task 4 produces what they run, it does not substitute for it.

## Review Focus

Five failure modes the spec implies that no happy path exercises. Each has its test assigned to the task that owns it.

1. **The residency `sed` silently matching nothing** after a whisper.cpp bump, so the build breaks in a way that looks like a compiler problem. → Task 1, by failing the build when the pattern is absent.
2. **An empty or truncated embedded shader blob** shipping — the binary links, and Metal fails only on a user's machine. → Task 1, via the blob-size guard.
3. **The darwin deferral leaking into Linux or Windows**, reinstating the crash that the unconditional call fixed. → Task 2, asserted per platform.
4. **`use_gpu=0` still paying for shader compilation**, which is the entire point of Task 2 and would otherwise pass unnoticed because the result is merely *slow*, not wrong. → Task 2.
5. **Metal asserted by nothing.** `vulkan_platform_has_backend()` returns false for darwin (`tests/lib/cpu-variant.sh:226-231`), so today no check would notice Metal disappearing. → Task 3.

---

### Task 1: Build Metal for darwin-arm64

**Files:**
- Modify: `scripts/48-whisper.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `libggml-metal.a` in the darwin-arm64 prefix, `-lggml-metal` and the three frameworks in `whisper.pc`. Tasks 3 and 4 assert against these.

- [ ] **Step 1: Turn Metal on for arm64 only**

`scripts/48-whisper.sh:253` currently forces it off for both darwin targets:

```
WHISPER_CMAKE_COMMON_ARG="${WHISPER_CMAKE_COMMON_ARG} -DGGML_METAL=OFF -DGGML_ACCELERATE=OFF"
```

Keep that as the darwin default and override it in the existing `else` arm (the arm64 branch, the one that sets `NM_GGML_CPU_FIXED_NAME` for Apple Silicon) with:

```
-DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON
```

Leave `GGML_ACCELERATE` as it is; changing it is not in scope.

Note while you are in this branch: its comment says "our 10.15 deployment target", and the x86_64 arm sets `-DCMAKE_OSX_DEPLOYMENT_TARGET=10.15.0` explicitly, while the dockerfile's own floor is 10.13. Do not change either — just do not let that comment mislead you into thinking Intel is safe to enable.

- [ ] **Step 2: Work around the clang 18 parse failure**

clang 18 can neither parse ggml's `visionOS` `@available` clauses nor link the `__isPlatformVersionAtLeast` they lower to. Take the pre-macOS-15 path upstream already supports and ships an env switch for:

```sh
metal_src=<path to ggml-metal.m in the whisper checkout>
before=$(grep -c '^#define GGML_METAL_HAS_RESIDENCY_SETS 1' "$metal_src")
[ "$before" -eq 1 ] || { log "Error: expected exactly one GGML_METAL_HAS_RESIDENCY_SETS define, found ${before} — has whisper.cpp changed?"; exit 1; }
sed -i 's/^#define GGML_METAL_HAS_RESIDENCY_SETS 1$/#undef GGML_METAL_HAS_RESIDENCY_SETS/' "$metal_src"
grep -q '^#undef GGML_METAL_HAS_RESIDENCY_SETS' "$metal_src" || { log "Error: residency-sets patch did not apply"; exit 1; }
```

**The count check is the point** (Review Focus 1). A bare `sed` that matches nothing succeeds silently, and the build then fails later with a compiler error nobody connects to this. Fail here, by name.

- [ ] **Step 3: Add the library and frameworks to `whisper.pc`**

The darwin branch of the pkg-config generation is at `scripts/48-whisper.sh:648`:

```
    elif [[ ${TARGET_OS} == "darwin" ]]; then
        lib_flags+=" -lggml-blas"
        lib_private_flags+=" -lz"
```

For arm64 add `-lggml-metal` **in the slot Vulkan occupies on other platforms** — before `-lggml-cpu`, with a trailing `-lggml-base` — plus:

```
-framework Foundation -framework Metal -framework MetalKit
```

pkg-config passes `-framework` flags through a `Libs:` line intact; that was verified. Adding them to the dockerfile's `ENV LDFLAGS` instead is the house style and is free because of `-dead_strip_dylibs`. Pick one, and say in a comment which and why.

- [ ] **Step 4: Guard the embedded blob**

After the build, assert the shader source really landed (Review Focus 2). The section is `__DATA,__ggml_metallib` and the research measured 609,531 bytes:

```sh
blob=$(<inspect the __DATA,__ggml_metallib section size in libggml-metal.a or the linked binary>)
[ "${blob:-0}" -gt 400000 ] || { log "Error: embedded Metal shader blob is ${blob:-0} bytes, expected ~600 KB — GGML_METAL_EMBED_LIBRARY did not take"; exit 1; }
```

A floor rather than an exact match, so an upstream shader change does not break the build, but an empty or truncated section does.

- [ ] **Step 5: Build it**

Build darwin-arm64 far enough to produce `libggml-metal.a` and link `whisper-cli`. The research did this from the first 157 lines of `ffmpeg-darwin-arm64.dockerfile` verbatim — reuse that recipe rather than inventing one, and note that the dockerfile runs osxcross's `build.sh` *before* the cross `ENV CC/CXX` and bakes `${PREFIX}/osxcross/bin` into `ENV PATH`, which is why a harness that lifts all ENV up front fails. Copy the gitignored `scripts/patches/` from the main checkout first.

Expected: `libggml-metal.a` exists, `whisper-cli` links, `cmake --install` succeeds.

- [ ] **Step 6: Prove both guards fail**

Break each deliberately on a scratch copy: change the residency `#define` so the count is 0, and truncate or empty the blob. Confirm each fails the build with its own message, then restore. A guard nobody has watched trigger is not a guard — this project has produced seven checks that passed while testing nothing.

- [ ] **Step 7: Commit**

```bash
git add scripts/48-whisper.sh
git commit -m "feat(darwin): build ggml's Metal backend for arm64 with the shaders embedded"
```

---

### Task 2: Do not pay for shaders nobody asked for

**Files:**
- Modify: `scripts/includes/ggml_cpu_dispatch.c`
- Possibly modify: `scripts/includes/af_whisper.c`

**Interfaces:**
- Consumes: Task 1's build.
- Produces: on darwin, `use_gpu=0` and `NOMERCY_GGML_GPU=0` avoid registry construction entirely. Task 3 asserts it.

**This is the decision the spec exists to make, so read its rationale before changing anything.** ggml compiles its shaders when the backend registry is constructed. This codebase reaches that through `nm_ggml_gpu_usable()`, which `af_whisper.c:153` calls **unconditionally, on its own line, before `use_gpu` is read**. With Metal on, every macOS run pays first-use shader compilation — `use_gpu=0` included.

That unconditional call is a crash fix, not an oversight: on Linux it used to sit behind `use_gpu &&`, which short-circuited the ICD guard away on exactly the option a user reaches for when a GPU misbehaves, and the process then died inside `ggml_backend_load_all()`. **On darwin there is no ICD guard, no hostile third-party drivers and no crash to prevent** — the guard is compiled out for non-Windows, non-Apple targets.

- [ ] **Step 1: Write the failing check first**

Before changing behaviour, add a check that a `use_gpu=0` darwin run does **not** construct the registry. ggml logs its Metal initialisation; capture that, or instrument `nm_backend_once()`. Run it against Task 1's build and watch it **fail** — it must fail now, or it is not measuring the thing.

- [ ] **Step 2: Defer on darwin only**

Make the deferral `#if defined(__APPLE__)` (or the existing darwin/fixed-mode conditional, whichever the file already uses — match it rather than adding a second style). Linux and Windows keep the unconditional call.

Write the comment that stops someone harmonising the two later:

```c
/* darwin defers this; Linux and Windows must not.
 *
 * The unconditional call on the other platforms is a crash fix: it used to be
 * the right-hand side of an && with the filter's use_gpu option, which
 * short-circuited the ICD guard away on exactly the option a user reaches for
 * when a GPU is causing trouble, and the process then died in
 * ggml_backend_load_all(). Here there is no ICD guard and no hostile driver to
 * survive -- what registry construction costs on darwin is Metal shader
 * compilation, seconds of it, on every run including use_gpu=0. So darwin
 * waits until it knows a GPU is actually wanted. Do not unify these.
 */
```

- [ ] **Step 3: `NOMERCY_GGML_GPU=0` must also skip it**

The spec requires both escape hatches to avoid the cost, not just `use_gpu=0`. Check where that variable is read and make sure the darwin path honours it before construction.

- [ ] **Step 4: Run the check from Step 1 and watch it pass**

Then confirm the GPU path still works: `use_gpu=1` must construct the registry and report `mtl`.

- [ ] **Step 5: Prove Linux is untouched (Review Focus 3)**

Build linux-x86_64 and confirm `nm_ggml_gpu_usable()` is still reached unconditionally — the Mesa-container assertions from the Vulkan work are the existing evidence; re-run them rather than reasoning. A regression here reinstates a crash on machines with hostile drivers.

- [ ] **Step 6: Commit**

```bash
git add scripts/includes/
git commit -m "fix(darwin): defer backend discovery until a GPU is actually wanted"
```

---

### Task 3: Assert Metal, because nothing does today

**Files:**
- Modify: `tests/lib/cpu-variant.sh`
- Modify: `tests/lib/cpu-variant.ps1` if it has an equivalent helper
- Modify: `README.md`

**Interfaces:**
- Consumes: Tasks 1 and 2.
- Produces: assertions that fail if Metal disappears or if the deferral regresses.

- [ ] **Step 1: Give darwin an arm in the backend helper**

`tests/lib/cpu-variant.sh:226-231`:

```sh
vulkan_platform_has_backend() {
	case "$1" in
	*darwin* | *freebsd*) return 1 ;;
	*) return 0 ;;
	esac
}
```

darwin returns false, so **Metal is asserted by nothing**. Add a darwin-arm64 arm that asserts the Metal backend is linked, in the same greppable style the Vulkan checks use for platforms a runner cannot execute. Keep `freebsd` and darwin-x86_64 returning false.

- [ ] **Step 2: Assert the metadata string is `mtl`**

Not `metal`. `GGML_METAL_NAME` is `"MTL"`, and an assertion written against the wrong string would pass on a CPU fallback.

- [ ] **Step 3: Prove both assertions can fail**

Point them at a binary built without Metal and confirm they report failure. Then at Task 1's build and confirm they pass.

- [ ] **Step 4: README**

Document that darwin-arm64 gets Metal, that darwin-x86_64 deliberately does not and why, that the reported backend is `mtl`, and that the first run compiles shaders once. Write it for someone deciding whether to use it, not someone who already knows.

- [ ] **Step 5: Commit**

```bash
git add tests/lib/ README.md
git commit -m "test(darwin): assert the Metal backend and the mtl metadata value"
```

---

### Task 4: Full build, and what the owner runs on their Mac

**Files:**
- Create: `tools/metal/verify-on-mac.sh`

**Interfaces:**
- Consumes: Tasks 1-3.
- Produces: a darwin-arm64 artifact and a script the owner runs to answer the four release gates.

- [ ] **Step 1: Full darwin-arm64 build**

Through the real dockerfile, not the trimmed research recipe. Confirm the guards from Task 1 ran, the artifact is produced, and record the size delta against the previous darwin-arm64 artifact — the research measured +767 KB on `whisper-cli`, of which 609,531 B is the shader source.

- [ ] **Step 2: Everything verifiable without Apple hardware**

The Metal backend is linked, the blob is present and the right size, the binary is still static with no new runtime dependency beyond the frameworks, and the existing darwin assertions still pass.

- [ ] **Step 3: Write the Mac verification script**

`tools/metal/verify-on-mac.sh`, to be run by the owner on Apple Silicon. It must answer the four gates and print each as a clear pass or fail:

1. **The embedded MSL compiles at all.** Run whisper once with `use_gpu=1` and show ggml's Metal initialisation succeeding.
2. **First-use compilation time.** Time the first run against a second run; report both. The spec expects a few seconds, negligible for a library transcode and not nothing for a one-shot.
3. **A device is selected in a daemon/SSH context, not just an interactive login.** The media server runs as a service; test it that way, because this is the gate most likely to be missed and most likely to fail.
4. **Output matches the CPU path**, to the standard the Vulkan work used, **and Metal actually beats the fixed-level NEON CPU build.** If it does not beat CPU, this phase is not worth shipping and the script should say so plainly.

Have it print a copy-pasteable summary block, so the result can be pasted into #69 without retyping.

- [ ] **Step 4: Commit**

```bash
git add tools/metal/verify-on-mac.sh
git commit -m "test(darwin): script the four Metal release gates for Apple hardware"
```

- [ ] **Step 5: Hand over, do not self-certify**

Report the build evidence and stop. **Do not describe Metal as working**; nothing in this plan proves that. The release decision belongs to the owner once the four gates come back from their Mac.
