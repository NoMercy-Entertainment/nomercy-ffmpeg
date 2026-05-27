# Gated dev → PR → master Release Flow — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Lock `master` so the only route in is a reviewed PR from `dev` that has passed an automated build/smoke gate and a fully ticked manual cross-platform test checklist; merging then produces the final release.

**Architecture:** A fast `pr-guards.yml` workflow produces the `pr-validation` required check (source-is-dev + checklist-complete). The existing `main.yml` produces the `pr-build` required check (full build + export + minimal smoke for all 5 platforms) and, on a PR, publishes a rolling `v{next}-rc` GitHub prerelease for manual testing; on push to `master` it builds the final release and deletes the RC. Branch protection (applied once by an admin) requires `pr-validation`, `pr-build`, and ≥1 approval.

**Tech Stack:** GitHub Actions (composite/reusable workflows), Bash, PowerShell, Node.js (zero-dependency checklist parser), `gh` CLI, Docker (FFmpeg cross-builds, actionlint).

**Restore point if anything breaks:** branch `backup/dev-pre-pr-flow-2026-05-27` / tag `checkpoint-pre-pr-flow-2026-05-27` (both at commit `7412436`). Restore with `git reset --hard backup/dev-pre-pr-flow-2026-05-27`.

**Spec:** `docs/superpowers/specs/2026-05-27-dev-pr-master-release-flow-design.md`

---

## File structure

| File | Responsibility |
|------|----------------|
| `.github/scripts/check-checklist.js` | Pure parser + CLI: fail if any box between the checklist delimiters is unticked |
| `.github/scripts/check-checklist.test.js` | Node `assert` tests for the parser |
| `.github/PULL_REQUEST_TEMPLATE.md` | PR body with the delimited per-platform manual-test checklist |
| `.github/workflows/pr-guards.yml` | `guard-source-branch`, `checklist-complete`, `pr-validation` aggregator |
| `.github/workflows/main.yml` | Modified: PR full-build, `smoke-test`, `publish-rc`, `pr-build` aggregator, final release + RC cleanup |
| `tests/smoke.sh` | Minimal unix smoke gate: version + clean exit, cross-arch presence fallback |
| `tests/smoke.test.sh` | Bash tests for `smoke.sh` against stub binaries |
| `tests/smoke.ps1` | Minimal Windows smoke gate: version + clean exit |
| `scripts/setup-branch-protection.sh` | Idempotent `gh api` ruleset application (default 1 approval), `DRY_RUN` mode |
| `docs/branch-protection-setup.md` | How to apply protection (script + UI fallback) + required contexts + rollout order |
| `CONTRIBUTING.md` | Full dev → PR → master flow + checkpoint restore |

`tests/tests.sh` and `tests/tests.ps1` are **unchanged** — they remain the manual on-hardware suite. `detect-changes.yml` is **unchanged** — the PR full-build is driven from `main.yml` via the existing `force_rebuild` input.

---

## Task 1: Checklist parser + tests

**Files:**
- Create: `.github/scripts/check-checklist.js`
- Test: `.github/scripts/check-checklist.test.js`

- [ ] **Step 1: Write the failing test**

Create `.github/scripts/check-checklist.test.js`:

```js
const assert = require('assert');
const { findUncheckedItems } = require('./check-checklist');

const wrap = (inner) =>
  `intro text\n<!-- TEST-CHECKLIST-START -->\n${inner}\n<!-- TEST-CHECKLIST-END -->\nfooter\n- [ ] outside box must be ignored`;

// all checked (mixed-case x)
let r = findUncheckedItems(wrap('- [x] alpha\n- [X] bravo'));
assert.strictEqual(r.error, null, 'no error when all checked');
assert.strictEqual(r.total, 2, 'counts two items');
assert.strictEqual(r.unchecked.length, 0, 'none unchecked');

// one unchecked — and the outside box is not counted
r = findUncheckedItems(wrap('- [x] alpha\n- [ ] bravo'));
assert.deepStrictEqual(r.unchecked, ['bravo'], 'only the inside unticked item');
assert.strictEqual(r.total, 2, 'outside box excluded from total');

// missing delimiters
r = findUncheckedItems('no markers here at all');
assert.strictEqual(r.error, 'delimiters-missing', 'flags missing delimiters');

// delimiters present but no checkbox items
r = findUncheckedItems(wrap('just prose, no checkboxes'));
assert.strictEqual(r.error, 'no-items', 'flags empty checklist');

console.log('all checklist parser tests passed');
```

