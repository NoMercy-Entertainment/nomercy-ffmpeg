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
3. ~~The darwin deferral leaking into Linux or Windows~~ — moot: Task 2 is dropped and no deferral exists. The Linux and Windows path is unchanged by this feature.
4. ~~`use_gpu=0` still paying for shader compilation~~ — this is now accepted behaviour, documented in the README, and measured by Task 4 gate 2 rather than fixed.
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

### Task 2: DROPPED — an optimisation for a cost nobody has measured

**Status: not implemented, and deliberately so. Do not pick this up without a number.**

This task asked for registry construction to be deferred on darwin so that a run
which wants no GPU would not pay ggml's one-off Metal shader compilation. Three
things were wrong with it.

**1. It named the wrong code.** The task pointed at `nm_ggml_gpu_usable()` and
`af_whisper.c:153`. The calls that actually drag ggml's registry in are
`nm_backend_once()` at the top of `nm_ggml_backend_init()` (before `use_gpu` is
read, which is the stemsplit path) and, for whisper, whisper.cpp itself. Section
5.5 of the research says these files need no change at all, which contradicted
this task outright; the contradiction was in the documents before any code was
written.

**2. Half of it is not achievable in our code.** Verified against the pinned
sources (whisper.cpp `v1.9.1` / ggml 0.15.1), recorded in
`.superpowers/sdd/2026-09-27-metal-backend/registry-construction-findings.md`:

- `ggml_backend_cpu_init()` does **not** construct the global registry: it
  dispatches straight through `ggml_backend_cpu_reg()`, a function-local static,
  and never reaches `get_reg()`. So a CPU-only stemsplit run genuinely can avoid
  the compile.
- `whisper_backend_init()` **does**, unavoidably: `whisper.cpp:1339` loops over
  `ggml_backend_dev_count()` for ACCEL backends and that loop is *not* gated by
  `params.use_gpu` (only `whisper_backend_init_gpu()`'s own loop is). So for the
  whisper filter no change of ours avoids it.
- `ggml_backend_load_all()` only touches `get_reg()` when it finds a matching
  dynamic backend library on disk. Every backend here is statically linked, so
  that call is doing nothing for us either way.
- The one real lever is ggml's own `GGML_METAL_DEVICES`, read at
  `ggml-metal.cpp:914-916` as `g_devices = atoi(env)` and consumed by
  `for (int i = 0; i < g_devices; ++i)`. Setting it to `0` skips device and
  library init entirely and registers cleanly with zero devices. But it is
  process-wide and latches on first call, so one filter asking for no GPU could
  silently take the GPU away from another filter in the same filtergraph.
  **Note the opposite sense for Vulkan:** `GGML_VK_VISIBLE_DEVICES` is a list of
  device *indices*, so `0` there means "use device 0". Do not carry this across.

**3. Nothing establishes that there is a problem.** The cost is stated nowhere as
a measured number — the spec and the research both reason about it. It could be
three seconds or a third of a second. The owner's decision, 2026-09-28: build
macOS with Metal and stop there; measure the compile on Apple hardware via Task
4, and only revisit this if the number turns out to matter.

**If it is ever revisited,** the achievable shape is: darwin-only C, no new
environment variable of ours, deferring `nm_backend_once()` for the stemsplit CPU
path; plus, only if the measured cost justifies the filtergraph hazard above,
ggml's `GGML_METAL_DEVICES=0`. The comment below was written for the original
plan and is kept because its warning still holds for anyone touching the Linux or
Windows path:

> The unconditional call on the other platforms is a crash fix: it used to be the
> right-hand side of an `&&` with the filter's `use_gpu` option, which
> short-circuited the ICD guard away on exactly the option a user reaches for
> when a GPU is causing trouble, and the process then died in
> `ggml_backend_load_all()`. Do not unify darwin with them.

---

### Task 3: Assert Metal, because nothing does today

**Files:**
- Modify: `tests/lib/cpu-variant.sh`
- Modify: `tests/lib/cpu-variant.ps1` if it has an equivalent helper
- Modify: `README.md`

**Interfaces:**
- Consumes: Task 1. (Task 2 is dropped; assert nothing about deferral.)
- Produces: assertions that fail if Metal disappears.

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
- Consumes: Tasks 1 and 3.
- Produces: a darwin-arm64 artifact and a script the owner runs to answer the four release gates.

- [ ] **Step 1: Full darwin-arm64 build**

Through the real dockerfile, not the trimmed research recipe. Confirm the guards from Task 1 ran, the artifact is produced, and record the size delta against the previous darwin-arm64 artifact — the research measured +767 KB on `whisper-cli`, of which 609,531 B is the shader source.

- [ ] **Step 2: Everything verifiable without Apple hardware**

The Metal backend is linked, the blob is present and the right size, the binary is still static with no new runtime dependency beyond the frameworks, and the existing darwin assertions still pass.

- [ ] **Step 3: Write the Mac verification script**

`tools/metal/verify-on-mac.sh`, to be run by the owner on Apple Silicon. It must answer the four gates and print each as a clear pass or fail:

1. **The embedded MSL compiles at all.** Run whisper once with `use_gpu=1` and show ggml's Metal initialisation succeeding.
2. **First-use compilation time — this is now the number that settles a dropped decision, so it is the most important thing the script produces.** Report three timings, not one:
   - `ffmpeg -version`, which never builds a filtergraph and so never touches ggml's registry — the baseline with no shader compile in it at all;
   - a one-second `stemsplit` run with `use_gpu=0`, which is what the owner actually runs day to day and which *does* pay the compile today;
   - the same run again in a fresh process, to show whether anything is cached between processes.

   The interesting figure is the **subtraction**: second minus first is what a macOS user who wants no GPU pays for Metal being linked in. ggml logs `"using embedded metal library"` and `"loaded in %.3f sec"`, so print those lines verbatim too rather than only wall-clock. Task 2 was dropped because this number does not exist; if it comes back large, that decision gets reopened with the number in hand, and if it comes back small the question is closed for good. Say which, plainly, in the summary block.
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
