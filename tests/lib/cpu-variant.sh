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

# --------------------------------------------------------------------------
# ggml Vulkan GPU backend (2026-09-23-ggml-vulkan-backend plan, Task 6)
# --------------------------------------------------------------------------
#
# Same division of labour as the CPU half above: predicates live here so
# tests/smoke.sh -- the script CI actually runs on every platform -- and
# tests/tests.sh can assert the same things in their own reporting voice.
#
# DEVIATION from the task-6 plan snippet, which excluded only darwin and said
# "Vulkan lands in five of the seven platforms". It lands in FOUR of seven.
# freebsd-x86_64 is excluded too, and has been since Task 2: these binaries
# link statically and FreeBSD's libc.a supplies dlopen() as a stub that sets
# "Service unavailable" and returns NULL unconditionally (verified for Task 5
# by disassembling dlopen in a statically linked FreeBSD 14.3 binary), so the
# loader shim could never open a real loader there. scripts/48-whisper.sh sets
# NM_VULKAN=0 for darwin AND freebsd. Shipping the plan's snippet as written
# would have failed every freebsd build for carrying no Vulkan, which is the
# correct state.
vulkan_platform_has_backend() {
	case "$1" in
	*darwin* | *freebsd*) return 1 ;;
	*) return 0 ;;
	esac
}

# True if ggml's Vulkan backend is really linked in. Greppable, so it works on
# the cross-exec platforms a runner cannot execute -- which, as with the CPU
# dispatcher check above, are the ones with the least other evidence
# (linux-aarch64 and windows-aarch64 have never been executed by any runner
# here).
#
# Two independent strings, either of which is enough: "ggml_vulkan" is
# ggml-vulkan.cpp's own log prefix, and vkGetInstanceProcAddr is one of the
# three loader symbols scripts/includes/vk_loader_shim.c defines. Checking the
# shim symbol matters as much as the backend: ggml-vulkan.a without the shim
# does not link at all, but a future refactor that dropped the shim while
# keeping the backend would produce a binary that cannot open a loader on any
# machine, and "ggml_vulkan" alone would still be there.
vulkan_backend_compiled_in() {
	grep -aq "ggml_vulkan" "$1" && grep -aq "vkGetInstanceProcAddr" "$1"
}

# True if the fork-and-probe ICD guard is compiled in. It is built only for
# non-Windows, non-Apple (ggml_cpu_dispatch.c's
# `#if !defined(_WIN32) && !defined(__APPLE__) && !defined(NM_NO_VULKAN)`), so
# this is an expectation that differs per platform rather than a thing that
# must always be true -- see vulkan_platform_has_guard.
#
# The marker is a notice only the guarded code can print. NOT "software
# rasteriser": that phrase is also in nm_vk_scan's device-name table, which
# every platform compiles, so it is present in a correct Windows binary whose
# guard is correctly absent. That mistake was made once already, during Task 5,
# and it accused windows-aarch64 of a bug it did not have.
vulkan_guard_compiled_in() {
	grep -aq "crash a statically linked" "$1"
}

vulkan_platform_has_guard() {
	case "$1" in
	*windows* | *darwin* | *freebsd*) return 1 ;;
	*) return 0 ;;
	esac
}

# The guard's VOCABULARY, not its behaviour. It reaches four different
# verdicts and must never confuse them in what it tells the user:
#
#   1. an observed crash, fully identified - a conclusion.
#   2. an observed crash the bisect could not finish attributing - it must say
#      it could not finish, and offer the budget knob, but NOT offer to skip
#      the check, which on that machine means reproducing the crash.
#   3. a precaution - the guard could not decide at all. It must say in so many
#      words that this is NOT a report that anything is broken.
#   4. a clean machine - software rasteriser only; the loader is left alone.
#
# Four review rounds went into separating these and two of the findings were
# exactly this wording collapsing, so the phrases are the feature.
#
# WHAT THIS PROVES, AND WHAT IT DOES NOT. It proves the vocabulary survives: if
# an arm is deleted or its message merged into another's, at least one phrase
# leaves the binary and this fails by name. It does NOT prove the arms still
# print their own message - a refactor that made arm 2 print arm 3's wording,
# leaving all four strings in the image, passes here. That claim needs the arms
# actually observed, which needs a machine whose drivers misbehave, and it
# lives in tools/ggml-variants/build-linux-x86_64.sh's Mesa block instead.
#
# It is deliberately kept as a string search anyway, and deliberately not made
# cleverer: on linux-aarch64, windows-aarch64 and freebsd-x86_64 no runner here
# can execute the binary at all, so this is the ONLY automated coverage those
# platforms can get. Its job is breadth.
#
# Renamed from vulkan_guard_verdicts_distinct, which promised what the Mesa
# block delivers.
vulkan_guard_vocabulary_intact() {
	local bin="$1" missing="" phrase
	# One phrase per arm, each unique to that arm. Arm 2 ("could not finish
	# identifying which") arrives from 7b98498 and was missing from this
	# list until the Task 6 review caught it - the arm round 5 exists to
	# create could have been deleted with this check still green.
	for phrase in \
		"vulkan disabled for this process" \
		"could not finish identifying which" \
		"not a report that anything is broken" \
		"the loader configuration is unchanged"; do
		grep -aq "${phrase}" "${bin}" || missing="${missing}
    missing: \"${phrase}\""
	done
	# Both escape hatches the notices tell people to reach for. A notice that
	# says "this is not a report that anything is broken" and then leaves the
	# reader no way to act on it is worse than no notice.
	for phrase in NOMERCY_VK_GUARD_MS NOMERCY_VK_ICD_GUARD; do
		grep -aq "${phrase}" "${bin}" || missing="${missing}
    missing escape hatch: ${phrase}"
	done
	if [[ -n "${missing}" ]]; then
		echo "FAIL: the guard's verdict vocabulary has been collapsed or lost:${missing}"
		return 1
	fi
	return 0
}

