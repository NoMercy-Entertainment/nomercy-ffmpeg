#!/bin/bash

if [[ ${TARGET_OS} == "darwin" ]]; then
	exit 255
fi

cd /build

git clone https://forgejo.phillippepelzer.me/FiLL/omnidrive.git

cd /build/omnidrive

cmake -S libomnidrive -B libomnidrive/build ${CMAKE_COMMON_ARG} 2>&1 | log
if [ ${PIPESTATUS[0]} -ne 0 ]; then
	exit 1
fi
cmake --build libomnidrive/build
cmake --install libomnidrive/build

# cmake --install above installs both libomnidrive.a and libomnidrive.so:
# libomnidrive's CMakeLists.txt defines an explicit `omnidrive_shared` SHARED
# target (OUTPUT_NAME omnidrive) regardless of BUILD_SHARED_LIBS, and installs
# it alongside the static target. In a dynamic link the linker prefers a
# visible .so over a .a for the same -l name, so leaving it in ${PREFIX}/lib
# would make -lomnidrive pick the .so the moment any platform's link stops
# being -static. Nothing links -lomnidrive today (every platform is -static,
# and a static link only ever considers .a), so removing it here changes
# nothing about what ships; it only removes a latent trap. Leave the .a.
rm -f ${PREFIX}/lib/libomnidrive.so ${PREFIX}/lib/libomnidrive.so.*

# Four libraries sit in the same trap: the base image ships both the archive
# and a visible system .so for each, and a dynamic link prefers the .so.
# omnidrive is handled above; stage the other three archives into
# ${PREFIX}/lib, ahead of the system dirs in LDFLAGS' -L order, so
# -lgomp/-lXau/-lXdmcp keep resolving to the .a once a link goes dynamic.
# (A fifth, libmvec.so.1, is part of glibc itself and is meant to stay.)
#
# Scoped to linux-x86_64 only, deliberately narrower than the .so removal
# above: linux-aarch64 stays -static (where only .a is ever considered, so
# staging here would be inert) and windows/freebsd cross-compile against
# unrelated toolchains/sysroots where these host archive paths don't apply
# and could even resolve to the wrong architecture's objects.
if [[ "${ARCH}" == "x86_64" && "${TARGET_OS}" == "linux" ]]; then
	for lib in gomp Xau Xdmcp; do
		src=$(find / -xdev -name "lib${lib}.a" 2>/dev/null | head -1)
		if [ -z "${src}" ]; then
			echo "56-omnidrive: lib${lib}.a not found in the image" >&2
			exit 1
		fi
		cp "${src}" ${PREFIX}/lib/
	done
fi

cp ./ffmpeg-integration/omnidrive.c /build/ffmpeg/libavformat/omnidrive.c

# 3. Four edits
# 3a. libavformat/Makefile
# Add the object after the UDP protocol object. Anchored loosely on the start of
# the OBJS-$(CONFIG_UDP_PROTOCOL) line, because in 8.1.1 that line is
# "OBJS-$(CONFIG_UDP_PROTOCOL)              += udp.o ip.o" (alignment + extra ip.o),
# which an exact-string substitution would miss.

sed -i '/^OBJS-\$(CONFIG_UDP_PROTOCOL)/a OBJS-$(CONFIG_OMNIDRIVE_PROTOCOL)        += omnidrive.o' /build/ffmpeg/libavformat/Makefile

# OBJS-$(CONFIG_OMNIDRIVE_PROTOCOL)        += omnidrive.o
# 3b. libavformat/protocols.c
# Add the extern declaration with the other ff_*_protocol externs (alphabetical):

sed -i 's/extern const URLProtocol ff_udp_protocol;/extern const URLProtocol ff_udp_protocol;\nextern const URLProtocol ff_omnidrive_protocol;/g' /build/ffmpeg/libavformat/protocols.c

# extern const URLProtocol ff_omnidrive_protocol;
# (The list is consumed automatically to build the protocol registry, so no further registration call is needed.)

# 3c. configure — declare the external library
# EXTERNAL_LIBRARY_LIST is a newline-separated, double-quoted block (4-space
# indent, NOT backslash-continued), kept alphabetical. libomnidrive sorts
# between liboapv and libopencv:

sed -i 's/^    liboapv$/    liboapv\n    libomnidrive/' /build/ffmpeg/configure

# 3d. configure — declare the protocol dependency + the lib probe
# No PROTOCOL_LIST edit is needed: PROTOCOL_LIST is computed by find_things_extern
# from libavformat/protocols.c, so the ff_omnidrive_protocol extern added in 3b
# is registered automatically.

# Tie the omnidrive protocol to the external library, grouped with the other
# "external library protocols" *_protocol_deps= lines (inserted after libsrt):
sed -i 's/^libsrt_protocol_select="network"$/&\nomnidrive_protocol_deps="libomnidrive"/' /build/ffmpeg/configure

# Add the link probe alongside the other "enabled libxxx && require ..." lines.
# Anchored on the real libsvtav1 probe line, matched loosely so spacing/version
# drift in the require_pkg_config arguments doesn't break the anchor.
# require <name> <header> <symbol> <linkflags> -> check_lib: confirms omnidrive.h
# is includable and omnidrive_open links against -lomnidrive (the check_lib from
# OmniDrive.md, in FFmpeg's idiom).
sed -i '/^enabled libsvtav1 .* require_pkg_config/a enabled libomnidrive && require libomnidrive omnidrive.h omnidrive_open -lomnidrive' /build/ffmpeg/configure

# Enable the library in the FFmpeg configure step. The omnidrive protocol then
# turns on automatically via its omnidrive_protocol_deps="libomnidrive".
add_enable "--enable-libomnidrive"

rm -rf /build/omnidrive

exit 0
