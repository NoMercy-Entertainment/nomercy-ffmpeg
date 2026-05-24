"""
Consolidate the ~50 download-only RUN steps in ffmpeg-base.dockerfile
into one RUN block. Reduces image layer count drastically so the runner's
fuse-overlayfs storage driver doesn't crash dockerd at image-finalize.

Boundaries are detected by literal anchor strings, not line numbers, so
the script is safe to re-run if the file shifts.

Run from the repo root: python scripts/consolidate_downloads.py
"""

from __future__ import annotations

import re
import sys
from pathlib import Path


DOCKERFILE = Path("ffmpeg-base.dockerfile")
START_ANCHOR = "# Download iconv\n"
END_ANCHOR_MARKER = "RUN mkdir -p /output\n"


def main() -> int:
    text = DOCKERFILE.read_text(encoding="utf-8")

    start = text.find(START_ANCHOR)
    if start == -1:
        print(f"ERROR: could not find start anchor {START_ANCHOR!r}", file=sys.stderr)
        return 1

    end = text.find(END_ANCHOR_MARKER, start)
    if end == -1:
        print(f"ERROR: could not find end anchor {END_ANCHOR_MARKER!r}", file=sys.stderr)
        return 1

    section = text[start:end]

    # Match each RUN block: starts with "RUN \\\n", continues until the
    # next blank line OR the next "# Download" comment OR end of section.
    run_blocks = re.findall(
        r"^RUN\s*\\?\n((?:[ \t]+.*\n)+)",
        section,
        flags=re.MULTILINE,
    )

    if not run_blocks:
        print("ERROR: no RUN blocks matched", file=sys.stderr)
        return 1

    print(f"Found {len(run_blocks)} RUN blocks to consolidate")

    # For each block, strip the leading whitespace and outer continuations,
    # extract the shell commands. Each block's body is a chain of
    # "    && cmd \\" lines plus a leading "    echo ..." or "    && cmd"
    # without leading &&.

    commands: list[str] = []
    for block in run_blocks:
        # Strip Dockerfile comment lines (start with #) before joining;
        # they were ignored by Docker as separate-line comments, but if we
        # leave them in after collapsing line continuations they become
        # inline shell comments and swallow the rest of the chain.
        raw_lines = block.splitlines()
        kept = []
        for line in raw_lines:
            stripped = line.strip()
            if stripped.startswith("#"):
                continue  # Dockerfile-level comment, drop
            kept.append(line)
        block_no_comments = "\n".join(kept) + "\n"

        # Collapse line continuations
        joined = block_no_comments.replace("\\\n", " ")
        # Split on && (top-level — none of these libs use && inside quotes)
        parts = [p.strip() for p in joined.split("&&")]
        parts = [p for p in parts if p]
        commands.extend(parts)

    # Build the consolidated RUN: same commands, joined with " \\\n    && ".
    # Wrap any `cd X && ... && cd ..` style sequences as subshells so
    # they don't leak directory state. The openssl block is the only
    # one that does cd, so handle it generically: any command starting
    # with "cd " becomes "(cd ..." and the next " cd .." closes it.

    # Detect cd-into followed by cd-out patterns and wrap them.
    # Easier: rebuild with explicit (cd dir && ...) using a state machine.
    rebuilt: list[str] = []
    i = 0
    while i < len(commands):
        cmd = commands[i]
        if cmd.startswith("cd ") and not cmd.startswith("cd .."):
            # Start of a directory-scoped block. Collect until we hit "cd .."
            target_dir = cmd[3:].split()[0]
            inner: list[str] = []
            i += 1
            while i < len(commands) and commands[i] != "cd ..":
                inner.append(commands[i])
                i += 1
            # Skip the "cd .." itself
            if i < len(commands) and commands[i] == "cd ..":
                i += 1
            inner_chain = " && ".join(inner)
            rebuilt.append(f"(cd {target_dir} && {inner_chain})")
            continue
        rebuilt.append(cmd)
        i += 1

    # Build the new RUN block
    new_run_lines = ["RUN \\\n"]
    for idx, cmd in enumerate(rebuilt):
        prefix = "    " if idx == 0 else "    && "
        new_run_lines.append(f"{prefix}{cmd} \\\n")
    # Replace trailing " \\\n" with "\n" on the last entry
    new_run_lines[-1] = new_run_lines[-1].rstrip(" \\\n") + "\n"

    consolidated = (
        "# All library sources downloaded in one RUN to keep the layer\n"
        "# count low — the host's fuse-overlayfs storage driver crashes\n"
        "# dockerd at image-finalize when there are ~50+ download layers.\n"
        + "".join(new_run_lines)
        + "\n"
    )

    new_text = text[:start] + consolidated + text[end:]
    DOCKERFILE.write_text(new_text, encoding="utf-8")
    print(
        f"Rewrote {DOCKERFILE}: {len(run_blocks)} RUN blocks "
        f"-> 1 RUN with {len(rebuilt)} chained commands"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
