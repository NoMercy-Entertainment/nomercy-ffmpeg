#!/bin/bash
# Real-model tests for the whisper filter options of issue #112: dtw,
# word_timestamps, prompt, prompt_file, beam_size and best_of.
#
# Two functions, each following run_custom_test's exit-code protocol in
# tests.sh: 0 pass, 2 skip (reason on a "SKIP: " line), anything else fail.
#
#   test_whisper_options            the new options do what they say
#   test_whisper_defaults_unchanged without them, output is byte-identical to
#                                   a reference build (v1.0.44)
#
# They need a model and a clip, which no platform archive ships:
#
#   WHISPER_TEST_MODEL     ggml-base.en.bin (sha256 a03779c8...c6d002)
#   WHISPER_TEST_AUDIO     jfk.wav from whisper.cpp v1.9.1 samples
#   WHISPER_TEST_REFERENCE_FFMPEG
#                          an ffmpeg from v1.0.44, for the defaults check only
#
# When a variable is unset, ggml-base.en.bin and jfk.wav next to the binary
# under test are used if present. Without them the tests SKIP with a reason.
# The JSON checks use python3, present on every host in the fleet.
#
# FFMPEG (set by tests.sh) is the binary under test; Platform picks the
# NOMERCY_GGML_CPU baseline both sides of the defaults check run on.

# Resolve the inputs into WT_MODEL / WT_AUDIO, or print a SKIP line and fail.
_whisper_test_inputs() {
	local bindir
	bindir="$(cd "$(dirname "${FFMPEG}")" && pwd)"
	WT_MODEL="${WHISPER_TEST_MODEL:-}"
	WT_AUDIO="${WHISPER_TEST_AUDIO:-}"
	[[ -z "${WT_MODEL}" && -f "${bindir}/ggml-base.en.bin" ]] && WT_MODEL="${bindir}/ggml-base.en.bin"
	[[ -z "${WT_AUDIO}" && -f "${bindir}/jfk.wav" ]] && WT_AUDIO="${bindir}/jfk.wav"

	if [[ -z "${WT_MODEL}" || ! -f "${WT_MODEL}" || -z "${WT_AUDIO}" || ! -f "${WT_AUDIO}" ]]; then
		echo "SKIP: no whisper model and clip in this environment (set WHISPER_TEST_MODEL to ggml-base.en.bin and WHISPER_TEST_AUDIO to jfk.wav)"
		return 1
	fi
	if ! command -v python3 >/dev/null 2>&1; then
		echo "SKIP: python3 is needed to validate the JSON output and is not installed"
		return 1
	fi
	return 0
}

# A scratch directory holding the model under a short name. avfilter treats
# ':' as its option separator, so an absolute path in model= or prompt_file=
# (a Windows drive letter, or any path with a colon) breaks the filter
# description. Running inside this directory with leaf names avoids that
# whole class of escaping problem.
_whisper_test_workdir() {
	WT_DIR="$(mktemp -d)"
	ln -s "$(cd "$(dirname "${WT_MODEL}")" && pwd)/$(basename "${WT_MODEL}")" "${WT_DIR}/model.bin" 2>/dev/null \
		|| cp "${WT_MODEL}" "${WT_DIR}/model.bin"
}

# _whisper_run <ffmpeg> <out> <err> <filter options...>
# Runs the filter over the clip with format/destination left to the caller.
# Always CPU and one filter thread, so two runs differ only in what is being
# compared. With WT_BASELINE set, also the platform's baseline ggml variant:
# the defaults check needs both builds on the same variant. The options checks
# leave it empty, because the baseline (no SIMD at all) is several times
# slower and those checks compare runs of one binary.
_whisper_run() {
	local bin="$1" out="$2" err="$3" opts="$4"
	(cd "${WT_DIR}" && env ${WT_BASELINE:+NOMERCY_GGML_CPU="${WT_BASELINE}"} "${bin}" -hide_banner -nostdin -nostats -filter_threads 1 \
		-i "${WT_AUDIO}" -af "whisper=model=model.bin:use_gpu=0:${opts}" -f null - >"${out}" 2>"${err}" </dev/null)
}

