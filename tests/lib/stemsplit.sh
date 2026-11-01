#!/bin/bash
# The stemsplit release gates (docs/superpowers/specs/2026-10-31-stemsplit-1.1.0-ci-gates-design.md).
#
# Three functions, each following run_custom_test's exit-code protocol in
# tests.sh: 0 pass, 2 skip (reason on a "SKIP: " line), anything else fail.
#
#   test_stemsplit_suite        the stemsplit tag's own test suite, run against
#                               the binary under test with the tiny RoFormer
#                               models and the Spleeter model (contract §8, the
#                               CI row)
#   test_stemsplit_clean_exit   20 Spleeter runs and 20 RoFormer runs, every one
#                               of which must leave on its own, with exit 0
#                               (contract §7 rule 7)
#   test_stemsplit_spleeter_ab  the Spleeter stems are byte-identical with the
#                               previous release's binary, per CPU variant this
#                               machine can run (contract §8, the Spleeter A/B row)
#
# They need the assets tests/lib/stemsplit-assets.sh fetches, in its layout,
# named by one variable (one run at a time per directory: the checks write
# their corpus and work files into it):
#
#   STEMSPLIT_ASSETS_DIR   the directory given to stemsplit-assets.sh. Unset, a
#                          stemsplit-assets/ directory next to the binary under
#                          test is used if present. Without one, every check
#                          SKIPs with a reason.
#
# Every ffmpeg run happens with that directory as the working directory and
# names its files by relative paths. On Windows, Git Bash turns an absolute path
# into C:/..., and the colon breaks avfilter's option parser the moment it lands
# in model=; relative paths never contain one. The same recipe the stemsplit
# repository's dev.sh documents.
#
# The suite and the corpus generator are Python (python3 with numpy). Where only
# `python` exists (Git Bash on Windows), a python3 shim is put on PATH for the
# duration of the check.
#
# FFMPEG (set by tests.sh) is the binary under test; Platform picks the
# baseline ggml variant the A/B gate repeats itself on.

# ---------------------------------------------------------------------------
# Inputs
# ---------------------------------------------------------------------------

# Resolve the assets into SS_ASSETS (an absolute path) and the relative names
# the checks use, or print a SKIP line and fail.
_stemsplit_inputs() {
	local bindir
	bindir="$(cd "$(dirname "${FFMPEG}")" && pwd)"
	SS_ASSETS="${STEMSPLIT_ASSETS_DIR:-}"
	[[ -z "${SS_ASSETS}" && -d "${bindir}/stemsplit-assets" ]] && SS_ASSETS="${bindir}/stemsplit-assets"
	if [[ -z "${SS_ASSETS}" || ! -d "${SS_ASSETS}" ]]; then
		echo "SKIP: no stemsplit assets in this environment (run tests/lib/stemsplit-assets.sh <platform> <dir> and set STEMSPLIT_ASSETS_DIR=<dir>)"
		return 1
	fi
	SS_ASSETS="$(cd "${SS_ASSETS}" && pwd)"
	SS_TESTS=ffmpeg-stemsplit/tests
	SS_TINY=tiny
	SS_MODEL=spleeter-2stems-f16.gguf
	# The previous release's binary for THIS platform (one directory each;
	# a machine testing two platforms must not have them overwrite each other).
	case "${FFMPEG}" in *.exe) SS_REF="ref/${Platform:-unknown}/ffmpeg.exe" ;; *) SS_REF="ref/${Platform:-unknown}/ffmpeg" ;; esac
	local f
	for f in "${SS_TESTS}/run_tests.sh" "${SS_TESTS}/gen_audio.py" "${SS_TINY}/tiny-mel-v1.gguf" "${SS_MODEL}"; do
		if [[ ! -f "${SS_ASSETS}/${f}" ]]; then
			echo "SKIP: ${SS_ASSETS}/${f} is missing (re-run tests/lib/stemsplit-assets.sh)"
			return 1
		fi
	done
	# The binary under test, as an absolute path the shell can run from inside
	# the assets directory. It is argv[0], never a filter option, so a colon in
	# it is harmless.
	SS_FFMPEG="$(cd "$(dirname "${FFMPEG}")" && pwd)/$(basename "${FFMPEG}")"
	return 0
}

