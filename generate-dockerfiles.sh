#!/bin/bash
# ──────────────────────────────────────────────────────────────
# generate-dockerfiles.sh — Generate per-script-layer Dockerfiles
#
# Reads each existing platform Dockerfile, preserves the platform
# setup (header) and FFmpeg build/package (footer), and replaces
# the monolithic "COPY scripts + RUN init.sh" with individual
# COPY+RUN pairs per build script.
#
# Layer strategy:
#   - Init helpers at the top (rarely change)
#   - Platform 00-scripts with only the resources they need
#   - Scripts 01-48 as individual layers
#   - C source files + resources right before scripts 49+ that use them
#   - Scripts 49-55 (custom FFmpeg patches)
#
# Result: changing spritevttenc.c only rebuilds 49-55 + FFmpeg,
# not the entire dependency chain.
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

# ── Collect C source files from includes ──────────────────────
mapfile -t C_SOURCES < <(ls scripts/includes/*.c 2>/dev/null | sort | xargs -I{} basename {})
echo "Found ${#C_SOURCES[@]} C source files"

# ── Extract header from a Dockerfile ─────────────────────────
extract_header() {
    local file="$1"
    # Stop at either the original marker or the generated marker
    awk '/^# Copy the build scripts$/{exit} /^# ═{3,}/{exit} {print}' "$file"
}

# ── Extract footer from a Dockerfile ─────────────────────────
extract_footer() {
    local file="$1"
    awk '/^# Copy the dev scripts$/{found=1} found{print}' "$file"
}

# ── Map C source files to the scripts that use them ──────────
# Each C file is copied right before the script that needs it.
# Changing one C file only invalidates that script + later ones.
declare -A C_FILE_FOR_SCRIPT=(
    [49-beatdetect.sh]="af_beatdetect.c"
    [51-vobsub-muxer.sh]="vobsubenc.c"
    [52-ocr-subtitle-encoder.sh]="ocr_subtitle_enc.c"
    [53-sprite-sheet-muxer.sh]="spritevttenc.c"
    [54-chapter-vtt-muxer.sh]="chaptervttenc.c"
)

# ── Map resource files to scripts that use them ──────────────
declare -A RESOURCE_FOR_SCRIPT=(
    [00-rcinfo.sh]="fftools.ico"
)

# ── Generate per-script build section ─────────────────────────
generate_build_steps() {
    local os="$1"  # linux, windows, darwin

    cat <<'BLOCK'

# ══════════════════════════════════════════════════════════════
# Per-dependency cached build layers
#
# Every file is copied individually, right before the script
# that uses it. Changing one file only invalidates that script
# and everything after it — nothing before is affected.
# ══════════════════════════════════════════════════════════════

# ── Build infrastructure (helpers only) ──────────────────────
COPY ./scripts/init/ /scripts/init/
RUN find /scripts -type f -name "*.sh" -exec sed -i 's/\r$//' {} + \
    && chmod +x /scripts/init/*.sh \
    && mkdir -p ${PREFIX}/lib ${PREFIX}/lib/pkgconfig ${PREFIX}/include ${PREFIX}/bin \
    && touch /build/enable.txt /build/cflags.txt /build/ldflags.txt /build/extra_libflags.txt

BLOCK

    # Platform-specific 00-scripts with their individual dependencies
    if [ "$os" = "darwin" ]; then
        cat <<'BLOCK'
COPY ./scripts/includes/darwin/00-platformversion.sh /scripts/00-platformversion.sh
RUN /scripts/init/run-step.sh 00-platformversion.sh

BLOCK
    elif [ "$os" = "windows" ]; then
        cat <<'BLOCK'
COPY ./scripts/includes/windows/00-rcinfo.sh /scripts/00-rcinfo.sh
COPY ./scripts/resources/fftools.ico /scripts/resources/fftools.ico
RUN /scripts/init/run-step.sh 00-rcinfo.sh

BLOCK
    fi

    # Per-script layers
    for script in "${SCRIPTS[@]}"; do
        local src="./scripts/${script}"

        # Windows: insert openblas before whisper
        if [ "$os" = "windows" ] && [ "$script" = "48-whisper.sh" ]; then
            echo "COPY ./scripts/includes/windows/48-openblas.sh /scripts/48-openblas.sh"
            echo "RUN /scripts/init/run-step.sh 48-openblas.sh"
            echo ""
        fi

        # Darwin: use platform-specific librsvg
        if [ "$os" = "darwin" ] && [ "$script" = "50-librsvg.sh" ]; then
            src="./scripts/includes/darwin/50-librsvg.sh"
        fi

        # Copy the C source file this script needs (if any)
        if [[ -n "${C_FILE_FOR_SCRIPT[$script]+x}" ]]; then
            echo "COPY ./scripts/includes/${C_FILE_FOR_SCRIPT[$script]} /scripts/includes/${C_FILE_FOR_SCRIPT[$script]}"
        fi

        echo "COPY ${src} /scripts/${script}"
        echo "RUN /scripts/init/run-step.sh ${script}"
        echo ""
    done
}

# ── Process each Dockerfile ──────────────────────────────────

process_dockerfile() {
    local platform="$1"
    local dockerfile="$2"

    if [ ! -f "$dockerfile" ]; then
        echo "⚠️  Skipping ${platform}: ${dockerfile} not found"
        return
    fi

    local os="${platform%%-*}"

    echo "Generating ${dockerfile} (${os})..."

    local outfile="${dockerfile}.new"

    extract_header "$dockerfile"       >  "$outfile"
    generate_build_steps "$os"         >> "$outfile"
    extract_footer "$dockerfile"       >> "$outfile"

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
echo "Layer strategy:"
echo "  init/ helpers → 00-scripts → 01-48 deps → C sources → 49-55 custom"
echo "  Changing a .c file only rebuilds 49-55 + FFmpeg, not 01-48"
