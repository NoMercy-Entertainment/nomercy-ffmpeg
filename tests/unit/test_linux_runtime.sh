#!/usr/bin/env bash
# Exercise actual Linux variant/link gates with fake tools, without FFmpeg.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/tool chain" "$WORK/build output"
export CAPTURE_ARGS="$WORK/args" COMPILER_CALLED="$WORK/compiler-called"
export CC="$WORK/tool chain/cc" CROSS_PREFIX="$WORK/tool chain/linux-"
unset LINUX_LINK_CC
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
link="$ROOT/scripts/includes/linux_link.sh"
bash "$link" -o "$WORK/output file" "$WORK/input object.o" "-L$WORK/library path" \
    -lcodec -lm -lsecond_codec -lpthread -lc -ldl -lrt -lutil -lmvec \
    -fopenmp -fopenmp -Wl,--start-group -lggml-vulkan -Wl,--end-group
args=()
while IFS= read -r -d '' arg; do args+=("$arg"); done <"$CAPTURE_ARGS"
for expected in -no-pie -nodefaultlibs -o "$WORK/output file" "$WORK/input object.o" "-L$WORK/library path" -Wl,--start-group -Wl,--end-group; do
    count=0
    for arg in "${args[@]}"; do [[ "$arg" != "$expected" ]] || count=$((count + 1)); done
    [[ $count == 1 ]] || fail "argument boundary or duplication: $expected"
    pass
done
mode=dynamic; depth=0; gomp=0; runtime=0
stack=()
for arg in "${args[@]}"; do
    case "$arg" in
        -fopenmp) fail 'OpenMP driver flag survived and could add a shared runtime' ;;
        -Wl,*)
            IFS=, read -r -a flags <<<"${arg#-Wl,}"
            for flag in "${flags[@]}"; do
                case "$flag" in
                    --push-state) stack[depth]=$mode; depth=$((depth + 1)) ;;
                    --pop-state)
                        [[ $depth -gt 0 ]] || fail 'unbalanced linker state'
                        depth=$((depth - 1)); mode=${stack[depth]}; unset 'stack[depth]' ;;
                    -Bstatic) mode=static ;;
                    -Bdynamic) mode=dynamic ;;
                esac
            done ;;
        -l*)
            case "$arg" in
                -lc|-lm|-lmvec|-lpthread|-ldl|-lrt|-lutil) expected=dynamic ;;
                *) expected=static ;;
            esac
            [[ "$mode" == "$expected" ]] || fail "$arg linked $mode instead of $expected"
            case "$arg" in
                -lgomp) gomp=$((gomp + 1)) ;;
                -lstdc++|-lgcc|-lgcc_eh) runtime=$((runtime + 1)) ;;
            esac
            pass ;;
    esac
done
[[ $depth == 0 && $mode == dynamic && $gomp == 1 && $runtime == 3 ]] || fail 'incomplete/unbalanced runtime scopes'
pass
bash "$link" -o ignored input.o
while IFS= read -r -d '' arg; do [[ $arg != -lgomp ]] || fail 'OpenMP runtime added without -fopenmp'; done <"$CAPTURE_ARGS"
pass
for flag in -static -static-pie; do
    rm -f "$COMPILER_CALLED"
    if bash "$link" -o ignored "$flag" >"$WORK/link.log" 2>&1; then fail "accepted $flag"; fi
    [[ ! -e "$COMPILER_CALLED" ]] || fail "invoked compiler after rejecting $flag"
    grep -q 'dynamic base runtime' "$WORK/link.log" || fail 'static rejection lost its reason'
    pass