# _whisper_check_json <file> [words] [dtw-vs-file]
# Every line parses, the first is the language line, and at least one segment
# follows. With "words": every segment carries a non-empty words array whose
# timings sit inside the segment, never go backwards, with 0 <= p <= 1, and
# whose text joined back together is the segment text (ignoring punctuation
# and case). With a third argument (a words run without DTW): at least one
# word start differs, which is what shows DTW was really active.
_whisper_check_json() {
	python3 - "$@" <<'PY'
import json, re, sys

def load(path):
    with open(path, encoding="utf-8") as f:
        lines = [l for l in f.read().split("\n") if l]
    if not lines:
        sys.exit(f"{path}: no output at all")
    objs = []
    for i, line in enumerate(lines, 1):
        try:
            objs.append(json.loads(line))
        except ValueError as e:
            sys.exit(f"{path}:{i}: not valid JSON ({e}): {line[:200]}")
    if "detected_language" not in objs[0]:
        sys.exit(f"{path}: first line is not the detected_language line: {lines[0][:200]}")
    segs = objs[1:]
    if not segs:
        sys.exit(f"{path}: no segments after the language line")
    return segs

def norm(s):
    return re.sub(r"[^\w]+", "", s.lower())

path = sys.argv[1]
segs = load(path)
want_words = len(sys.argv) > 2 and sys.argv[2] == "words"

for n, s in enumerate(segs, 1):
    for k in ("start", "end", "text"):
        if k not in s:
            sys.exit(f"{path}: segment {n} has no '{k}'")
    if not want_words:
        if "words" in s:
            sys.exit(f"{path}: segment {n} has a words array nobody asked for")
        continue
    w = s.get("words")
    if not w:
        sys.exit(f"{path}: segment {n} has no words: {s}")
    prev = None
    for x in w:
        if not (0.0 <= x["p"] <= 1.0):
            sys.exit(f"{path}: segment {n}: p out of range: {x}")
        if not (s["start"] <= x["start"] <= x["end"] <= s["end"]):
            sys.exit(f"{path}: segment {n}: word outside [{s['start']}, {s['end']}]: {x}")
        if prev is not None and x["start"] < prev:
            sys.exit(f"{path}: segment {n}: word starts go backwards at {x}")
        prev = x["start"]
    joined = " ".join(x["text"] for x in w)
    if norm(joined) != norm(s["text"]):
        sys.exit(f"{path}: segment {n}: words {joined!r} do not make up text {s['text']!r}")

if len(sys.argv) > 3:
    other = load(sys.argv[3])
    a = [x["start"] for s in segs for x in s["words"]]
    b = [x["start"] for s in other for x in s["words"]]
    if a == b:
        sys.exit(f"{path}: every word start equals the run without DTW; DTW did not take effect")

print(f"{path}: {len(segs)} segment(s) OK" + (" with words" if want_words else ""))
PY
}

