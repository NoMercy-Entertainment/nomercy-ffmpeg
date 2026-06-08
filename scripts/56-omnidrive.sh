#!/bin/bash

if [[ ${TARGET_OS} == "darwin" ]]; then
	exit 255
fi

cd /build

git clone https://forgejo.phillippepelzer.me/FiLL/omnidrive.git

cd /build/omnidrive

cmake -S libomnidrive -B libomnidrive/build ${CMAKE_COMMON_ARG} | log
if [ ${PIPESTATUS[0]} -ne 0 ]; then
	exit 1
fi
cmake --build libomnidrive/build
cmake --install libomnidrive/build

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
