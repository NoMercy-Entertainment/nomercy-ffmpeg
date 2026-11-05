/*
 * nm_ggml_threads.h - the ggml thread rule the ggml filters share: physical
 * cores this process may run on, and the thread count for a filter graph
 * (#115). Moved out of af_whisper.c unchanged so that af_lyricsalign.c runs
 * ggml with exactly the rule whisper runs it with; af_whisper.c's tests pin
 * the behaviour.
 *
 * FFmpeg-only (libavfilter/avfilter.h, filters.h, libavutil/cpu.h); it is
 * not part of tests/unit. Memory through NM_GT_MALLOC / NM_GT_FREE, which
 * default to av_malloc / av_free.
 */
#ifndef NM_GGML_THREADS_H
#define NM_GGML_THREADS_H

#include <stdio.h>
#include <stdlib.h>

#if defined(_WIN32)
#include <windows.h>
#elif defined(__APPLE__) || defined(__FreeBSD__)
#include <sys/param.h>
#include <sys/types.h>
#include <sys/sysctl.h>
#elif defined(__linux__)
#include <sched.h>
#endif

#include "libavutil/common.h"
#include "libavutil/cpu.h"
#include "libavutil/mem.h"
#include "libavfilter/avfilter.h"
#include "libavfilter/filters.h"

#ifndef NM_GT_MALLOC
#define NM_GT_MALLOC(n) av_malloc(n)
#define NM_GT_FREE(p)   av_free(p)
#endif

/**
 * Physical cores this process may run on, or 0 when the platform cannot say.
 *
 * Only cores with at least one logical CPU in the process affinity count, so
 * a pinned or cgroup-limited process is not told about cores it cannot use.
 * The same count af_stemsplit.c uses for its thread default. Shared by
 * af_whisper.c and af_lyricsalign.c.
 */
static inline int nm_ggml_physical_cores(void)
{
#if defined(_WIN32)
    SYSTEM_LOGICAL_PROCESSOR_INFORMATION *info;
    DWORD_PTR proc_mask, sys_mask;
    DWORD len = 0;
    int i, n, cores = 0;

    if (!GetProcessAffinityMask(GetCurrentProcess(), &proc_mask, &sys_mask))
        return 0;
    GetLogicalProcessorInformation(NULL, &len);
    if (GetLastError() != ERROR_INSUFFICIENT_BUFFER || !len)
        return 0;
    info = NM_GT_MALLOC(len);
    if (!info)
        return 0;
    if (GetLogicalProcessorInformation(info, &len)) {
        n = len / sizeof(*info);
        for (i = 0; i < n; i++)
            if (info[i].Relationship == RelationProcessorCore &&
                (info[i].ProcessorMask & proc_mask))
                cores++;
    }
    NM_GT_FREE(info);
    return cores;
#elif defined(__APPLE__) || defined(__FreeBSD__)
    int n = 0;
    size_t size = sizeof(n);
#if defined(__APPLE__)
    const char *name = "hw.physicalcpu";
#else
    const char *name = "kern.smp.cores";
#endif
    return sysctlbyname(name, &n, &size, NULL, 0) == 0 && n > 0 ? n : 0;
#elif defined(__linux__)
    cpu_set_t set;
    int cpu, cores = 0;

    if (sched_getaffinity(0, sizeof(set), &set))
        return 0;
    // A core counts once: at the lowest of its hyperthreads that the
    // affinity mask allows.
    for (cpu = 0; cpu < CPU_SETSIZE; cpu++) {
        char path[96], list[256], *p;
        int first = -1;
        FILE *f;

        if (!CPU_ISSET(cpu, &set))
            continue;
        snprintf(path, sizeof(path),
                 "/sys/devices/system/cpu/cpu%d/topology/thread_siblings_list", cpu);
        f = fopen(path, "r");
        if (!f)
            return 0;
        p = fgets(list, sizeof(list), f);
        fclose(f);
        if (!p)
            return 0;
        // "0,28" or "0-1": walk every sibling, ranges included
        while (*p && first < 0) {
            long lo = strtol(p, &p, 10), hi = lo, c;
            if (*p == '-')
                hi = strtol(p + 1, &p, 10);
            for (c = lo; c <= hi && c < CPU_SETSIZE; c++)
                if (CPU_ISSET(c, &set)) {
                    first = c;
                    break;
                }
            if (*p != ',')
                break;
            p++;
        }
        if (first == cpu)
            cores++;
    }
    return cores;
#else
    return 0;
#endif
}

/**
 * Threads for whisper.cpp: half the physical cores, unless the graph's thread
 * count was set on purpose.
 *
 * ggml's thread pool (no OpenMP, #64) busy-waits at every barrier, so a worker
 * that has to share a core - with its hyperthread twin, with ffmpeg's own
 * threads, with anything else the machine runs - stalls all the others. With
 * ffmpeg's default (threads=auto, which libavfilter turns into
 * min(cpus + 1, 16)) every whisper run on the CPU fell off that cliff: jfk.wav
 * on base.en took 53.6 s with 7 threads on 6 cores against 3.3 s with 6, and
 * 16.0 s with 16 threads on an 8-core/16-thread i7 against 5.0 s with 4. It
 * is what made vad_model unusable at the default (#115).
 *
 * Half the physical cores is the rule af_stemsplit.c follows for the same
 * reason (owner decision D16): a media server transcribes while it also
 * serves and transcodes, so a filter never takes the whole machine. When the
 * platform cannot count physical cores, half the logical CPUs.
 *
 * A graph thread count other than ffmpeg's automatic one was chosen on
 * purpose (-filter_threads, or the filter's own threads option) and is
 * followed, never above the CPUs this process may use. The thread count does
 * not change the transcript.
 */
static inline int nm_ggml_filter_threads(AVFilterContext *ctx)
{
    const int cpus = av_cpu_count();
    const int graph = FFMAX(1, ff_filter_get_nb_threads(ctx));
    const int automatic = cpus > 1 ? FFMIN(cpus + 1, 16) : 1;
    const int cores = nm_ggml_physical_cores();

    if (graph != automatic)
        return FFMAX(1, FFMIN(graph, cpus));
    return FFMAX(1, (cores > 0 ? cores : cpus) / 2);
}

#endif /* NM_GGML_THREADS_H */
