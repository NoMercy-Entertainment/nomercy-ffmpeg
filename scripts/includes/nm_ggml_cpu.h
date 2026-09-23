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

#ifdef __cplusplus
extern "C" {
#endif

const char *nm_ggml_cpu_variant_name(void);

#ifdef __cplusplus
}
#endif

#endif /* NM_GGML_CPU_H */