- [ ] **Step 2: Run test to verify it fails**

Run: `node .github/scripts/check-checklist.test.js`
Expected: FAIL — `Cannot find module './check-checklist'`.

- [ ] **Step 3: Write minimal implementation**

Create `.github/scripts/check-checklist.js`:

```js
#!/usr/bin/env node
// Fails (exit 1) if any checkbox between the TEST-CHECKLIST delimiters is
// unticked. Only boxes inside the delimiters count — boxes anywhere else in
// the PR body are ignored, so optional/cosmetic checkboxes never block merge.
'use strict';

const START = '<!-- TEST-CHECKLIST-START -->';
const END = '<!-- TEST-CHECKLIST-END -->';

function extractSection(body) {
  const s = body.indexOf(START);
  const e = body.indexOf(END);
  if (s === -1 || e === -1 || e < s) return null;
  return body.slice(s + START.length, e);
}

function findUncheckedItems(body) {
  const section = extractSection(body || '');
  if (section === null) return { error: 'delimiters-missing', unchecked: [], total: 0 };
  const unchecked = [];
  let total = 0;
  for (const line of section.split(/\r?\n/)) {
    const m = line.match(/^\s*-\s*\[( |x|X)\]\s*(.*)$/);
    if (!m) continue;
    total += 1;
    if (m[1] === ' ') unchecked.push(m[2].trim());
  }
  return { error: total === 0 ? 'no-items' : null, unchecked, total };
}

module.exports = { extractSection, findUncheckedItems, START, END };

if (require.main === module) {
  const res = findUncheckedItems(process.env.PR_BODY || '');
  if (res.error === 'delimiters-missing') {
    console.error('❌ Test-checklist delimiters not found in the PR body. Use the PR template.');
    process.exit(1);
  }
  if (res.error === 'no-items') {
    console.error('❌ No checklist items found between the delimiters.');
    process.exit(1);
  }
  if (res.unchecked.length > 0) {
    console.error(`❌ ${res.unchecked.length}/${res.total} manual-test items still unchecked:`);
    for (const u of res.unchecked) console.error(`   - [ ] ${u}`);
    process.exit(1);
  }
  console.log(`✅ All ${res.total} manual-test checklist items are checked.`);
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `node .github/scripts/check-checklist.test.js`
Expected: PASS — prints `all checklist parser tests passed`.

- [ ] **Step 5: Verify the CLI behaves (manual smoke of the entrypoint)**

Run (PowerShell):
```powershell
$env:PR_BODY = "x`n<!-- TEST-CHECKLIST-START -->`n- [ ] a`n<!-- TEST-CHECKLIST-END -->"; node .github/scripts/check-checklist.js; "exit=$LASTEXITCODE"
```
Expected: prints the unchecked item and `exit=1`.
Then:
```powershell
$env:PR_BODY = "x`n<!-- TEST-CHECKLIST-START -->`n- [x] a`n<!-- TEST-CHECKLIST-END -->"; node .github/scripts/check-checklist.js; "exit=$LASTEXITCODE"
```
Expected: prints `✅ All 1 manual-test checklist items are checked.` and `exit=0`.

- [ ] **Step 6: Commit**

```bash
git add .github/scripts/check-checklist.js .github/scripts/check-checklist.test.js
git commit -m "feat(ci): add PR manual-test checklist parser with tests"
```

---

## Task 2: PR template

**Files:**
- Create: `.github/PULL_REQUEST_TEMPLATE.md`

- [ ] **Step 1: Write the template**

Create `.github/PULL_REQUEST_TEMPLATE.md`:

```markdown
## Summary

<!-- What changed and why. -->

## Release candidate

When this PR is opened/updated, CI builds all platforms and publishes a **Release Candidate**
prerelease tagged `vX.Y.Z-rc` on the [Releases page](../../releases). Download the binary for
each platform and test it **on real hardware** before ticking the boxes below.

> PRs into `master` are only accepted from the `dev` branch. PRs from any other branch are
> rejected automatically by the `guard-source-branch` check.

