#!/usr/bin/env bash
# glibc-hosts.sh <ffmpeg> <whisper model> <clip> [<spleeter model> <mix.wav>]
#
# Runs the linux-x86_64 archive on the hosts its glibc 2.35 floor
# promises (Ubuntu 22.04 / glibc 2.35, Debian 12 / 2.36) and on newer ones
# (Ubuntu 24.04 / 2.39 with Mesa's software Vulkan driver, Ubuntu 26.04 /
# 2.43), each with the Vulkan loader installed. The archive links the host's
# glibc dynamically, so the first thing this proves is that it starts at all
# on 2.35 and 2.36; the rest is real whisper and stemsplit inference on each
# host. The archive carries the Vulkan
# backend and the fork-and-probe driver guard: with no ICD, or with only
# Mesa's software rasteriser, every run must land on the CPU backend and still
# transcribe. No "foreign glibc" notice is expected, because the binary's glibc
# IS the host's.
#
# None of these containers has a GPU. This test proves the glibc floor and the
# fallback to the CPU; that the same binary uses a GPU when there is one is
# proven on real hardware (tools/gpu-container and the release verify).
#
# Exit 0 when every host passed, 1 on any failure, 2 when Docker is not here.
set -u
ffmpeg="${1:?ffmpeg binary}"; wmodel="${2:?whisper model}"; clip="${3:?clip}"
smodel="${4:-}"; mix="${5:-}"
if ! grep -aq 'ggml_vulkan' "${ffmpeg}"; then
	echo 'FAIL: glibc-hosts.sh expects the linux-x86_64 archive, which carries the Vulkan backend' >&2
	exit 1
fi
if ! command -v docker >/dev/null 2>&1; then
	echo "SKIP: docker is not installed; the glibc hosts cannot be run here"
	exit 2
fi
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
cp "${ffmpeg}" "${work}/ffmpeg" && chmod +x "${work}/ffmpeg"
cp "${wmodel}" "${work}/model.bin"
cp "${clip}" "${work}/clip.wav"
if [[ -n "${smodel}" && -n "${mix}" ]]; then
	cp "${smodel}" "${work}/spleeter.gguf"
	cp "${mix}" "${work}/mix.wav"
fi
cat >"${work}/inside.sh" <<'EOF'
set -u
export DEBIAN_FRONTEND=noninteractive
pkgs="libvulkan1 python3"; [[ "${1:-}" == mesa ]] && pkgs="${pkgs} mesa-vulkan-drivers"
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq --no-install-recommends ${pkgs} >/dev/null 2>&1 || { echo "  could not install ${pkgs}"; exit 1; }
cd /w
host="$(ldd --version 2>&1 | head -1 | grep -oE '[0-9]+\.[0-9]+$')"
echo "  host glibc ${host:-?}, drivers: $(ls /usr/share/vulkan/icd.d/ 2>/dev/null | wc -l); no GPU in this container, so it must start and fall back to the CPU"
fail=0
# The floor itself: the loader must accept the binary before FFmpeg runs.
if ! ./ffmpeg -version >version.out 2>version.err; then
	echo "  FAIL: ffmpeg does not start on glibc ${host}:"; head -3 version.err | sed 's/^/        /'; exit 1
