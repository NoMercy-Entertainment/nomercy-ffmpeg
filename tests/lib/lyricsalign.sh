#!/bin/bash
# Real-model tests for the lyricsalign filter (#126): the JSON shape, the
# JFK port gates (a) and (c), determinism, the init failures, the output
# destinations, the empty-line marker, blend=0, no_alignment, Windows text
# forms, lines espeak cannot speak, backing lengths, short audio, the frame
# metadata, and (on a GPU runner) use_gpu=1.
#
# Every function follows run_custom_test's exit-code protocol in tests.sh:
# 0 pass, 2 skip (reason on a "SKIP: " line), anything else fail.
#
# They need assets no platform archive ships, in one directory:
#
#   LYRICSALIGN_ASSETS_DIR   wav2vec2-xlsr-53-espeak-cv-ft-f16.gguf, jfk.wav
#                            (whisper.cpp v1.9.1 samples), jfk.txt (the
#                            sentence, one line), jfk-alignment.json (the
#                            fixture in tests/unit/fixtures/jfk/);
#                            tests/lib/lyricsalign-assets.sh fetches them.
#                            Unset, a lyricsalign-assets/ directory next to
#                            the binary under test is used if present.
#   LYRICSALIGN_TEST_GPU=1   also run the use_gpu=1 check (a GPU runner)
#
# Without the assets every check SKIPs with a reason. The JSON checks use
# python3; gate (a) also needs numpy.
#
# Every ffmpeg run happens inside a work directory with relative paths: on
# Windows, Git Bash turns an absolute path into C:/..., and the colon breaks
# avfilter's option parser the moment such a path lands in model=. The work
# directory sits inside the assets directory when that is writable (the
# assets are then ../name), else in $TMPDIR with links or copies.
#
# FFMPEG (set by tests.sh) is the binary under test.

LA_MODEL_NAME=wav2vec2-xlsr-53-espeak-cv-ft-f16.gguf

_la_inputs() {
	local bindir
	bindir="$(cd "$(dirname "${FFMPEG}")" && pwd)"
	LA_ASSETS="${LYRICSALIGN_ASSETS_DIR:-}"
	[[ -z "${LA_ASSETS}" && -d "${bindir}/lyricsalign-assets" ]] && LA_ASSETS="${bindir}/lyricsalign-assets"
	if [[ -z "${LA_ASSETS}" || ! -d "${LA_ASSETS}" ]]; then
		echo "SKIP: no lyricsalign assets in this environment (run tests/lib/lyricsalign-assets.sh <dir> and set LYRICSALIGN_ASSETS_DIR=<dir>)"
		return 1
	fi
	LA_ASSETS="$(cd "${LA_ASSETS}" && pwd)"
	LA_ASSETS="$(_la_native "${LA_ASSETS}")"
	local f
	for f in "${LA_MODEL_NAME}" jfk.wav jfk.txt jfk-alignment.json; do
		if [[ ! -f "${LA_ASSETS}/${f}" ]]; then
			echo "SKIP: ${LA_ASSETS}/${f} is missing (run tests/lib/lyricsalign-assets.sh)"
			return 1
		fi
	done
	# Captured first, then searched: under smoke.sh's pipefail, `ffmpeg | grep -q`
	# fails when grep closes the pipe on its first match and ffmpeg takes the
	# SIGPIPE (this repository has hit that before), and the check would skip
	# a build that has the filter.
	local filters
	filters="$("${FFMPEG}" -hide_banner -filters 2>/dev/null)" || true
	if ! grep -q ' lyricsalign ' <<<"${filters}"; then
		echo "SKIP: no lyricsalign filter in this build"
		return 1
	fi
	if ! command -v python3 >/dev/null 2>&1; then
		echo "SKIP: python3 is needed to validate the JSON output and is not installed"
		return 1
	fi
	return 0
}

# Under Git Bash the python3 on PATH is the Windows one, which cannot open a
# /f/... path: hand it (and bash, which accepts both) the F:/... spelling.
_la_native() {
	if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

# The work directory, and the relative names of the assets from inside it.
_la_workdir() {
	if LA_DIR="$(mktemp -d "${LA_ASSETS}/la-work.XXXXXX" 2>/dev/null)"; then
		LA_DIR="$(_la_native "${LA_DIR}")"
		LA_MODEL="../${LA_MODEL_NAME}"
		LA_AUDIO="../jfk.wav"
		LA_TEXT="../jfk.txt"
	else
		LA_DIR="$(_la_native "$(mktemp -d)")"
		ln -s "${LA_ASSETS}/${LA_MODEL_NAME}" "${LA_DIR}/model.gguf" 2>/dev/null || cp "${LA_ASSETS}/${LA_MODEL_NAME}" "${LA_DIR}/model.gguf"
		cp "${LA_ASSETS}/jfk.wav" "${LA_DIR}/jfk.wav"
		cp "${LA_ASSETS}/jfk.txt" "${LA_DIR}/jfk.txt"
		LA_MODEL=model.gguf
		LA_AUDIO=jfk.wav
		LA_TEXT=jfk.txt
	fi
	cp "${LA_ASSETS}/jfk-alignment.json" "${LA_DIR}/fixture.json"
}

_la_cleanup() {
	[[ -n "${LA_DIR:-}" && -d "${LA_DIR}" ]] && rm -rf "${LA_DIR}"
}

# _la_graph <backing> <text> <opts>: the filter graph. backing is "self"
# (the vocals themselves, through asplit), "null" (anullsrc, endless) or a
# literal "<chain>[b]" producing the backing.
_la_graph() {
	local backing="$1" text="$2" opts="$3" filter
	filter="lyricsalign=model=${LA_MODEL}:text_file=${text}:language=en-us:use_gpu=0:threads=4${opts:+:${opts}}"
	case "${backing}" in
	self) echo "[0:a]asplit[v][b];[v][b]${filter}" ;;
	null) echo "anullsrc=r=16000:cl=mono[b];[0:a]anull[v];[v][b]${filter}" ;;
	*)    echo "${backing};[v][b]${filter}" ;;   # a chain that consumes [0:a] and yields [v] and [b]
	esac
}