## Manual cross-platform test

Run the full manual suite on each platform — `tests/tests.sh` (unix) or `tests/tests.ps1`
(Windows) — and confirm the version is correct. Tick a box only after the binary passes on
**real hardware** for that platform. All boxes must be checked before this PR can be merged.

<!-- TEST-CHECKLIST-START -->
- [ ] linux-x86_64 — tested on real hardware, `tests/tests.sh` ✓, version correct
- [ ] linux-aarch64 — tested on real hardware, `tests/tests.sh` ✓, version correct
- [ ] windows-x86_64 — tested on real hardware, `tests/tests.ps1` ✓, version correct
- [ ] darwin-x86_64 — tested on real hardware, `tests/tests.sh` ✓, version correct
- [ ] darwin-arm64 — tested on real hardware, `tests/tests.sh` ✓, version correct
- [ ] Hardware acceleration (NVENC / AMF / VPL) verified where applicable
<!-- TEST-CHECKLIST-END -->

## Notes

<!-- Anything reviewers should know. -->
```

- [ ] **Step 2: Verify the parser accepts the template's checklist**

Run (PowerShell — feeds the template body to the parser; an all-unticked template must fail):
```powershell
$env:PR_BODY = Get-Content -Raw .github/PULL_REQUEST_TEMPLATE.md; node .github/scripts/check-checklist.js; "exit=$LASTEXITCODE"
```
Expected: lists 6 unchecked items and `exit=1` (confirms delimiters + items are detected; a real PR with all boxes ticked will pass).

- [ ] **Step 3: Commit**

```bash
git add .github/PULL_REQUEST_TEMPLATE.md
git commit -m "feat(ci): add PR template with delimited manual-test checklist"
```

---

## Task 3: pr-guards.yml workflow

**Files:**
- Create: `.github/workflows/pr-guards.yml`

- [ ] **Step 1: Write the workflow**

Create `.github/workflows/pr-guards.yml`:

```yaml
name: PR Guards

# Fast, build-free gates for PRs into master. `edited` is included so the
# checklist re-evaluates the moment a reviewer ticks a box.
on:
  pull_request:
    branches: [master]
    types: [opened, edited, synchronize, reopened]

concurrency:
  group: pr-guards-${{ github.event.pull_request.number }}
  cancel-in-progress: true

jobs:
  guard-source-branch:
    runs-on: ubuntu-latest
    steps:
      - name: Enforce PR source branch is dev
        run: |
          if [[ "${{ github.head_ref }}" != "dev" ]]; then
            echo "❌ PRs into master are only allowed from 'dev' (got '${{ github.head_ref }}')."
            exit 1
          fi
          echo "✅ PR source branch is dev."

  checklist-complete:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4
      - name: Verify manual-test checklist is complete
        env:
          PR_BODY: ${{ github.event.pull_request.body }}
        run: node .github/scripts/check-checklist.js

  # Single required context for branch protection. always() + explicit result
  # checks so a failed/ skipped dependency reliably fails this job (a job
  # skipped via failed `needs` can otherwise be miscounted as passing).
  pr-validation:
    needs: [guard-source-branch, checklist-complete]
    if: always()
    runs-on: ubuntu-latest
    steps:
      - name: Verify all PR gates passed
        run: |
          guard='${{ needs.guard-source-branch.result }}'
          checklist='${{ needs.checklist-complete.result }}'
          if [[ "$guard" != "success" || "$checklist" != "success" ]]; then
            echo "❌ PR gates failed: guard=$guard checklist=$checklist"
            exit 1
          fi
          echo "✅ All PR validation gates passed."
```

- [ ] **Step 2: Validate the workflow with actionlint**

Run:
```bash
docker run --rm -v "$(pwd)":/repo --workdir /repo rhysd/actionlint:latest -color .github/workflows/pr-guards.yml
```
Expected: no errors (exit 0). If Docker is unavailable, validate YAML parses instead:
`node -e "require('js-yaml')" 2>/dev/null && node -e "const y=require('js-yaml');y.load(require('fs').readFileSync('.github/workflows/pr-guards.yml','utf8'));console.log('yaml ok')"` — and rely on the integration test PR in Task 11.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/pr-guards.yml
git commit -m "feat(ci): add pr-guards workflow (source-branch + checklist gates)"
```

