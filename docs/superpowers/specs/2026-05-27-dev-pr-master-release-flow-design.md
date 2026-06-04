# Design: dev → PR → master release flow

**Date:** 2026-05-27
**Status:** Approved (pending written-spec review)
**Repo:** `NoMercy-Entertainment/nomercy-ffmpeg` (public)
**Checkpoint to restore the pre-change dev state:** branch `backup/dev-pre-pr-flow-2026-05-27` / tag `checkpoint-pre-pr-flow-2026-05-27` (both at `7412436`).

## Goal

Make `master` carry only validated, working code by forcing every change through a
gated `dev → PR → master` flow:

- `master` is fully locked: no direct pushes, and the **only** route in is a PR **from `dev`**.
- Opening/updating that PR produces a **release-candidate (RC) build** of all 5 platforms,
  published as a downloadable GitHub **prerelease**, so a contributor can test each platform
  **manually on real hardware**.
- The PR cannot be merged until **every** platform test is **checked off** in the PR body
  (and the automated gates are green).
- Merging to `master` produces the **final release** — guaranteed to come from code that was
  validated in the PR.

## Naming note

The repository's release branch is `master`. Throughout this document and the conversation,
"main" refers colloquially to `master`. **We do not rename the branch** (explicit user choice).

## Platforms (single source of truth lives in `detect-changes.yml`)

`linux-x86_64`, `linux-aarch64`, `windows-x86_64`, `darwin-x86_64`, `darwin-arm64`.

---

## Flow overview

```
feature/fix  ──PR──►  dev  ──PR (only route to master)──►  master
                       │                                       │
   PR opened/updated:  │                              after merge to master:
   • build all 5 (RC)  │                              • final build (detect-changes diff)
   • minimal smoke     │                              • Trivy security scan
   • publish/refresh   │                              • real GitHub release  v{next}
       prerelease      │                              • delete the v{next}-rc prerelease+tag
       v{next}-rc      │
   • contributor       │
       downloads,      │
       tests on real   │
       hardware, ticks │
       every platform  │
       in the PR body  │
                       ▼
        MERGE GATE (branch protection on master):
        • pr-validation  = source is dev  AND  full test-checklist ticked
        • pr-build       = build + export + smoke green for all 5 platforms
        • ≥ 1 reviewer approval
        • branch up to date, no force-push, no deletion, no bypass
```

---

## Section 1 — Branch protection on `master`

A single repository **ruleset** targeting `refs/heads/master`, enforcement **active**, with
**no bypass actors** (applies to admins too):

- **Require a pull request before merging.** No direct pushes.
- **Require ≥ 1 approving review** (user requirement: a reviewer approval must always be present).
- **Require status checks to pass**, exactly two contexts (aggregators from Section 2):
  - `pr-validation`
  - `pr-build`
- **Require branches to be up to date** before merging.
- **Block force pushes** and **block branch deletion**.

"Only from `dev`" is not expressible natively in GitHub branch protection; it is enforced by the
`guard-source-branch` job feeding the required `pr-validation` check (fails when `head_ref != dev`).

**Applied by:** a repo admin, because the current working token is `admin:false` (it has
`maintain`). See Section 6.

---

## Section 2 — Workflow restructuring

Two required checks, each produced by a single **aggregator job** so branch protection does not
need to enumerate every matrix leg (e.g. `build-platforms (linux-x86_64)`).

### New: `.github/workflows/pr-guards.yml`

Fast, no build. Triggers on `pull_request` targeting `master`, types
`[opened, edited, synchronize, reopened]` (`edited` is required so the checklist re-evaluates the
moment a box is ticked).

- `guard-source-branch` — fails if `github.head_ref != 'dev'`, with a clear message.
- `checklist-complete` — a `github-script` step that extracts **only** the checkboxes between
  `<!-- TEST-CHECKLIST-START -->` and `<!-- TEST-CHECKLIST-END -->` in the PR body and fails while
  any `- [ ]` remains unchecked. Checkboxes outside the delimiters never block.
- `pr-validation` — aggregator, `needs: [guard-source-branch, checklist-complete]`.
  **Required check #1.**

### Modified: `.github/workflows/main.yml`

Triggers: `push` to `master`, `pull_request` to `master` `[opened, synchronize, reopened]`,
`workflow_dispatch`. (Note: deliberately **not** `edited` here — body edits must not re-trigger
the heavy build; only `pr-guards.yml` listens to `edited`.)

- `detect-changes`
  - On a **pull_request** event → force a full build of **all** platforms + base. An RC validates
    everything, and this sidesteps the existing PR-diff limitation (the job checks out `ref: master`
    and diffs `HEAD^..HEAD`, which does not reflect PR contents). Implemented by passing
    `force_rebuild: true` to the reusable `detect-changes` workflow when
    `github.event_name == 'pull_request'`.
  - On a **push to master** → unchanged diff-based detection.
- `build-base`, `build-platforms`, `export-artifacts` — structurally unchanged. The build checks
  out the PR merge ref (current `actions/checkout` default for `pull_request`), so it builds the
  code that would land on `master`.
- `smoke-test` (renamed from `test-platforms`) — simplified and now genuinely blocking (Section 4).
- `publish-rc` *(new, pull_request only)* — after `smoke-test` succeeds, create/refresh the
  `v{next}-rc` prerelease with the version-stamped binaries (Section 3).
- `pr-build` — aggregator, `needs: [build-base, build-platforms, export-artifacts, smoke-test]`.
  **Required check #2.** Uses `always() && !cancelled()` semantics so a skipped optional job does
  not falsely fail it, but fails if any needed job failed.
