# Disposable runtime fixtures

These sources are only for runtime validation inside the disposable FreeBSD
guest. Their `.so` outputs must never enter an FFmpeg release archive.

With the production FreeBSD toolchain and installed Snappy, build a staging
directory with this layout:

```sh
mkdir -p "$OUT/hostile-abort" "$OUT/hostile-hang"
cp tools/freebsd-vm/verify-runtime.sh "$OUT/verify-runtime.sh"
"$CXX" $CXXFLAGS -std=c++11 -c tools/freebsd-vm/fixtures/dlopen-main.cpp -o "$OUT/main.o"
bash scripts/includes/freebsd_link.sh "$OUT/main.o" -L"$PREFIX/lib" -lsnappy -o "$OUT/dlopen-main"
"$CC" -std=c11 -fPIC -shared tools/freebsd-vm/fixtures/dlopen-plugin.c -o "$OUT/plugin.so"
"$CC" -std=c11 -fPIC -shared tools/freebsd-vm/fixtures/hostile-vulkan-loader.c -Wl,-soname,libvulkan.so.1 -o "$OUT/hostile-abort/libvulkan.so.1"
"$CC" -std=c11 -fPIC -shared -DNM_HOSTILE_HANG=1 tools/freebsd-vm/fixtures/hostile-vulkan-loader.c -Wl,-soname,libvulkan.so.1 -o "$OUT/hostile-hang/libvulkan.so.1"
```

Copy the focused Vulkan-enabled FFmpeg to `$OUT/ffmpeg`, copy the staging
directory into the guest, then run:

```sh
sh verify-runtime.sh /tmp/freebsd-runtime
```

The main executable uses static Snappy/C++ and only FreeBSD base DSOs. It starts
a worker before `dlopen`, then verifies the plugin's constructor, late-loaded
thread-local storage on both threads, and allocations freed across the module
boundary. The plugin is absent from its startup dependencies.

The two fake Vulkan loaders abort or hang from their constructors. Trace files
prove they were opened. Guarded probes must reach the later whisper model-open
failure without killing or hanging the parent. Unguarded controls must reproduce
the failures. A bare missing model path is insufficient: whisper rejects it in
`init()` before `config_input()` reaches backend discovery.

No speech model is downloaded. The probes establish discovery/guard safety and
dynamic-loading behavior, not transcription correctness or physical GPU speed.

## Test-only Bash for the guest

Existing Bash helpers can be run without installing packages from a newer
FreeBSD repository. Cross-build Bash 5.2.37 using the same FreeBSD 14.3 compiler
and sysroot environment:

```sh
mkdir -p "$SOURCES" "$BASH_OUT"
curl -fL https://ftp.gnu.org/gnu/bash/bash-5.2.37.tar.gz -o "$SOURCES/bash-5.2.37.tar.gz"
curl -fL https://ftp.gnu.org/gnu/bash/bash-5.2.37.tar.gz.sig -o "$SOURCES/bash-5.2.37.tar.gz.sig"
curl -fL https://ftp.gnu.org/gnu/gnu-keyring.gpg -o "$SOURCES/gnu-keyring.gpg"
bash tools/freebsd-vm/fixtures/build-bash.sh "$SOURCES" "$BASH_OUT"
```

The helper pins SHA-256
`9599b22ecd1d5787ad7d3b7bf0c59f312b3396d1e281175dd1f8a4014da621ff`,
verifies GNU's detached signature with Chet Ramey's fingerprint
`7C0135FB088AAF6C66C650B9BB5869F064EA74AB`, and limits make to two jobs.
The same source hash is recorded in
[Buildroot's signature-verified update](https://lists.buildroot.org/pipermail/buildroot/2025-February/774200.html).
Readline, history, programmable completion, NLS, curses and Bash's private malloc
are disabled. The output is a disposable test tool, never part of the FFmpeg
release archive. Copy it into the guest and invoke it explicitly for the small
JPEG XL/HAP/APV and Vulkan-startup helpers; avoid the full codec suite under
software emulation.
