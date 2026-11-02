#!/usr/bin/env bash
# Builds and runs every tests/unit/test_*.c against the headers in
# scripts/includes. Plain C, no FFmpeg build needed; CI runs this on ubuntu.
#
# Usage: tests/unit/run.sh            (uses $CC, default cc)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
CC="${CC:-cc}"
OUT="$(mktemp -d)"
trap 'rm -rf "${OUT}"' EXIT

failed=0
ran=0
for src in "${HERE}"/test_*.c; do
	[[ -f "${src}" ]] || continue
	name="$(basename "${src}" .c)"
	ran=$((ran + 1))
	echo "== ${name}"
	if ! "${CC}" -std=c11 -Wall -Wextra -Werror -O2 -I "${ROOT}/scripts/includes" \
		"${src}" -o "${OUT}/${name}"; then
		echo "❌ ${name}: does not compile cleanly"
		failed=$((failed + 1))
		continue
	fi
	if "${OUT}/${name}"; then
		echo "✅ ${name}"
	else
		echo "❌ ${name}"
		failed=$((failed + 1))
	fi
done

# A run that found nothing to test must not read as green.
if [[ ${ran} -eq 0 ]]; then
	echo "❌ no tests/unit/test_*.c found"
	exit 1
fi
echo "${ran} unit test program(s), ${failed} failed"
[[ ${failed} -eq 0 ]]