---

## Task 4: Unix smoke test + tests

**Files:**
- Create: `tests/smoke.sh`
- Test: `tests/smoke.test.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/smoke.test.sh`:

```bash
#!/usr/bin/env bash
# Tests tests/smoke.sh against stub ffmpeg/ffprobe binaries (shell scripts).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SMOKE="${HERE}/smoke.sh"
PASS=0; FAIL=0

make_stub() {  # dir, name, version_string, exit_code
  local dir="$1" name="$2" ver="$3" code="$4"
  cat > "${dir}/${name}" <<EOF
#!/usr/bin/env bash
echo "${name} version ${ver} Copyright (c) the FFmpeg developers"
exit ${code}
EOF
  chmod +x "${dir}/${name}"
}

expect() {  # description, expected_rc, actual_rc
  if [[ "$2" == "$3" ]]; then echo "✅ $1"; ((PASS++)); else echo "❌ $1 (expected rc $2, got $3)"; ((FAIL++)); fi
}

# Case 1: correct version → pass (rc 0)
d="$(mktemp -d)"; make_stub "$d" ffmpeg 8.1.1 0; make_stub "$d" ffprobe 8.1.1 0
bash "$SMOKE" "$d" 8.1.1 >/dev/null 2>&1; expect "correct version passes" 0 $?

# Case 2: wrong version → fail (rc != 0)
d="$(mktemp -d)"; make_stub "$d" ffmpeg 7.0.0 0; make_stub "$d" ffprobe 7.0.0 0
bash "$SMOKE" "$d" 8.1.1 >/dev/null 2>&1; rc=$?; [[ $rc -ne 0 ]] && rc=1; expect "wrong version fails" 1 $rc

# Case 3: non-zero ffmpeg exit (not exec-format) → fail
d="$(mktemp -d)"; make_stub "$d" ffmpeg 8.1.1 3; make_stub "$d" ffprobe 8.1.1 0
bash "$SMOKE" "$d" 8.1.1 >/dev/null 2>&1; rc=$?; [[ $rc -ne 0 ]] && rc=1; expect "non-zero ffmpeg exit fails" 1 $rc

# Case 4: missing binary → fail
d="$(mktemp -d)"; make_stub "$d" ffprobe 8.1.1 0
bash "$SMOKE" "$d" 8.1.1 >/dev/null 2>&1; rc=$?; [[ $rc -ne 0 ]] && rc=1; expect "missing ffmpeg fails" 1 $rc

echo "----"; echo "passed=$PASS failed=$FAIL"
[[ $FAIL -eq 0 ]]
```

- [ ] **Step 2: Run test to verify it fails**

Run (use the Bash tool): `bash tests/smoke.test.sh`
Expected: FAIL — every case errors because `tests/smoke.sh` does not exist yet.

- [ ] **Step 3: Write minimal implementation**

Create `tests/smoke.sh`:

