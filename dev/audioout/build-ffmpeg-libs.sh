#!/usr/bin/env bash
# Build the decoder-subset ffmpeg static libs used by the audioout daemon
# (AUDIOOUT_WITH_LIBAV). Same Jessie glibc 2.19 sysroot and cross toolchain
# as build-daemon.sh; the result lands in dev/audioout/.ffinstall and the
# daemon links it statically. Subset mirrors bin/ffmpeg-legacy's decoders:
# aac/aac_latm, mp3, flac, vorbis, opus, wmav1/2, alac, pcm; demuxers:
# mov/mp3/ogg/flac/asf/matroska/aac/wav/opus; swresample for planar->s16.
#
# Output: dev/audioout/.ffinstall/{lib,include}
# Usage:   bash dev/audioout/build-ffmpeg-libs.sh [ffmpeg-version]
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
VERSION="${1:-7.0.2}"
SHA256="8646515b638a3ad303e23af6a3587734447cb8fc0a0c064ecdb8e95c4fd8b389"
SRC="/tmp/ffbuild-$VERSION"

bash "$HERE/fetch-sysroot.sh"

mkdir -p "$HERE/.ffinstall"
[ -f "$SRC.tar.xz" ] || curl -fsSL "https://www.ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz" -o "$SRC.tar.xz"
echo "$SHA256  $SRC.tar.xz" | (cd /tmp && sha256sum -c -)
rm -rf "/tmp/ffmpeg-$VERSION"
[ -d "/tmp/ffmpeg-$VERSION" ] || tar xf "$SRC.tar.xz" -C /tmp
cd "/tmp/ffmpeg-$VERSION"

hdr() {
    nix build --no-link --print-out-paths --impure --expr \
        "let p = builtins.fetchTarball \"https://github.com/NixOS/nixpkgs/archive/255a186666b6130ddddf8ad749887102a0820914.tar.gz\"; in (import p {}).pkgsCross.armv7l-hf-multiplatform.$1" \
        | tail -1
}
SYSROOT="$HERE/.sysroot"

nix shell "nixpkgs#gcc" "nixpkgs#gnumake" "nixpkgs#pkgsCross.armv7l-hf-multiplatform.stdenv.cc" -c bash -c "
CC=armv7l-unknown-linux-gnueabihf-gcc ./configure --prefix='$HERE/.ffinstall' \
  --enable-cross-compile --cross-prefix=armv7l-unknown-linux-gnueabihf- --arch=arm --target-os=linux \
  --sysroot='$SYSROOT' --cc=armv7l-unknown-linux-gnueabihf-gcc --host-cc=gcc \
  --disable-everything --disable-doc --disable-programs --disable-network --disable-autodetect \
  --disable-avdevice --disable-swscale --disable-postproc --disable-avfilter \
  --disable-iconv --disable-vaapi --disable-vdpau --disable-libxcb --disable-lzma \
  --enable-static --disable-shared --enable-small --enable-pic \
  --enable-avcodec --enable-avformat --enable-avutil --enable-swresample \
  --enable-demuxer=mov,mp3,ogg,flac,asf,matroska,aac,wav,opus \
  --enable-protocol=file \
  --enable-decoder=aac,aac_latm,mp3,mp3float,flac,vorbis,opus,wmav1,wmav2,alac,pcm_s16le,pcm_u8,pcm_f32le,pcm_s16be \
  --enable-parser=aac,mpegaudio,vorbis,opus,flac \
  --extra-cflags='-Os -ffunction-sections -fdata-sections -mfpu=vfpv3-d16 -march=armv7-a' \
  --extra-ldflags='-Wl,--gc-sections'
make -j8
make install-libs install-headers
"
echo "ffmpeg libs installed to $HERE/.ffinstall"