done
if FAKE_CC_EXIT=43 bash "$link" -o ignored; then rc=0; else rc=$?; fi
[[ $rc == 43 ]] || fail 'compiler failure was hidden'
pass
for flag in --version -v; do
    bash "$link" "$flag"
    args=()
    while IFS= read -r -d '' arg; do args+=("$arg"); done <"$CAPTURE_ARGS"
    [[ ${#args[@]} == 1 && ${args[0]} == "$flag" ]] || fail 'compiler query was modified'
    pass
done
for decorated in '/missing/cc' '@printf "CC %s\n"; missing-cc'; do
    env LINUX_LINK_CC="$CC" CC="$decorated" bash "$link" -o "$WORK/stable output" "$WORK/stable input.o"
    args=()
    while IFS= read -r -d '' arg; do args+=("$arg"); done <"$CAPTURE_ARGS"
    [[ ${args[3]} == "$WORK/stable output" && ${args[4]} == "$WORK/stable input.o" ]] || fail 'captured compiler lost input/output arguments'
    pass
done

cat >"${CROSS_PREFIX}readelf" <<'EOF'
#!/usr/bin/env bash
[[ $# == 4 && $1 == --program-headers && $2 == --dynamic && $3 == --version-info ]] || exit 64
mode=${INFO_MODE:-base}
[[ $mode != tool-error ]] || exit 42
case "$mode" in
    static|needed-only) ;;
    interp-only) echo '  INTERP 0x123' ;;
    wrong-loader) echo '[Requesting program interpreter: /lib64/ld-linux-x86-64.so.2bad]' ;;
    *) echo '[Requesting program interpreter: /lib64/ld-linux-x86-64.so.2]' ;;
esac
case "$mode" in static|interp-only) exit 0 ;; esac
[[ $mode == no-libc ]] || echo '0x1 (NEEDED) Shared library: [libc.so.6]'
echo '0x1 (NEEDED) Shared library: [libm.so.6]'
echo '0x1 (NEEDED) Shared library: [libmvec.so.1]'
echo '0x1 (NEEDED) Shared library: [ld-linux-x86-64.so.2]'
case "$mode:${4##*/}" in
    codec:ffplay_g) echo '0x1 (NEEDED) Shared library: [libavcodec.so.62]' ;;
    gomp:*) echo '0x1 (NEEDED) Shared library: [libgomp.so.1]' ;;
    cxx:*) echo '0x1 (NEEDED) Shared library: [libstdc++.so.6]' ;;
    unwind:*) echo '0x1 (NEEDED) Shared library: [libgcc_s.so.1]' ;;
esac
if [[ $mode == own-definition ]]; then
    printf "Version definition section '.gnu.version_d':\n  Name: GLIBC_99.0\n"
fi
echo "Version needs section '.gnu.version_r':"
echo '  Name: GLIBC_2.2.5 Flags: none'
case "$mode" in
    high-minor) echo '  Name: GLIBC_2.40 Flags: none' ;;
    high-digits) echo '  Name: GLIBC_2.100 Flags: none' ;;
    high-major) echo '  Name: GLIBC_10.0 Flags: none' ;;
    high-patch) echo '  Name: GLIBC_2.39.1 Flags: none' ;;
    private) echo '  Name: GLIBC_PRIVATE Flags: none' ;;
    old-minor) echo '  Name: GLIBC_2.9 Flags: none' ;;
    *) echo '  Name: GLIBC_2.39 Flags: none' ;;
esac
EOF
chmod +x "${CROSS_PREFIX}readelf"
for program in ffmpeg_g ffprobe_g ffplay_g; do touch "$WORK/build output/$program"; done
gate="$ROOT/scripts/includes/verify_linux_runtime.sh"
accept() {
    INFO_MODE=$2 bash "$gate" "$1" "$WORK/build output" >"$WORK/gate.log" 2>&1 || { cat "$WORK/gate.log"; fail "$1 rejected $2"; }
    pass
}
reject() {
    if INFO_MODE=$2 bash "$gate" "$1" "$WORK/build output" >"$WORK/gate.log" 2>&1; then fail "$1 accepted $2"; fi
    grep -Fq "$3" "$WORK/gate.log" || { cat "$WORK/gate.log"; fail "$2 failed at wrong gate"; }
    pass
}
accept cpu static
[[ $(grep -c 'CPU variant has no shared startup runtime' "$WORK/gate.log") == 3 ]] || fail 'CPU optional program was not checked'
reject cpu base 'dynamic interpreter'
reject cpu interp-only 'dynamic interpreter'
reject cpu needed-only 'shared startup dependencies'
accept hardware base
[[ $(grep -c 'hardware glibc base runtime only' "$WORK/gate.log") == 3 ]] || fail 'hardware optional program was not checked'
accept hardware old-minor
accept hardware own-definition
reject hardware static 'missing Linux x86_64 runtime linker'
reject hardware wrong-loader 'missing Linux x86_64 runtime linker'
reject hardware no-libc 'missing dynamic base libc'
for mode in codec gomp cxx unwind; do reject hardware "$mode" 'unexpected shared dependency'; done
for mode in high-minor high-digits high-major high-patch private; do reject hardware "$mode" 'unsupported glibc requirement'; done
if INFO_MODE=tool-error bash "$gate" hardware "$WORK/build output" >"$WORK/gate.log" 2>&1; then rc=0; else rc=$?; fi
[[ $rc == 42 ]] || fail 'readelf failure was hidden'
pass
reject other static 'Unknown Linux variant'
rm "$WORK/build output/ffmpeg_g"
reject hardware base 'Missing ffmpeg_g'
touch "$WORK/build output/ffmpeg_g"
rm "$WORK/build output/ffplay_g"
accept hardware base
rm "$WORK/build output/ffprobe_g"
reject cpu static 'Missing ffprobe_g'
echo "all $passed Linux link/runtime checks passed"
