#!/bin/bash
# Refuse workflow steps that reference a remote action by a branch name.
# A branch runs whatever it holds on the day; pin a commit SHA instead, with the
# version as a trailing comment:  uses: owner/repo@<40-hex sha> # v1.2.3
# Local actions (./path) and docker:// references carry no branch and pass.
# Usage: check-action-pins.sh <workflows-dir>
dir=${1:?usage: check-action-pins.sh <workflows-dir>}
shopt -s nullglob
files=("$dir"/*.yml "$dir"/*.yaml)
if [ ${#files[@]} -eq 0 ]; then
    echo "❌ no workflow files under ${dir} -- nothing was checked"
    exit 1
fi

bad=0
checked=0
for f in "${files[@]}"; do
    n=0
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        # The value after `uses:`, without a trailing comment or quotes.
        [[ $line =~ ^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*([^[:space:]#]+) ]] || continue
        ref=${BASH_REMATCH[2]}
        ref=${ref//\"/}
        ref=${ref//\'/}
        case $ref in ./* | docker://*) continue ;; esac
        checked=$((checked + 1))
        case ${ref##*@} in
            master | main | HEAD | dev | develop | trunk)
                echo "❌ ${f}:${n}: ${ref} is a branch; pin it to a commit SHA"
                bad=$((bad + 1))
                ;;
        esac
    done <"$f"
done

if [ "$checked" -eq 0 ]; then
    echo "❌ found no remote 'uses:' lines in ${#files[@]} files -- the pattern is broken"
    exit 1
fi
if [ "$bad" -ne 0 ]; then
    echo "❌ ${bad} of ${checked} action references point at a branch"
    exit 1
fi
echo "✅ ${checked} action references checked in ${#files[@]} files; none points at a branch"
