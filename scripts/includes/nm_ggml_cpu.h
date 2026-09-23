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
 * The four functions below share one cached decision, taken the first time any
 * of them is called. That first call is also what runs the software-Vulkan
 * guard, so it MUST happen before anything else in the process touches ggml's
 * backend registry - see ggml_cpu_dispatch.c for why that ordering is a
 * correctness requirement and not a preference.
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

#ifdef __cplusplus
}
#endif

#endif /* NM_GGML_CPU_H */
