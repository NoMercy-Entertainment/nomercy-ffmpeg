#!/usr/bin/env bash
# Fetch everything the stemsplit release gates need, pinned by SHA-256, and
# print the environment they read. Used by CI's smoke job and by anyone running
# the manual suite by hand:
#
#     tests/lib/stemsplit-assets.sh <platform> <dir>
#     eval "$(tests/lib/stemsplit-assets.sh linux-x86_64 ~/nm-assets)"
#
# What it fetches, and why each one is pinned:
#
#   * the ffmpeg-stemsplit v1.1.0 source archive -- its tests/ directory is the
#     suite the gates run (design D1). The archive is the tag's, so the checks
#     are the ones the filter was released with, not whatever the default
#     branch holds this afternoon.
#   * the tiny RoFormer models of that tag (design D2), a release asset.
#   * the Spleeter model, from the org's public models release, the same file
#     metal-gates fetches.
#   * the previous nomercy-ffmpeg release's binary for <platform>, the A/B
#     gate's reference: Spleeter stems must be byte-identical with it.
#
# Downloading a model and not checking what came back is how a green run ends
# up measuring something else, so a digest mismatch fails here, loudly. A file
# already in <dir> with the right digest is kept, so a persistent runner or a
# contributor's machine fetches each asset once.
#
# Everything lands under <dir>, in a fixed layout the checks rely on:
#
#     <dir>/ffmpeg-stemsplit/      the tag's whole tree (tests/ reads ../docs,
#                                  ../src and ../test.flac, so tests/ alone is
#                                  not enough)
#     <dir>/tiny/                  the tiny models
#     <dir>/spleeter-2stems-f16.gguf
#     <dir>/ref/<platform>/ffmpeg[.exe]
#                                  the previous release's binary; one
#                                  directory per platform, so a machine that
#                                  tests several platforms keeps them apart
#
# One run at a time per <dir>: the checks write their corpus and work files
# into it. Two platforms checked at once need two directories.
#
# The checks run with <dir> as the working directory and name every file by a
# relative path. That is not a style choice: on Windows, Git Bash turns an
# absolute path into C:/..., and the colon breaks avfilter's option parser the
# moment such a path lands in model=. Relative paths have no colon anywhere.
#
# Output: one STEMSPLIT_ASSETS_DIR=<dir> line on stdout (everything else goes to
# stderr), suitable for `>> "$GITHUB_ENV"` and for `eval`. Under MSYS the path
# is printed in the mixed C:/... form, which PowerShell, Git Bash and a native
# Python can all open.
set -euo pipefail

PLATFORM="${1:?usage: stemsplit-assets.sh <platform> <dir>}"
DIR="${2:?usage: stemsplit-assets.sh <platform> <dir>}"

STEMSPLIT_TAG=v1.1.0
FORGEJO=https://forgejo.phillippepelzer.me/FiLL/ffmpeg-stemsplit
# The suite comes from this commit on stemsplit's main, not from the tag: it is
# the tag plus two tests-only commits, one that lets the suite run on Windows
# and macOS (design D1a) and one that reads a GPU's refusal of the graph as the
# CPU run it is (design D9). The filter in it is byte-identical with the tag's,
# and FILTER_SHA is asserted below so that stays provable.
SUITE_REF=a8b8ea3
ARCHIVE_SHA=89f438ee54b9b6cc12837c8466a42fcf8d275aa67cc2826d0ed910955a226901
FILTER_SHA=13d5583478829b97c743f70eb867335d1f75a7fd125018eff7bea34ecd86e3f4
TINY_SHA=7b04652c855296e7d428ad5a130cf842e4da90eb16d2246fc7393284c42ea235
SPLEETER_URL=https://github.com/NoMercy-Entertainment/nomercy-stemsplit-models/releases/download/v2026.09.09/spleeter-2stems-f16.gguf
SPLEETER_SHA=155dc9d2e2eef70ad633af98134df29a5273defaeb98ef013d46251faa69d0ad

# The previous release: the one the A/B gate compares against. Bump all eight
# lines together when a release ships; the digests are the ones GitHub reports
# for the assets (gh release view --json assets).
REF_VERSION=v1.0.44
REF_BASE=https://github.com/NoMercy-Entertainment/nomercy-ffmpeg/releases/download/${REF_VERSION}
ref_digest() {
	case "$1" in
	linux-x86_64)    echo 191d9ef68a43b2756b973cb5ca1c6563b876750bfa582ea06271a4977e19008b ;;
	linux-aarch64)   echo 7072575443c972b947fcf38e488199361f697febd58e476b76993b6e9482701e ;;
	windows-x86_64)  echo aed6833b59d6b44876841ef6dd6db85946b1f22e39741fd89e3d4f972ff54ec3 ;;
	windows-aarch64) echo 80ab139dd3e99a9b4ca80c055e3362466c586df94d48474f396f64325ce23796 ;;
	darwin-x86_64)   echo 515e3792c6f9a3373ccfeda447d845e8266b182d3dc48cd629331027b7667172 ;;
	darwin-arm64)    echo 3031e87dcf67240ef07e479d9f37e648e537a85676e4c43e3423efac4c8acef0 ;;
	freebsd-x86_64)  echo e956a5abf82f3fad0ecd32c9ce47bdad40e46e484b8497667980c71ca5567332 ;;
	*) return 1 ;;
	esac
}

