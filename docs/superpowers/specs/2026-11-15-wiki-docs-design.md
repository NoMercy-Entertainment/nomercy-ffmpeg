# Documentation on the GitHub Wiki — design

Date: 2026-11-15. Owner decisions are marked **(owner)**; my calls are marked **(call)**.

## Intent

`README.md` is 1461 lines. About 1000 of them document individual filters
(stemsplit alone ~400, GPU/Metal ~300), with CI, local builds, configuration and
licensing mixed in between. Someone who wants "what is this and how do I get it"
has to scroll through pages of filter detail, and the contributor side is thin and
partly wrong (`CONTRIBUTING.md` still says six platforms, says smoke only checks
the version, and points at a backup branch that is not part of the branch model).

The owner wants: **every component in its own file, fully worked out there, and
every component listed in the README with a link** **(owner)**. Audience: users
**and contributors, including external ones** **(owner)**.

## Goals

- A short README that is an overview: what this is, download, quick start, and a
  list of **every** component, each with one line and a link to its page.
- One GitHub Wiki page per component, complete enough that nobody needs the old
  README for it.
- Contributor documentation an outside contributor can act on: how the build is
  put together, how to build and test locally, how to add or bump a library, how a
  release travels.
- The Wiki describes **the latest release on master**, always **(owner)**.

## Non-goals

- No docs website (MkDocs/Pages) and no restyling of `UPDATE.md`.
- No changes to filters, scripts, tests or workflows. Documentation only.
- Internal infrastructure is not documented: the Forgejo mirror, the owner's
  self-hosted fleet by name, tokens, the WSL/host specifics. Contributors read
  "release candidates are verified on real hardware by the project's self-hosted
  runners" and nothing more specific **(owner: external audience)**.

## Anti-goals (failure even if it "works")

- **Losing a fact.** Every statement in today's README must land on a page or be
  dropped on purpose as stale. A mapping table (below) is the checklist.
- **Copying stale claims.** Several README statements are already wrong (examples
  under Accuracy). Moving them to the Wiki unchecked would bless them.
- **A Wiki that describes unreleased behaviour.** Users download releases.
- **A Wiki anyone can edit.** The repo is public; default Wiki permissions let
  every GitHub user edit.

## Approaches considered

| | What | Trade-off |
|---|---|---|
| A | Markdown in the repo: short README + `docs/` | Versioned with the code, reviewable in PRs; the owner did not pick it |
| **B** | **GitHub Wiki** | **Picked (owner).** Separate pages, easy navigation and editing; not tied to PRs or releases, so it needs an update rule (below) |
| C | Docs site (MkDocs on Pages) | Best navigation/search; adds a workflow and upkeep |

## What lives where

**Wiki** (`github.com/NoMercy-Entertainment/nomercy-ffmpeg.wiki.git`, its own git
repo; page = file name, `-` for spaces):

