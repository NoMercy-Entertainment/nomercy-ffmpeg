#!/bin/bash
# Pack one ggml CPU backend build into a single object whose symbols cannot
# clash with another variant of the same backend in the same binary.
#
# The two recipes differ because the object formats do:
#
#   ELF  - prefix EVERY symbol, which keeps COMDAT groups internally
#          consistent, then restore the names of the undefined references so
#          libc, libstdc++ and ggml-base still resolve.
#   COFF - rename only DEFINED symbols. Prefixing everything also renames the
#          COMDAT section symbols, which corrupts the section names and makes
#          the link produce an empty binary with no error.
#
# Tools are taken from NM_NM / NM_OBJCOPY / NM_LD so the same code serves the
# cross toolchains (mingw, llvm-mingw, aarch64-linux-gnu).

nm_pack_variant() {
    local format="$1" archive="$2" prefix="$3" output="$4"
    local nm="${NM_NM:-nm}" objcopy="${NM_OBJCOPY:-objcopy}" ld="${NM_LD:-ld}"
    local tmp="${output%.o}.whole.o"

    if [[ ! -f ${archive} ]]; then
        echo "nm_pack_variant: no such archive: ${archive}" >&2
        return 1
    fi

    "${ld}" -r --whole-archive "${archive}" -o "${tmp}" || return 1

    case "${format}" in
    elf)
        "${nm}" -u "${tmp}" | awk '{ print $NF }' | sort -u > "${tmp}.undef"
        "${objcopy}" --prefix-symbols="${prefix}" "${tmp}" "${tmp}.pre" || return 1
        awk -v p="${prefix}" '{ print p $1 " " $1 }' "${tmp}.undef" > "${tmp}.restore"
        "${objcopy}" --redefine-syms="${tmp}.restore" "${tmp}.pre" "${output}" || return 1
        ;;
    coff)
        "${nm}" --defined-only "${tmp}" \
            | awk -v p="${prefix}" '$2 ~ /^[TDBRWV]$/ { print $3 " " p $3 }' > "${tmp}.redef"
        "${objcopy}" --redefine-syms="${tmp}.redef" "${tmp}" "${output}" || return 1
        ;;
    *)
        echo "nm_pack_variant: unknown object format: ${format}" >&2
        return 1
        ;;
    esac

    # The entry point must exist under the prefix, or the dispatcher will not link.
    if ! "${nm}" --defined-only "${output}" | grep -q "${prefix}ggml_backend_cpu_reg"; then
        echo "nm_pack_variant: ${prefix}ggml_backend_cpu_reg missing from ${output}" >&2
        return 1
    fi
    rm -f "${tmp}" "${tmp}".*
}
