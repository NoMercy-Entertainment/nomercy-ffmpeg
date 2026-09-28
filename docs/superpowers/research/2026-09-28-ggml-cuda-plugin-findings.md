# CUDA as an optional ggml plugin — findings

Date: 2026-09-28. Research only, nothing committed besides this file, no build scripts touched.
Evaluates the owner's idea: keep the base ffmpeg static-Vulkan as it is today (~225 MB), and let
a user who wants CUDA drop in a separate file that ggml loads at runtime via its own
`ggml_backend_load_all()` mechanism, instead of linking cuBLAS/cuBLASLt into the shipped binary.

Sources read directly, not assumed: `ggml/src/ggml-backend-reg.cpp`, `ggml-backend-dl.cpp`,
`ggml-backend-impl.h`, `ggml/src/CMakeLists.txt`, `ggml/src/ggml-cuda/CMakeLists.txt`,
`ggml/CMakeLists.txt`, `ggml-cuda.cu` — all from the pinned tree (whisper.cpp v1.9.1,
`f049fff`, ggml 0.15.1), cloned fresh into container `cuda-size-build` (left running from the
prior round, reused rather than re-cloning). Also read: this project's
`scripts/includes/vk_loader_shim.c`, `scripts/includes/ggml_cpu_dispatch.c`,
`docs/superpowers/specs/2026-09-23-ggml-gpu-backends-design.md`, and
`docs/superpowers/specs/2026-09-26-nvenc-wsl2-design.md` (read via
`git show origin/feat/nvenc-wsl2-dynamic:...`, `MSYS_NO_PATHCONV=1`).