say() { echo "$*" >&2; }
die() { say "stemsplit-assets: $*"; exit 1; }

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
	curl -fsSL --retry 3 -o "${out}.part" "${url}" || die "download failed: ${url}"
	got="$(sha256_of "${out}.part")"
	if [[ "${got}" != "${want}" ]]; then
		rm -f "${out}.part"
		die "$(basename "${out}"): expected ${want}, got ${got}"
	fi
	mv "${out}.part" "${out}"
	say "fetched: $(basename "${out}")"
}

# A path the platform's own tools can open. Git Bash would hand C:/... to a
# native program anyway, but a Python started from here cannot open /d/a/...,
# and PowerShell cannot open either.
native() {
	if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi
}

ref_sha="$(ref_digest "${PLATFORM}")" || die "no reference digest for platform '${PLATFORM}'"
case "${PLATFORM}" in
windows-*) ref_ext=zip; ref_bin=ffmpeg.exe ;;
*)         ref_ext=tar.gz; ref_bin=ffmpeg ;;
esac

mkdir -p "${DIR}"
DIR="$(cd "${DIR}" && pwd)"

# 1. The source tree with the suite. Forgejo's archive unpacks as
#    ffmpeg-stemsplit/. A tree from an older run is replaced when its
#    marker names another ref.
fetch "${FORGEJO}/archive/${SUITE_REF}.tar.gz" "${DIR}/ffmpeg-stemsplit-${SUITE_REF}.tar.gz" "${ARCHIVE_SHA}"
if [[ ! -f "${DIR}/ffmpeg-stemsplit/tests/run_tests.sh" || "$(cat "${DIR}/ffmpeg-stemsplit/.nm-suite-ref" 2>/dev/null)" != "${SUITE_REF}" ]]; then
	rm -rf "${DIR}/ffmpeg-stemsplit"
	tar -xzf "${DIR}/ffmpeg-stemsplit-${SUITE_REF}.tar.gz" -C "${DIR}"
	echo "${SUITE_REF}" >"${DIR}/ffmpeg-stemsplit/.nm-suite-ref"
	say "unpacked: ffmpeg-stemsplit/ at ${SUITE_REF} (suite for ${STEMSPLIT_TAG})"
fi
for f in tests/run_tests.sh tests/gen_audio.py docs/integration.md src/af_stemsplit.c; do
	[[ -f "${DIR}/ffmpeg-stemsplit/${f}" ]] || die "the archive did not yield ffmpeg-stemsplit/${f}"
done
# The filter under test must be the released one: the file in this tree must
# be the tag's, byte for byte, or the suite would be checking a later filter.
got="$(sha256_of "${DIR}/ffmpeg-stemsplit/src/af_stemsplit.c")"
[[ "${got}" == "${FILTER_SHA}" ]] || die "src/af_stemsplit.c at ${SUITE_REF} is ${got}, not the ${STEMSPLIT_TAG} file (${FILTER_SHA})"
say "verified: src/af_stemsplit.c is the ${STEMSPLIT_TAG} file"

# 2. The tiny RoFormer models.
fetch "${FORGEJO}/releases/download/${STEMSPLIT_TAG}/stemsplit-tiny-models-${STEMSPLIT_TAG}.tar.xz" \
	"${DIR}/stemsplit-tiny-models-${STEMSPLIT_TAG}.tar.xz" "${TINY_SHA}"
if [[ ! -f "${DIR}/tiny/tiny-mel-v1.gguf" ]]; then
	rm -rf "${DIR}/tiny"
	tar -xJf "${DIR}/stemsplit-tiny-models-${STEMSPLIT_TAG}.tar.xz" -C "${DIR}"
	say "unpacked: tiny/ ($(ls "${DIR}/tiny" | wc -l | tr -d ' ') entries)"
fi
[[ -f "${DIR}/tiny/tiny-mel-v1.gguf" && -f "${DIR}/tiny/tiny-bs-v1.gguf" ]] || die "the tiny tarball did not yield tiny-mel-v1.gguf and tiny-bs-v1.gguf"

# 3. The Spleeter model.
fetch "${SPLEETER_URL}" "${DIR}/spleeter-2stems-f16.gguf" "${SPLEETER_SHA}"

# 4. The previous release's binary for this platform.
ref_archive="${DIR}/ffmpeg-${PLATFORM}-${REF_VERSION}.${ref_ext}"
fetch "${REF_BASE}/ffmpeg-9.0-${PLATFORM}-${REF_VERSION}.${ref_ext}" "${ref_archive}" "${ref_sha}"
ref_dir="${DIR}/ref/${PLATFORM}"
if [[ ! -f "${ref_dir}/${ref_bin}" ]]; then
	rm -rf "${ref_dir}"
	mkdir -p "${ref_dir}"
	case "${ref_ext}" in
	zip)    (cd "${ref_dir}" && unzip -o -q "${ref_archive}" "${ref_bin}") ;;
	tar.gz) tar -xzf "${ref_archive}" -C "${ref_dir}" "./${ref_bin}" ;;
	esac
	chmod +x "${ref_dir}/${ref_bin}" 2>/dev/null || true
	say "unpacked: ref/${PLATFORM}/${ref_bin} (${REF_VERSION})"
fi
[[ -f "${ref_dir}/${ref_bin}" ]] || die "the ${REF_VERSION} archive did not yield ${ref_bin}"

echo "STEMSPLIT_ASSETS_DIR=$(native "${DIR}")"
