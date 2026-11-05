#!/bin/bash
# Host entry point for the lyricsalign lab (Git Bash on Windows, or any shell).
#
#   tools/lyricsalign-lab/run.sh image           build the lab image
#   tools/lyricsalign-lab/run.sh build [--fresh] build ffmpeg with the filter
#   tools/lyricsalign-lab/run.sh suite [name]    unit tests + the real-model gates
#   tools/lyricsalign-lab/run.sh shell [-c cmd]  a shell in the lab
#
# Assets (the GGUF, jfk.wav, jfk.txt, jfk-alignment.json) are read from
# LYRICSALIGN_LAB_ASSETS, by default the lyricsalign-assets directory next to
# this repository's checkout.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
ASSETS="${LYRICSALIGN_LAB_ASSETS:-${ROOT}/../lyricsalign-assets}"
IMAGE=lyricsalign-lab
# Docker Desktop wants F:/... host paths; Git Bash would turn the container
# side of a -v into C:/... unless path conversion is off. So: convert the host
# side by hand, and switch the automatic conversion off.
export MSYS_NO_PATHCONV=1
host() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }

cmd="${1:-build}"; shift || true
case "${cmd}" in
image)
	cp "${ROOT}/scripts/includes/whisper-dtw-median-filter.patch" "${HERE}/"
	trap 'rm -f "${HERE}/whisper-dtw-median-filter.patch"' EXIT
	docker build -t "${IMAGE}" "$(host "${HERE}")"
	;;
build|suite|shell)
	mounts=(-v "$(host "${ROOT}"):/repo" -v lyricsalign-lab-prefix:/opt/nm -v lyricsalign-lab-build:/build)
	if [[ -d "${ASSETS}" ]]; then mounts+=(-v "$(host "$(cd "${ASSETS}" && pwd)"):/assets:ro"); fi
	case "${cmd}" in
	build) docker run --rm "${mounts[@]}" "${IMAGE}" /lab/build.sh "$@" ;;
	suite) docker run --rm "${mounts[@]}" "${IMAGE}" /lab/suite.sh "$@" ;;
	shell) tty=(); [[ -t 0 ]] && tty=(-it); docker run --rm "${tty[@]}" "${mounts[@]}" "${IMAGE}" bash "$@" ;;
	esac
	;;
*)
	echo "usage: run.sh image | build [--fresh] | suite [name] | shell [-c cmd]" >&2
	exit 2
	;;
esac
