# Contributing

## Branch model

```
feature/fix → dev → (PR, the only route) → master → release
```

- **`dev`** is the integration branch. Do your work here (or in a branch merged into `dev`).
- **`master`** is protected and only ever receives reviewed, fully tested code via a PR **from `dev`**.
- Direct pushes to `master` are blocked. PRs into `master` from any branch other than `dev` are
  rejected automatically.

## Opening a release PR (dev → master)

1. Open a PR from `dev` into `master`. The PR body comes from the template with a per-platform
   manual-test checklist.
2. CI builds all platforms and publishes a **Release Candidate** prerelease `vX.Y.Z-rc` on the
   Releases page.
3. For **each** platform: download the RC binary, run the manual suite on **real hardware** —
   `tests/tests.sh` (unix) or `tests/tests.ps1` (Windows) — confirm the version, and verify
   hardware acceleration (NVENC/AMF/VPL) where applicable.
4. Tick the matching checkbox in the PR for every platform you verified.
5. Get at least one approving review.

## Merge requirements

A PR into `master` can only merge when **all** of these are green:

- `pr-validation` — source branch is `dev` and every manual-test checkbox is ticked.
- `pr-build` — full build + export + smoke passed for all 5 platforms.
- At least one approving review; conversations resolved; branch up to date.

On merge, `master` builds the **final release** `vX.Y.Z`, runs the Trivy scan, and the `-rc`
prerelease is deleted.

## Smoke vs. manual tests

- **CI smoke** (`tests/smoke.sh` / `tests/smoke.ps1`): only checks the binary runs, reports the
  expected version, and exits cleanly. Cross-arch (linux-aarch64) is checked for presence only.
- **Manual suite** (`tests/tests.sh` / `tests/tests.ps1`): the full codec/hardware suite a
  contributor runs on real hardware before ticking the checklist.

## Restore point

A pre-change checkpoint of `dev` exists at branch `backup/dev-pre-pr-flow-2026-05-27` /
tag `checkpoint-pre-pr-flow-2026-05-27` (commit `7412436`). Restore with
`git reset --hard backup/dev-pre-pr-flow-2026-05-27`.
