#!/usr/bin/env bash
# Host-side protocol test for the audioout daemon (x86, fakesink, no
# audio). Same 22 checks as the on-device run; use for fast iteration on
# the daemon and its Lua client.
#
# Usage: bash dev/audioout/host-test.sh
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)

bash "$HERE/build-host.sh" || exit 1

WAV=/tmp/audioout-spike/tone30.wav
if [ ! -f "$WAV" ]; then
    mkdir -p /tmp/audioout-spike
    python3 -I -c "
import math, struct, wave
w = wave.open('$WAV', 'w')
w.setnchannels(1); w.setsampwidth(2); w.setframerate(22050)
frames = bytearray()
for i in range(int(22050 * 30)):
    t = i / 22050
    a = 0.6
    if t < 0.05: a *= t / 0.05
    if 30.0 - t < 0.05: a *= (30.0 - t) / 0.05
    frames += struct.pack('<h', int(a * 32767 * math.sin(2 * math.pi * 440.0 * t)))
w.writeframes(bytes(frames)); w.close()
print('wav written: $WAV')
"
fi

SOCK=/tmp/test_audioout.sock
rm -f "$SOCK" "$SOCK fifo" /tmp/test_audioout_fifo

GST_OUT=$(nix build --no-link --print-out-paths --impure --expr "(import <nixpkgs> {}).gst_all_1.gstreamer.out" | tail -1)
BASE_OUT=$(nix build --no-link --print-out-paths --impure --expr "(import <nixpkgs> {}).gst_all_1.gst-plugins-base.out" | tail -1)
GLIB_OUT=$(nix build --no-link --print-out-paths --impure --expr "(import <nixpkgs> {}).glib.out" | tail -1)

nix shell nixpkgs#gst_all_1.gst-plugins-base nixpkgs#luajit -c bash -c "
export GST_PLUGIN_SYSTEM_PATH_1_0=$GST_OUT/lib/gstreamer-1.0:$BASE_OUT/lib/gstreamer-1.0
export GST_PLUGIN_SYSTEM_PATH=\$GST_PLUGIN_SYSTEM_PATH_1_0
export LD_LIBRARY_PATH=$GST_OUT/lib:$GLIB_OUT/lib:$BASE_OUT/lib:\${LD_LIBRARY_PATH:-}
$HERE/out/audioout-host --socket $SOCK --fifo /tmp/test_audioout_fifo \
    --rate 22050 --channels 1 --output mtk --sink fakesink > /tmp/audioout-host.log 2>&1 &
DPID=\$!
sleep 2
luajit $HERE/daemon_test.lua $SOCK $WAV 30000
rc=\$?
kill \$DPID 2>/dev/null
exit \$rc
"
rc=$?
echo "== daemon log (tail) =="
tail -6 /tmp/audioout-host.log
exit $rc