```bash
#!/usr/bin/env bash
# Minimal CI smoke gate: assert the freshly-built binary runs, reports the
# expected version, and exits cleanly. This is NOT the full codec suite — that
# is tests/tests.sh, run manually on real hardware by a contributor.
#
# Usage: smoke.sh <workspace_dir> <expected_version>
#
# Cross-arch note: linux-aarch64 is smoke-tested on an x86_64 runner and cannot
# execute. We detect the exec-format failure (exit 126 / "Exec format error")
# and fall back to a presence+non-empty check — the most a cross-arch runner
# can verify. Any other non-zero exit is a real failure.
set -uo pipefail

WORKSPACE="${1:?workspace dir required}"
EXPECTED_VERSION="${2:?expected version required}"

fail() { echo "❌ $*" >&2; exit 1; }
note() { echo "ℹ️  $*"; }
ok()   { echo "✅ $*"; }

ffmpeg_bin="${WORKSPACE}/ffmpeg"
ffprobe_bin="${WORKSPACE}/ffprobe"

[[ -f "${ffmpeg_bin}"  ]] || fail "ffmpeg binary not found at ${ffmpeg_bin}"
[[ -f "${ffprobe_bin}" ]] || fail "ffprobe binary not found at ${ffprobe_bin}"
[[ -s "${ffmpeg_bin}"  ]] || fail "ffmpeg binary is empty"
[[ -s "${ffprobe_bin}" ]] || fail "ffprobe binary is empty"
chmod +x "${ffmpeg_bin}" "${ffprobe_bin}" 2>/dev/null || true

is_exec_format_error() {
  echo "$1" | grep -qiE "exec format error|cannot execute binary file"
}

assert_version() {  # bin, banner
  local bin="$1" banner="$2" out code
  out="$("${bin}" -version 2>&1)"; code=$?
  if [[ ${code} -ne 0 ]]; then
    if [[ ${code} -eq 126 ]] || is_exec_format_error "${out}"; then
      note "Cross-arch runner: $(basename "${bin}") present but not executable here — presence check only."
      return 10   # signal: cross-arch, skip remaining version asserts
    fi
    echo "${out}"; fail "$(basename "${bin}") -version exited ${code}"
  fi
  echo "${out}" | grep -q "${banner}" || { echo "${out}"; fail "missing '${banner}' banner"; }
  echo "${out}" | grep -q "${EXPECTED_VERSION}" || { echo "${out}"; fail "expected version ${EXPECTED_VERSION} not found"; }
  ok "$(basename "${bin}") reports version ${EXPECTED_VERSION} and exits 0"
  return 0
}

assert_version "${ffmpeg_bin}" "ffmpeg version"; rc=$?
if [[ ${rc} -eq 10 ]]; then
  ok "Smoke (presence-only) passed for cross-arch binaries."
  exit 0
fi
assert_version "${ffprobe_bin}" "ffprobe version"
ok "Smoke test passed."
```

- [ ] **Step 4: Run test to verify it passes**

Run (Bash tool): `bash tests/smoke.test.sh`
Expected: PASS — `passed=4 failed=0`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add tests/smoke.sh tests/smoke.test.sh
git commit -m "feat(ci): add minimal unix smoke gate with tests"
```

---

## Task 5: Windows smoke test

**Files:**
- Create: `tests/smoke.ps1`

> No unit-test harness here: testing a `.exe`-invoking PowerShell script locally would require a real stub executable; the bash sibling carries the non-trivial cross-arch logic and is unit-tested in Task 4. This script is validated by a parse check plus the Windows integration leg in Task 11.

- [ ] **Step 1: Write the implementation**

Create `tests/smoke.ps1`:

```powershell
# Minimal CI smoke gate for Windows: assert ffmpeg.exe/ffprobe.exe run, report
# the expected version, and exit cleanly. NOT the full codec suite (tests.ps1).
param(
    [Parameter(Mandatory = $true)][string]$Workspace,
    [Parameter(Mandatory = $true)][string]$ExpectedVersion
)
$ErrorActionPreference = 'Stop'

function Fail($msg) { Write-Host "❌ $msg"; exit 1 }

$ffmpeg  = Join-Path $Workspace 'ffmpeg.exe'
$ffprobe = Join-Path $Workspace 'ffprobe.exe'

if (-not (Test-Path $ffmpeg))  { Fail "ffmpeg.exe not found at $ffmpeg" }
if (-not (Test-Path $ffprobe)) { Fail "ffprobe.exe not found at $ffprobe" }

function Assert-Version($bin, $banner) {
    $out = & $bin -version 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { Write-Host $out; Fail "$bin -version exited $LASTEXITCODE" }
    if ($out -notmatch [regex]::Escape($banner)) { Write-Host $out; Fail "missing '$banner' banner" }
    if ($out -notmatch [regex]::Escape($ExpectedVersion)) { Write-Host $out; Fail "expected version $ExpectedVersion not found" }
    Write-Host "✅ $(Split-Path $bin -Leaf) reports version $ExpectedVersion and exits 0"
}

