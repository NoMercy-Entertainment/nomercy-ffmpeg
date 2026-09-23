#!/bin/bash
# Assert the dispatcher's selection behaviour. Reuses the two variants built by
# selftest.sh (lo = sse42, hi = avx2+fma+f16c).
set -eu
REPO="${REPO:-/repo}"
WORK="${WORK:-/tmp/nm-selftest}"

cat > "${WORK}/dispatch_main.c" <<'EOF'
#include <stdio.h>
#include <string.h>
#include "nm_ggml_cpu.h"
int main(void)
{
    const char *v = nm_ggml_cpu_variant_name();
    printf("%s\n", v ? v : "(null)");
    return v ? 0 : 1;
}
EOF

gcc -O2 -I"${WORK}/inst-lo/include" -I"${REPO}/scripts/includes" -I"${WORK}" \
    "${WORK}/dispatch_main.c" "${REPO}/scripts/includes/ggml_cpu_dispatch.c" -static \
    "${WORK}/lo.o" "${WORK}/hi.o" "${WORK}/inst-lo/lib/libggml-base.a" \
    -lstdc++ -lm -lpthread -fopenmp -o "${WORK}/dispatch_test"

fail=0
check() { # description expected actual
    if [[ "$3" == "$2" ]]; then echo "  ok: $1 -> $3"; else echo "  FAIL: $1 -> got '$3', want '$2'"; fail=1; fi
}
check "auto-select on an AVX2 host" "haswell"  "$("${WORK}/dispatch_test")"
check "override to baseline"        "sse42"    "$(NOMERCY_GGML_CPU=sse42 "${WORK}/dispatch_test")"
check "unknown override falls back" "haswell"  "$(NOMERCY_GGML_CPU=nonsense "${WORK}/dispatch_test")"
[[ ${fail} -eq 0 ]] && echo "PASS" || { echo "FAILED"; exit 1; }
