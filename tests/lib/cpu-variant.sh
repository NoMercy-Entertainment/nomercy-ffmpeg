#!/bin/bash
# Assert the ggml CPU variant dispatcher keeps working in the built binary.
#
# Sourced by tests.sh; expects $FFMPEG to point at the binary under test and
# $Platform to be the platform tag tests.sh already computes (e.g.
# "linux-x86_64", "darwin-arm64").
#
# DEVIATION from the task-8 brief: the brief's test runs stemsplit against a
# real model and greps the resulting log line. That cannot work in tests.sh's
# own environment -- the stemsplit/whisper models are published as release
# assets, not shipped inside the platform archive tests.sh unpacks and tests
# against, and reading tests.sh/tests.ps1/smoke.sh/smoke.ps1/verify-rc.sh/
# verify-rc.ps1 top to bottom confirms none of them reference a model path
# anywhere (the existing "stemsplit" test at tests.sh:330 only checks that
# the filter is *registered*, via `-filters | grep stemsplit`, precisely
# because no model is available to actually run it).
#
# It goes deeper than "no model to feed it", too: NOMERCY_GGML_CPU is only
# ever read inside nm_select() (scripts/includes/ggml_cpu_dispatch.c), which
# is only ever called from ggml_backend_cpu_init(), which both filters call
# strictly AFTER a real model has been fully resolved (see af_stemsplit.c's
# "backend: CPU only" comment -- it runs after ss_repack_all_kernels() -- and
# af_whisper.c's init(), which calls it only after
# whisper_init_from_file_with_params() has already succeeded). So there is no
# way, with or without a model file present, to observe *which* variant gets
# selected without a model that actually loads successfully.
#
# So this test always asserts the cheap, always-reachable half of the
# guarantee: setting NOMERCY_GGML_CPU to the platform baseline, or to
# garbage, never stops the binary from starting -- the dispatcher's own
# contract is that an unknown or unsupported value is ignored rather than
# failing to start (see nm_select()'s comment). When a model happens to be
# available -- TEST_MODEL/TEST_MP3 env vars, or (the convention this
# project's own manual verification workdirs, e.g. tools/ggml-variants'
# build-*.sh WORK directories, already use) a spleeter-2stems-f16.gguf and a
# *.mp3 sitting right next to the binary -- it also runs the full brief-style
# check: the automatically-selected variant is logged and reflected in frame
# metadata, forcing the baseline selects exactly the baseline, and forcing a
# nonsense value falls back to the automatic choice (mirroring what
# tools/ggml-variants/dispatch-test.sh already proved in isolation for Task
# 3, but here against the real, filter-integrated, shipped binary). Absent a
# model, that second half is a SKIP with the reason recorded -- never a
# silent pass -- via run_custom_test's exit-code-2 protocol in tests.sh.
#
# The always-on half (cpu_variant_is_darwin / cpu_variant_baseline /
# cpu_variant_startup_ok below) is factored out so tests/smoke.sh -- the
# script CI actually runs on every platform, unlike this one -- can assert
# the same startup guarantee without duplicating it. See smoke.sh for why it
# needs its own copy of the darwin/baseline decision instead of calling
# test_cpu_variant() directly: smoke.sh has its own fail()/note()/ok()
# reporting and its own cross-exec platform handling that must run first.

# True if the platform tag carries no ggml cpu dispatcher at all (fixed
# instruction level, Task 6) -- NOMERCY_GGML_CPU is a no-op there.
cpu_variant_is_darwin() {
	case "$1" in
	*darwin*) return 0 ;;
	*) return 1 ;;
	esac
}

# Prints the baseline variant name for a platform tag: the one guaranteed to
# run on every machine the binary supports, x86_64 or aarch64.
cpu_variant_baseline() {
	case "$1" in
	*aarch64* | *arm64*) echo "armv8.0" ;;
	*) echo "x64" ;;
	esac
}

# True if the binary was actually compiled with the dispatcher. Added after a
# first round of review pointed out that cpu_variant_startup_ok below is
# trivially true for ANY binary, old or new: an old, pre-dispatcher binary
# never reads NOMERCY_GGML_CPU at all, so it "starts cleanly" with it set for
# exactly the wrong reason, and a smoke check built only on that can never
# fail -- which manufactures false confidence instead of catching a
# regression. NOMERCY_GGML_CPU is read via getenv() exactly once, inside
# nm_select() (scripts/includes/ggml_cpu_dispatch.c), so the literal
# environment-variable name survives as a string constant in the binary even
# stripped of symbols -- confirmed empirically (see task-8 report): 0
# occurrences in a real pre-dispatcher release binary, 1 in a
# dispatcher-enabled build, on both the linux and windows binaries tested.
# Deliberately not asserted on darwin: NM_GGML_CPU_FIXED mode (Task 6)
# compiles out nm_select()/getenv() entirely there, so a darwin binary
# legitimately never contains this string -- that is the correct state, not
# a failure, so darwin skips this check the same way it skips the rest.
cpu_variant_dispatcher_compiled_in() {
	grep -aq "NOMERCY_GGML_CPU" "$1"
}

