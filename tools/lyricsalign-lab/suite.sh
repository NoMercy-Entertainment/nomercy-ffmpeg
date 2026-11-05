#!/bin/bash
# The lab's test run: the unit tests (no ffmpeg needed) and every function of
# tests/lib/lyricsalign.sh against the ffmpeg build.sh produced, with the
# assets mounted at /assets (the GGUF, jfk.wav, jfk.txt, jfk-alignment.json).
#
# Exit code: 0 when nothing failed (skips are reported, not failures).
set -uo pipefail
REPO=/repo
FFMPEG=${FFMPEG:-/build/ffmpeg/ffmpeg}
export FFMPEG
export LYRICSALIGN_ASSETS_DIR=${LYRICSALIGN_ASSETS_DIR:-/assets}
export JFK_WAV=${JFK_WAV:-/assets/jfk.wav}
export Platform=linux-x86_64

failed=0
printf '\n== unit tests\n'
if ! bash "${REPO}/tests/unit/run.sh"; then failed=$((failed + 1)); fi

lib="${REPO}/tests/lib/lyricsalign.sh"
if [[ ! -f "${lib}" ]]; then
	echo "lyricsalign.sh: not present yet"
	exit ${failed}
fi
[[ -x "${FFMPEG}" ]] || { echo "no ffmpeg at ${FFMPEG}; run build.sh first"; exit 1; }
printf '\n== tests/lib/lyricsalign.sh against %s\n' "${FFMPEG}"
# shellcheck source=/dev/null
source "${lib}"
only="${1:-}"
for fn in $(declare -F | awk '{print $3}' | grep '^test_lyricsalign_' | sort); do
	[[ -n "${only}" && "${fn}" != *"${only}"* ]] && continue
	start=$(date +%s)
	out="$("${fn}" 2>&1)"; rc=$?
	secs=$(( $(date +%s) - start ))
	case ${rc} in
	0) echo "✅ ${fn} (${secs}s)" ;;
	2) echo "➖ ${fn}: $(echo "${out}" | grep -m1 '^SKIP: ' | sed 's/^SKIP: //')" ;;
	*) echo "❌ ${fn} (exit ${rc}, ${secs}s)"; echo "${out}" | tail -n 25 | sed 's/^/   | /'; failed=$((failed + 1)) ;;
	esac
done
echo "${failed} failed"
exit ${failed}