test_whisper_options() {
	local ffmpeg="${FFMPEG:?FFMPEG must point at the binary under test}"
	local d rc

	_whisper_test_inputs || return 2
	WT_BASELINE=""
	_whisper_test_workdir
	d="${WT_DIR}"
	# shellcheck disable=SC2064
	trap "rm -rf '${d}'" RETURN
	echo "model: ${WT_MODEL}"
	echo "audio: ${WT_AUDIO}"

	# 1. Plain JSON: every line parses, language line first.
	_whisper_run "${ffmpeg}" "${d}/plain.json" "${d}/plain.err" "format=json:destination=-" \
		|| { tail -5 "${d}/plain.err"; echo "FAIL: format=json run exited non-zero"; return 1; }
	_whisper_check_json "${d}/plain.json" || return 1

	# 2. ffmpeg -h filter=whisper lists the six options.
	local help opt
	help="$("${ffmpeg}" -hide_banner -nostdin -h filter=whisper 2>&1 </dev/null)"
	for opt in dtw word_timestamps prompt prompt_file beam_size best_of; do
		echo "${help}" | grep -qE "^ +${opt} " || { echo "FAIL: -h filter=whisper does not list ${opt}"; return 1; }
	done
	echo "-h filter=whisper lists all six options"

	# 3. prompt_file: a missing file fails init and names the path.
	_whisper_run "${ffmpeg}" "${d}/x.out" "${d}/missing.err" "format=json:destination=-:prompt_file=no-such-prompt.txt"
	rc=$?
	[[ ${rc} -ne 0 ]] || { echo "FAIL: a missing prompt_file did not fail"; return 1; }
	grep -q "no-such-prompt.txt" "${d}/missing.err" \
		|| { tail -5 "${d}/missing.err"; echo "FAIL: the prompt_file error does not name the path"; return 1; }
	echo "missing prompt_file fails (exit ${rc}) and names the path"

	# 4. prompt_file wins over prompt. Proven both ways: the run with both set
	#    matches the run with the file's prompt alone, AND differs from the run
	#    with the losing prompt alone - otherwise prompts would simply have no
	#    effect on this clip and the first comparison would prove nothing.
	printf 'Hello Kennedy.\n' >"${d}/prompt.txt"
	_whisper_run "${ffmpeg}" "${d}/both.json" "${d}/both.err" "format=json:destination=-:prompt=Zebra zebra zebra:prompt_file=prompt.txt" \
		|| { tail -5 "${d}/both.err"; echo "FAIL: prompt + prompt_file run failed"; return 1; }
	_whisper_run "${ffmpeg}" "${d}/file.json" "${d}/file.err" "format=json:destination=-:prompt=Hello Kennedy." \
		|| { echo "FAIL: prompt run failed"; return 1; }
	_whisper_run "${ffmpeg}" "${d}/zebra.json" "${d}/zebra.err" "format=json:destination=-:prompt=Zebra zebra zebra" \
		|| { echo "FAIL: prompt run failed"; return 1; }
	cmp -s "${d}/both.json" "${d}/file.json" \
		|| { diff "${d}/both.json" "${d}/file.json" | head -6; echo "FAIL: with both set, the output is not the prompt_file output"; return 1; }
	if cmp -s "${d}/both.json" "${d}/zebra.json"; then
		echo "FAIL: the two prompts give identical output, so this check cannot tell which one won"
		return 1
	fi
	grep -q "using prompt_file" "${d}/both.err" || { echo "FAIL: no warning that prompt_file overrides prompt"; return 1; }
	echo "prompt_file wins over prompt (and the prompts do change the output)"

	# 5. Beam search runs and gives valid output.
	_whisper_run "${ffmpeg}" "${d}/beam.json" "${d}/beam.err" "format=json:destination=-:beam_size=5:best_of=3" \
		|| { tail -5 "${d}/beam.err"; echo "FAIL: beam_size=5:best_of=3 failed"; return 1; }
	_whisper_check_json "${d}/beam.json" || return 1
	# Parsing alone would also pass if beam_size were ignored. On this clip
	# beam search finds a different transcript than greedy decoding does.
	if cmp -s "${d}/beam.json" "${d}/plain.json"; then
		echo "FAIL: beam_size=5 gives the same output as greedy decoding; was it applied?"
		return 1
	fi
	_whisper_run "${ffmpeg}" "${d}/x.out" "${d}/beam9.err" "format=json:destination=-:beam_size=9"
	[[ $? -ne 0 ]] && grep -q "beam_size" "${d}/beam9.err" \
		|| { tail -3 "${d}/beam9.err"; echo "FAIL: beam_size=9 (above whisper.cpp's 8 decoders) was not rejected"; return 1; }
	echo "beam search changes the output; beam_size above 8 is rejected"

	# 6. DTW is really on: our line is logged and whisper.cpp's "disabling"
	#    warning is not. An unknown and two mismatched presets fail.
	_whisper_run "${ffmpeg}" "${d}/dtw.json" "${d}/dtw.err" "format=json:destination=-:dtw=base.en:word_timestamps=1" \
		|| { tail -5 "${d}/dtw.err"; echo "FAIL: dtw=base.en:word_timestamps=1 failed"; return 1; }
	grep -q "DTW on (preset base.en); flash attention turned off" "${d}/dtw.err" \
		|| { echo "FAIL: no 'flash attention turned off' line with dtw=base.en"; return 1; }
	if grep -q "not supported with flash_attn" "${d}/dtw.err"; then
		echo "FAIL: whisper.cpp still switched DTW off because of flash attention"
		return 1
	fi
	_whisper_run "${ffmpeg}" "${d}/x.out" "${d}/bogus.err" "format=json:destination=-:dtw=bogus"
	[[ $? -ne 0 ]] && grep -q "Unknown dtw preset 'bogus'.*large.v3.turbo" "${d}/bogus.err" \
		|| { tail -3 "${d}/bogus.err"; echo "FAIL: an unknown dtw preset did not fail with the list of presets"; return 1; }
	local preset
	for preset in base large.v3; do
		_whisper_run "${ffmpeg}" "${d}/x.out" "${d}/mis.err" "format=json:destination=-:dtw=${preset}"
		[[ $? -ne 0 ]] && grep -q "dtw=${preset} does not match this model" "${d}/mis.err" \
			|| { tail -3 "${d}/mis.err"; echo "FAIL: dtw=${preset} on base.en did not fail naming the preset"; return 1; }
	done
	echo "DTW active with base.en; unknown and mismatched presets (base, large.v3) fail"

	# 7. Word timestamps, without and with DTW. The DTW run must differ from
	#    the t0-only run, or DTW did nothing.
	_whisper_run "${ffmpeg}" "${d}/words.json" "${d}/words.err" "format=json:destination=-:word_timestamps=1" \
		|| { tail -5 "${d}/words.err"; echo "FAIL: word_timestamps=1 failed"; return 1; }
	_whisper_check_json "${d}/words.json" words || return 1
	_whisper_check_json "${d}/dtw.json" words "${d}/words.json" || return 1

	# 8. word_timestamps with format=srt: a warning, and output identical to
	#    the same run without it.
	_whisper_run "${ffmpeg}" "${d}/a.srt" "${d}/a.err" "format=srt:destination=-:word_timestamps=1" \
		|| { echo "FAIL: srt run with word_timestamps failed"; return 1; }
	_whisper_run "${ffmpeg}" "${d}/b.srt" "${d}/b.err" "format=srt:destination=-" \
		|| { echo "FAIL: srt run failed"; return 1; }
	[[ -s "${d}/b.srt" ]] || { echo "FAIL: format=srt wrote nothing"; return 1; }
	grep -q "word_timestamps only applies to format=json" "${d}/a.err" \
		|| { echo "FAIL: no warning for word_timestamps with format=srt"; return 1; }
	cmp -s "${d}/a.srt" "${d}/b.srt" || { echo "FAIL: word_timestamps changed the srt output"; return 1; }
	echo "word_timestamps with format=srt warns and leaves the output alone"

	# 9. destination=- and an escaped pipe:1 write the same bytes.
	_whisper_run "${ffmpeg}" "${d}/pipe.json" "${d}/pipe.err" "format=json:destination=pipe\\\\:1" \
		|| { tail -3 "${d}/pipe.err"; echo "FAIL: destination=pipe\\:1 failed"; return 1; }
	[[ -s "${d}/pipe.json" ]] || { echo "FAIL: destination=pipe\\:1 wrote nothing"; return 1; }
	cmp -s "${d}/plain.json" "${d}/pipe.json" || { echo "FAIL: destination=- and pipe\\:1 differ"; return 1; }
	echo "destination=- and destination=pipe\\:1 give the same bytes"

	echo "all whisper option checks passed"
	return 0
}