Assert-Version $ffmpeg  'ffmpeg version'
Assert-Version $ffprobe 'ffprobe version'
Write-Host '✅ Smoke test passed.'
exit 0
```

- [ ] **Step 2: Validate the script parses**

Run (PowerShell):
```powershell
$null = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path tests/smoke.ps1), [ref]$null, [ref]$null); "parse ok"
```
Expected: prints `parse ok` with no parser errors.

- [ ] **Step 3: Commit**

```bash
git add tests/smoke.ps1
git commit -m "feat(ci): add minimal windows smoke gate"
```

---

## Task 6: main.yml — PR full build + smoke-test job

**Files:**
- Modify: `.github/workflows/main.yml`

- [ ] **Step 1: Force a full build on pull_request**

In `.github/workflows/main.yml`, change the `detect-changes` call so PRs rebuild everything (an RC must validate all platforms; this also sidesteps PR-diff detection). Replace:

```yaml
  detect-changes:
    uses: ./.github/workflows/detect-changes.yml
    with:
      force_rebuild: ${{ inputs.force_rebuild || false }}
```

with:

```yaml
  detect-changes:
    uses: ./.github/workflows/detect-changes.yml
    with:
      # A PR builds all platforms (it becomes the RC). Pushes to master keep
      # normal diff-based detection. workflow_dispatch honours its input.
      force_rebuild: ${{ inputs.force_rebuild || github.event_name == 'pull_request' }}
```

- [ ] **Step 2: Replace the `test-platforms` job with a minimal `smoke-test` job**

Replace the entire `test-platforms:` job (the block from `  test-platforms:` through the end of its `Run windows tests` step) with:

```yaml
  # ── Minimal smoke gate: binary runs, reports the expected version, exits 0 ──
  # The full codec/hardware suite (tests/tests.sh, tests/tests.ps1) is run
  # MANUALLY by a contributor on real hardware against the RC prerelease.
  smoke-test:
    needs: [detect-changes, export-artifacts]
    if: |
      always() && !cancelled()
      && needs.export-artifacts.result == 'success'
      && needs.detect-changes.outputs.platforms-to-build != '[]'
    strategy:
      fail-fast: false
      matrix: ${{ fromJSON(needs.detect-changes.outputs.test-matrix) }}
    runs-on: ${{ matrix.os }}
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Download build artifacts
        uses: actions/download-artifact@v4
        with:
          name: build-artifacts
          path: downloads/

      - name: Unpack binary
        shell: bash
        run: |
          archive="downloads/ffmpeg-${FFMPEG_VERSION}-${{ matrix.platform }}.${{ matrix.ext }}"
          if [[ ! -f "${archive}" ]]; then
            echo "❌ Expected artifact missing: ${archive}"
            ls -la downloads/ || true
            exit 1
          fi
          case "${{ matrix.ext }}" in
            tar.gz) tar -xzf "${archive}" ;;
            zip)    unzip -o "${archive}" ;;
          esac

      - name: Smoke test (unix)
        if: matrix.kind == 'unix'
        shell: bash
        run: |
          chmod +x tests/smoke.sh
          tests/smoke.sh "${GITHUB_WORKSPACE}" "${FFMPEG_VERSION}"

      - name: Smoke test (windows)
        if: matrix.kind == 'windows'
        shell: pwsh
        run: ./tests/smoke.ps1 -Workspace $env:GITHUB_WORKSPACE -ExpectedVersion $env:FFMPEG_VERSION
```

- [ ] **Step 3: Re-point the `release` job's dependency**

In the `release:` job, change:

```yaml
    needs: [detect-changes, export-artifacts, test-platforms]
```
to:
```yaml
    needs: [detect-changes, export-artifacts, smoke-test]
```
and in that job's `if:` change `needs.test-platforms.result == 'success'` to `needs.smoke-test.result == 'success'`.

- [ ] **Step 4: Validate with actionlint**

Run:
```bash
docker run --rm -v "$(pwd)":/repo --workdir /repo rhysd/actionlint:latest -color .github/workflows/main.yml
```
Expected: no errors (exit 0).

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/main.yml
git commit -m "feat(ci): PR full-build and replace tests with minimal smoke gate"
```

---

## Task 7: main.yml — publish RC prerelease on PRs

**Files:**
- Modify: `.github/workflows/main.yml`

- [ ] **Step 1: Add the `publish-rc` job**

Insert this job after `smoke-test` (and before `security-scan`):