- `security-scan` — **push to master only** (unchanged; Trivy).
- `release` *(final, push to master only)* — after `smoke-test` succeeds, create the real release
  `v{next}` and clean up the `v{next}-rc` prerelease + tag.

---

## Section 3 — RC prerelease lifecycle

- **Tag:** rolling `v{next}-rc` — a single prerelease per merge candidate, **updated in place** on
  each PR sync (no tag spam).
- **Marked `prerelease: true`.** Body states "Release Candidate — not for production" and links to
  the manual test instructions (`tests/tests.sh` / `tests/tests.ps1` + `CONTRIBUTING.md`).
- Contains the same version-stamped binaries for all 5 platforms as a real release, so the tester
  validates exactly what will be merged.
- **On the final release** (`v{next}` on master merge): the `v{next}-rc` prerelease and its tag are
  deleted as cleanup.
- **Version derivation:** `{next}` = latest semver tag + 1 patch (existing `detect-changes` logic).
  This is correct under the assumption of **one active `dev → master` PR at a time** (the team's
  situation). Parallel RCs could shift the computed version — documented as a known assumption
  (accepted by user).

---

## Section 4 — Minimal smoke test (the CI gate)

New `tests/smoke.sh` and `tests/smoke.ps1`, replacing the heavy suite **as the CI gate**:

- Run `ffmpeg -version` and `ffprobe -version`.
- Assert: **exit code 0**, output contains `ffmpeg version` **and** the expected `FFMPEG_VERSION`
  (`8.1.1`, sourced from the workflow env / single source of truth).
- **Genuinely blocking** — the previous `|| exit 0` failure-swallowing in `main.yml` is removed for
  the smoke step.
- **Cross-arch** (`linux-aarch64` runs on an x86_64 hosted runner, so the binary cannot execute):
  assert the archive extracts and the binary exists and is non-empty; skip execution. The smoke
  scripts detect the non-executable case and degrade to a presence check rather than failing.

The existing full suites `tests/tests.sh` and `tests/tests.ps1` remain in the repo unchanged as the
**manual** test a contributor runs on real hardware (NVENC/AMF/VPL, all codecs). The PR template
links to them.

---

## Section 5 — PR template + checklist gate

New `.github/PULL_REQUEST_TEMPLATE.md`:

- Short summary / list of changes.
- "Where to find the RC build" — points at the `v{next}-rc` prerelease.
- A delimited, machine-readable checklist; **only** boxes inside the delimiters count toward the
  `checklist-complete` gate:

```markdown
<!-- TEST-CHECKLIST-START -->
### Manual cross-platform test (required before merge)
- [ ] linux-x86_64 — binary tested on real hardware, `tests/tests.sh` ✓, version correct
- [ ] linux-aarch64 — binary tested on real hardware, `tests/tests.sh` ✓, version correct
- [ ] windows-x86_64 — binary tested on real hardware, `tests/tests.ps1` ✓, version correct
- [ ] darwin-x86_64 — binary tested on real hardware, `tests/tests.sh` ✓, version correct
- [ ] darwin-arm64 — binary tested on real hardware, `tests/tests.sh` ✓, version correct
- [ ] Hardware acceleration (NVENC/AMF/VPL) verified where applicable
<!-- TEST-CHECKLIST-END -->
```

The template also states that PRs to `master` are only accepted from `dev`.

---

## Section 6 — Admin setup script + documentation

- **`scripts/setup-branch-protection.sh`** — idempotent `gh api` script applying the Section 1
  ruleset to `master`. Requires an **admin-scoped token** (the current token is `admin:false`, so a
  repo admin runs it once). Required-approvals count is a parameter, **default 1**.
- **`docs/branch-protection-setup.md`** — how to run the script, plus manual UI fallback steps
  (Settings → Rules → Rulesets), and the exact list of required status-check contexts
  (`pr-validation`, `pr-build`).
- **`CONTRIBUTING.md`** — documents the full `dev → PR → master` flow, what the contributor must
  test, how the checklist gate works, and how to restore from the checkpoint.

---

## Out of scope (YAGNI)

- Renaming `master` → `main`.
- Bit-for-bit "RC artifact == release artifact" guarantee. `master` rebuilds the final release;
  the PR validation guarantees the **source** is good (matches user intent: "so that a final build
  can be made via main").
- Trivy scanning on PRs (stays master-only).
- Any third-party checklist action (we use an in-repo `github-script` — Option A).

## Files touched

| File | Change |
|------|--------|
| `.github/workflows/pr-guards.yml` | **new** — guard-source-branch, checklist-complete, pr-validation |
| `.github/workflows/main.yml` | modify — PR full build, rename test→smoke, add publish-rc, add pr-build aggregator, final release + rc cleanup |
| `.github/workflows/detect-changes.yml` | minor — accept PR full-build path (via existing `force_rebuild`) |
| `.github/PULL_REQUEST_TEMPLATE.md` | **new** — summary + delimited platform checklist |
| `tests/smoke.sh` | **new** — version + clean-exit (+ cross-arch presence) |
| `tests/smoke.ps1` | **new** — version + clean-exit |
| `scripts/setup-branch-protection.sh` | **new** — idempotent ruleset via gh api, default 1 approval |
| `docs/branch-protection-setup.md` | **new** — script + UI fallback + required contexts |
| `CONTRIBUTING.md` | **new** — full flow documentation |

## Known assumptions / risks

- One active `dev → master` PR at a time (version derivation).
- Branch protection must be applied by an admin; until then the gates exist but are not enforced at
  merge time.
- `dev → master` PRs are internal (same repo), so self-hosted runners and secrets are available for
  the RC build. External contributors fork and PR into `dev`, never `master`.
- Required status-check **context names** must match the aggregator job names exactly; renaming a
  job requires updating the ruleset.