test_whisper_defaults_unchanged() {
	local ffmpeg="${FFMPEG:?FFMPEG must point at the binary under test}"
	local ref="${WHISPER_TEST_REFERENCE_FFMPEG:-}"
	local d fmt

	_whisper_test_inputs || return 2
	if [[ -z "${ref}" || ! -x "${ref}" ]]; then
		echo "SKIP: no reference ffmpeg (set WHISPER_TEST_REFERENCE_FFMPEG to a v1.0.44 build)"
		return 2
	fi
	WT_BASELINE="$(cpu_variant_baseline "${Platform:-}")"
	_whisper_test_workdir
	d="${WT_DIR}"
	# shellcheck disable=SC2064
	trap "rm -rf '${d}'" RETURN
	echo "reference: ${ref}"

	for fmt in json srt; do
		_whisper_run "${ffmpeg}" "${d}/new.${fmt}" "${d}/new.err" "format=${fmt}:destination=-" \
			|| { tail -5 "${d}/new.err"; echo "FAIL: format=${fmt} run of the build under test failed"; return 1; }
		_whisper_run "${ref}" "${d}/ref.${fmt}" "${d}/ref.err" "format=${fmt}:destination=-" \
			|| { tail -5 "${d}/ref.err"; echo "FAIL: format=${fmt} run of the reference failed"; return 1; }
		# Two empty files compare equal; that must not count as a pass.
		[[ -s "${d}/ref.${fmt}" ]] || { echo "FAIL: the reference wrote no ${fmt}"; return 1; }
		cmp "${d}/new.${fmt}" "${d}/ref.${fmt}" \
			|| { diff "${d}/new.${fmt}" "${d}/ref.${fmt}" | head -8; echo "FAIL: default format=${fmt} output differs from the reference"; return 1; }
		echo "format=${fmt}: byte-identical to the reference ($(wc -c <"${d}/new.${fmt}") bytes)"
	done
	return 0
}
