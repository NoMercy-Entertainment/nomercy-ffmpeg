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
 * A ready backend: the GPU when `use_gpu` is non-zero and a usable one exists,
 * otherwise the best CPU instruction-set variant. Returns NULL only if even the
 * CPU backend could not be created. The caller owns the result and releases it
 * with ggml_backend_free().
 */
ggml_backend_t nm_ggml_backend_init(int use_gpu);

/*
 * 1 when a usable, non-software GPU device exists. This is for callers that do
 * not create their own backend and instead hand a yes/no to a library that
 * picks one itself - af_whisper.c, whose whisper.cpp selects internally from
 * whisper_context_params::use_gpu.
 */
int nm_ggml_gpu_usable(void);

/*
 * "vulkan" - or whatever ggml calls the registry owning the device, folded to
 * lower case - when a usable GPU exists, otherwise "cpu". This says what is
 * AVAILABLE, not what a given filter chose: a filter started with use_gpu=0
 * reports "cpu" from its own flag rather than asking here.
 */
const char *nm_ggml_backend_name(void);

/*
 * The GPU's description, e.g. "NVIDIA GeForce RTX 3070", or the selected CPU
 * variant name when no usable GPU exists. Same caveat as above: it answers
 * "what is available", not "what did this filter use".
 */
const char *nm_ggml_backend_device(void);

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