# python3 with numpy, or a SKIP line. Under Git Bash on Windows only `python`
# may exist: a python3 shim goes on PATH for this shell. The suite also calls
# two GNU coreutils by name that macOS does not ship: sha256sum (five model
# identity checks compare against it) and nproc (a message). Where they are
# missing, shims over shasum and sysctl go on the same PATH.
_stemsplit_python() {
	SS_SHIM=""
	_stemsplit_shim() { # name, body
		[[ -n "${SS_SHIM}" ]] || { SS_SHIM="$(mktemp -d)"; PATH="${SS_SHIM}:${PATH}"; }
		printf '#!/bin/sh\n%s\n' "$2" >"${SS_SHIM}/$1"
		chmod +x "${SS_SHIM}/$1"
	}
	if ! command -v python3 >/dev/null 2>&1; then
		if command -v python >/dev/null 2>&1; then
			_stemsplit_shim python3 'exec python "$@"'
		else
			echo "SKIP: python3 is needed for the stemsplit corpus and checkers and is not installed"
			return 1
		fi
	fi
	if ! command -v sha256sum >/dev/null 2>&1 && command -v shasum >/dev/null 2>&1; then
		_stemsplit_shim sha256sum 'exec shasum -a 256 "$@"'
	fi
	if ! command -v nproc >/dev/null 2>&1 && command -v sysctl >/dev/null 2>&1; then
		_stemsplit_shim nproc 'sysctl -n hw.logicalcpu 2>/dev/null || sysctl -n hw.ncpu'
	fi
	if ! python3 -c "import numpy" >/dev/null 2>&1; then
		echo "SKIP: python3 has no numpy (pip install numpy); the stemsplit corpus and checkers need it"
		return 1
	fi
	return 0
}

# The corpus, generated once into <assets>/audio by the tag's generator. Both
# binaries of the A/B gate read the same files, so the generator's exact output
# does not matter; that it is the tag's generator does, because the suite's
# checks are written against these lengths and rates.
_stemsplit_corpus() {
	if [[ ! -f "${SS_ASSETS}/audio/mix.wav" || ! -f "${SS_ASSETS}/audio/short.wav" ]]; then
		(cd "${SS_ASSETS}" && python3 "${SS_TESTS}/gen_audio.py" audio) >"${SS_ASSETS}/audio-gen.log" 2>&1 \
			|| { cat "${SS_ASSETS}/audio-gen.log"; echo "FAIL: the corpus generator failed"; return 1; }
	fi
	return 0
}

# A fresh work directory under the assets, relative name "work". The old one
# is removed as far as the OS allows: on Windows a file a crashed run still
# holds open cannot be deleted, and that must not stop the next run.
_stemsplit_work() {
	SS_WORK="${SS_ASSETS}/work"
	rm -rf "${SS_WORK}" 2>/dev/null || true
	mkdir -p "${SS_WORK}"
}

# ---------------------------------------------------------------------------
# test_stemsplit_suite
# ---------------------------------------------------------------------------

test_stemsplit_suite() {
	local ffmpeg="${FFMPEG:?FFMPEG must point at the binary under test}"
	local rc summary passed failed skipped line

	_stemsplit_inputs || return 2
	_stemsplit_python || return 2
	_stemsplit_corpus || return 1
	_stemsplit_work

	echo "assets: ${SS_ASSETS}"
	echo "suite:  ${SS_TESTS}/run_tests.sh (ffmpeg-stemsplit v1.1.0)"
	# TINY_DIR set explicitly means a missing tiny file is a failure, not a
	# skip: a partial tarball must not pass green. MODEL turns the Spleeter
	# tiers on. NM_GGML=1 tells the suite this binary took nomercy-ffmpeg's
	# nm_ggml path, so it asserts the CPU-variant log and metadata instead of
	# skipping them. WORK is relative for the same reason everything else is.
	(cd "${SS_ASSETS}" && TINY_DIR="${SS_TINY}" MODEL="${SS_MODEL}" NM_GGML=1 WORK=work/suite \
		sh "${SS_TESTS}/run_tests.sh" "${SS_FFMPEG}" audio) >"${SS_WORK}/suite.log" 2>&1
	rc=$?
	# The suite prints colour codes; strip them before reading it. python3,
	# not sed: BSD sed (macOS) does not understand \x1b.
	python3 -c 'import re, sys; sys.stdout.write(re.sub(r"\x1b\[[0-9;]*m", "", sys.stdin.read()))' \
		<"${SS_WORK}/suite.log" >"${SS_WORK}/suite.txt"

	summary="$(grep -E '^passed [0-9]+, failed [0-9]+, skipped [0-9]+' "${SS_WORK}/suite.txt" | tail -1)"
	if [[ -z "${summary}" ]]; then
		tail -30 "${SS_WORK}/suite.txt"
		echo "FAIL: the suite ended without its summary line (exit ${rc})"
		return 1
	fi
	passed="$(echo "${summary}" | sed -E 's/^passed ([0-9]+), failed ([0-9]+), skipped ([0-9]+).*/\1/')"
	failed="$(echo "${summary}" | sed -E 's/^passed ([0-9]+), failed ([0-9]+), skipped ([0-9]+).*/\2/')"
	skipped="$(echo "${summary}" | sed -E 's/^passed ([0-9]+), failed ([0-9]+), skipped ([0-9]+).*/\3/')"
	echo "suite: passed ${passed}, failed ${failed}, skipped ${skipped} (exit ${rc})"

	# What was not proven, by name, so a run that proved less than it looks
	# cannot be mistaken for a full one.
	grep -E '^ *SKIP ' "${SS_WORK}/suite.txt" | sed 's/^ */   /' | head -40
	if [[ "${failed}" != "0" || "${rc}" != "0" ]]; then
		echo "--- failures ---"
		grep -E '^ *FAIL ' "${SS_WORK}/suite.txt" | sed 's/^ */   /'
		echo "--- last lines ---"
		tail -20 "${SS_WORK}/suite.txt"
		echo "FAIL: ${failed} check(s) of the stemsplit v1.1.0 suite failed (full log: ${SS_WORK}/suite.log)"
		return 1
	fi
	# Two tiers are expected to skip: the real-weight RoFormer tiers (MODEL_DIR)
	# and the presets with real weights. Anything the tiny tier skips would be
	# a tiny file that is missing, and TINY_DIR makes that a failure above.
	[[ "${passed}" -gt 0 ]] || { echo "FAIL: the suite passed nothing"; return 1; }
	return 0
}

