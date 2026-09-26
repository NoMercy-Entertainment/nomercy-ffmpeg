/*
 * Which ggml CPU backend variant this process selected.
 *
 * The binary carries several instruction-set variants of ggml's CPU backend;
 * ggml_cpu_dispatch.c picks one the first time ggml asks for a CPU backend.
 * Returns a stable string such as "x64", "sse42", "ivybridge", "haswell",
 * or an ARM level such as "armv8.2+dotprod+fp16".
 */
#ifndef NM_GGML_CPU_H
#define NM_GGML_CPU_H

#include <ggml-backend.h>

#ifdef __cplusplus
extern "C" {
#endif

const char *nm_ggml_cpu_variant_name(void);

/*
 * Which device should a filter run on?
 *
 * The functions below share one cached decision, taken the first time any of
 * them is called. That first call is also what runs the software-Vulkan guard,
 * so it MUST happen before anything else in the process touches ggml's backend
 * registry - see ggml_cpu_dispatch.c for why that ordering is a correctness
 * requirement and not a preference.
 *
 * CALL THEM UNCONDITIONALLY. In particular, do not put one on the right-hand
 * side of an `&&` whose left-hand side can be false: C short-circuits, the
 * guard then never runs, and the next thing that touches ggml's registry
 * segfaults on a machine with software Vulkan installed. That is not
 * hypothetical - it shipped once, as `use_gpu && nm_ggml_gpu_usable()`, and
 * `use_gpu=0` is precisely the option someone sets when a GPU is misbehaving.
 *
 * SIDE EFFECT, deliberate and load bearing: on Linux the first call may
 * rewrite this PROCESS's VK_ICD_FILENAMES and VK_DRIVER_FILES, because the
 * Vulkan loader is global and some drivers kill a statically linked binary
 * during enumeration. FFmpeg's own Vulkan code (the vulkan hwaccel,
 * libplacebo) reads the same two variables and therefore sees the same reduced
 * driver list. This happens only when a probe PROVED a crash, or when a
 * hardware-only list can be substituted for one containing a software
 * rasteriser; an inconclusive probe changes nothing at all. The first call
 * also forks, once. Call these early, from one thread, for both reasons.
 */

/*
 * ABOUT `gpu_device`, which every function below that takes one means the same
 * way: the index of a GPU among the GPU and IGPU devices ggml enumerates, in
 * enumeration order. That is whisper.cpp's own counting
 * (whisper_backend_init_gpu walks ggml_backend_dev_get(i) and takes the
 * gpu_device'th device whose type is GPU or IGPU), and matching it is the whole
 * point: these functions exist to report what ran, and on a two-GPU machine
 * with gpu_device=1 an index-less answer named device 0 while the work happened
 * on device 1. An index past the end is not an error - whisper falls back to
 * the CPU there, and so do these.
 */

/*
 * A ready backend: the `gpu_device`'th GPU when `use_gpu` is non-zero and that
 * one is usable, otherwise the best CPU instruction-set variant. Returns NULL
 * only if even the CPU backend could not be created. The caller owns the result
 * and releases it with ggml_backend_free().
 */
ggml_backend_t nm_ggml_backend_init(int use_gpu, int gpu_device);

/*
 * 1 when the GPU path is usable at all: at least one GPU/IGPU device exists and
 * NONE of them is a software rasteriser. Deliberately index-independent,
 * because the property it guarantees has to hold for whatever index a caller
 * (or whisper.cpp, which we cannot steer) ends up selecting. Pair it with
 * nm_ggml_gpu_count() when you need to know whether a specific index exists.
 */
int nm_ggml_gpu_usable(void);

/*
 * How many GPU/IGPU devices there are, in the order above. 0 when the GPU path
 * is unusable for any reason. A caller whose gpu_device is >= this will get the
 * CPU, and should say so rather than name a device.
 */
int nm_ggml_gpu_count(void);

/*
 * "vulkan" - or whatever ggml calls the registry owning that device, folded to
 * lower case - when the `gpu_device`'th GPU is usable, otherwise "cpu". This
 * says what is AVAILABLE at that index, not what a given filter chose: a filter
 * started with use_gpu=0 reports "cpu" from its own flag rather than asking
 * here.
 */
const char *nm_ggml_backend_name(int gpu_device);

/*
 * That device's description, e.g. "NVIDIA GeForce RTX 3070", or the selected
 * CPU variant name when the index has no usable GPU behind it. Same caveat as
 * above: it answers "what is available", not "what did this filter use".
 */
const char *nm_ggml_backend_device(int gpu_device);

/*
 * One sentence about anything surprising the guard did to this process -
 * drivers it had to disable, a probe it could not run - or NULL, which is the
 * answer on every machine where nothing was wrong. Filters log it once at
 * AV_LOG_INFO so that a user whose GPU quietly vanished has something to pull
 * on; without it the guard is completely silent about removing a driver.
 */
const char *nm_ggml_backend_notice(void);

#ifdef __cplusplus
}
#endif

#endif /* NM_GGML_CPU_H */
