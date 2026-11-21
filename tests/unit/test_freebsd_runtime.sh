#!/usr/bin/env bash
# Exercise the production linker and ELF dependency gate without a cross compiler.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/tool chain" "$WORK/build output"
export CAPTURE_ARGS="$WORK/args" COMPILER_CALLED="$WORK/compiler-called"
export CC="$WORK/tool chain/cc" CROSS_PREFIX="$WORK/tool chain/freebsd-"
unset FREEBSD_LINK_CC
passed=0
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { passed=$((passed + 1)); }

cat >"$CC" <<'EOF'
#!/usr/bin/env bash
printf '%s\0' "$@" >"$CAPTURE_ARGS"
touch "$COMPILER_CALLED"
exit "${FAKE_CC_EXIT:-0}"
EOF
chmod +x "$CC"

bash "$ROOT/scripts/includes/freebsd_link.sh" -o "$WORK/output file" \
    "$WORK/input object.o" "-L$WORK/library path" \
    -lcodec -lm -lsecond_codec -lpthread -lc -lthr -lstdc++ \
    -Wl,--start-group -lggml-vulkan -Wl,--end-group
args=()
while IFS= read -r -d '' arg; do args+=("$arg"); done <"$CAPTURE_ARGS"
for expected in -nodefaultlibs -o "$WORK/output file" "$WORK/input object.o" "-L$WORK/library path" -Wl,--start-group -Wl,--end-group; do
    count=0
    for arg in "${args[@]}"; do [[ "$arg" != "$expected" ]] || count=$((count + 1)); done
    [[ $count == 1 ]] || fail "argument boundary or duplication: $expected"
    pass
done

# Interpret linker state across interleaved codec/system libraries. Each scope
# must restore the previous state, including inside an existing archive group.
mode=dynamic; depth=0; libraries=0; runtime=0
stack=()
for arg in "${args[@]}"; do
    case "$arg" in
        -Wl,*)
            IFS=, read -r -a flags <<<"${arg#-Wl,}"
            for flag in "${flags[@]}"; do
                case "$flag" in
                    --push-state) stack[depth]=$mode; depth=$((depth + 1)) ;;
                    --pop-state)
                        [[ $depth -gt 0 ]] || fail 'unbalanced linker state'
                        depth=$((depth - 1)); mode=${stack[depth]}; unset 'stack[depth]'
                        ;;
                    -Bstatic) mode=static ;;
                    -Bdynamic) mode=dynamic ;;
                esac
            done
            ;;
        -l*)
            libraries=$((libraries + 1))
            case "$arg" in
                -lc|-lm|-lpthread|-lthr) expected=dynamic ;;
                *) expected=static ;;
            esac
            [[ "$mode" == "$expected" ]] || fail "$arg linked $mode, expected $expected"
            case "$arg" in -lc++|-lcxxrt|-lgcc_eh|-lgcc) runtime=$((runtime + 1)) ;; esac
            pass
            ;;
    esac
done
[[ $depth == 0 && $mode == dynamic && $libraries -ge 12 && $runtime == 4 ]] || fail 'incomplete runtime or unbalanced library scopes'
pass

rm -f "$COMPILER_CALLED"
if bash "$ROOT/scripts/includes/freebsd_link.sh" -o ignored -static >"$WORK/link.log" 2>&1; then
    fail 'accepted a fully static link'