# ---------------------------------------------------------------------------
# test_stemsplit_clean_exit
# ---------------------------------------------------------------------------

# _stemsplit_timed <seconds> <log> <command...>
# Runs the command with stdout+stderr into <log>, inside the assets directory.
# Returns the command's status, or 124 when it had to be killed. Written
# without `timeout`: macOS has none by default, and a check that silently
# cannot enforce its own limit is the fault class this test exists to catch.
_stemsplit_timed() {
	local limit="$1" log="$2" pid waited=0 rc
	shift 2
	(cd "${SS_ASSETS}" && exec "$@" >"${log}" 2>&1 </dev/null) &
	pid=$!
	while kill -0 "${pid}" 2>/dev/null; do
		if (( waited >= limit )); then
			kill -TERM "${pid}" 2>/dev/null
			sleep 2
			kill -KILL "${pid}" 2>/dev/null
			wait "${pid}" 2>/dev/null
			return 124
		fi
		sleep 1
		waited=$((waited + 1))
	done
	wait "${pid}"
	rc=$?
	return "${rc}"
}

# _stemsplit_series <label> <runs> <limit> <must-match> <ffmpeg args...>
# Runs ffmpeg <runs> times; every run must exit 0 within <limit> seconds and
# its log must match <must-match> (proof the filter did its work rather than
# exiting early). Prints the tally; returns 1 on any failure.
_stemsplit_series() {
	local label="$1" runs="$2" limit="$3" must="$4"
	shift 4
	local i rc ok=0 hung=0 nonzero=0 nowork=0 t0 t1 ms lo="" hi="" total=0 log
	echo "== ${runs} ${label} runs (limit ${limit} s each) =="
	for ((i = 1; i <= runs; i++)); do
		log="${SS_WORK}/${label}-${i}.log"
		t0=$(date +%s)
		_stemsplit_timed "${limit}" "${log}" "${SS_FFMPEG}" "$@"
		rc=$?
		t1=$(date +%s)
		ms=$(( (t1 - t0) ))
		if (( rc == 124 )); then
			hung=$((hung + 1)); echo "  run ${i}: did not exit within ${limit} s (killed)"
		elif (( rc != 0 )); then
			nonzero=$((nonzero + 1)); echo "  run ${i}: exit ${rc} after ${ms} s"
			tail -3 "${log}" | sed 's/^/      /'
		elif ! grep -q -- "${must}" "${log}"; then
			nowork=$((nowork + 1)); echo "  run ${i}: exit 0 but the log never said '${must}'"
			tail -3 "${log}" | sed 's/^/      /'
		else
			ok=$((ok + 1)); total=$((total + ms))
			[[ -z ${lo} || ${ms} -lt ${lo} ]] && lo=${ms}
			[[ -z ${hi} || ${ms} -gt ${hi} ]] && hi=${ms}
		fi
	done
	echo "  ${label}: ${ok}/${runs} exited cleanly, ${hung} hung, ${nonzero} exited non-zero, ${nowork} did no work"
	(( ok > 0 )) && echo "  ${label}: clean runs took ${lo}-${hi} s, mean $((total / ok)) s (this machine only, not a benchmark)"
	(( hung == 0 && nonzero == 0 && nowork == 0 ))
}

