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
#          Renaming the symbol alone is not enough on COFF: vague-linkage
#          definitions (C++ vtables, template instantiations, the compiler's
#          auto-generated ".refptr.<sym>" indirection cells for cross-TU
#          globals) live in COMDAT sections named "<kind>$<sym>", e.g.
#          ".rdata$_ZTVsomething" or ".text$_ZSt...". The final linker folds
#          COMDAT groups together by matching these SECTION NAMES, not symbol
#          names, so two variants that keep the same section name collide and
#          get folded into one, leaving the other variant's (correctly
#          prefixed) symbol references dangling ("undefined reference").
#          Renaming the matching "<kind>$<sym>" section alongside its symbol,
#          for every section kind gcc/mingw is known to emit, avoids the
#          collision without touching the base segment names (.text, .data,
#          .rdata, ...) themselves or any section outside this pattern.
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
        if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
            echo "nm_pack_variant: ${nm} -u failed on ${tmp}" >&2
            return 1
        fi
        # ggml-cpu always calls out to libc/pthread/ggml-base, so an empty
        # undefined-symbol list means nm silently failed (or something about
        # the toolchain/archive is wrong), not that there is nothing to
        # restore. Failing here beats letting a fully-prefixed, libc-less
        # object through and surfacing it as a baffling link error later.
        if [[ ! -s ${tmp}.undef ]]; then
            echo "nm_pack_variant: no undefined symbols found in ${tmp}; ${nm} may have failed silently" >&2
            return 1
        fi
        "${objcopy}" --prefix-symbols="${prefix}" "${tmp}" "${tmp}.pre" || return 1
        awk -v p="${prefix}" '{ print p $1 " " $1 }' "${tmp}.undef" > "${tmp}.restore"
        "${objcopy}" --redefine-syms="${tmp}.restore" "${tmp}.pre" "${output}" || return 1
        ;;
    coff)
        "${nm}" --defined-only "${tmp}" \
            | awk -v p="${prefix}" '$2 ~ /^[TDBRWV]$/ { print $3 " " p $3 }' > "${tmp}.redef"
        if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
            echo "nm_pack_variant: ${nm} --defined-only failed on ${tmp}" >&2
            return 1
        fi
        if [[ ! -s ${tmp}.redef ]]; then
            echo "nm_pack_variant: no defined symbols found in ${tmp}; ${nm} may have failed silently" >&2
            return 1
        fi
        : > "${tmp}.secargs"
        while read -r old new; do
            for kind in text data rdata bss pdata xdata; do
                printf -- '--rename-section=.%s$%s=.%s$%s\n' "${kind}" "${old}" "${kind}" "${new}" >> "${tmp}.secargs"
            done
        done < "${tmp}.redef"
        # objcopy silently skips --rename-section entries whose old name does
        # not exist in this object, so it is safe to try every section kind
        # for every renamed symbol rather than knowing which kind applies.
        # secargs is passed as an objcopy response file (@file): with 6
        # section kinds tried per renamed symbol a template-heavy archive can
        # produce thousands of flags, well past the argument-list limits some
        # Windows toolchains impose, and it avoids word-splitting/globbing an
        # unquoted command substitution full of mangled C++ names.
        "${objcopy}" --redefine-syms="${tmp}.redef" "@${tmp}.secargs" "${tmp}" "${output}" || return 1
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
