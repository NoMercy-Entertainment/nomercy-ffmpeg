# Linux glibc `dlopen` diagnostic

Run this manual diagnostic on Linux x86_64 with glibc and a native GCC/G++
toolchain, static glibc/C++ development libraries, Bash, GNU binutils and GNU
coreutils. No GPU, driver, model or FFmpeg build is needed:

```sh
bash tools/linux-runtime/test-dlopen.sh
# Optional directory for binaries, logs and ELF reports:
bash tools/linux-runtime/test-dlopen.sh /tmp/nomercy-dlopen
```

The test builds a C++ executable and a small C shared plugin. The executable
creates a pthread key, loads the plugin, and starts a `std::thread`. The plugin
creates its own key. The worker stores distinct static sentinel addresses in
both keys, reads both values, then exits so the destructors run.

Two controls must satisfy explicit assertions:

| Executable | Link policy | Expected observations |
| --- | --- | --- |
| `hardware` | Actual `scripts/includes/linux_link.sh`: static C++ runtime and system glibc | Distinct keys; both values intact; each destructor runs once with its own value. |
| `static-control` | Fully static, including glibc | Same key index; plugin value overwrites the main value; main destructor receives the plugin value once; plugin destructor does not run. |

The negative control succeeds only when it observes the complete collision
signature. A timeout, crash, failed plugin load, missing destructor, or another
unexpected result fails the diagnostic. Neither destructor dereferences or
frees its argument, and the test never calls `dlclose`. The plugin `.so` is a
test fixture; it is never part of an FFmpeg release archive.

By default, generated files remain in ignored `output/linux-runtime/dlopen/`.
Each run has a 15-second timeout with a two-second forced-termination grace
period. `CC` and `CXX` can select native compilers; each must name one executable.
The hardware link explicitly captures `CC` as `LINUX_LINK_CC`.
The static link's expected `dlopen` warning is retained in `static-link.log`.
Both expected signatures were verified on Ubuntu 24.04 / glibc 2.39 with GCC
13.3, directly under WSL2 without a GPU or Docker runtime.

This reproduces a Linux/glibc runtime boundary: a fully static executable and
a dynamically loaded shared libc can allocate pthread keys independently while
accessing the same per-thread slots. It demonstrates why the hardware build
shares system glibc while keeping codecs and C++ static. It does not establish
every GPU failure's cause, test GPU acceleration, or apply to other platforms.
The exact negative-control behavior is libc-dependent: a future libc that fixes
this interaction can make this diagnostic fail because the collision disappears.
The CPU release variant does not use this test plugin.
