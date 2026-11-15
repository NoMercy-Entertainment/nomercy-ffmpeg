#!/bin/bash

cd /build/libvmaf

if [[ "${TARGET_OS}" == "windows" && "${ARCH}" == "aarch64" ]]; then
    # This target uses llvm-mingw, whose C++ library is libc++. The bundled
    # libsvm (src/svm.cpp) declares its own global `swap` template. libc++
    # calls unqualified swap() inside __split_buffer so ADL can find a better
    # overload; svm_node lives in the global namespace, so libsvm's swap and
    # std::swap are both candidates and every std::vector<svm_node> operation
    # fails with "call to 'swap' is ambiguous". libstdc++ does not do this,
    # which is why the GCC platforms never saw it.
    # std::swap is behaviourally identical to the helper being removed.
    sed -i 's|^template <class T> static inline void swap(T& x, T& y) { T t=x; x=y; y=t; }|#include <utility>\nusing std::swap;|' libvmaf/src/svm.cpp
    grep -q '^using std::swap;' libvmaf/src/svm.cpp || { log -a "libvmaf: svm.cpp swap patch did not apply"; exit 1; }
fi

# Built-in models: meson turns each model JSON into C with xxd, and when xxd
# is missing it skips the models WITHOUT an error. Every release up to
# v1.0.47 shipped a libvmaf with no model at all, so a plain `libvmaf` filter
# failed with "could not load libvmaf model with version: vmaf_v0.6.1".
# The base image has no xxd; supply the one form meson uses (`xxd -i [-n name]
# in out`, plus its `-n test` probe) unless a real xxd is there. The build
# checks below fail the step if the models are still missing.
if ! command -v xxd >/dev/null 2>&1; then
    XXD_DIR=$(mktemp -d)
    cat > "${XXD_DIR}/xxd" << 'PYXXD'
#!/usr/bin/env python3
# Minimal `xxd -i` for libvmaf's built-in models: same C output as xxd.
import re
import sys

args, name, include, files = sys.argv[1:], None, False, []
i = 0
while i < len(args):
    if args[i] == "-i":
        include = True
    elif args[i] == "-n":
        i += 1
        name = args[i] if i < len(args) else ""
    else:
        files.append(args[i])
    i += 1
if not include:
    sys.exit(0)  # meson's `xxd -n test` probe: -n is supported
if len(files) != 2:
    sys.exit("xxd shim: expected -i [-n name] <in> <out>")
with open(files[0], "rb") as f:
    data = f.read()
var = re.sub(r"[^0-9A-Za-z]", "_", files[0] if name is None else name)
if var[:1].isdigit():
    var = "__" + var
rows = ["  " + ", ".join("0x%02x" % b for b in data[k:k + 12]) for k in range(0, len(data), 12)]
with open(files[1], "w") as f:
    f.write("unsigned char %s[] = {\n%s\n};\nunsigned int %s_len = %d;\n" % (var, ",\n".join(rows), var, len(data)))
PYXXD
    chmod +x "${XXD_DIR}/xxd"
    export PATH="${XXD_DIR}:${PATH}"
    log "libvmaf: no xxd in the image, using the built-in-model shim"
fi

mkdir build && cd build
meson --prefix=${PREFIX} \
    --buildtype=release --default-library=static -Dbuilt_in_models=true -Denable_tests=false -Denable_docs=false -Denable_avx512=true -Denable_float=true \
    --cross-file="/build/cross_file.txt" ../libvmaf 2>&1 | log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi

ninja -j$(nproc) && ninja install || exit 1

# The default model must be compiled in, or the filter cannot run without a
# model file (see the xxd note above).
if [ ! -s src/vmaf_v0.6.1.json.c ] || ! grep -q 'src_vmaf_v0_6_1_json_len' src/vmaf_v0.6.1.json.c; then
    log -a "libvmaf: the built-in model vmaf_v0.6.1 was not generated"
    exit 1
fi
log "libvmaf: built-in models compiled in: $(ls src/*.json.c | wc -l)"
sed -i 's/Libs.private:/Libs.private: -lstdc++/; t; $ a Libs.private: -lstdc++' ${PREFIX}/lib/pkgconfig/libvmaf.pc
rm -rf /build/libvmaf

add_enable "--enable-libvmaf"

exit 0