```yaml
  # ── Publish/refresh the Release Candidate prerelease (PR only) ───────────
  # Gives contributors version-stamped binaries to test manually on each
  # platform. Deleted+recreated each run so assets and tag always match the
  # latest PR head. Promoted to a real release on master merge (see release).
  publish-rc:
    needs: [detect-changes, export-artifacts, smoke-test]
    if: |
      github.event_name == 'pull_request'
      && needs.export-artifacts.result == 'success'
      && needs.smoke-test.result == 'success'
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - name: Download build artifacts
        uses: actions/download-artifact@v4
        with:
          name: build-artifacts
          path: downloads/

      - name: Stage RC files with version-stamped names
        run: |
          set -euo pipefail
          mkdir -p release
          VERSION="${{ needs.detect-changes.outputs.version }}"
          for f in downloads/ffmpeg-${FFMPEG_VERSION}-*; do
            [[ -f "$f" ]] || continue
            base=$(basename "$f")
            case "$base" in
              *.tar.gz) stem="${base%.tar.gz}"; ext="tar.gz" ;;
              *)        stem="${base%.*}";     ext="${base##*.}" ;;
            esac
            cp "$f" "release/${stem}-${VERSION}-rc.${ext}"
          done
          ls -lh release/

      - name: Remove previous RC for a clean refresh
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          gh release delete "${{ needs.detect-changes.outputs.version }}-rc" \
            --repo "${GITHUB_REPOSITORY}" --cleanup-tag --yes 2>/dev/null || true

      - name: Publish RC prerelease
        uses: softprops/action-gh-release@v2
        with:
          tag_name: ${{ needs.detect-changes.outputs.version }}-rc
          name: Release Candidate ${{ needs.detect-changes.outputs.version }}-rc
          target_commitish: ${{ github.event.pull_request.head.sha }}
          draft: false
          prerelease: true
          files: release/*
          body: |
            # FFmpeg ${{ needs.detect-changes.outputs.version }} — Release Candidate

            **Not for production.** Built from PR #${{ github.event.pull_request.number }}
            (branch `${{ github.head_ref }}`).

            Download the binary for each platform and run the manual suite
            (`tests/tests.sh` / `tests/tests.ps1`) on real hardware, then tick the
            matching box in the PR checklist. All boxes must be checked before merge.
```

- [ ] **Step 2: Validate with actionlint**

Run:
```bash
docker run --rm -v "$(pwd)":/repo --workdir /repo rhysd/actionlint:latest -color .github/workflows/main.yml
```
Expected: no errors (exit 0).

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/main.yml
git commit -m "feat(ci): publish rolling RC prerelease on dev->master PRs"
```

---

## Task 8: main.yml — pr-build aggregator + final RC cleanup

**Files:**
- Modify: `.github/workflows/main.yml`

- [ ] **Step 1: Add the `pr-build` aggregator job**

Insert after `publish-rc`. This is the single `pr-build` required context for branch protection; it fails unless every build/export/smoke job succeeded.

```yaml
  # ── Single required status context for the PR build path ─────────────────
  # always() so it always reports; explicit result checks so any failed
  # dependency reliably fails the gate. PR-only (skipped on master pushes).
  pr-build:
    needs: [detect-changes, build-base, build-platforms, export-artifacts, smoke-test]
    if: always() && github.event_name == 'pull_request'
    runs-on: ubuntu-latest
    steps:
      - name: Verify the PR build path is green
        run: |
          base='${{ needs.build-base.result }}'
          platforms='${{ needs.build-platforms.result }}'
          export='${{ needs.export-artifacts.result }}'
          smoke='${{ needs.smoke-test.result }}'
          echo "base=$base platforms=$platforms export=$export smoke=$smoke"
          # On a PR we force a full build, so build-base must succeed.
          if [[ "$base" != "success" ]]; then echo "❌ build-base: $base"; exit 1; fi
          if [[ "$platforms" != "success" ]]; then echo "❌ build-platforms: $platforms"; exit 1; fi
          if [[ "$export" != "success" ]]; then echo "❌ export-artifacts: $export"; exit 1; fi
          if [[ "$smoke" != "success" ]]; then echo "❌ smoke-test: $smoke"; exit 1; fi
          echo "✅ PR build path passed."
