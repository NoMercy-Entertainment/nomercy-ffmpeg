#!/bin/bash

if [[ ${TARGET_OS} == "darwin" ]]; then
	exit 255
fi

cd /build

# The newest release when there is one, otherwise the default branch. This is
# the owner's own repository, and the rule for those is "always the latest" --
# the same rule 49-beatdetect.sh, 57-keydetect.sh and 60-stemsplit.sh follow --
# so it is deliberately not pinned to a fixed commit, even though the October
# 2026 audit (AUD-9125) asked for one. omnidrive has no release yet, so today
# this builds the default branch exactly as before; the first release makes it
# reproducible per release without touching this script again.
#
# Whatever is built, its commit goes into the log, so a build can always be
# traced to the exact source it used even while there is no tag to pin.
omnidrive_repo=https://forgejo.phillippepelzer.me/FiLL/omnidrive.git
omnidrive_api=https://forgejo.phillippepelzer.me/api/v1/repos/FiLL/omnidrive
#
# CI resolves the ref once per run -- the newest release tag, or the default
# branch's commit while there is none -- and passes it in as OMNIDRIVE_REF,
# for the same two reasons as the filter scripts: every platform builds the
# same source, and a new commit reruns init.sh instead of replaying the
# previous clone from the build cache. A local build passes nothing.
omnidrive_tag=""
if [ -z "${OMNIDRIVE_REF}" ]; then
    omnidrive_tag=$(curl -fsSL --retry 3 --max-time 60 "${omnidrive_api}/releases/latest" 2>/dev/null \
        | sed -n 's/.*"tag_name" *: *"\([^"]*\)".*/\1/p')
fi
if [ -n "${OMNIDRIVE_REF}" ]; then
    log "omnidrive: ${OMNIDRIVE_REF}, chosen once for this build run"
    git clone "${omnidrive_repo}" || exit 1
    git -C /build/omnidrive checkout --quiet "${OMNIDRIVE_REF}" || exit 1
elif [ -n "${omnidrive_tag}" ]; then
    log "omnidrive: newest release ${omnidrive_tag}"
    git clone --branch "${omnidrive_tag}" "${omnidrive_repo}" || exit 1
else
    log "omnidrive: no release published yet -- building the default branch"
    git clone "${omnidrive_repo}" || exit 1
fi
log "omnidrive: building commit $(git -C /build/omnidrive rev-parse HEAD)"

cd /build/omnidrive

cmake -S libomnidrive -B libomnidrive/build ${CMAKE_COMMON_ARG} 2>&1 | log
if [ ${PIPESTATUS[0]} -ne 0 ]; then
	exit 1
fi
cmake --build libomnidrive/build || exit 1
cmake --install libomnidrive/build || exit 1

cp ./ffmpeg-integration/omnidrive.c /build/ffmpeg/libavformat/omnidrive.c || exit 1

# Each sed below is followed by a check for the text only that edit can
# produce. A sed whose anchor is gone succeeds and changes nothing, and the
# protocol then silently fails to link -- the dead-anchor fault this repository
# has hit before. All five checks were validated against FFmpeg 9.0: they pass
# on the real files and fail when their anchor is removed.
omnidrive_edit_applied() {   # omnidrive_edit_applied <what> <grep-flags> <text> <file>
    grep $2 -- "$3" "$4" || { log "omnidrive: the $1 edit did not apply to $4"; exit 1; }
}

# 3. Four edits
# 3a. libavformat/Makefile
# Add the object after the UDP protocol object. Anchored loosely on the start of
# the OBJS-$(CONFIG_UDP_PROTOCOL) line, because in 8.1.1 that line is
# "OBJS-$(CONFIG_UDP_PROTOCOL)              += udp.o ip.o" (alignment + extra ip.o),
# which an exact-string substitution would miss.

sed -i '/^OBJS-\$(CONFIG_UDP_PROTOCOL)/a OBJS-$(CONFIG_OMNIDRIVE_PROTOCOL)        += omnidrive.o' /build/ffmpeg/libavformat/Makefile
omnidrive_edit_applied "Makefile object" -qF 'OBJS-$(CONFIG_OMNIDRIVE_PROTOCOL)' /build/ffmpeg/libavformat/Makefile

# OBJS-$(CONFIG_OMNIDRIVE_PROTOCOL)        += omnidrive.o
# 3b. libavformat/protocols.c
# Add the extern declaration with the other ff_*_protocol externs (alphabetical):

sed -i 's/extern const URLProtocol ff_udp_protocol;/extern const URLProtocol ff_udp_protocol;\nextern const URLProtocol ff_omnidrive_protocol;/g' /build/ffmpeg/libavformat/protocols.c
omnidrive_edit_applied "protocol extern" -qxF 'extern const URLProtocol ff_omnidrive_protocol;' /build/ffmpeg/libavformat/protocols.c

# extern const URLProtocol ff_omnidrive_protocol;
# (The list is consumed automatically to build the protocol registry, so no further registration call is needed.)

# 3c. configure — declare the external library
# EXTERNAL_LIBRARY_LIST is a newline-separated, double-quoted block (4-space
# indent, NOT backslash-continued), kept alphabetical. libomnidrive sorts
# between liboapv and libopencv:

sed -i 's/^    liboapv$/    liboapv\n    libomnidrive/' /build/ffmpeg/configure
omnidrive_edit_applied "library list" -qxF '    libomnidrive' /build/ffmpeg/configure

# 3d. configure — declare the protocol dependency + the lib probe
# No PROTOCOL_LIST edit is needed: PROTOCOL_LIST is computed by find_things_extern
# from libavformat/protocols.c, so the ff_omnidrive_protocol extern added in 3b
# is registered automatically.

# Tie the omnidrive protocol to the external library, grouped with the other
# "external library protocols" *_protocol_deps= lines (inserted after libsrt):
sed -i 's/^libsrt_protocol_select="network"$/&\nomnidrive_protocol_deps="libomnidrive"/' /build/ffmpeg/configure
omnidrive_edit_applied "protocol deps" -qxF 'omnidrive_protocol_deps="libomnidrive"' /build/ffmpeg/configure

# Add the link probe alongside the other "enabled libxxx && require ..." lines.
# Anchored on the real libsvtav1 probe line, matched loosely so spacing/version
# drift in the require_pkg_config arguments doesn't break the anchor.
# require <name> <header> <symbol> <linkflags> -> check_lib: confirms omnidrive.h
# is includable and omnidrive_open links against -lomnidrive (the check_lib from
# OmniDrive.md, in FFmpeg's idiom).
sed -i '/^enabled libsvtav1 .* require_pkg_config/a enabled libomnidrive && require libomnidrive omnidrive.h omnidrive_open -lomnidrive' /build/ffmpeg/configure
omnidrive_edit_applied "enabled line" -qF 'enabled libomnidrive && require libomnidrive' /build/ffmpeg/configure

# Enable the library in the FFmpeg configure step. The omnidrive protocol then
# turns on automatically via its omnidrive_protocol_deps="libomnidrive".
add_enable "--enable-libomnidrive"

rm -rf /build/omnidrive

exit 0