fi
[[ ! -e "$COMPILER_CALLED" ]] || fail 'invoked the compiler after rejecting -static'
grep -q 'dynamic base runtime' "$WORK/link.log" || fail 'static rejection lost its reason'
pass
if FAKE_CC_EXIT=43 bash "$ROOT/scripts/includes/freebsd_link.sh" -o ignored; then rc=0; else rc=$?; fi
[[ $rc == 43 ]] || fail 'compiler failure was hidden'
pass
for flag in --version -v; do
    bash "$ROOT/scripts/includes/freebsd_link.sh" "$flag"
    args=()
    while IFS= read -r -d '' arg; do args+=("$arg"); done <"$CAPTURE_ARGS"
    [[ ${#args[@]} == 1 && ${args[0]} == "$flag" ]] || fail 'compiler identity query was modified'
    pass
done

# FFmpeg make exports a decorated CC recipe. The captured compiler must win
# without treating the recipe as an executable or splitting filename arguments.
for decorated_cc in '/missing/target-cc' '@printf "CC %s\n"; missing-target-cc'; do
    env FREEBSD_LINK_CC="$CC" CC="$decorated_cc" bash "$ROOT/scripts/includes/freebsd_link.sh" \
        -o "$WORK/stable output" "$WORK/stable input.o"
    args=()
    while IFS= read -r -d '' arg; do args+=("$arg"); done <"$CAPTURE_ARGS"
    input_count=0; output_count=0
    for arg in "${args[@]}"; do
        [[ "$arg" != "$WORK/stable input.o" ]] || input_count=$((input_count + 1))
        [[ "$arg" != "$WORK/stable output" ]] || output_count=$((output_count + 1))
    done
    [[ $input_count == 1 && $output_count == 1 ]] || fail 'captured compiler lost argument boundaries'
    pass
done

cat >"${CROSS_PREFIX}readelf" <<'EOF'
#!/usr/bin/env bash
[[ $# == 3 && $1 == --program-headers && $2 == --dynamic ]] || exit 64
[[ ${READELF_MODE:-base} != tool-error ]] || exit 42
case "${READELF_MODE:-base}" in
    no-loader) ;;
    wrong-loader) echo '[Requesting program interpreter: /libexec/ld-elf.so.1bad]' ;;
    *) echo '[Requesting program interpreter: /libexec/ld-elf.so.1]' ;;
esac
[[ ${READELF_MODE:-base} == no-libc ]] || echo '0x1 (NEEDED) Shared library: [libc.so.7]'
echo '0x1 (NEEDED) Shared library: [libm.so.5]'
echo '0x1 (NEEDED) Shared library: [libthr.so.3]'
case "${READELF_MODE:-base}:${3##*/}" in
    codec:ffplay_g) echo '0x1 (NEEDED) Shared library: [libvulkan.so.1]' ;;
    cxx:*) echo '0x1 (NEEDED) Shared library: [libc++.so.1]' ;;
    unwind:*) echo '0x1 (NEEDED) Shared library: [libgcc_s.so.1]' ;;
esac
EOF
chmod +x "${CROSS_PREFIX}readelf"
for program in ffmpeg_g ffprobe_g ffplay_g; do touch "$WORK/build output/$program"; done
gate="$ROOT/scripts/includes/verify_freebsd_runtime.sh"
bash "$gate" "$WORK/build output" >"$WORK/runtime.log"
[[ $(grep -c 'base runtime only' "$WORK/runtime.log") == 3 ]] || fail 'not every shipped program was checked'
pass
for fault in codec cxx unwind no-loader wrong-loader no-libc tool-error; do
    if READELF_MODE=$fault bash "$gate" "$WORK/build output" >"$WORK/runtime.log" 2>&1; then
        fail "runtime gate accepted $fault"
    fi
    case "$fault" in
        codec) reason='ffplay_g: unexpected shared dependency libvulkan.so.1' ;;
        cxx) reason='unexpected shared dependency libc++.so.1' ;;
        unwind) reason='unexpected shared dependency libgcc_s.so.1' ;;
        no-loader|wrong-loader) reason='missing FreeBSD runtime linker' ;;
        no-libc) reason='missing dynamic base libc' ;;
        tool-error) reason='' ;;
    esac
    [[ -z "$reason" ]] || grep -Fq "$reason" "$WORK/runtime.log" || fail "$fault failed at the wrong gate"
    pass
done
rm "$WORK/build output/ffmpeg_g"
if bash "$gate" "$WORK/build output" >"$WORK/runtime.log" 2>&1; then fail 'accepted ffprobe+ffplay without ffmpeg'; fi
grep -q 'Missing ffmpeg_g' "$WORK/runtime.log" || fail 'missing ffmpeg failed at wrong gate'
pass
touch "$WORK/build output/ffmpeg_g"
rm "$WORK/build output/ffplay_g"
bash "$gate" "$WORK/build output" >"$WORK/runtime.log"
pass
rm "$WORK/build output/ffprobe_g"
if bash "$gate" "$WORK/build output" >"$WORK/runtime.log" 2>&1; then fail 'accepted only one shipped program'; fi
grep -q 'Missing ffprobe_g' "$WORK/runtime.log" || fail 'missing ffprobe failed at wrong gate'
pass
echo "all $passed FreeBSD link/runtime checks passed"
