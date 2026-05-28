# Branch protection setup (master)

`master` must be locked so the only way in is a reviewed PR from `dev` that passed the required
checks. This is a repository setting, not code, so it is applied **once by a repo admin**.

## Required status check contexts

These names must match the workflow aggregator jobs exactly:

| Context | Workflow | Asserts |
|---------|----------|---------|
| `pr-validation` | `.github/workflows/pr-guards.yml` | PR source is `dev` **and** the manual-test checklist is fully ticked |
| `pr-build` | `.github/workflows/main.yml` | Full build + export + minimal smoke green for all 5 platforms |

## Option A — script (recommended)

Requires a gh token with **repo admin** rights.

```bash
REPO=NoMercy-Entertainment/nomercy-ffmpeg APPROVALS=1 ./.github/scripts/setup-branch-protection.sh
# Preview without applying:
DRY_RUN=true ./.github/scripts/setup-branch-protection.sh
```

## Option B — GitHub UI

Settings → Branches → Add branch ruleset (or classic protection) for `master`:

1. **Require a pull request before merging** — require **1** approval, dismiss stale approvals.
2. **Require status checks to pass** — add `pr-validation` and `pr-build`; enable "Require branches
   to be up to date before merging".
3. **Require conversation resolution before merging**.
4. **Do not allow force pushes**; **do not allow deletions**.
5. **Include administrators** (no bypass).

The required contexts only appear in the picker after they have run at least once — open a test PR
from `dev` first (see rollout order below).

## Rollout order (first time)

1. Land all the workflow/template/script changes on `master` (master is not protected yet).
2. Open a test PR `dev → master` so `pr-validation` and `pr-build` run once and register as contexts.
3. Apply protection (Option A or B).
4. Confirm: a direct push to `master` is rejected, and a PR from a non-`dev` branch fails
   `guard-source-branch`.