```

- [ ] **Step 2: Delete the RC when the final release is cut**

In the `release:` job (master push), add this step immediately after `Create release`:

```yaml
      - name: Delete the promoted RC prerelease
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          gh release delete "${{ needs.detect-changes.outputs.version }}-rc" \
            --repo "${GITHUB_REPOSITORY}" --cleanup-tag --yes 2>/dev/null || true
          echo "🧹 Removed RC ${{ needs.detect-changes.outputs.version }}-rc (promoted to final)."
```

- [ ] **Step 3: Validate with actionlint**

Run:
```bash
docker run --rm -v "$(pwd)":/repo --workdir /repo rhysd/actionlint:latest -color .github/workflows/main.yml
```
Expected: no errors (exit 0).

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/main.yml
git commit -m "feat(ci): add pr-build required gate and final RC cleanup"
```

---

## Task 9: Branch-protection setup script

**Files:**
- Create: `scripts/setup-branch-protection.sh`

- [ ] **Step 1: Write the script**

Create `scripts/setup-branch-protection.sh`:

```bash
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
```

- [ ] **Step 2: Syntax-check and dry-run**

Run (Bash tool):
```bash
bash -n scripts/setup-branch-protection.sh && DRY_RUN=true APPROVALS=1 bash scripts/setup-branch-protection.sh
```
Expected: no syntax error; prints the protection JSON with `"required_approving_review_count": 1` and `"contexts": ["pr-validation","pr-build"]`; exit 0. (No live API call.)

- [ ] **Step 3: Commit**

```bash
git add scripts/setup-branch-protection.sh
git commit -m "feat(ci): add idempotent branch-protection setup script"
```

---

## Task 10: Documentation

**Files:**
- Create: `docs/branch-protection-setup.md`
- Create: `CONTRIBUTING.md`

- [ ] **Step 1: Write `docs/branch-protection-setup.md`**

```markdown
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
REPO=NoMercy-Entertainment/nomercy-ffmpeg APPROVALS=1 ./scripts/setup-branch-protection.sh
# Preview without applying:
DRY_RUN=true ./scripts/setup-branch-protection.sh
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
```

- [ ] **Step 2: Write `CONTRIBUTING.md`**

```markdown
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
```

- [ ] **Step 3: Commit**

```bash
git add docs/branch-protection-setup.md CONTRIBUTING.md
git commit -m "docs: document dev->PR->master flow and branch-protection setup"
```

---

## Task 11: Full validation + rollout

**Files:** none (verification only)

- [ ] **Step 1: Lint every workflow**

Run:
```bash
docker run --rm -v "$(pwd)":/repo --workdir /repo rhysd/actionlint:latest -color
```
Expected: no errors across all workflows (exit 0).

- [ ] **Step 2: Re-run all unit tests**

Run:
```bash
node .github/scripts/check-checklist.test.js && bash tests/smoke.test.sh
```
Expected: `all checklist parser tests passed` and `passed=4 failed=0`.

- [ ] **Step 3: Rollout (requires maintainer/admin actions — document, do not force)**

1. Merge this `dev` work to `master` once (master not yet protected) so the workflows exist there.
2. Open a test PR `dev → master`; confirm `pr-guards` runs (checklist fails while boxes are
   unticked), `main.yml` builds all platforms and publishes `vX.Y.Z-rc`.
3. Tick the checklist boxes; confirm `pr-validation` flips to success.
4. A repo admin runs `scripts/setup-branch-protection.sh` (or the UI steps).
5. Verify a direct push to `master` is rejected and a non-`dev` PR fails `guard-source-branch`.

- [ ] **Step 4: Final commit (if any doc tweaks from rollout)**

```bash
git add -A
git commit -m "docs: rollout notes for gated release flow" || echo "nothing to commit"
```

---

## Self-review notes

- **Spec coverage:** Section 1 → Tasks 9/10; Section 2 → Tasks 3/6/7/8; Section 3 → Tasks 7/8;
  Section 4 → Tasks 4/5/6; Section 5 → Tasks 1/2/3; Section 6 → Tasks 9/10. All covered.
- **Required-context name consistency:** `pr-validation` (Task 3) and `pr-build` (Task 8) are used
  identically in the setup script (Task 9) and docs (Task 10).
- **detect-changes.yml** stays untouched: PR full-build rides the existing `force_rebuild` input.
- **Known assumption:** one active `dev → master` PR at a time (RC version derivation), per the spec.
```