# The guarantee that outranks every performance goal on this branch: a machine
# with no usable GPU must behave exactly as it did before any of this existed.
# A CI runner is that machine -- no GPU, and usually no driver at all -- which
# makes it the single most representative environment available for the case
# four separate startup crashes were found in.
#
# THIS USED TO RUN `ffmpeg -version`, AND THAT WAS THE BUG. `-version` never
# builds a filtergraph, so it never instantiates whisper or stemsplit, so it
# never reaches ggml's backend registry -- and the registry is the thing that
# crashes. Measured by the Task 6 reviewer on one binary in one
# mesa-vulkan-drivers container, back to back:
#
#     whisper instantiated, guard ON   -> exit 251   (clean error)
#     whisper instantiated, guard OFF  -> exit 139   (Segmentation fault)
#     ffmpeg -version,      guard ON   -> exit 0
#     ffmpeg -version,      guard OFF  -> exit 0
#
# So the old predicate reported PASS for a configuration guaranteed to kill a
# real filter on that machine, while its success line claimed the binary
# "starts cleanly ... with either escape hatch set". An assertion that
# advertises coverage it does not have is the fifth instance of that shape on
# this branch; it is not going to be the one that ships.
#
# The probe therefore instantiates the whisper filter for real. af_whisper.c's
# init() calls nm_ggml_gpu_usable() and ggml_backend_load_all() BEFORE it
# rejects a missing model (af_whisper.c:168-182), so this needs no model file
# and no media -- and the "No whisper model path specified" error it comes back
# with is positive proof that ggml init was reached and survived, which is
# stronger than merely not crashing.

# 0.1 s of 16 kHz mono silence, written by hand. Only used when the binary has
# no lavfi input device: the shipped builds do, but the ggml harness builds are
# --disable-everything and do not, and a probe that quietly degrades to "could
# not test anything" on some builds is how this check went wrong the first
# time. 44-byte canonical WAV header + 3200 zero samples.
_vulkan_write_silence() {
	local out="$1" n=3200 bytes=$((3200 * 2))
	{
		printf 'RIFF'
		printf "$(printf '\x%02x\x%02x\x%02x\x%02x' \
			$(( (bytes + 36) & 255 )) $(( ((bytes + 36) >> 8) & 255 )) \
			$(( ((bytes + 36) >> 16) & 255 )) $(( ((bytes + 36) >> 24) & 255 )))"
		printf 'WAVEfmt '
		printf '\x10\x00\x00\x00\x01\x00\x01\x00\x80\x3e\x00\x00\x00\x7d\x00\x00\x02\x00\x10\x00'
		printf 'data'
		printf "$(printf '\x%02x\x%02x\x%02x\x%02x' \
			$(( bytes & 255 )) $(( (bytes >> 8) & 255 )) \
			$(( (bytes >> 16) & 255 )) $(( (bytes >> 24) & 255 )))"
		head -c "${bytes}" /dev/zero
	} > "${out}" 2>/dev/null || return 1
	[[ -s "${out}" ]]
}

