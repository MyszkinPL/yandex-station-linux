#!/bin/sh
# Mic ADC setup for the Yandex Station (5x TLV320ADC3101, card "snddaudio0").
# Replaces the vendor /system/bin/i2c_ma: the kernel driver owns the chips,
# this only sets ALSA controls, so the register state ends up as i2c_ma
# leaves it (see README.md of track audio, table "i2c_ma -> controls").
#
# Run with no capture open (processing block and biquads may only change
# while the ADCs are powered down). Writes only the ADC registers through
# the driver; no GPIO, no PMIC, nothing on the amplifiers.
#
#   station-mics-init.sh          apply
#   station-mics-init.sh show     print the controls (read only)
set -eu

CARD=${CARD:-snddaudio0}
A="amixer -q -c $CARD cset"

# vendor biquad A (HPF ~25 Hz at 16 kHz): N0 N1 N2 D1 D2 = 7f22 80de 7f22 7f21 81ba,
# biquads B..E flat (reset values N0 = 0x7fff, the rest 0)
FLAT="32767,0,0,0,0"
BIQUAD="32546,32990,32546,32545,33210,$FLAT,$FLAT,$FLAT,$FLAT"

if [ "${1:-}" = show ]; then
	for k in 0 1 2 3 4; do
		amixer -c "$CARD" contents | grep -A2 -E "name='ADC$k (PGA|ADC Processing|ADC Soft|Left Input DIF_2L_3L|Right Input DIF_2R_3R|Left ADC Biquad|Right ADC Biquad)" || true
	done
	exit 0
fi

[ -e /proc/asound/"$CARD" ] || { echo "card $CARD not found" >&2; exit 1; }
# the per-substream status file needs CONFIG_SND_VERBOSE_PROCFS; check it when present
st=$(cat /proc/asound/"$CARD"/pcm0c/sub0/status 2>/dev/null || echo unknown)
case "$st" in
closed|unknown) ;;
*) echo "capture is running on $CARD, stop it first" >&2; exit 1 ;;
esac

# PGA gain in 0.5 dB steps: 40 = 20 dB (microphones), 1 = 0.5 dB (reference taps)
# slot: ADC0..3 = i2c-1 0x18..0x1b, ADC4 = i2c-0 0x18
gain() {
	case "$1" in
	0|1|2) echo 40,40 ;;
	# ADC3 right: the speaker amplifier's tap, the echo canceller's reference
	# (listend sets it too): 30 dB, else it sinks in the ADC's noise
	3) echo 40,61 ;;
	4) echo 1,1 ;;
	esac
}

for k in 0 1 2 3 4; do
	p="ADC$k"
	# differential IN2(P)/IN3(M) pairs, 0 dB, single-ended inputs off (P1 R52/R55 = 0x3f)
	$A name="$p Left Input DIF_2L_3L Capture Switch" on
	$A name="$p Right Input DIF_2R_3R Capture Switch" on
	$A name="$p Left Input DIF_2L_3L Capture Volume" 1
	$A name="$p Right Input DIF_2R_3R Capture Volume" 1
	# P1 R59/R60
	$A name="$p PGA Capture Volume" "$(gain $k)"
	# P0 R82 = 0x00 (unmute, fine gain 0 dB)
	$A name="$p PGA Capture Switch" on,on
	# P0 R81 D1:D0 = 10
	$A name="$p ADC Soft Stepping" off
	# P0 R61 = 0x02 (PRB_R2, filter A, 5 biquads) and its coefficients (page 4);
	# the control counts from PRB_R1 = 0
	$A name="$p ADC Processing Block" 1
	$A name="$p Left ADC Biquad Coefficients" "$BIQUAD"
	$A name="$p Right ADC Biquad Coefficients" "$BIQUAD"
done
echo "mic ADCs configured on $CARD"
