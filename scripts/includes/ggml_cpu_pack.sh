#!/bin/bash
# Pack one ggml CPU backend build into a single object (or, on
# coff-archive, a rewritten archive) whose symbols cannot clash with another
# variant of the same backend in the same binary.
#
# The three recipes differ because the object formats and the linkers do:
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
#   COFF-ARCHIVE - windows-aarch64 only. Same "rename defined symbols"
#          intent as COFF, but it cannot partial-link first and it does not
#          rename sections. Both differences are forced by llvm-mingw, the
#          only working Windows-on-ARM toolchain (see
#          ffmpeg-windows-aarch64.dockerfile for why GCC was abandoned):
#
#          1. Its linker is ld.lld, whose MinGW driver does not implement -r
#             at all ("lld: error: unknown argument: -r", verified against the
#             pinned llvm-mingw 20260728). No other tool in the image can
#             partial-link aarch64 PE: GNU ld has no aarch64 PE emulation
#             ("relocatable linking with relocations from format
#             pe-aarch64-little to format elf64-littleaarch64 is not
#             supported"). So the rename is applied to the ARCHIVE instead --
#             objcopy rewrites every member in place and writes a new archive.
#             This also sidesteps extracting members to a directory, which
#             would be lossy: ggml-cpu.a really does contain two members
#             called quants.c.obj and two called repack.cpp.obj (the generic
#             and the arch/arm copies).
#
#          2. llvm-objcopy rejects --rename-section on COFF outright ("option
#             is not supported for COFF"), so the "<kind>$<symbol>" renames
#             above are simply not available. They are not needed here: they
#             exist because GNU ld folds COMDAT groups by SECTION NAME,
#             whereas ld.lld folds COFF COMDATs by their leader SYMBOL name --
#             which --redefine-syms has already made unique per variant.
#             Verified on the real ggml-cpu backend: the two-variant link
#             resolves with zero undefined symbols, each variant keeps its own
#             512 text symbols at distinct addresses, and dotprod/fp16
#             instructions appear only inside the armv8.2 variant's functions.
#             (Cross-checked against a GNU-binutils build that DID rename the
#             sections: identical symbol counts and identical dotprod split,
#             so nothing is lost by dropping them.)
#
#          Because a member's reference to another member's symbol is an
#          UNDEFINED symbol rather than an internal relocation (there is no
#          partial link to resolve it), the rename list has to be the union of
#          the defined symbols of the WHOLE archive, applied to every member.
#          That renames definitions and cross-member references alike -- the
#          same end state `ld -r` plus a per-object rename produces -- while
#          genuinely external undefined symbols (libc, libc++, ggml-base) are
#          not in the list and stay untouched.
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

    # coff-archive never partial-links; the other two recipes start from one
    # merged object.
    if [[ ${format} != coff-archive ]]; then
        "${ld}" -r --whole-archive "${archive}" -o "${tmp}" || return 1
    fi

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
    coff-archive)
        # sort -u, unlike the merged-object recipes: nm runs over a whole
        # archive here, and a COMDAT definition (vtable, template
        # instantiation, inline function) is emitted into every member that
        # needed it, so the same "old new" pair comes out many times.
        # llvm-objcopy tolerates exact duplicates (checked), but GNU objcopy
        # rejects a redefine list with a repeated old name outright, so the
        # recipe stays portable if this platform's toolchain ever changes --
        # and the list is a fraction of the size either way.
        "${nm}" --defined-only "${archive}" \
            | awk -v p="${prefix}" '$2 ~ /^[TDBRWV]$/ { print $3 " " p $3 }' \
            | sort -u > "${output}.redef"
        if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
            echo "nm_pack_variant: ${nm} --defined-only failed on ${archive}" >&2
            return 1
        fi
        if [[ ! -s ${output}.redef ]]; then
            echo "nm_pack_variant: no defined symbols found in ${archive}; ${nm} may have failed silently" >&2
            return 1
        fi
        "${objcopy}" --redefine-syms="${output}.redef" "${archive}" "${output}" || return 1
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
    rm -f "${tmp}" "${tmp}".* "${output}.redef"
}
