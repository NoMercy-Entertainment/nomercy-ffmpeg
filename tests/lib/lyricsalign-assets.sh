#!/usr/bin/env bash
# Fetch what the lyricsalign checks (tests/lib/lyricsalign.sh) need, pinned by
# SHA-256, and print the environment they read. Used by CI's Linux smoke job
# and by anyone running the suite by hand:
#
#     tests/lib/lyricsalign-assets.sh <dir>
#     eval "$(tests/lib/lyricsalign-assets.sh ~/nm-assets)"
#
# What it fetches:
#
#   * the model, wav2vec2-xlsr-53-espeak-cv-ft-f16.gguf (about 630 MB), from
#     the org's public nomercy-lyricsalign-models release;
#   * whisper.cpp v1.9.1's samples/jfk.wav (public domain), the clip of the
#     JFK port fixture.
#
# And it writes jfk.txt (the sentence, one line) and copies the fixture files
# from tests/unit/fixtures/jfk/ (jfk-alignment.json, jfk-logprobs-f16.npy).
#
# A file already in <dir> with the right digest is kept, so a persistent
# runner fetches the model once. A digest mismatch fails here, loudly: a
# model that is not the pinned one would be measured against gates set with
# the pinned one.
#
# Output: one LYRICSALIGN_ASSETS_DIR=<dir> line on stdout (everything else
# goes to stderr), suitable for `>> "$GITHUB_ENV"` and for `eval`. Under MSYS
# the path is printed in the mixed C:/... form.
set -euo pipefail

DIR="${1:?usage: lyricsalign-assets.sh <dir>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES="${HERE}/../unit/fixtures/jfk"

# The model release: the digest is the one the converter reproduces (its
# README has the recipe); bump the three lines together when a new release
# ships. LYRICSALIGN_MODEL_URL overrides the URL for a release under test.
MODEL_NAME=wav2vec2-xlsr-53-espeak-cv-ft-f16.gguf
MODEL_RELEASE=v2026.11.05
MODEL_URL="${LYRICSALIGN_MODEL_URL:-https://github.com/NoMercy-Entertainment/nomercy-lyricsalign-models/releases/download/${MODEL_RELEASE}/${MODEL_NAME}}"
MODEL_SHA=b1474de65e4a966046d390f191af092e718e5e773dcedc5398f31057ee2d38b4
JFK_URL=https://raw.githubusercontent.com/ggml-org/whisper.cpp/v1.9.1/samples/jfk.wav
JFK_SHA=59dfb9a4acb36fe2a2affc14bacbee2920ff435cb13cc314a08c13f66ba7860e
JFK_TEXT="And so my fellow Americans, ask not what your country can do for you, ask what you can do for your country."

say() { echo "$*" >&2; }
die() { say "lyricsalign-assets: $*"; exit 1; }

sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
	else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# fetch <url> <file> <sha256>: keep a file whose digest matches, refetch one
# whose digest does not, refuse one that still does not match afterwards.
fetch() {
	local url="$1" out="$2" want="$3" got
	if [[ -f "${out}" ]]; then
		got="$(sha256_of "${out}")"
		if [[ "${got}" == "${want}" ]]; then say "cached:  $(basename "${out}")"; return 0; fi
		say "cached $(basename "${out}") has digest ${got}, expected ${want}: refetching"
	fi
	[[ -n "${url}" ]] || die "$(basename "${out}") is not in ${DIR} and no URL is pinned for it yet"
	curl -fsSL --retry 3 -o "${out}.part" "${url}" || die "download failed: ${url}"
	got="$(sha256_of "${out}.part")"
	if [[ "${got}" != "${want}" ]]; then
		rm -f "${out}.part"
		die "$(basename "${out}"): expected ${want}, got ${got}"
	fi
	mv "${out}.part" "${out}"
	say "fetched: $(basename "${out}")"
}

native() {
	if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi
}

mkdir -p "${DIR}"
DIR="$(cd "${DIR}" && pwd)"

fetch "${MODEL_URL}" "${DIR}/${MODEL_NAME}" "${MODEL_SHA}"
fetch "${JFK_URL}" "${DIR}/jfk.wav" "${JFK_SHA}"
printf '%s\n' "${JFK_TEXT}" >"${DIR}/jfk.txt"
for f in jfk-alignment.json jfk-logprobs-f16.npy; do
	[[ -f "${FIXTURES}/${f}" ]] || die "${FIXTURES}/${f} is missing from the checkout"
	cp "${FIXTURES}/${f}" "${DIR}/${f}"
done
say "fixture: jfk.txt, jfk-alignment.json, jfk-logprobs-f16.npy"

echo "LYRICSALIGN_ASSETS_DIR=$(native "${DIR}")"