# _la_run <out> <err> <backing> <text> <opts> [input args...]
# LA_OUT_ARGS adds output options (such as -t 5) in front of -f null -.
# Runs the filter over the clip (or the given input args) to -f null -, with
# stdout in <out> and stderr in <err>; returns ffmpeg's exit code.
_la_run() {
	local out="$1" err="$2" backing="$3" text="$4" opts="$5"
	shift 5
	local input=("$@")
	[[ ${#input[@]} -eq 0 ]] && input=(-i "${LA_AUDIO}")
	(cd "${LA_DIR}" && env ${LA_ENV:-} "${FFMPEG}" -hide_banner -nostdin -nostats ${LA_LOGLEVEL:+-loglevel "${LA_LOGLEVEL}"} \
		"${input[@]}" -filter_complex "$(_la_graph "${backing}" "${text}" "${opts}")" ${LA_OUT_ARGS:-} -f null - >"${out}" 2>"${err}" </dev/null)
}

# _la_check <jsonl> <mode> [args]: the python checks. Modes:
#   shape                     header + one line per text line, all valid JSON, ordered times
#   gate_c <fixture.json>     every word start within 0.040 s of the fixture, line start and lead_in too
#   reasons <expected...>     per line, the reason ("ok" for a written line), in order
#   check <value>             the header's check field
#   written <n>               the header's written count
#   starts_equal <other.jsonl> the written word starts are the same
_la_check() {
	python3 - "$@" <<'PY'
import json, sys

def load(path):
    lines = [l for l in open(path, encoding="utf-8").read().split("\n") if l.strip()]
    rows = []
    for i, l in enumerate(lines):
        try:
            rows.append(json.loads(l))
        except ValueError as e:
            sys.exit(f"line {i + 1} is not JSON: {e}: {l[:120]}")
    if not rows:
        sys.exit("no output")
    return rows[0], rows[1:]

def num(x):
    return x is not None and isinstance(x, (int, float))

path, mode, args = sys.argv[1], sys.argv[2], sys.argv[3:]
head, lines = load(path)
for key in ("model", "language", "lines", "written", "mapping_misses", "check"):
    if key not in head:
        sys.exit(f"header lacks {key}: {head}")
if head["lines"] != len(lines):
    sys.exit(f"header says {head['lines']} lines, {len(lines)} follow")
written = 0
for i, row in enumerate(lines):
    if row.get("index") != i:
        sys.exit(f"line {i}: index {row.get('index')}")
    for key in ("text", "start", "end", "score", "words"):
        if key not in row:
            sys.exit(f"line {i} lacks {key}")
    if row["start"] is None:
        if row["end"] is not None or row["score"] != 0 or row["words"] or "reason" not in row:
            sys.exit(f"line {i}: a skipped line must have end null, score 0, no words and a reason: {row}")
        if row["reason"] not in ("empty", "no_phones", "disagree", "first_gap", "stray_prefix", "check_failed", "no_alignment"):
            sys.exit(f"line {i}: unknown reason {row['reason']}")
        if "vocals_start" not in row or "check_start" not in row:
            sys.exit(f"line {i}: a skipped line reports vocals_start and check_start")
        continue
    written += 1
    if not (num(row["start"]) and num(row["end"]) and row["start"] <= row["end"]):
        sys.exit(f"line {i}: start/end {row['start']}/{row['end']}")
    if not (0 <= row["score"] <= 1):
        sys.exit(f"line {i}: score {row['score']}")
    if "lead_in" not in row or row["lead_in"] < 0:
        sys.exit(f"line {i}: lead_in {row.get('lead_in')}")
    if not row["words"]:
        sys.exit(f"line {i}: a written line has words")
    prev = None
    for w in row["words"]:
        for key in ("text", "start", "end", "score"):
            if key not in w:
                sys.exit(f"line {i}: word lacks {key}: {w}")
        if w["start"] is None:
            continue
        if not (row["start"] <= w["start"] <= w["end"] <= row["end"]):
            sys.exit(f"line {i}: word {w['text']} {w['start']}-{w['end']} outside {row['start']}-{row['end']}")
        if prev is not None and w["start"] < prev:
            sys.exit(f"line {i}: word {w['text']} starts before the previous word")
        prev = w["start"]
if head["written"] != written:
    sys.exit(f"header says written {head['written']}, {written} lines are")

if mode == "shape":
    print(f"shape ok: {len(lines)} lines, {written} written")
elif mode == "gate_c":
    fix = json.load(open(args[0], encoding="utf-8"))
    if len(lines) != 1 or lines[0]["start"] is None:
        sys.exit(f"gate c: the JFK line must be written: {lines[0] if lines else None}")
    row = lines[0]
    words = [w for w in row["words"] if w["start"] is not None]
    if len(words) != len(fix["words"]):
        sys.exit(f"gate c: {len(words)} words, fixture {len(fix['words'])}")
    worst = 0.0
    for w, f in zip(words, fix["words"]):
        d = abs(w["start"] - f["start"])
        worst = max(worst, d)
        if d > 0.040 + 1e-9:
            sys.exit(f"gate c: word {w['text']} at {w['start']}, fixture {f['start']} ({d:.3f} s)")
    # the written start and the lead-in are 10 ms quantities: one hop of slack
    if abs(row["start"] - fix["line"]["start_written"]) > 0.010 + 1e-9:
        sys.exit(f"gate c: line start {row['start']}, fixture {fix['line']['start_written']}")
    if abs(row["lead_in"] - fix["line"]["lead_in"]) > 0.010 + 1e-9:
        sys.exit(f"gate c: lead_in {row['lead_in']}, fixture {fix['line']['lead_in']}")
    print(f"gate c ok: {len(words)} words, worst {worst:.3f} s, line start {row['start']}, lead_in {row['lead_in']}")
elif mode == "reasons":
    got = [("ok" if r["start"] is not None else r["reason"]) for r in lines]
    if got != args:
        sys.exit(f"reasons {got}, expected {args}")
    print("reasons ok:", " ".join(got))
elif mode == "check":
    if head["check"] != args[0]:
        sys.exit(f"check is {head['check']}, expected {args[0]}")
    print("check ok:", head["check"])
elif mode == "written":
    if head["written"] != int(args[0]):
        sys.exit(f"written is {head['written']}, expected {args[0]}")
    print("written ok:", head["written"])
elif mode == "starts_equal":
    _, other = load(args[0])
    a = [[w["start"] for w in r["words"]] for r in lines]
    b = [[w["start"] for w in r["words"]] for r in other]
    if a != b:
        sys.exit(f"word starts differ: {a} vs {b}")
    print("starts equal")
else:
    sys.exit(f"unknown mode {mode}")
PY
}

_la_fail() {  # <label> <err file>
	echo "FAIL: $1"
	tail -n 15 "$2" | sed 's/^/   | /'
	return 1
}

# ---------------------------------------------------------------------------
# The checks
# ---------------------------------------------------------------------------

test_lyricsalign_shape() {
	_la_inputs || return 2
	_la_workdir
	local rc=0
	if _la_run "${LA_DIR}/out.jsonl" "${LA_DIR}/err.txt" self "${LA_TEXT}" "destination=-" &&
	   _la_check "${LA_DIR}/out.jsonl" shape && _la_check "${LA_DIR}/out.jsonl" written 1; then :; else _la_fail "shape" "${LA_DIR}/err.txt"; rc=1; fi
	_la_cleanup
	return ${rc}
}

test_lyricsalign_jfk_gate_c() {
	_la_inputs || return 2
	_la_workdir
	local rc=0
	if _la_run "${LA_DIR}/out.jsonl" "${LA_DIR}/err.txt" null "${LA_TEXT}" "destination=-" &&
	   _la_check "${LA_DIR}/out.jsonl" gate_c "${LA_DIR}/fixture.json"; then :; else _la_fail "gate c" "${LA_DIR}/err.txt"; rc=1; fi
	_la_cleanup
	return ${rc}
}

test_lyricsalign_gate_a() {
	_la_inputs || return 2
	if ! python3 -c "import numpy" 2>/dev/null; then
		echo "SKIP: gate (a) needs numpy for python3"
		return 2
	fi
	if [[ ! -f "${LA_ASSETS}/jfk-logprobs-f16.npy" ]]; then
		echo "SKIP: ${LA_ASSETS}/jfk-logprobs-f16.npy is missing (run tests/lib/lyricsalign-assets.sh)"
		return 2
	fi
	_la_workdir
	local rc=0
	if LA_ENV="NOMERCY_LYRICSALIGN_EMISSIONS=emissions.f32" _la_run "${LA_DIR}/out.jsonl" "${LA_DIR}/err.txt" null "${LA_TEXT}" "destination=-" &&
	   [[ -s "${LA_DIR}/emissions.f32" ]] &&
	   python3 - "${LA_DIR}/emissions.f32" "${LA_ASSETS}/jfk-logprobs-f16.npy" <<'PY'
import sys, numpy as np
got = np.fromfile(sys.argv[1], dtype="<f4")
ref = np.load(sys.argv[2]).astype(np.float32)
if got.size % ref.shape[1]:
    sys.exit(f"emissions hold {got.size} floats, not a multiple of {ref.shape[1]}")
got = got.reshape(-1, ref.shape[1])
if got.shape != ref.shape:
    sys.exit(f"emissions are {got.shape}, fixture {ref.shape}")
agree = float((got.argmax(1) == ref.argmax(1)).mean())
mean = float(np.abs(got - ref).mean())
print(f"gate a: argmax agreement {agree * 100:.2f} %, mean |delta| {mean:.4f} nats")
if agree < 0.99 or mean >= 0.05:
    sys.exit("gate a: FAIL (needs >= 99 % and < 0.05 nats)")
PY
	then :; else _la_fail "gate a" "${LA_DIR}/err.txt"; rc=1; fi
	_la_cleanup
	return ${rc}
}

test_lyricsalign_deterministic() {
	_la_inputs || return 2
	_la_workdir
	local rc=0
	if _la_run "${LA_DIR}/a.jsonl" "${LA_DIR}/err.txt" self "${LA_TEXT}" "destination=-" &&
	   _la_run "${LA_DIR}/b.jsonl" "${LA_DIR}/err2.txt" self "${LA_TEXT}" "destination=-" &&
	   cmp -s "${LA_DIR}/a.jsonl" "${LA_DIR}/b.jsonl" && [[ -s "${LA_DIR}/a.jsonl" ]]; then
		echo "two runs are byte-identical ($(wc -c <"${LA_DIR}/a.jsonl") bytes)"
	else
		_la_fail "determinism" "${LA_DIR}/err2.txt"; rc=1
	fi
	_la_cleanup
	return ${rc}
}

test_lyricsalign_init_failures() {
	_la_inputs || return 2
	_la_workdir
	local rc=0
	: >"${LA_DIR}/empty.txt"
	printf '\n \n' >"${LA_DIR}/blank.txt"
	# missing model: a non-zero exit naming the path
	if _la_run "${LA_DIR}/o" "${LA_DIR}/e1" self "${LA_TEXT}" "model=nope.gguf" || ! grep -q "nope.gguf" "${LA_DIR}/e1"; then
		_la_fail "a missing model must fail init and name the path" "${LA_DIR}/e1"; rc=1
	fi
	if _la_run "${LA_DIR}/o" "${LA_DIR}/e2" self empty.txt "" || ! grep -q "no lyric line" "${LA_DIR}/e2"; then
		_la_fail "an empty text_file must fail init" "${LA_DIR}/e2"; rc=1
	fi
	if _la_run "${LA_DIR}/o" "${LA_DIR}/e3" self blank.txt "" || ! grep -q "no lyric line" "${LA_DIR}/e3"; then
		_la_fail "a blank text_file must fail init" "${LA_DIR}/e3"; rc=1
	fi
	if _la_run "${LA_DIR}/o" "${LA_DIR}/e4" self "${LA_TEXT}" "language=xx-nope" || ! grep -q "xx-nope" "${LA_DIR}/e4"; then
		_la_fail "an unknown voice must fail init and name it" "${LA_DIR}/e4"; rc=1
	fi
	if _la_run "${LA_DIR}/o" "${LA_DIR}/e5" self "${LA_TEXT}" "espeak_data=nowhere" || ! grep -q "nowhere/phontab" "${LA_DIR}/e5"; then
		_la_fail "missing espeak data must fail init with the path" "${LA_DIR}/e5"; rc=1
	fi
	[[ ${rc} -eq 0 ]] && echo "all five init failures fail with their message"
	_la_cleanup
	return ${rc}
}

test_lyricsalign_destination_pipe() {
	_la_inputs || return 2
	_la_workdir
	local rc=0
	if _la_run "${LA_DIR}/a.jsonl" "${LA_DIR}/err.txt" self "${LA_TEXT}" "destination=-" &&
	   _la_run "${LA_DIR}/b.jsonl" "${LA_DIR}/err2.txt" self "${LA_TEXT}" "destination=pipe\\\\:1" &&
	   cmp -s "${LA_DIR}/a.jsonl" "${LA_DIR}/b.jsonl" && [[ -s "${LA_DIR}/a.jsonl" ]]; then
		echo "destination=- and destination=pipe\\:1 give the same bytes"
	else
		_la_fail "destination=- and pipe:1 must match" "${LA_DIR}/err2.txt"; rc=1
	fi
	# no destination: nothing on stdout, the lines in the log
	if LA_LOGLEVEL=info _la_run "${LA_DIR}/c.jsonl" "${LA_DIR}/err3.txt" self "${LA_TEXT}" "" &&
	   [[ ! -s "${LA_DIR}/c.jsonl" ]] && grep -q '"written":' "${LA_DIR}/err3.txt" && grep -q '"index":0' "${LA_DIR}/err3.txt"; then
		echo "an empty destination logs the lines"
	else
		_la_fail "an empty destination must log the lines and write nothing to stdout" "${LA_DIR}/err3.txt"; rc=1
	fi
	_la_cleanup
	return ${rc}
}

test_lyricsalign_empty_line() {
	_la_inputs || return 2
	_la_workdir
	local rc=0
	{ cat "${LA_ASSETS}/jfk.txt"; echo; cat "${LA_ASSETS}/jfk.txt"; } >"${LA_DIR}/three.txt"
	if _la_run "${LA_DIR}/out.jsonl" "${LA_DIR}/err.txt" self three.txt "destination=-" &&
	   _la_check "${LA_DIR}/out.jsonl" shape &&
	   _la_check "${LA_DIR}/out.jsonl" reasons ok empty ok; then :; else _la_fail "empty line" "${LA_DIR}/err.txt"; rc=1; fi
	_la_cleanup
	return ${rc}
}

test_lyricsalign_blend_zero() {
	_la_inputs || return 2
	_la_workdir
	local rc=0
	if _la_run "${LA_DIR}/a.jsonl" "${LA_DIR}/err.txt" self "${LA_TEXT}" "destination=-:blend=0" &&
	   _la_check "${LA_DIR}/a.jsonl" check none && _la_check "${LA_DIR}/a.jsonl" written 1 &&
	   _la_run "${LA_DIR}/b.jsonl" "${LA_DIR}/err2.txt" self "${LA_TEXT}" "destination=-:blend=0.5" &&
	   _la_check "${LA_DIR}/b.jsonl" check backing && _la_check "${LA_DIR}/b.jsonl" written 1 &&
	   _la_check "${LA_DIR}/a.jsonl" starts_equal "${LA_DIR}/b.jsonl"; then :; else _la_fail "blend" "${LA_DIR}/err2.txt"; rc=1; fi
	_la_cleanup
	return ${rc}
}

test_lyricsalign_no_alignment() {
	_la_inputs || return 2
	_la_workdir
	local rc=0 i
	for i in $(seq 40); do cat "${LA_ASSETS}/jfk.txt"; done >"${LA_DIR}/forty.txt"
	if _la_run "${LA_DIR}/out.jsonl" "${LA_DIR}/err.txt" self forty.txt "destination=-" -t 2 -i "${LA_AUDIO}" &&
	   _la_check "${LA_DIR}/out.jsonl" shape && _la_check "${LA_DIR}/out.jsonl" written 0 &&
	   grep -q '"reason":"no_alignment"' "${LA_DIR}/out.jsonl" && ! grep -q '"reason":"disagree"' "${LA_DIR}/out.jsonl"; then
		echo "forty sentences on 2 s: written 0, every line no_alignment, exit 0"
	else
		_la_fail "no_alignment" "${LA_DIR}/err.txt"; rc=1
	fi
	_la_cleanup
	return ${rc}
}

test_lyricsalign_text_forms() {
	_la_inputs || return 2
	_la_workdir
	local rc=0
	# BOM, CRLF and a trailing space on the one line: the same result as the plain file
	{ printf '\xEF\xBB\xBF'; tr -d '\n' <"${LA_ASSETS}/jfk.txt"; printf ' \r\n'; } >"${LA_DIR}/win1.txt"
	# a whitespace-only middle line between two copies: an empty line
	{ tr -d '\n' <"${LA_ASSETS}/jfk.txt"; printf '\r\n \t\r\n'; tr -d '\n' <"${LA_ASSETS}/jfk.txt"; printf '\r\n'; } >"${LA_DIR}/win3.txt"
	if _la_run "${LA_DIR}/a.jsonl" "${LA_DIR}/err.txt" null win1.txt "destination=-" &&
	   _la_run "${LA_DIR}/b.jsonl" "${LA_DIR}/err2.txt" null "${LA_TEXT}" "destination=-" &&
	   python3 - "${LA_DIR}/a.jsonl" "${LA_DIR}/b.jsonl" <<'PY'
import json, sys
a = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8") if l.strip()]
b = [json.loads(l) for l in open(sys.argv[2], encoding="utf-8") if l.strip()]
if a[1]["text"] != b[1]["text"]:
    sys.exit(f"the BOM/CR/space line reads {a[1]['text']!r}, plain {b[1]['text']!r}")
if [w["start"] for w in a[1]["words"]] != [w["start"] for w in b[1]["words"]] or a[1]["start"] != b[1]["start"]:
    sys.exit("the BOM/CRLF file gives different starts than the plain file")
print("BOM, CRLF and trailing blanks change nothing")
PY
	then :; else _la_fail "text forms (BOM/CRLF)" "${LA_DIR}/err.txt"; rc=1; fi
	if _la_run "${LA_DIR}/c.jsonl" "${LA_DIR}/err3.txt" null win3.txt "destination=-" &&
	   _la_check "${LA_DIR}/c.jsonl" reasons ok empty ok; then echo "a whitespace-only line is empty"; else _la_fail "text forms (blank line)" "${LA_DIR}/err3.txt"; rc=1; fi
	_la_cleanup
	return ${rc}
}

test_lyricsalign_odd_lines() {
	_la_inputs || return 2
	_la_workdir
	local rc=0
	{ printf '...\n'; printf '\xF0\x9F\x8E\xB5\xF0\x9F\x8E\xB5\n'; printf 'caf\xFF\xC3\xA9 au lait\n'; cat "${LA_ASSETS}/jfk.txt"; } >"${LA_DIR}/odd.txt"
	if _la_run "${LA_DIR}/out.jsonl" "${LA_DIR}/err.txt" null odd.txt "destination=-" &&
	   _la_check "${LA_DIR}/out.jsonl" shape &&
	   python3 - "${LA_DIR}/out.jsonl" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8") if l.strip()][1:]
if rows[0]["start"] is not None and rows[0].get("reason") != "no_phones":
    sys.exit(f"'...' gave {rows[0]}")
if rows[1]["start"] is None and rows[1].get("reason") != "no_phones":
    sys.exit(f"the emoji line gave {rows[1]}")
# (espeak-ng has names for emoji in its dictionaries, so that line may be placed, with a tiny score)
if "\ufffd" not in rows[2]["text"]:
    sys.exit(f"the invalid byte was not repaired: {rows[2]['text']!r}")
if rows[3]["start"] is None:
    sys.exit(f"the JFK line after the odd ones was not written: {rows[3]}")
print("punctuation and emoji lines:", rows[0].get("reason", "placed"), rows[1].get("reason", "placed"), "; the invalid byte became U+FFFD")
PY
	then :; else _la_fail "odd lines" "${LA_DIR}/err.txt"; rc=1; fi
	_la_cleanup
	return ${rc}
}

test_lyricsalign_backing_lengths() {
	_la_inputs || return 2
	_la_workdir
	local rc=0
	if _la_run "${LA_DIR}/a.jsonl" "${LA_DIR}/err.txt" "[0:a]asplit[v][b0];[b0]atrim=0:9[b]" "${LA_TEXT}" "destination=-" &&
	   _la_check "${LA_DIR}/a.jsonl" check backing && _la_check "${LA_DIR}/a.jsonl" written 1 &&
	   _la_run "${LA_DIR}/b.jsonl" "${LA_DIR}/err2.txt" "[0:a]asplit[v][b0];[b0]apad=whole_dur=15[b]" "${LA_TEXT}" "destination=-" &&
	   _la_check "${LA_DIR}/b.jsonl" check backing && _la_check "${LA_DIR}/b.jsonl" shape; then
		echo "a backing 2 s shorter and one 4 s longer than the vocals both run to the end"
	else
		_la_fail "backing lengths" "${LA_DIR}/err2.txt"; rc=1
	fi
	_la_cleanup
	return ${rc}
}

test_lyricsalign_short_audio() {
	_la_inputs || return 2
	_la_workdir
	local rc=0
	if _la_run "${LA_DIR}/a.jsonl" "${LA_DIR}/err.txt" self "${LA_TEXT}" "destination=-" -t 0.5 -i "${LA_AUDIO}" &&
	   _la_check "${LA_DIR}/a.jsonl" shape; then
		echo "half a second of audio: exit 0, $(grep -o '"written":[0-9]*' "${LA_DIR}/a.jsonl")"
	else
		_la_fail "short audio" "${LA_DIR}/err.txt"; rc=1
	fi
	_la_cleanup
	return ${rc}
}

test_lyricsalign_metadata() {
	_la_inputs || return 2
	_la_workdir
	local rc=0
	if (cd "${LA_DIR}" && "${FFMPEG}" -hide_banner -nostdin -nostats -loglevel info -i "${LA_AUDIO}" \
		-filter_complex "[0:a]asplit[v][b];[v][b]lyricsalign=model=${LA_MODEL}:text_file=${LA_TEXT}:language=en-us:use_gpu=0:threads=4,ametadata=print:file=meta.txt" \
		-f null - >/dev/null 2>"${LA_DIR}/err.txt") &&
	   grep -q "lavfi.lyricsalign.backend=cpu" "${LA_DIR}/meta.txt" &&
	   grep -q "lavfi.lyricsalign.cpu_variant=" "${LA_DIR}/meta.txt" &&
	   grep -q "lavfi.lyricsalign.version=" "${LA_DIR}/meta.txt"; then
		echo "frames carry $(grep -m3 -o 'lavfi.lyricsalign.[a-z_]*=[^ ]*' "${LA_DIR}/meta.txt" | tr '\n' ' ')"
	else
		_la_fail "frame metadata" "${LA_DIR}/err.txt"; rc=1
	fi
	_la_cleanup
	return ${rc}
}

# words[].text per lyric token: a token espeak does not speak ("-") yields no
# word, a token espeak expands ("1999" = nineteen ninety nine) is one word
# spanning its phones; the labels never shift.
test_lyricsalign_word_labels() {
	_la_inputs || return 2
	_la_workdir
	local rc=0
	printf '%s\n' "and so my fellow americans" "ask not - what your country can do for you 1999" > "${LA_DIR}/labels.txt"
	if _la_run "${LA_DIR}/out.jsonl" "${LA_DIR}/err.txt" self labels.txt "destination=-" &&
	   python3 - "${LA_DIR}/out.jsonl" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8") if l.strip()]
line = rows[2]
if line.get("reason"):
    sys.exit("line 2 was not written: %s" % line["reason"])
texts = [w["text"] for w in line["words"]]
want = ["ask", "not", "what", "your", "country", "can", "do", "for", "you", "1999"]
if texts != want:
    sys.exit("word labels %r, want %r" % (texts, want))
last = line["words"][-1]
if last["start"] is None or last["end"] is None or last["end"] <= last["start"]:
    sys.exit("the expanded token has no span: %r" % last)
print("word labels: hyphen dropped, 1999 spans one word (%.2f..%.2f)" % (last["start"], last["end"]))
PY
	then :; else _la_fail "word labels" "${LA_DIR}/err.txt"; rc=1; fi
	_la_cleanup
	return ${rc}
}

# words[] when espeak-ng writes two lyric tokens as one word (#131). en-us
# says "of the" and "in the" as one word that is the two tokens' phones one
# after the other: it is cut where the token ends and each token keeps its
# entry. "to be" sounds different joined than apart, so where to cut is not
# known: one entry, labelled with both. Before #131 every word of such a
# line had text null.
test_lyricsalign_joined_words() {
	_la_inputs || return 2
	_la_workdir
	local rc=0
	printf '%s\n' "and so my fellow americans" "ask not what your country can do for you of the people" \
		"ask what you can do to be free in the house" > "${LA_DIR}/joined.txt"
	if _la_run "${LA_DIR}/out.jsonl" "${LA_DIR}/err.txt" self joined.txt "destination=-" &&
	   _la_check "${LA_DIR}/out.jsonl" shape &&
	   python3 - "${LA_DIR}/out.jsonl" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8") if l.strip()]
want = {
    2: ["ask", "not", "what", "your", "country", "can", "do", "for", "you", "of", "the", "people"],
    3: ["ask", "what", "you", "can", "do", "to be", "free", "in", "the", "house"],
}
for at, texts in want.items():
    line = rows[at]
    if line.get("reason"):
        sys.exit("line %d was not written: %s" % (at - 1, line["reason"]))
    got = [w["text"] for w in line["words"]]
    if got != texts:
        sys.exit("line %d: word labels %r, want %r" % (at - 1, got, texts))
    for a, b in zip(line["words"], line["words"][1:]):
        if a["start"] is None or b["start"] is None or a["end"] > b["start"] + 1e-9:
            sys.exit("line %d: %r (%s..%s) runs into %r (%s..%s)" % (at - 1, a["text"], a["start"], a["end"], b["text"], b["start"], b["end"]))
words = rows[2]["words"]
print("joined words: of %.2f..%.2f and the %.2f..%.2f are cut apart, 'to be' is one entry, no text is null" % (
    words[9]["start"], words[9]["end"], words[10]["start"], words[10]["end"]))
PY
	then :; else _la_fail "joined words" "${LA_DIR}/err.txt"; rc=1; fi
	_la_cleanup
	return ${rc}
}

# The two onset refinements of #130 are options with their defaults, an
# out-of-range value fails init, and the JFK numbers do not depend on them:
# the sentence is the first line, so step 7 walks it back, 7b leaves a line
# that was walked back alone and 7c needs a previous line. With both off the
# filter writes step 7 as v1.0.46 did, so the two runs are the same bytes
# and gate (c) holds on them.
test_lyricsalign_onset_options() {
	_la_inputs || return 2
	_la_workdir
	local rc=0 help
	help="$("${FFMPEG}" -hide_banner -h filter=lyricsalign 2>&1)" || true
	if ! grep -Eq 'soft_walkback +<float>.*\(default 0\.1\)' <<<"${help}" ||
	   ! grep -Eq 'unheard_island +<int>.*\(default 1\)' <<<"${help}"; then
		echo "FAIL: -h filter=lyricsalign does not list soft_walkback (float, default 0.1) and unheard_island (int, default 1)"
		grep -E 'soft_walkback|unheard_island' <<<"${help}" | sed 's/^/   | /'
		rc=1
	fi
	if _la_run "${LA_DIR}/o" "${LA_DIR}/e1" null "${LA_TEXT}" "soft_walkback=0.9" || ! grep -q "soft_walkback" "${LA_DIR}/e1"; then
		_la_fail "soft_walkback=0.9 is over the 0.8 s of step 7 and must fail init naming the option" "${LA_DIR}/e1"; rc=1
	fi
	if _la_run "${LA_DIR}/o" "${LA_DIR}/e2" null "${LA_TEXT}" "unheard_island=2" || ! grep -q "unheard_island" "${LA_DIR}/e2"; then
		_la_fail "unheard_island=2 must fail init naming the option" "${LA_DIR}/e2"; rc=1
	fi
	if _la_run "${LA_DIR}/on.jsonl" "${LA_DIR}/err.txt" null "${LA_TEXT}" "destination=-" &&
	   _la_run "${LA_DIR}/off.jsonl" "${LA_DIR}/err2.txt" null "${LA_TEXT}" "destination=-:soft_walkback=0:unheard_island=0" &&
	   [[ -s "${LA_DIR}/on.jsonl" ]] && cmp -s "${LA_DIR}/on.jsonl" "${LA_DIR}/off.jsonl" &&
	   _la_check "${LA_DIR}/off.jsonl" gate_c "${LA_DIR}/fixture.json"; then
		echo "soft_walkback=0:unheard_island=0 gives the JFK line byte for byte as the defaults do"
	else
		_la_fail "the JFK line must not depend on soft_walkback and unheard_island" "${LA_DIR}/err2.txt"; rc=1
	fi
	_la_cleanup
	return ${rc}
}

# Downstream closes the output early (-t on the output adds a trim after the
# graph): the audio received so far is still aligned and written, with a
# warning, and ffmpeg exits 0.
test_lyricsalign_output_closed() {
	_la_inputs || return 2
	_la_workdir
	local rc=0
	if LA_OUT_ARGS="-t 5" _la_run "${LA_DIR}/out.jsonl" "${LA_DIR}/err.txt" self "${LA_TEXT}" "destination=-" &&
	   _la_check "${LA_DIR}/out.jsonl" shape &&
	   grep -q "output closed" "${LA_DIR}/err.txt"; then
		echo "output closed after 5 s: header + line written, warning logged"
	else
		_la_fail "output closed early" "${LA_DIR}/err.txt"; rc=1
	fi
	_la_cleanup
	return ${rc}
}

# A destination that cannot take the bytes fails the run instead of leaving
# a truncated file behind an exit 0.
test_lyricsalign_write_error() {
	_la_inputs || return 2
	# Git Bash shows a /dev/full that the native ffmpeg.exe cannot open.
	if [[ ! -w /dev/full ]] || command -v cygpath >/dev/null 2>&1; then
		echo "SKIP: /dev/full is needed to provoke a write error (Linux only)"
		return 2
	fi
	_la_workdir
	local rc=0
	if _la_run "${LA_DIR}/out.jsonl" "${LA_DIR}/err.txt" self "${LA_TEXT}" "destination=/dev/full"; then
		_la_fail "a write error must fail the run (exit 0)" "${LA_DIR}/err.txt"; rc=1
	elif ! grep -qi "lyricsalign: .*writ" "${LA_DIR}/err.txt"; then
		_la_fail "the write error is not reported" "${LA_DIR}/err.txt"; rc=1
	else
		echo "destination=/dev/full: non-zero exit, error reported"
	fi
	_la_cleanup
	return ${rc}
}

# The model and the espeak-ng data under a directory whose name is outside
# the ANSI code page (Windows narrow file APIs): both are found.
test_lyricsalign_unicode_paths() {
	_la_inputs || return 2
	_la_workdir
	local rc=0 sub="lyrics-ジ" bindir
	bindir="$(cd "$(dirname "${FFMPEG}")" && pwd)"
	if [[ ! -f "${bindir}/espeak-ng-data/phontab" ]]; then
		echo "SKIP: no espeak-ng-data next to ${FFMPEG} to copy"
		_la_cleanup; return 2
	fi
	mkdir -p "${LA_DIR}/${sub}"
	cp -r "${bindir}/espeak-ng-data" "${LA_DIR}/${sub}/espeak-ng-data"
	python3 - "${LA_DIR}/${LA_MODEL}" "${LA_DIR}/${sub}/model.gguf" <<'PY'
import os, shutil, sys
src, dst = os.path.abspath(sys.argv[1]), sys.argv[2]
try:
    os.link(src, dst)
except OSError:
    try:
        os.symlink(src, dst)
    except OSError:
        shutil.copyfile(src, dst)
PY
	if LA_MODEL="${sub}/model.gguf" _la_run "${LA_DIR}/out.jsonl" "${LA_DIR}/err.txt" self "${LA_TEXT}" "destination=-:espeak_data=${sub}/espeak-ng-data" &&
	   _la_check "${LA_DIR}/out.jsonl" shape; then
		echo "model and espeak-ng data under ${sub}/: found"
	else
		_la_fail "non-ASCII paths" "${LA_DIR}/err.txt"; rc=1
	fi
	_la_cleanup
	return ${rc}
}

# The output is input 0 unchanged: a 44.1 kHz stereo vocal with a 16 kHz mono
# backing (written first in the graph) leaves the output at 44.1 kHz stereo.
test_lyricsalign_output_format() {
	_la_inputs || return 2
	_la_workdir
	local rc=0
	if LA_LOGLEVEL=info _la_run "${LA_DIR}/out.jsonl" "${LA_DIR}/err.txt" \
	     "anullsrc=r=16000:cl=mono[b];[0:a]aresample=44100,aformat=channel_layouts=stereo[v]" "${LA_TEXT}" "destination=-" &&
	   _la_check "${LA_DIR}/out.jsonl" shape &&
	   grep -E "Stream #0:0.*44100 Hz, stereo" "${LA_DIR}/err.txt" >/dev/null; then
		echo "output stays 44100 Hz stereo with a 16 kHz mono backing"
	else
		_la_fail "output format" "${LA_DIR}/err.txt"; grep -E "Stream #0:0" "${LA_DIR}/err.txt" | sed 's/^/   | /'; rc=1
	fi
	_la_cleanup
	return ${rc}
}

test_lyricsalign_gpu() {
	_la_inputs || return 2
	if [[ "${LYRICSALIGN_TEST_GPU:-0}" != "1" ]]; then
		echo "SKIP: use_gpu=1 is only checked on a GPU runner (LYRICSALIGN_TEST_GPU=1)"
		return 2
	fi
	_la_workdir
	local rc=0
	if _la_run "${LA_DIR}/cpu.jsonl" "${LA_DIR}/err.txt" null "${LA_TEXT}" "destination=-" &&
	   _la_run "${LA_DIR}/gpu.jsonl" "${LA_DIR}/err2.txt" null "${LA_TEXT}" "destination=-:use_gpu=1" &&
	   python3 - "${LA_DIR}/cpu.jsonl" "${LA_DIR}/gpu.jsonl" <<'PY'
import json, sys
a = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8") if l.strip()][1:]
b = [json.loads(l) for l in open(sys.argv[2], encoding="utf-8") if l.strip()][1:]
worst = 0.0
for ra, rb in zip(a, b):
    for wa, wb in zip(ra["words"], rb["words"]):
        if (wa["start"] is None) != (wb["start"] is None):
            sys.exit(f"word {wa['text']}: placed on one backend only")
        if wa["start"] is not None:
            worst = max(worst, abs(wa["start"] - wb["start"]))
if worst > 0.040 + 1e-9:
    sys.exit(f"GPU and CPU word starts differ by {worst:.3f} s")
print(f"GPU within {worst:.3f} s of the CPU, backend {open(sys.argv[2].replace('gpu.jsonl', 'err2.txt')).read().count('ggml backend')} line(s)")
PY
	then :; else _la_fail "use_gpu=1" "${LA_DIR}/err2.txt"; rc=1; fi
	_la_cleanup
	return ${rc}
}
