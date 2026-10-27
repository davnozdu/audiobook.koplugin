#!/usr/bin/env bash
# Build the audioout daemon for Kobo armv7l (same recipe as build-spike.sh:
# Debian Jessie glibc 2.19 sysroot, runs bare under the device loader).
# See build-spike.sh for why this compiles outside the nix sandbox.
#
# Output: dev/audioout/out/audioout
#
# Usage: bash dev/audioout/build-daemon.sh
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
NIXPKGS_PIN="https://github.com/NixOS/nixpkgs/archive/255a186666b6130ddddf8ad749887102a0820914.tar.gz"

bash "$HERE/fetch-sysroot.sh"

hdr() {
    nix build --no-link --print-out-paths --impure --expr \
        "let p = builtins.fetchTarball \"$NIXPKGS_PIN\"; in (import p {}).pkgsCross.armv7l-hf-multiplatform.$1" \
        | tail -1
}

SYSROOT="$HERE/.sysroot"
OUT="$HERE/out"
mkdir -p "$OUT"

GST_DEV=$(hdr gst_all_1.gstreamer.dev)
GLIB_DEV=$(hdr glib.dev)
GLIB_OUT=$(hdr glib.out)
echo "headers: $GST_DEV / $GLIB_DEV"

cd "$REPO"
# Decoder-subset ffmpeg static libs (Tier 5b, in-process decode): built
# once by build-ffmpeg-libs.sh into .ffinstall; auto-enabled when present.
FFI="$HERE/.ffinstall"
AV_FLAGS=""
[ -f "$FFI/lib/libavformat.a" ] && AV_FLAGS="-DAUDIOOUT_WITH_LIBAV -I$FFI/include $FFI/lib/libavformat.a $FFI/lib/libavcodec.a $FFI/lib/libswresample.a $FFI/lib/libavutil.a"

nix shell "nixpkgs#pkgsCross.armv7l-hf-multiplatform.stdenv.cc" -c \
    armv7l-unknown-linux-gnueabihf-gcc \
    -O2 -Wall -static-libgcc -nostdinc \
    -o "$OUT/audioout" \
    "$REPO/audioout.c" \
    $AV_FLAGS \
    -ldl -lpthread -l:libm.so.6 \
    --sysroot="$SYSROOT" \
    -I"$SYSROOT/usr/include" \
    -I"$SYSROOT/usr/include/arm-linux-gnueabihf" \
    -isystem "$(nix shell nixpkgs#pkgsCross.armv7l-hf-multiplatform.stdenv.cc -c armv7l-unknown-linux-gnueabihf-gcc -print-file-name=include)" \
    -I"$GST_DEV/include/gstreamer-1.0" \
    -I"$GLIB_DEV/include/glib-2.0" \
    -I"$GLIB_OUT/lib/glib-2.0/include" \
    -Wl,--dynamic-linker=/lib/ld-linux-armhf.so.3 \
    -B"$SYSROOT/usr/lib/arm-linux-gnueabihf/" \
    -L"$SYSROOT/usr/lib/arm-linux-gnueabihf" \
    -L"$SYSROOT/lib/arm-linux-gnueabihf"

echo "built: $OUT/audioout"