test_stemsplit_clean_exit() {
	local ffmpeg="${FFMPEG:?FFMPEG must point at the binary under test}"
	local runs="${STEMSPLIT_CLEAN_EXIT_RUNS:-20}" fail=0

	_stemsplit_inputs || return 2
	_stemsplit_python || return 2
	_stemsplit_corpus || return 1
	_stemsplit_work

	# Spleeter: the 4 s corpus file, one stem to a real file. The limit is far
	# above any plausible run time, so a "hang" is unambiguous and a slow
	# machine is not one.
	_stemsplit_series spleeter "${runs}" 300 "lavfi.stemsplit.version" \
		-hide_banner -nostdin -nostats -loglevel info -y -i audio/short.wav \
		-af "stemsplit=model=${SS_MODEL}:stem=accompaniment,ametadata=mode=print:key=lavfi.stemsplit.version" \
		-f wav work/spleeter.wav || fail=1
	# RoFormer: the tiny Mel model, both pads. "weights loaded" is the engine's
	# own line; a run that exits 0 without it never ran RoFormer.
	_stemsplit_series roformer "${runs}" 300 "weights loaded" \
		-hide_banner -nostdin -nostats -v verbose -y -i audio/short.wav \
		-filter_complex "[0:a]stemsplit=model=${SS_TINY}/tiny-mel-v1.gguf[v][a]" \
		-map "[v]" -f null - -map "[a]" -f null - || fail=1

	if (( fail )); then
		echo "FAIL: not every run exited cleanly; this is contract §7 rule 7 (logs in ${SS_WORK})"
		return 1
	fi
	echo "every run of both series exited cleanly"
	return 0
}

# ---------------------------------------------------------------------------
# test_stemsplit_spleeter_ab
# ---------------------------------------------------------------------------

# The stemsplit repository's own case list (tests/ab_gate.sh of v1.1.0): an
# input and an option set per line. 32-bit float WAV with -fflags +bitexact,
# so equal files mean equal samples and nothing else is in the header.
_STEMSPLIT_AB_CASES="mix.wav|
mix.wav|:stem=vocals
mix.wav|:stem=accompaniment
mix.wav|:highband=passthrough
mix.wav|:highband=zeros
mix.wav|:highband=average
mix.wav|:bleed=0.05:smooth=2:exponent=1.5
mix.wav|:overlap=1.5
mix.wav|:threads=1
short.wav|
mono_src.wav|
mix48.wav|
mix96.wav|
mix51.wav|"

# _stemsplit_ab_run <binary> <out dir, relative> <input> <options> <variant>
# stderr goes to <out dir>/run.err: the previous release's binary probes for
# Vulkan at startup and says so on machines without it, which is noise here
# and shown only when a run fails.
_stemsplit_ab_run() {
	local bin="$1" out="$2" in="$3" opts="$4" variant="$5" rc
	local wavout="-c:a pcm_f32le -fflags +bitexact -f wav"
	mkdir -p "${SS_ASSETS}/${out}"
	case "${opts}" in
	*stem=vocals* | *stem=accompaniment*)
		# shellcheck disable=SC2086
		(cd "${SS_ASSETS}" && env ${variant:+NOMERCY_GGML_CPU="${variant}"} "${bin}" -hide_banner -nostdin -nostats -v error -y \
			-i "audio/${in}" -af "stemsplit=model=${SS_MODEL}${opts}" ${wavout} "${out}/one.wav" 2>"${out}/run.err") ;;
	*)
		# shellcheck disable=SC2086
		(cd "${SS_ASSETS}" && env ${variant:+NOMERCY_GGML_CPU="${variant}"} "${bin}" -hide_banner -nostdin -nostats -v error -y \
			-i "audio/${in}" -filter_complex "[0:a]stemsplit=model=${SS_MODEL}${opts}[v][a]" \
			-map "[v]" ${wavout} "${out}/v.wav" -map "[a]" ${wavout} "${out}/a.wav" 2>"${out}/run.err") ;;
	esac
	rc=$?
	(( rc == 0 )) || tail -3 "${SS_ASSETS}/${out}/run.err" | sed 's/^/        /'
	return "${rc}"
}