A real DL-mode build (`-DGGML_BACKEND_DL=ON -DBUILD_SHARED_LIBS=ON -DGGML_CUDA=ON
-DCMAKE_CUDA_ARCHITECTURES=86-real -DGGML_NATIVE=OFF`) was run to completion in that container,
producing real `libggml-base.so`, `libggml.so`, `libggml-cuda.so` and a DL-mode `whisper-cli`. A
second, short-lived container (`cuda-plugin-test`, `--gpus all`, mounting the same `cuda-size-work`
volume, based on the project's own `nomercyentertainment/ffmpeg-base:latest`) then ran that
`whisper-cli` against the real RTX 3070 to see whether the plugin actually loads and runs — not
just links. **It worked, end to end, on the first try**, and every number/quote below marked
**[measured]** is from that real build and run, not inferred. The one thing not built this
session is a *static-ggml-base* host trying to dlopen this same plugin — see the note at the end
of §2.

---

## 1. Can it work at all, given a statically linked host?

**No — a fully static executable cannot host this route. [reasoned, doubly corroborated]**

This project already proved the general shape of this limit: `scripts/includes/vk_loader_shim.c`
exists specifically because "Opening a shared library from a static executable works; it is the
reverse — a loaded module calling back into the executable — that does not [work]." The
2026-09-23 GPU-backends design doc states the CUDA-specific case directly: "we have since proven
a fully static executable **cannot** export its symbols to a `dlopen`ed module, so that route is
closed on linux and freebsd" (§1, `2026-09-23-ggml-gpu-backends-design.md`).

**The mechanism matters and it is not what that framing implies.** ggml's `GGML_BACKEND_DL`
plugins do **not** work by calling back into symbols the host executable exports. They work by
the module carrying its own ordinary shared-library dependency:

- `ggml/src/CMakeLists.txt:265-283` (`ggml_add_backend_library()`): under `GGML_BACKEND_DL`, each
  backend is built as a CMake `MODULE`, and — critically — `target_link_libraries(${backend}
  PRIVATE ggml-base)` is an ordinary link against the `ggml-base` target, which `GGML_BACKEND_DL`
  forces to be a real shared object: `if (GGML_BACKEND_DL AND NOT BUILD_SHARED_LIBS)
  message(FATAL_ERROR "GGML_BACKEND_DL requires BUILD_SHARED_LIBS")` (line 188-190).
- The module is opened with a plain `dlopen(path.string().c_str(), RTLD_NOW | RTLD_LOCAL)`
  (`ggml-backend-dl.cpp:35`) — `RTLD_LOCAL`, not `RTLD_GLOBAL`, so the module's own symbols are
  never injected into the process's global scope for anyone else to find either.

So the module's undefined `ggml-base` symbol references are resolved at load time via its own
`DT_NEEDED` entry for `libggml-base.so.<soversion>` — an ordinary SONAME lookup — not via the
host executable's exported dynamic symbol table.

**Is `-rdynamic`/`--export-dynamic` on the dynamic executable sufficient? No, and it is not
actually the relevant lever.** `feat/nvenc-wsl2-dynamic`'s design (`git show
origin/feat/nvenc-wsl2-dynamic:docs/superpowers/specs/2026-09-26-nvenc-wsl2-design.md`) gives the
ffmpeg binary an ELF interpreter but explicitly keeps "every third-party library... statically
linked — this is not a move to dynamic dependencies" (its own "What changes" section). Under that
plan, `ggml-base` stays whole-archived into the ffmpeg binary exactly as today (confirmed: our
current static build already does "a whole-archive relink of libwhisper.a + libggml-base.a +
libggml.a + libparakeet.a", per the comment at `scripts/includes/ggml_cpu_dispatch.c` line ~115).
There is no `libggml-base.so` anywhere in that binary's dependency graph, `-rdynamic` or not, so a
standard `GGML_BACKEND_DL`-built module's `DT_NEEDED` for `libggml-base.so.0` has nothing correct
to resolve against. `-rdynamic` would matter for a *different* plugin pattern — a module with
deliberately unresolved externs that the host's own dynamic symbol table satisfies — which is not
what upstream's unmodified `GGML_BACKEND_DL` build produces, and patching that build is out of
scope.

**Conclusion:** `feat/nvenc-wsl2-dynamic`'s dynamic executable (dynamic against glibc only) is a
*necessary* prerequisite — dlopen doesn't work at all from a fully static binary — but it is
**not sufficient**. Getting the plugin route to work also requires our own ffmpeg to stop
whole-archiving `ggml-base` statically and instead link it as a real shared object
(`libggml-base.so`) that ships alongside the executable, so that both the host and the CUDA
module resolve the *same* file. See §2 for what happens if that second step is skipped.

**[measured, confirmed]** This was verified directly: `readelf -d libggml-cuda.so` lists, among
its `NEEDED` entries, `libggml-base.so.0`, `libcudart.so.12`, `libcublas.so.12`, `libcuda.so.1`,
`libnccl.so.2` — a plain SONAME dependency list, exactly as the CMake reading predicted, nothing
resolved by symbol interposition against a caller. And `whisper-cli` built in the *same*
`BUILD_SHARED_LIBS=ON` configuration is itself tiny (998 KB) and `NEEDED`s only `libwhisper.so.1`
and `libggml.so.0` (which itself pulls `libggml-base.so.0` in transitively) — i.e. the host and
the plugin share the identical `ggml-base`, and it ran correctly end to end (see §2).

---

## 2. The two-copies-of-ggml problem

**Real, and structural — not a link-time nuisance that a flag avoids. [reasoned from source,
partially measured]**

`GGML_BACKEND_DL` is an **all-or-nothing switch for the whole ggml build it's set on**, not a
per-backend option. `ggml_add_backend_library()` (`ggml/src/CMakeLists.txt:265-283`) branches on
one global `GGML_BACKEND_DL` value for every backend it's called for — Vulkan, CPU, CUDA alike —
and `add_library(ggml-base ...)` (line 192) takes the ambient `BUILD_SHARED_LIBS`, which
`GGML_BACKEND_DL` forces ON (line 188-190). **There is no supported way, in one ggml
configuration, to compile Vulkan and CPU statically while making only CUDA a loadable module.**
Building `libggml-cuda.so` at all means running a **second, separate** cmake configuration of
ggml/whisper.cpp with `GGML_BACKEND_DL=ON`, producing its own private `libggml-base.so`,
`libggml.so`, `libggml-cpu.so`, and `libggml-cuda.so` — architecturally unrelated to whatever our
main static ffmpeg build whole-archives.

**Measured, this session:** that second build's `libggml-base.so.0.15.1` is **913,472 bytes**
(≈0.9 MB, unstripped), `SONAME libggml-base.so.0`, `NEEDED`: libgomp, libstdc++, libm, libgcc_s,
libc. So the "second copy" costs almost nothing in size — the risk is entirely in **process-wide
state**, not disk space.

**Can a plugin be built against a host-*provided* ggml-base instead?** Yes, in principle, but
only by adopting exactly the model upstream's own DL-mode `whisper-cli`/`llama-cli` use: the
*host executable itself* is also built with `BUILD_SHARED_LIBS=ON`, so it `NEEDED`s the same
`libggml-base.so.0` / `libggml.so` the module does — one file, mapped once by the dynamic linker,
shared by both. **That is not our situation and would not become our situation just by adding a
CUDA plugin build**: our ffmpeg's own ggml-base would have to switch from whole-archive-static to
a real shared dependency shipped next to the executable. Doing that without patching ggml's CMake
(out of scope) is possible — it only means changing how *our* build invokes cmake for the
non-CUDA parts, not changing ggml source — but it is a bigger structural change than "add one
optional file"; see §5's note on the distribution-model line.

**What breaks if it isn't done — i.e., if `libggml-cuda.so` is dropped next to a host that keeps
whole-archiving ggml-base statically, as `feat/nvenc-wsl2-dynamic` does today:**

`ggml_backend_load_all()` — already called unconditionally by this project today
(`scripts/includes/af_whisper.c:168`, `ff_thread_once(&init_static_once, ggml_backend_load_all)`)
— runs inside the **host's own statically-linked** copy of `ggml-backend-reg.cpp` (that file is
part of the separate `ggml` target, `ggml/src/CMakeLists.txt:242-244`, also whole-archived today).
When it `dlopen()`s `libggml-cuda.so`, the dynamic linker sees a `DT_NEEDED` for
`libggml-base.so.0` that **no already-loaded shared object satisfies** (the host's ggml-base is
static, invisible to the dynamic linker as a named `.so`), so it loads a **fresh, independent**
`libggml-base.so` from disk — a second, unsynchronized instance of every process-wide global
`ggml-base` owns: the log-callback state (`ggml_log_set()`), OpenMP/pthread threadpool
bookkeeping, and any other lazily-initialized global table in `ggml.c` / `ggml-alloc.c` /
`ggml-backend.cpp` / `ggml-threading.cpp` (all compiled into `ggml-base`, confirmed from the
source list at `ggml/src/CMakeLists.txt:192-209`).

The backend **registry** itself (the `devices` vector `nm_gpu_at()` walks) is *not* duplicated —
it lives in the outer `ggml` target the host already statically embeds, and the CUDA module's
returned `ggml_backend_reg_t` gets appended into that one singleton normally, through plain
C-struct/vtable interop that should work given identical struct layouts from the same pinned
header version. The duplication is specifically in **ggml-base's own runtime state**. Two
concrete consequences, neither a guaranteed crash, both real:

- Any custom log redirection this project adds later (routing ggml's log lines through `av_log`)
  would silently **not** catch anything the CUDA backend logs, because that goes through the
  module's own independent logger state.
- Any ggml-base global that assumes "exactly one instance per process" (one-time init flags,
  thread-pool sizing decided once) initializes twice — wasted resource, not a hard failure, but
  unverified beyond that reasoning.

**What was actually verified this session, and what remains open.** The **shared-ggml-base**
configuration — host `whisper-cli` also built `BUILD_SHARED_LIBS=ON`, so it and
`libggml-cuda.so` both `NEEDED` the exact same `libggml-base.so.0` — was built and **run for
real** against the RTX 3070 in `cuda-plugin-test`:

```
load_backend: loaded CUDA backend from /work/build-dl-plugin/bin/libggml-cuda.so
load_backend: loaded CPU backend from /work/build-dl-plugin/bin/libggml-cpu.so
...
whisper_backend_init_gpu: using CUDA0 backend
...
[00:00:00.000 --> 00:00:11.000]   And so my fellow Americans, ask not what your country can do
for you, ask what you can do for your country.
```

— the same transcript as every CPU and statically-linked-CUDA run in this project's prior
sessions, encode time 5.1s (vs. the CPU backend's ~2s on the small `base.en` model on this
machine, consistent with earlier findings that this model is too small for CUDA to show its
usual advantage). **This is real, working, single-copy confirmation of the plugin mechanism
end to end** — the load, the registration, the device selection, and a correct inference all
happened through a genuinely separate `.so` `dlopen`'d at runtime.

**What this does *not* test:** a host that keeps whole-archiving `ggml-base` statically (today's
actual static ffmpeg, or `feat/nvenc-wsl2-dynamic`'s dynamic-but-static-libs binary) trying to
load this same `libggml-cuda.so`. Building that specific combination — no CUDA compiled in, ggml-
base still a static archive, then dropping the DL-built `libggml-cuda.so` next to it and letting
`ggml_backend_load_all()` find it — did not fit in this session's time budget. The two-copies
reasoning above stands as **[reasoned, not empirically exercised]** for that specific
configuration: dlopen's dependency resolution does not care whether the *caller* is static or
dynamic, only whether `libggml-base.so.0` is findable (via `LD_LIBRARY_PATH`/rpath/ld.so.conf) —
so shipping one next to the plugin would make the load succeed either way, but only the
shared-config case (this session's real test) confirms it also *runs correctly*. The static-host
case is the one that would actually create two independent copies of ggml-base's globals, and
that specific run was not observed.

---

## 3. Where does it look, and what must the file be called?

**[measured, directly from source, exact line numbers]**

`ggml_backend_load_all()` → `ggml_backend_load_all_from_path(nullptr)`
(`ggml-backend-reg.cpp:555-559`) calls `ggml_backend_load_best(name, silent, dir_path)` for a
fixed list of backend names in this order (`:566-580`):

```
blas, zendnn, cann, cuda, hip, metal, rpc, sycl, vulkan, virtgpu, opencl, hexagon, musa, openvino, cpu
```

**`cuda` is tried before `vulkan`** — this is the load/registration-order fact §5 depends on.

`ggml_backend_load_best("cuda", silent, nullptr)` (`:473-553`):

- Filename prefix/extension: `backend_filename_prefix()` = `"libggml-"` (Linux) / `"ggml-"`
  (Windows); extension `.so` / `.dll` (`:458-467`). So it scans for files matching
  `libggml-cuda-*.so` (Linux) / `ggml-cuda-*.dll` (Windows).
- Search paths, when `dir_path` is `nullptr` (our case) (`:483-490`): 1) `GGML_BACKEND_DIR`, a
  **compile-time** CMake define (not set in our build), 2) the **executable's own directory**
  (`get_executable_path()`, via `/proc/self/exe` on Linux, `GetModuleFileNameW` on Windows,
  `:394-450`), 3) the **current working directory** (`fs::current_path()`).
- Each wildcard match is `dlopen`'d and scored via an exported `ggml_backend_score()` symbol
  (`:515`) — used by, e.g., the CPU backend's multiple ISA variants. **CUDA does not define
  one**: `ggml-cuda.cu:5765` has only `GGML_BACKEND_DL_IMPL(ggml_backend_cuda_reg)`, no
  `GGML_BACKEND_DL_SCORE_IMPL` (confirmed absent by grep across `ggml-cuda/`). So the wildcard
  path always scores 0 for CUDA, and it always falls through to the **exact-filename fallback**
  (`:538-551`): load `libggml-cuda.so` (no suffix) if present in any search path, in order.

**`GGML_BACKEND_PATH` is not a search-path variable.** It is read once, *after* every named
backend above has already been tried (`ggml_backend_load_all_from_path`, checked at
`ggml-backend-reg.cpp:582`), and force-loads exactly **one** literal file path via
`ggml_backend_load()` — a manual override, not a directory to scan.

**Practical answer:** ship one file, named exactly `libggml-cuda.so` (Linux) / `ggml-cuda.dll`
(Windows), in the **same directory as the ffmpeg executable** — the most robust of the three
search locations for a CLI tool invoked from arbitrary working directories. No wildcard/version
suffix is needed or looked for, since CUDA never scores itself.

---

## 4. What is actually in the package, and how big?

**[measured, this session + carried from the 2026-09-28 dynamic-ffmpeg findings]**

| component | size | source |
|---|---|---|
| `libcudart.so` | 724 KB | measured, prior session, this CUDA 12.9.1 devel image |
| `libcublas.so` | 101 MB | measured, prior session |
| `libcublasLt.so` | **715 MB** | measured, prior session |
| `libggml-base.so` (DL build) | 0.9 MB | measured, this session |
| `libggml-cuda.so` itself, sm_86 only, stripped | **36.9 MB** | measured, this session |

**[measured]** `readelf -d libggml-cuda.so`'s full `NEEDED` list: `libggml-base.so.0`,
`libcudart.so.12`, `libcublas.so.12`, `libcuda.so.1` (the driver), `libnccl.so.2`, `libstdc++.so.6`,
`libm.so.6`, `libgcc_s.so.1`, `libc.so.6`. Note **`libcublasLt.so.12` is not a direct `NEEDED`
entry of our module** — it is pulled in transitively by `libcublas.so.12`'s own dependency list
(confirmed via `ldd` on the previous session's dynamically-linked `whisper-cli`), exactly as
expected from the CMakeLists reading: our own `target_link_libraries` never names `cublasLt` in
the non-static branch, NVIDIA's own `libcublas.so` does. This 36.9 MB figure is **sm_86 only**
(single architecture, matching the owner's RTX 3070); a multi-arch package (sm_75/86/89/90, per
the prior session's size table) would carry more compiled kernel variants and be correspondingly
larger, though nowhere near cuBLASLt's scale — the kernel code is the "tens of MB" part, not the
hundreds-of-MB part.

**New this session — not previously flagged:** ggml's CUDA backend links **NCCL by default**.
`ggml/CMakeLists.txt:210`: `option(GGML_CUDA_NCCL "ggml: use NVIDIA Collective Comm. Library"
ON)`. The DL-mode configure log confirms it activates against this project's own base image:
`-- Found NCCL: /usr/lib/x86_64-linux-gnu/libnccl.so`, `-- Including CUDA backend`. **[measured]**
`libnccl.so.2.27.3` in that image is **411,566,008 bytes (≈411.6 MB)**. NCCL is multi-GPU
collective communication — irrelevant to whisper/stemsplit's single-device inference on a desktop
RTX 3070 — and it is **not** a hard dependency: `ggml-cuda/CMakeLists.txt:185-191` only links it
`if (GGML_CUDA_NCCL)`. **Action, independent of static-vs-plugin:** pass `-DGGML_CUDA_NCCL=OFF`
whenever CUDA is built, in either distribution model — skipping this silently adds another ~400
MB (bundled) or an undocumented new host dependency (`libnccl.so.2`, not resolved), on top of
everything below.

**cuBLASLt is not avoidable by choosing the dynamic/plugin route.** The prior session's own
`cuda-run-test` container (still present, inspected this session) shows a **dynamically linked**
`whisper-cli` — `cudart`/`cublas` as ordinary `NEEDED` `.so` entries, not statically archived —
whose `ldd` output still lists `libcublasLt.so.12 => /usr/local/cuda/lib64/libcublasLt.so.12`,
because NVIDIA's own `libcublas.so` carries a transitive `DT_NEEDED` on `libcublasLt.so`
regardless of how *our* CMake links against `CUDA::cublas`. There is no build flag on our side
that removes it; only patching ggml (out of scope) or not shipping cuBLAS-backed CUDA at all would.

**So, plainly: the honest number for "the CUDA plugin package" is dominated by cuBLASLt and lands
close to 800 MB, not 100 MB**, once NCCL is correctly stripped out. `libggml-cuda.so` itself
(just our compiled kernels, no cuBLAS statically inside it in this mode) is the only piece likely
to be "tens of MB" — everything else is NVIDIA's own runtime.

**Could the user instead be told to install the CUDA Toolkit and get almost nothing from us?**
Yes, this is real and should be stated as an alternative, not folded into "the package is
~800MB": if the optional download is *only* `libggml-cuda.so` (tens of MB) plus a short list of
required NVIDIA `.so` SONAMEs, and the user is expected to already have `libcudart.so.12`,
`libcublas.so.12`, `libcublasLt.so.12` on their system (from a CUDA Toolkit or driver-bundled
runtime install), the download shrinks to near-nothing — at the cost of a materially heavier
support ask than "you need an NVIDIA driver" (what Vulkan/NVENC/NVDEC/CUVID already require):
cuBLAS/cuBLASLt are CUDA Toolkit runtime packages, not part of the GPU driver, and most
driver-only self-hosted boxes (WSL2/Docker Desktop machines with a working `nvidia-smi`) do not
have them. Both options are legitimate; which one to offer is the owner's distribution-policy
call, not a technical one — but it should be made informed of the ~800 MB number, not "CUDA is
optional so it must be small."

---

## 5. What would have to change in this repo

**Selection-order bug — confirmed to apply identically to the plugin route, not just a
statically-linked CUDA. [measured, from source]**

`ggml_backend_registry()`'s constructor (`ggml-backend-reg.cpp`, per the 2026-09-28 dynamic
findings doc, lines 116-165) registers backends `CUDA → Metal → SYCL → Vulkan → ...` in fixed
source order, and `ggml_backend_load_all_from_path()` calls `ggml_backend_load_best("cuda", ...)`
**before** `ggml_backend_load_best("vulkan", ...)` (§3 above, lines 569 vs. 574) — same ordering
problem, same root cause, whether CUDA arrives statically linked or as a dropped-in
`libggml-cuda.so`: load order determines registration order determines enumeration order.

This project's own `nm_gpu_at(gpu_device)` (`scripts/includes/ggml_cpu_dispatch.c:1315-1337`)
walks `ggml_backend_dev_count()` in that raw order and returns the `gpu_device`'th `GPU`/`IGPU`
device with **no backend-name filtering at all**. `gpu_device=0` — the default for both `whisper`
and `stemsplit` — is "whichever backend happened to register first and has a device." The moment
`libggml-cuda.so` is present and loads on a machine that also has a working Vulkan driver (the
owner's own desktop), device 0 silently becomes CUDA. The prior findings doc already measured
Vulkan running 2.3-12.3x faster than CUDA-with-cuBLAS would on this exact RTX 3070 for these two
graphs — so an untouched selection rule turns "drop in an optional file" into a silent regression
for every existing command line on a dual-backend machine, with no error and no changed flags.
Checked and confirmed still absent on `dev`, `feat/nvenc-wsl2-dynamic`, and
`research/cuda-vs-vulkan` — no branch has this fix.

**Selection rule this needs, to ship with the plugin, not after it:** `nm_backend_discover()` /
`nm_gpu_at()` must stop using raw enumeration order as the selection key. Concretely: walk the
full device list once, bucket each device by `ggml_backend_dev_backend_reg(dev)` →
`ggml_backend_reg_name(reg)` (lower-cased — `nm_backend_discover()` already does exactly this
fold for its own `nm_gpu_backend_name` field, `ggml_cpu_dispatch.c:1403-1416`), and build the
`gpu_device`-indexed list preferring `vulkan` devices ahead of anything else, `cuda` included.
**Vulkan must stay the default with no configuration change.** An explicit new opt-in (an env
var, e.g. `NOMERCY_GGML_GPU_BACKEND=cuda`, since `gpu_device` is already spoken for as a
same-backend index and would be ambiguous the moment two backend *types* coexist) is needed for
someone who deliberately wants CUDA over Vulkan.

**Other concrete changes:**

- `scripts/48-whisper.sh`: today's commented-out CUDA block (`# if check_enabled "cuda"; then
  ... GGML_CUDA=ON ...`) assumes one static build. It would need replacing with a **second,
  separate** cmake invocation (`GGML_BACKEND_DL=ON -DBUILD_SHARED_LIBS=ON -DGGML_CUDA=ON
  -DGGML_CUDA_NCCL=OFF`, per §2 and §4) producing `libggml-cuda.so` (and, per §2, our main
  ffmpeg build changing ggml-base from whole-archive-static to a shared `libggml-base.so` shipped
  alongside the executable — not a change confined to this one script).
- Dockerfiles: the CUDA devel image / toolkit needs to be present at build time only for
  whichever image builds the optional plugin package — it should **not** become a new dependency
  of the base ffmpeg image, which stays exactly as it builds today.
- `nm_backend_discover()` / `nm_gpu_at()` in `ggml_cpu_dispatch.c`, per the selection rule above.

**Does this cross the owner's "no second artifact for the base download" line?** No, for the
distribution question as asked: the base ffmpeg download stays one file, Vulkan stays default,
and CUDA support is inert until a user deliberately adds a file. But be precise about what
enables that: per §1/§2, making the plugin route work safely (one shared `ggml-base` state, not
two) means the *base* ffmpeg itself has to stop being a single fully-static binary and become "an
executable plus its own `libggml-base.so`" — a change to the "one static binary, self-contained"
promise that `2026-09-23-ggml-gpu-backends-design.md`'s own Non-goals section protected ("If a
GPU backend cannot be made to work inside a static binary, it does not ship — that trade was
already decided"). That is a real, separate concession from "ship an optional add-on file," and
the owner should sign off on it explicitly rather than have it arrive as a side effect of the
CUDA plugin decision.

---

## Summary

1. **Requires a dynamically-linked host — confirmed mechanism, not the one first assumed, and now
   confirmed working end to end.** A fully static binary cannot dlopen a working plugin at all
   (confirmed by this project's own prior Vulkan work). The fix is not "export the host's symbols
   with `-rdynamic`" — ggml's own DL modules link against a named `libggml-base.so` via ordinary
   `DT_NEEDED`, not against the caller; **[measured]** `readelf -d libggml-cuda.so` confirms this
   directly, and a real DL-mode `whisper-cli` (998 KB, `NEEDED libwhisper.so.1`/`libggml.so.0`)
   `dlopen`'d the plugin, found the RTX 3070, and produced a correct transcript running on
   `CUDA0`. `feat/nvenc-wsl2-dynamic` gives a dynamic *executable* but deliberately keeps
   ggml-base statically whole-archived, so it remains necessary but not sufficient on its own —
   what actually made this session's test work is the host *also* dynamically linking ggml-base.
2. **Two copies of ggml-base is a real, structural risk in the static-host configuration**, not a
   flag away: `GGML_BACKEND_DL` is all-or-nothing for an entire ggml build, so a loadable
   `libggml-cuda.so` necessarily comes from a wholly separate build with its own private
   `libggml-base.so` (measured: 0.9 MB, so cheap in size, not in shared state). This session
   verified the **shared-ggml-base** configuration works correctly (§2); it did not build and run
   the **static-ggml-base** configuration this project actually ships today, which is the one
   where a real duplicate-globals risk would appear — that remains reasoned from source, not
   observed.
3. **Search path and filename, quoted from source and confirmed by the real load log:**
   `load_backend: loaded CUDA backend from /work/build-dl-plugin/bin/libggml-cuda.so` — found in
   the executable's own directory with no other configuration, exactly as
   `ggml_backend_load_best()` promises. Ship `libggml-cuda.so` next to the ffmpeg binary; CUDA has
   no score function so no wildcard variant naming is needed; `GGML_BACKEND_PATH` is a one-file
   override, not a search directory.
4. **Package size is ~800 MB, not ~100 MB**, once NCCL (411 MB, on by default, not needed for a
   single desktop GPU) is correctly disabled — cuBLASLt's ~715 MB is unavoidable through any
   build flag on our side (confirmed: not even a direct `NEEDED` of `libggml-cuda.so`, but a
   transitive one through NVIDIA's own `libcublas.so.12`), static or dynamic. The compiled-kernel
   part is small and now measured directly: **36.9 MB stripped for `libggml-cuda.so` itself,
   sm_86 only**. The alternative "tell the user to install the CUDA Toolkit, ship only
   `libggml-cuda.so`" is real and would shrink the download to ~37+ MB, at the cost of a heavier
   support ask than the driver-only bar NVENC/Vulkan set.
5. **The Vulkan-default regression is real and applies identically to the plugin route** (CUDA
   registers before Vulkan in ggml's own fixed load order, regardless of static vs. dynamic), and
   is still unfixed on every branch. It must ship with the plugin support, not after: prefer
   Vulkan by backend name, require explicit opt-in for CUDA. The plugin idea itself does not cross
   the "no second base artifact" line, but making it safe (§2) does require retiring "one fully
   static binary" as an absolute for the base build — a distinct decision the owner should make
   knowingly.

## What is still open

- The **static-ggml-base host + dropped-in plugin** combination — today's actual shipping shape,
  as opposed to the shared-ggml-base configuration this session proved works — was not built and
  run. This is the one open question that actually matters for shipping: does the two-copies
  scenario in §2 merely waste a little memory, or can it corrupt state under real use? Reasoned
  from source (duplicate globals, ABI-compatible struct/vtable interop should be mechanically
  safe) but not observed.
- The static-multi (4-arch) whole-static CUDA size from the *prior* round's open question finished
  in the same container while this session ran: `/work/build-static-multi/bin/whisper-cli` was
  observed at 886 MB unstripped; a final stripped number was not captured before this document
  closed, and is a leftover for whoever reads that container next, not blocking for this task.
- Multi-arch size for `libggml-cuda.so` itself (this session only measured sm_86).

Containers `cuda-size-build` and `cuda-run-test`, and volumes `cuda-size-work` / `cuda-runtest-work`
/ `nmcuda-build`, were found already in place from the prior round and were reused rather than
recreated — this session added a build directory inside `cuda-size-build` (`/work/build-dl-plugin`,
now safe to delete, everything needed from it is recorded above) and created one new short-lived
container, `cuda-plugin-test`, to run the live GPU test; that container has been removed.
