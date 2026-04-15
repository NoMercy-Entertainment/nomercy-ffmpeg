#!/bin/bash
# ──────────────────────────────────────────────────────────────
# generate-dockerfiles.sh — Generate per-script-layer Dockerfiles
#
# Reads each existing platform Dockerfile, preserves the platform
# setup (header) and FFmpeg build/package (footer), and replaces
# the monolithic "COPY scripts + RUN init.sh" with individual
# COPY+RUN pairs per build script.
#
# This enables Docker layer caching per dependency:
#   - Change script 53 → only scripts 53-55 + FFmpeg rebuild
#   - Scripts 01-52 remain cached
#
# Usage: bash generate-dockerfiles.sh
# ──────────────────────────────────────────────────────────────

set -euo pipefail
cd "$(dirname "$0")"

# ── Collect the ordered list of build scripts ─────────────────
mapfile -t SCRIPTS < <(ls scripts/*.sh 2>/dev/null | sort | xargs -I{} basename {})

if [ ${#SCRIPTS[@]} -eq 0 ]; then
    echo "❌ No build scripts found in scripts/"
    exit 1
fi

echo "Found ${#SCRIPTS[@]} build scripts"

# ── Extract header from a Dockerfile ─────────────────────────
# Everything before the line "# Copy the build scripts"
extract_header() {
    local file="$1"
    awk '/^# Copy the build scripts$/{exit} {print}' "$file"
}

# ── Extract footer from a Dockerfile ─────────────────────────
# Everything from "# Copy the dev scripts" to end of file
extract_footer() {
    local file="$1"
    awk '/^# Copy the dev scripts$/{found=1} found{print}' "$file"
}

# ── Generate per-script build section ─────────────────────────
generate_build_steps() {
    local os="$1"  # linux, windows, darwin

    # Infrastructure: init scripts, includes, C sources
    cat <<'BLOCK'

# ══════════════════════════════════════════════════════════════
# Per-dependency cached build layers
#
# Each script gets its own COPY+RUN so Docker can cache individual
# dependency builds. Changing one script only invalidates that
# layer and everything after it — earlier deps stay cached.
# ══════════════════════════════════════════════════════════════

# ── Build infrastructure (helpers, platform includes, C sources)
COPY ./scripts/init/ /scripts/init/
COPY ./scripts/includes/ /scripts/includes/
RUN find /scripts -type f -name "*.sh" -exec sed -i 's/\r$//' {} + \
    && chmod +x /scripts/init/*.sh \
    && mkdir -p ${PREFIX}/lib ${PREFIX}/lib/pkgconfig ${PREFIX}/include ${PREFIX}/bin \
    && touch /build/enable.txt /build/cflags.txt /build/ldflags.txt /build/extra_libflags.txt

BLOCK

    # Platform-specific 00-scripts (run before numbered scripts)
    if [ "$os" = "darwin" ]; then
        cat <<'BLOCK'
# ── Darwin: platform version helper ──────────────────────────
COPY ./scripts/includes/darwin/00-platformversion.sh /scripts/00-platformversion.sh
RUN /scripts/init/run-step.sh 00-platformversion.sh

BLOCK
    elif [ "$os" = "windows" ]; then
        cat <<'BLOCK'
# ── Windows: resource info ───────────────────────────────────
COPY ./scripts/includes/windows/00-rcinfo.sh /scripts/00-rcinfo.sh
RUN /scripts/init/run-step.sh 00-rcinfo.sh

BLOCK
    fi

    # Per-script layers
    echo "# ── Dependency build steps ─────────────────────────────────"
    for script in "${SCRIPTS[@]}"; do
        local src="./scripts/${script}"

        # Windows: insert openblas before whisper (same number group)
        if [ "$os" = "windows" ] && [ "$script" = "48-whisper.sh" ]; then
            echo ""
            echo "# Windows: OpenBLAS for Whisper acceleration"
            echo "COPY ./scripts/includes/windows/48-openblas.sh /scripts/48-openblas.sh"
            echo "RUN /scripts/init/run-step.sh 48-openblas.sh"
        fi

        # Darwin: use platform-specific librsvg
        if [ "$os" = "darwin" ] && [ "$script" = "50-librsvg.sh" ]; then
            src="./scripts/includes/darwin/50-librsvg.sh"
            echo ""
            echo "# Darwin: platform-specific librsvg (replaces default)"
            echo "COPY ${src} /scripts/${script}"
            echo "RUN /scripts/init/run-step.sh ${script}"
            continue
        fi

        echo ""
        echo "COPY ${src} /scripts/${script}"
        echo "RUN /scripts/init/run-step.sh ${script}"
    done
    echo ""
}

# ── Process each Dockerfile ──────────────────────────────────

process_dockerfile() {
    local platform="$1"
    local dockerfile="$2"

    if [ ! -f "$dockerfile" ]; then
        echo "⚠️  Skipping ${platform}: ${dockerfile} not found"
        return
    fi

    # Determine OS from platform name
    local os="${platform%%-*}"

    echo "Generating ${dockerfile} (${os})..."

    local outfile="${dockerfile}.new"

    # Combine: header + per-script layers + footer
    extract_header "$dockerfile"       >  "$outfile"
    generate_build_steps "$os"         >> "$outfile"
    extract_footer "$dockerfile"       >> "$outfile"

    # Replace original with generated version
    mv "$outfile" "$dockerfile"
    echo "✅ ${dockerfile}"
}

# ── Run for all platforms ─────────────────────────────────────

process_dockerfile "linux-x86_64"   "ffmpeg-linux-x86_64.dockerfile"
process_dockerfile "linux-aarch64"  "ffmpeg-linux-aarch64.dockerfile"
process_dockerfile "windows-x86_64" "ffmpeg-windows-x86_64.dockerfile"
process_dockerfile "darwin-x86_64"  "ffmpeg-darwin-x86_64.dockerfile"
process_dockerfile "darwin-arm64"   "ffmpeg-darwin-arm64.dockerfile"

echo ""
echo "All Dockerfiles updated with per-script caching layers."
echo ""
echo "To test locally:"
echo "  docker buildx build -f ffmpeg-linux-x86_64.dockerfile --progress=plain ."
echo ""
echo "To verify caching:"
echo "  1. Build once (cold build)"
echo "  2. Change a late script (e.g. scripts/53-sprite-sheet-muxer.sh)"
echo "  3. Rebuild — scripts 01-52 show CACHED, only 53+ rebuild"