# The always-on guarantee: NOMERCY_GGML_CPU can never stop the binary from
# starting, unset, forced to the platform baseline, or forced to garbage.
# Needs no model, so it is reachable everywhere the binary can be executed at
# all. $1 = ffmpeg path, $2 = baseline name. Prints one line per attempt on
# failure and returns 1; prints nothing on success (callers report success in
# their own voice) and returns 0.
cpu_variant_startup_ok() {
	local ffmpeg="$1" baseline="$2" value out code
	for value in "" "${baseline}" "definitely-not-a-real-variant"; do
		if [[ -n "${value}" ]]; then
			out=$(NOMERCY_GGML_CPU="${value}" "${ffmpeg}" -hide_banner -version 2>&1)
		else
			# The "unset" case must actually be unset, not just
			# unassigned in this subshell -- a plain call here would
			# still inherit whatever NOMERCY_GGML_CPU the caller's own
			# environment holds, silently skipping the one case this
			# loop exists to cover.
			out=$(env -u NOMERCY_GGML_CPU "${ffmpeg}" -hide_banner -version 2>&1)
		fi
		code=$?
		if [[ ${code} -ne 0 ]]; then
			echo "FAIL: '${ffmpeg} -version' did not start with NOMERCY_GGML_CPU='${value}' (exit ${code})"
			echo "${out}" | tail -5
			return 1
		fi
	done
	return 0
}

test_cpu_variant() {
	local platform="${Platform:-}"
	local ffmpeg="${FFMPEG:?FFMPEG must point at the binary under test}"
	local baseline

	if cpu_variant_is_darwin "${platform}"; then
		echo "SKIP: ${platform} carries no ggml cpu dispatcher (fixed instruction level, Task 6); NOMERCY_GGML_CPU is a no-op there"
		return 2
	fi

	baseline="$(cpu_variant_baseline "${platform}")"
	echo "platform baseline: ${baseline}"

	# --- always-on guarantee: the variable can never make a machine unbootable ---
	if ! cpu_variant_startup_ok "${ffmpeg}" "${baseline}"; then
		return 1
	fi
	echo "startup guarantee held: default, forced baseline (${baseline}) and a nonsense override all start cleanly"

	# --- model-gated: does the dispatcher actually pick what it claims to? ---
	local model="${TEST_MODEL:-}"
	local audio="${TEST_MP3:-}"
	local bindir
	bindir="$(cd "$(dirname "${ffmpeg}")" && pwd)"
	[[ -z "${model}" && -f "${bindir}/spleeter-2stems-f16.gguf" ]] && model="${bindir}/spleeter-2stems-f16.gguf"
	if [[ -z "${audio}" ]]; then
		audio=$(ls "${bindir}"/*.mp3 2>/dev/null | head -1)
	fi

	if [[ -z "${model}" || ! -f "${model}" || -z "${audio}" || ! -f "${audio}" ]]; then
		echo "SKIP: no stemsplit model available in this environment (published as a release asset, not shipped in the platform archive; set TEST_MODEL/TEST_MP3 to exercise the full check) - startup guarantee above still held"
		return 2
	fi
	echo "model: ${model}"
	echo "audio: ${audio}"

	# avfilter's option-string parser treats ':' as the key=value separator,
	# so an absolute path containing one (confirmed while verifying this test
	# on Windows: "C:\Users\...") breaks "-af stemsplit=model=<path>:stem=..."
	# partway through parsing. Running ffmpeg with its working directory set
	# to the model's folder and passing only the leaf filename sidesteps that
	# whole class of escaping bugs instead of trying to escape it correctly.
	local modeldir modelleaf
	modeldir="$(cd "$(dirname "${model}")" && pwd)"
	modelleaf="$(basename "${model}")"

	_cpu_variant_probe() { # $1 = NOMERCY_GGML_CPU value, may be empty
		local v="$1" got
		if [[ -n "${v}" ]]; then
			got=$(cd "${modeldir}" && NOMERCY_GGML_CPU="${v}" "${ffmpeg}" -hide_banner -loglevel info -nostats -t 8 \
				-i "${audio}" -vn \
				-af "stemsplit=model=${modelleaf}:stem=accompaniment,ametadata=mode=print:key=lavfi.stemsplit.cpu_variant" \
				-f null - 2>&1 | grep -oE "lavfi\.stemsplit\.cpu_variant=[a-z0-9.+_]+" | head -1 | cut -d= -f2)
		else
			got=$(cd "${modeldir}" && "${ffmpeg}" -hide_banner -loglevel info -nostats -t 8 \
				-i "${audio}" -vn \
				-af "stemsplit=model=${modelleaf}:stem=accompaniment,ametadata=mode=print:key=lavfi.stemsplit.cpu_variant" \
				-f null - 2>&1 | grep -oE "lavfi\.stemsplit\.cpu_variant=[a-z0-9.+_]+" | head -1 | cut -d= -f2)
		fi
		printf '%s' "${got}"
	}

	local auto_variant forced_variant bogus_variant
	auto_variant=$(_cpu_variant_probe "")
	if [[ -z "${auto_variant}" ]]; then
		echo "FAIL: no lavfi.stemsplit.cpu_variant metadata with automatic selection (old, dispatcher-less binary?)"
		return 1
	fi
	echo "automatic: ${auto_variant}"

	forced_variant=$(_cpu_variant_probe "${baseline}")
	if [[ "${forced_variant}" != "${baseline}" ]]; then
		echo "FAIL: NOMERCY_GGML_CPU=${baseline} selected '${forced_variant}', not '${baseline}'"
		return 1
	fi
	echo "forced baseline: ${forced_variant}"

	bogus_variant=$(_cpu_variant_probe "definitely-not-a-real-variant")
	if [[ "${bogus_variant}" != "${auto_variant}" ]]; then
		echo "FAIL: an unknown NOMERCY_GGML_CPU fell back to '${bogus_variant}', not the automatic choice '${auto_variant}'"
		return 1
	fi
	echo "unknown override falls back to automatic: ${bogus_variant}"

	echo "selected ${auto_variant} automatically; baseline override selects ${baseline}; unknown override falls back safely"
	return 0
}