| Page | Content (source in today's README unless noted) |
|---|---|
| `Home` | What this is, who it is for, where to go next |
| `_Sidebar` | Every page, grouped Users / Filters / Contributors |
| `Installation` | Release archives, naming (`ffmpeg-9.0-<platform>`, 9.0.2 inside), `.sha256`, `manifest.json` (+ signature if the release really ships one), macOS signing |
| `Platforms` | Platform table, per-platform runtime notes, Linux x86_64 glibc 2.35 floor, Windows ARM64 notes, FreeBSD baseline |
| `npm-Package` | `@nomercy-entertainment/ffmpeg-static` usage (summary; the package README stays the source) |
| `Filter-stemsplit` | Spleeter + RoFormer, presets, options, `use_gpu`, `cpu_fallback`, `cpu_assist`, model files |
| `Filter-lyricsalign` | Usage, options (incl. `soft_walkback`, `unheard_island`), output format, assets |
| `Whisper-Language-Detection` | Our patch: `lavfi.whisper.language(_confidence)`, `detected_language` in JSON |
| `Whisper-Word-Timestamps` | Our patch: per-word times (DTW or token timing), prompt (inline or file), beam search |
| `Filter-trailingsilence` | Measure-then-cut workflow, metadata, JSON, `destination=-` |
| `Filter-keydetect` | Key and chord detection |
| `Filter-beatdetect` | Tempo, beat grid, confidence |
| `Muxer-Sprite-Sheet` | Thumbnail sprite sheets with a WebVTT timeline (spritevtt) |
| `Muxer-Chapter-VTT` | Chapter metadata as WebVTT |
| `Muxer-VOBsub` | DVD-style VOBsub output |
| `Protocol-dvdread` | `dvdread://` input over libdvdread |
| `Protocol-OmniDrive` | OmniDrive storage I/O (platforms it exists on) |
| `Auto-Create-Directories` | Output muxers create missing parent directories |
| `AACS-and-BDplus` | libaacs/libbluray with the built-in keydb |
| `HLS-Master-Playlist` | The HLS muxer extensions (FRAME-RATE, VIDEO-RANGE, aname/autoselect/…) |
| `Subtitles-OCR` | Tesseract bitmap-to-WebVTT encoder |
| `HEVC-Alpha` | What remains ours on 9.0 |
| `License` | Today's licence text, unchanged (MIT for the repo; binaries built `--enable-gpl --enable-nonfree`) |
| `GPU-Acceleration` | Vulkan for whisper/stemsplit, device checks, env vars, the F32 note |
| `Metal` | Apple Silicon path, what runs on Metal and what does not |
| `CPU-Instruction-Sets` | ggml CPU dispatcher, `NOMERCY_GGML_CPU` |
| `Codecs-and-Libraries` | Everything vs official FFmpeg: audio, video, disc, hardware per platform, limitations, configure summary |
| `Security` | Trivy, digests, pinned versions, link to `docs/security/known-unfixed.md` on master |
| `Contributing` | Route for outside contributors: **open an issue first; a PR only after the proposal is agreed** **(owner)**. Then fork → PR into `dev`; fork PRs get no CI (CI runs on PRs into master and skips forks on self-hosted runners), so maintainers build and test before merging. What a good PR has, code style |
| `Architecture` | Base image → platform dockerfiles → `init.sh` → `scripts/NN-*.sh`; `scripts/includes/` (patches and **whole-file FFmpeg copies**, and why their upstream SHA-256 is checked); `fetch-pinned` |
| `Building-Locally` | Base + one platform with Docker/compose, output, times, disk (replaces `actions.md`) |
| `Adding-or-Updating-a-Library` | Pin + digest, where the script goes, platform differences, the traps we hit (wrap fallbacks, line-number seds, whole-file copies) |
| `Testing` | `smoke.sh/ps1`, `tests.sh/ps1`, unit tests, asset scripts, cross-arch header-only smoke, `*_TEST_REQUIRED` |
| `CI-and-Releases` | Workflows, PR → RC → Verify RC → checklist → squash merge → release → npm; what each check means |

**One page per component, never several components on one page** (owner's words);
a long page may get sub-pages **(call)**. The README lists every NoMercy-only
component on its own line; the bundled libraries (fdk-aac, the AV1 stack, libjxl, …)
are one grouped line linking to `Codecs-and-Libraries` **(call)**.

**Version history (call):** pages describe the latest release; "since vX.Y" markers
stay where behaviour changed (npm and MediaServer users can pin older releases);
internals of past releases (the 8.1.x backports, old defaults beyond one line) go.

**Verification (call):** claims are checked against the scripts, workflows and the
green v1.0.47 Verify RC run. No new hardware runs. A claim that cannot be shown is
dropped or marked as unverified on the page.

**Leftover README sections (call):** "NoMercy MediaServer" becomes two lines on
`Installation` (it consumes the releases and checks digests); a claim of a *signed*
manifest stays only if the release ships a signature. "About NoMercy Entertainment"
and the contact line stay as a short README footer.

**Mapping table (call):** the first deliverable is a table of every README section →
page, with a "dropped as stale" column and the reason. It is shown to the owner with
the pages at the final review, not as a separate gate.

**Repo:**
- `README.md`: badges, two-paragraph intro, download + 3-line quick start,
  platform one-liner, then **the full component list, one line + Wiki link each**,
  then links to Contributing, Security, License. Target ≤ 200 lines **(call)**.
- `CONTRIBUTING.md`: stays (GitHub shows it on new PRs); short, correct, links to
  the Wiki contributor pages. Stale lines removed (six platforms, smoke claim,
  backup branch) **(call)**.
- `actions.md`: content moves to `Building-Locally`; the file is removed **(call)**.
- `UPDATE.md`, `docs/security/known-unfixed.md`: stay in the repo; they belong to
  each release **(call)**.
- `clients/npm/README.md:82` links to `README.md#linux-x86_64-requirements`; it
  points to the `Platforms` Wiki page instead **(call)**.
- Language: English, like the repo. Short sentences, one idea per sentence, tables
  for options; the owner is dyslexic and outside readers skim **(call)**.

## Keeping the Wiki on the latest release (owner)

- **Today:** dev and master are identical (v1.0.47, 7fca656), so the Wiki is
  written from the current tree and is correct for the latest release at once.
- **From now on:** a change on dev does **not** touch the Wiki. At release time,
  after the release run is green, the Wiki pages for what the release changed
  (read from its `UPDATE.md` entry) are updated. This step is added to
  `CI-and-Releases` and to my release routine.
- The README on dev links to Wiki pages by name; it reaches master's front page
  with the next release (no docs-only release, per the no-pointless-releases rule).
  Until then master's front page keeps the long v1.0.47 README, which is correct
  for v1.0.47, so nothing is wrong in between.

## Accuracy pass

Every claim is checked against the scripts, workflows and the v1.0.47 binaries
before it goes on a page. Already seen as stale in today's README:
- the CI diagram still has a separate "Linux x86_64 hardware" job;
- "every master build publishes a Release Candidate" (RCs come from the dev→master PR);
- "JPEG XL, HAP and APV … ship with the first release after v1.0.45" (they shipped);
- `manifest.json.sig` / GPG signature: to be checked against the v1.0.47 assets
  (the release lists `manifest.json` and `.sha256` files only);
- version numbers in the configure summary and library tables.

## Setup steps

1. Wiki enabled via the API (done, 2026-11-15).
2. Owner created the first page (the wiki repo exists, branch `master`) and
   "Restrict editing to users in teams with push access only" is on (done).
3. I write all pages locally in a clone of the wiki repo and the README /
   CONTRIBUTING changes on dev.
4. The owner reviews; the Wiki push and the dev commit happen on the owner's say-so.

## Left to the builder

Page wording and order inside a page; whether a long page (stemsplit) gets
sub-pages; examples kept or trimmed as long as each option keeps one example.