fi
printf '  %-18s %s\n' version "ok ($(head -1 version.out | cut -d' ' -f3))"
whisper_text_present() {
	python3 - "$1" <<'PY'
import json
import sys
try:
    with open(sys.argv[1], encoding="utf-8") as stream:
        objects = [json.loads(line) for line in stream if line.strip()]
    if not objects or not isinstance(objects[0], dict) or "detected_language" not in objects[0]:
        raise ValueError("missing language object")
    if not any(
        isinstance(segment, dict)
        and isinstance(segment.get("text"), str)
        and segment["text"].strip()
        and isinstance(segment.get("start"), (int, float))
        and isinstance(segment.get("end"), (int, float))
        and 0 <= segment["start"] < segment["end"]
        for segment in objects[1:]
    ):
        raise ValueError("no nonempty timed transcription segment")
except (OSError, ValueError, TypeError) as error:
    print(f"  invalid Whisper transcription: {error}", file=sys.stderr)
    sys.exit(1)
PY
}
run() {  # run <label> <env...> -- <ffmpeg args...>
	local label="$1"; shift
	local envs=(); while [[ "$1" != "--" ]]; do envs+=("$1"); shift; done; shift
	timeout -k 5 300 env "${envs[@]}" ./ffmpeg -hide_banner -nostdin -nostats "$@" >"out.${label}" 2>"err.${label}" </dev/null
	local rc=$? verdict=ok
	[[ ${rc} -eq 0 ]] || verdict="FAIL (exit ${rc})"
	grep -q "this machine's glibc is" "err.${label}" && verdict="${verdict} FAIL (foreign-glibc notice on the binary's own glibc)"
	[[ -s "out.${label}" ]] || verdict="${verdict} FAIL (no output)"
	case "${label}" in
	whisper*)
		grep -Fq "whisper: ggml backend 'cpu' (" "err.${label}" || verdict="${verdict} FAIL (Whisper CPU backend not confirmed)"
		whisper_text_present "out.${label}" || verdict="${verdict} FAIL (no valid transcription text)"
		;;
	stemsplit*)
		grep -Eiq '^lavfi\.stemsplit\.backend=cpu[[:space:]]*$' "out.${label}" || verdict="${verdict} FAIL (stemsplit CPU backend not confirmed)"
		;;
	esac
	[[ "${verdict}" == ok ]] || { fail=1; grep -E "whisper:|stemsplit:|vulkan|Floating|glibc" "err.${label}" | head -4 | sed 's/^/        /'; }
	printf '  %-18s %s\n' "${label}" "${verdict}"
}
W="whisper=model=model.bin:use_gpu=0:format=json:destination=-"
run whisper          -- -filter_threads 1 -i clip.wav -af "${W}" -f null -
run whisper-gpu1     -- -filter_threads 1 -i clip.wav -af "whisper=model=model.bin:use_gpu=1:format=json:destination=-" -f null -
run whisper-nogpu    NOMERCY_GGML_GPU=0 -- -filter_threads 1 -i clip.wav -af "${W}" -f null -
if [[ -f spleeter.gguf ]]; then
	S="stemsplit=model=spleeter.gguf:stem=accompaniment,ametadata=mode=print:key=lavfi.stemsplit.backend:file=out.stemsplit"
	run stemsplit        -- -i mix.wav -t 3 -af "${S}" -f null -
	run stemsplit-gpu1   -- -i mix.wav -t 3 -af "stemsplit=model=spleeter.gguf:stem=accompaniment:use_gpu=1,ametadata=mode=print:key=lavfi.stemsplit.backend:file=out.stemsplit-gpu1" -f null -
fi
# A plain encode through the host's dynamic loader path, no GPU asked for. The
# stream goes to stdout, so the "no output" check above means encoded bytes.
run encode           -- -f lavfi -i "testsrc=duration=1:size=320x240:rate=5" -c:v libx264 -f h264 -
exit ${fail}
EOF
mount_src="${work}"
command -v cygpath >/dev/null 2>&1 && mount_src="$(cygpath -m "${work}")"
export MSYS_NO_PATHCONV=1
status=0
for host in "ubuntu:22.04" "debian:12" "ubuntu:24.04 mesa" "ubuntu:26.04"; do
	image="${host%% *}"; extra="${host#* }"; [[ "${extra}" == "${host}" ]] && extra=""
	echo "== ${image}${extra:+ +${extra}}"
	if docker run --rm -v "${mount_src}:/w" "${image}" bash /w/inside.sh ${extra}; then
		echo "   passed"
	else
		echo "   FAILED"; status=1
	fi
done
exit ${status}