# Runs the whisper filter once, under whatever environment the caller has set,
# and classifies what came back. Echoes a diagnostic; returns:
#   0 - reached ggml init and returned (proved by the model rejection)
#   1 - died on a signal: a crash, which is exactly what is being tested for
#   2 - the filter could not be instantiated here at all, for an unrelated
#       reason. Never reported as a pass.
# $1 = ffmpeg, $2 = "lavfi" or a path to a wav.
_vulkan_filter_probe() {
	local ffmpeg="$1" input="$2" out code
	if [[ "${input}" == "lavfi" ]]; then
		out=$("${ffmpeg}" -hide_banner -loglevel error -nostats \
			-f lavfi -i "anullsrc=channel_layout=mono:sample_rate=16000" -t 0.1 \
			-af whisper -f null - 2>&1)
	else
		out=$("${ffmpeg}" -hide_banner -loglevel error -nostats \
			-i "${input}" -t 0.1 -af whisper -f null - 2>&1)
	fi
	code=$?

	# Positive proof FIRST, and it is the real discriminator. af_whisper.c
	# prints this only after nm_ggml_gpu_usable() and ggml_backend_load_all()
	# have both returned (af_whisper.c:168-182), so seeing it means the
	# process reached ggml init and came back. A crash during init means it
	# never prints.
	if echo "${out}" | grep -q "No whisper model path specified"; then
		return 0
	fi

	# Only then the exit code, and NOT as ">= 128". That rule is wrong here:
	# ffmpeg exits with 256+AVERROR, so a perfectly ordinary
	# AVERROR(EINVAL) is 234 and AVERROR(EIO) is 251 -- measured, this probe
	# returns 234 for the missing model. Reading those as "signal 106" and
	# "signal 123" would turn every healthy run into a reported crash, which
	# is the same kind of wrong as the bug this rewrite fixes, pointing the
	# other way. Only the signals a crash actually arrives as.
	case ${code} in
	132 | 134 | 135 | 136 | 137 | 139)
		echo "crashed: exit ${code} (killed by signal $((code - 128)))"
		echo "${out}" | tail -6
		return 1 ;;
	esac

	echo "could not instantiate the whisper filter here (exit ${code}); this configuration proved nothing"
	echo "${out}" | tail -4
	return 2
}

# $1 = ffmpeg path. Echoes diagnostics; returns 0 on proof, 1 on a crash in a
# configuration that promises not to crash, 2 if the filter could not be
# instantiated at all on this build.
#
# WHICH CONFIGURATIONS ARE ALLOWED TO CRASH, which is the whole contract:
#
#   * default, no driver findable, NOMERCY_GGML_GPU=0 -- these MUST NOT crash,
#     ever, on any machine. That is the branch's headline guarantee.
#   * NOMERCY_VK_ICD_GUARD=0 -- this one is ALLOWED to crash, and asserting
#     otherwise would be wrong. It means "skip the driver check and use Vulkan
#     as-is", i.e. opt out of the protection; on a machine whose drivers really
#     do kill a static binary, crashing is the documented consequence of
#     setting it (Task 3's N11 is exactly about not recommending it to such a
#     machine). Measured here: on a container with mesa installed, the guard-on
#     run returns cleanly and the guard-off run is exit 139. Failing CI for
#     that would be a false failure on correct behaviour -- and GitHub's
#     ubuntu runners do ship software Vulkan drivers, so it would fire. It is
#     run anyway, because "the guard is load-bearing on this machine" is worth
#     printing; it just reports instead of failing.
vulkan_startup_ok() {
	local ffmpeg="$1" input="lavfi" tmp spec label rc diag
	local inconclusive=0

	# lavfi first: no temp file, and it is what a shipped build uses. The
	# ggml harness builds are --disable-everything and have no lavfi indev,
	# so fall back to a silent wav rather than quietly proving nothing.
	if ! _vulkan_filter_probe "${ffmpeg}" lavfi >/dev/null 2>&1; then
		tmp="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/nm-vk-$$")"
		mkdir -p "${tmp}"
		if _vulkan_write_silence "${tmp}/silence.wav"; then
			input="${tmp}/silence.wav"
		fi
	fi

	# label:may-crash:env
	local -a envs=(
		"as the runner is:no:"
		"no driver findable:no:VK_ICD_FILENAMES=/nonexistent.json VK_DRIVER_FILES=/nonexistent.json"
		"gpu disabled:no:NOMERCY_GGML_GPU=0"
		"guard disabled:yes:NOMERCY_VK_ICD_GUARD=0"
	)
	for spec in "${envs[@]}"; do
		label="${spec%%:*}"
		# Two statements, not one `local a=.. b=..`: the second initialiser
		# would be expanded before the first assignment lands, which under
		# set -u is an unbound-variable abort rather than an empty string.
		local rest="${spec#*:}"
		local may_crash="${rest%%:*}"
		# shellcheck disable=SC2086
		diag=$(env ${rest#*:} bash -c '
			source "$0"
			_vulkan_filter_probe "$1" "$2"' "${BASH_SOURCE[0]}" "${ffmpeg}" "${input}")
		rc=$?
		case ${rc} in
		0) ;;
		1) if [[ ${may_crash} == yes ]]; then
			   echo "note: ${label}: this machine's drivers do kill a static binary, so the guard is load-bearing here - which is what opting out of it means, not a failure"
		   else
			   echo "FAIL: the binary died instantiating a ggml filter (${label})"
			   echo "${diag}" | sed 's/^/    /'
			   return 1
		   fi ;;
		*) echo "note: ${label}: ${diag}"
		   inconclusive=1 ;;
		esac
	done
	[[ ${inconclusive} -eq 0 ]] || return 2
	return 0
}