test_stemsplit_spleeter_ab() {
	local ffmpeg="${FFMPEG:?FFMPEG must point at the binary under test}"
	local variants variant ref i in opts label b w same f n pass=0 fail=0

	_stemsplit_inputs || return 2
	if [[ -z "${Platform:-}" ]]; then
		echo "SKIP: Platform is not set, so the reference build for this platform cannot be found"
		return 2
	fi
	if [[ ! -f "${SS_ASSETS}/${SS_REF}" ]]; then
		echo "SKIP: no reference build at ${SS_ASSETS}/${SS_REF} (re-run tests/lib/stemsplit-assets.sh ${Platform} <dir>)"
		return 2
	fi
	_stemsplit_python || return 2
	_stemsplit_corpus || return 1
	_stemsplit_work
	ref="${SS_ASSETS}/${SS_REF}"
	chmod +x "${ref}" 2>/dev/null || true
	echo "reference: ${ref} ($("${ref}" -version 2>/dev/null | head -1 | cut -c1-60))"

	# Every CPU variant this machine can run: the automatic choice and the
	# platform baseline. darwin builds at one fixed level and ignore the
	# override, so there only the automatic choice is a distinct run.
	if cpu_variant_is_darwin "${Platform:-}"; then variants="auto"
	else variants="auto $(cpu_variant_baseline "${Platform:-}")"; fi

	# A 5.1 input, derived from the corpus the same way every time, by the
	# binary under test (pan is not under test here).
	(cd "${SS_ASSETS}" && "${SS_FFMPEG}" -hide_banner -nostdin -nostats -v error -y -i audio/mix.wav \
		-af "pan=5.1|FL=c0|FR=c1|FC=0.5*c0+0.5*c1|LFE=0*c0|BL=c0|BR=c1" -c:a pcm_s16le audio/mix51.wav) \
		|| { echo "FAIL: could not derive the 5.1 input"; return 1; }

	for variant in ${variants}; do
		local v=""
		[[ "${variant}" != auto ]] && v="${variant}"
		echo "== comparing against the reference (cpu variant: ${variant}) =="
		i=0
		while IFS='|' read -r in opts; do
			[[ -z "${in}" ]] && continue
			i=$((i + 1))
			label="${in}${opts:- (defaults)}"
			b="work/ab/${variant}/${i}/ref"; w="work/ab/${variant}/${i}/new"
			if ! _stemsplit_ab_run "${ref}" "${b}" "${in}" "${opts}" "${v}"; then
				fail=$((fail + 1)); echo "  FAIL  ${label} (the reference binary failed)"; continue
			fi
			if ! _stemsplit_ab_run "${SS_FFMPEG}" "${w}" "${in}" "${opts}" "${v}"; then
				fail=$((fail + 1)); echo "  FAIL  ${label} (the binary under test failed)"; continue
			fi
			same=1
			for f in "${SS_ASSETS}/${b}"/*.wav; do
				n="$(basename "${f}")"
				if [[ ! -s "${f}" || ! -s "${SS_ASSETS}/${w}/${n}" ]]; then
					same=0; echo "        ${n} is empty"
				elif ! cmp -s "${f}" "${SS_ASSETS}/${w}/${n}"; then
					same=0; echo "        ${n} differs: $(cmp "${f}" "${SS_ASSETS}/${w}/${n}" 2>&1 | head -1)"
				fi
			done
			if (( same )); then pass=$((pass + 1)); echo "  SAME  ${label}"
			else fail=$((fail + 1)); echo "  DIFF  ${label}"; fi
		done <<<"${_STEMSPLIT_AB_CASES}"

		# The gate is only worth something if it can see a difference: two
		# option sets that must differ (the defaults and highband=zeros) are
		# compared on the reference's own output. Identical means the inputs
		# or the pipeline stopped exercising the filter, and every SAME above
		# proves nothing.
		if cmp -s "${SS_ASSETS}/work/ab/${variant}/1/ref/a.wav" "${SS_ASSETS}/work/ab/${variant}/5/ref/a.wav"; then
			fail=$((fail + 1)); echo "  FAIL  sanity: highband=zeros and the defaults gave identical output"
		else
			pass=$((pass + 1)); echo "  OK    sanity: the comparison can see a real difference"
		fi
	done

	echo "A/B gate: ${pass} identical, ${fail} different"
	if (( fail > 0 )); then
		echo "FAIL: the Spleeter path changed against the previous release (outputs under ${SS_WORK}/ab)"
		return 1
	fi
	return 0
}
