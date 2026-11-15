# Contributing

The full guide is in the Wiki: [Contributing](https://github.com/NoMercy-Entertainment/nomercy-ffmpeg/wiki/Contributing). This file is the short version.

## The route

1. Open an issue first. Say what you want to change and why.
2. Wait until a maintainer agrees to the proposal. A PR that was never agreed may be closed.
3. Fork the repository and branch from `dev`.
4. Open the PR into `dev` and link the issue.
5. A maintainer builds and tests it, then merges it into `dev`.

## Branches

Only `master` and `dev` exist in this repository. Do not push other branches here. Work in your fork.

- `dev` is where changes land.
- `master` is the latest release. It only receives a PR from `dev`, opened by a maintainer.

## No CI on fork PRs

The build jobs run on the project's self-hosted runners and skip PRs from forks. A maintainer builds all platforms and runs the tests before merging. Say in your PR what you tested yourself.

## Commit messages

Use `type(scope): short description`.

## More

| Page | What it covers |
|---|---|
| [Contributing](https://github.com/NoMercy-Entertainment/nomercy-ffmpeg/wiki/Contributing) | The route and what a good PR has |
| [Architecture](https://github.com/NoMercy-Entertainment/nomercy-ffmpeg/wiki/Architecture) | How the build is laid out |
| [Building-Locally](https://github.com/NoMercy-Entertainment/nomercy-ffmpeg/wiki/Building-Locally) | Build one platform on your machine |
| [Adding-or-Updating-a-Library](https://github.com/NoMercy-Entertainment/nomercy-ffmpeg/wiki/Adding-or-Updating-a-Library) | Change a bundled library or a patch |
| [Testing](https://github.com/NoMercy-Entertainment/nomercy-ffmpeg/wiki/Testing) | The test scripts and what each one checks |
| [CI-and-Releases](https://github.com/NoMercy-Entertainment/nomercy-ffmpeg/wiki/CI-and-Releases) | What happens after a PR is merged |
