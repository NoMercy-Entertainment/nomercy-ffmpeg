#!/usr/bin/env bash
# foreign-glibc.sh <ffmpeg> <whisper model> <clip> [<spleeter model> <mix.wav>]
#
# Runs the linux-x86_64 binary on hosts whose glibc is NOT the one it was linked
# with, each with the Vulkan loader installed and no driver, and on the matching
# host with Mesa's software drivers. Every run must finish, write output, and
# on a foreign glibc say why Vulkan is off. This is the check that found
# nothing for two releases: a statically linked binary that opens the host's
# Vulkan loader brings the host's libc.so.6 in as a second libc, and any glibc
# other than the build's dies on the first allocation from a thread (SIGFPE),
# with no driver installed at all. The smoke job runs on the build's glibc
# (ubuntu-24.04), so this one runs the other hosts in containers; it needs
# Docker. Design: docs/superpowers/specs/2026-11-02-vulkan-loader-glibc-guard-design.md.
#
# Exit 0 when every host passed, 1 on any failure, 2 when Docker is not here.
set -u

ffmpeg="${1:?ffmpeg binary}"; wmodel="${2:?whisper model}"; clip="${3:?clip}"
smodel="${4:-}"; mix="${5:-}"

if ! command -v docker >/dev/null 2>&1; then
	echo "SKIP: docker is not installed; the foreign-glibc hosts cannot be run here"
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

# What runs inside each container. Written as a file so the quoting is read
# once, here, and not through docker's argv.
cat >"${work}/inside.sh" <<'EOF'
set -u
export DEBIAN_FRONTEND=noninteractive
pkgs="libvulkan1"; [[ "${1:-}" == mesa ]] && pkgs="${pkgs} mesa-vulkan-drivers"
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq --no-install-recommends ${pkgs} >/dev/null 2>&1 || { echo "  could not install ${pkgs}"; exit 1; }
cd /w
host="$(ldd --version 2>&1 | head -1 | grep -oE '[0-9]+\.[0-9]+$')"
# grep -a, not strings: the minimal images have no binutils.
own="$(grep -a -o -m1 -E 'GNU C Library [^,]*release version [0-9]+\.[0-9]+' ffmpeg | grep -oE '[0-9]+\.[0-9]+$' | head -1)"
want=no; [[ -n "${host}" && -n "${own}" && "${host}" != "${own}" ]] && want=yes
echo "  host glibc ${host:-?}, binary glibc ${own:-?}, drivers: $(ls /usr/share/vulkan/icd.d/ 2>/dev/null | wc -l); a foreign-glibc notice is expected: ${want}"
fail=0
run() {  # run <label> <env...> -- <ffmpeg args...>
	local label="$1"; shift
	local envs=(); while [[ "$1" != "--" ]]; do envs+=("$1"); shift; done; shift
	env "${envs[@]}" ./ffmpeg -hide_banner -nostdin -nostats "$@" >"out.${label}" 2>"err.${label}" </dev/null
	local rc=$? has=no verdict=ok
	grep -q "this machine's glibc is" "err.${label}" && has=yes
	[[ ${rc} -eq 0 ]] || verdict="FAIL (exit ${rc})"
	[[ "${has}" == "${want}" ]] || verdict="${verdict} FAIL (notice ${has}, expected ${want})"
	[[ -s "out.${label}" ]] || verdict="${verdict} FAIL (no output)"
	[[ "${verdict}" == ok ]] || { fail=1; grep -E "whisper:|stemsplit:|Floating" "err.${label}" | head -4 | sed 's/^/        /'; }
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
exit ${fail}
EOF

# Docker on Windows (Git Bash) wants a Windows path for the bind mount.
mount_src="${work}"
command -v cygpath >/dev/null 2>&1 && mount_src="$(cygpath -m "${work}")"
export MSYS_NO_PATHCONV=1

status=0
for host in "ubuntu:26.04" "ubuntu:22.04" "debian:12" "ubuntu:24.04 mesa"; do
	image="${host%% *}"; extra="${host#* }"; [[ "${extra}" == "${host}" ]] && extra=""
	echo "== ${image}${extra:+ +${extra}}"
	if docker run --rm -v "${mount_src}:/w" "${image}" bash /w/inside.sh ${extra}; then
		echo "   passed"
	else
		echo "   FAILED"; status=1
	fi
done
exit ${status}
