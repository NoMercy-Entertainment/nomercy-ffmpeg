#!/usr/bin/env bash
# Apply branch protection to master so the only route in is a reviewed PR from
# dev that passes the required checks. Idempotent (re-running just re-applies).
#
# Requires an ADMIN-scoped gh token (repo admin). The day-to-day maintainer
# token (admin:false) cannot set protection — a repo admin runs this once.
#
#   REPO=owner/name BRANCH=master APPROVALS=1 ./scripts/setup-branch-protection.sh
#   DRY_RUN=true ./scripts/setup-branch-protection.sh   # print payload, no API call
set -euo pipefail

REPO="${REPO:-NoMercy-Entertainment/nomercy-ffmpeg}"
BRANCH="${BRANCH:-master}"
APPROVALS="${APPROVALS:-1}"
DRY_RUN="${DRY_RUN:-false}"

# Required status-check contexts MUST match the aggregator job names exactly:
#   pr-validation  → .github/workflows/pr-guards.yml
#   pr-build       → .github/workflows/main.yml
payload="$(cat <<JSON
{
  "required_status_checks": { "strict": true, "contexts": ["pr-validation", "pr-build"] },
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "required_approving_review_count": ${APPROVALS},
    "dismiss_stale_reviews": true
  },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_conversation_resolution": true
}
JSON
)"

echo "${payload}" | jq . >/dev/null || { echo "❌ payload is not valid JSON"; exit 1; }

if [[ "${DRY_RUN}" == "true" ]]; then
  echo "DRY RUN — would PUT branch protection on ${REPO}@${BRANCH}:"
  echo "${payload}" | jq .
  exit 0
fi

echo "${payload}" | gh api -X PUT "repos/${REPO}/branches/${BRANCH}/protection" \
  -H "Accept: application/vnd.github+json" --input -
echo "✅ Branch protection applied to ${REPO}@${BRANCH} (approvals=${APPROVALS})."
