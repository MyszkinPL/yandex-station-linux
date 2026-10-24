#!/bin/sh
# Boot-time sound setup for the Yandex Station (run by the stage B init in
# the Debian overlay once both cards are there; the drivers are built in).
#   - mic ADCs as the vendor's i2c_ma leaves them (station-mics-init.sh,
#     next to this script)
#   - speakers: output on, master at a quiet -40 dB. The vendor scripts
#     leave the amplifiers at about +1 dB, and Android starts at 85 %
#     (about +2 dB); -20 dB is already painfully loud on this speaker.
set -eu

DIR=$(dirname "$0")
sh "$DIR/station-mics-init.sh"

# "Master Playback Volume" (vendor scale): 0 = mute, 1 = -103.75 dB,
# 0.125 dB per step, 1023 = +24 dB; 511 = -40 dB
for p in Subwoofer Tweeters; do
	amixer -q -c snddaudio1 cset name="$p Master Playback Volume" 511
	amixer -q -c snddaudio1 cset name="$p Speaker Switch" on,on
done
echo "speakers on snddaudio1: master -40 dB, output on"
