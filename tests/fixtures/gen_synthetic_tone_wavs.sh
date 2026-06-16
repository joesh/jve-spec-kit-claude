#!/usr/bin/env bash
# Generate synthetic WAV fixtures with KNOWN, DISTINCT per-channel content for the
# audio-decode regression battery (per-channel extraction + continuity + rate conv).
#
# Each channel carries a pure sine at a distinct frequency so a black-box test can
# assert "decoded channel k carries frequency f_k" via Goertzel power — expected
# values derived from what we synthesize here, never from decoder output.
#
# Reproducible: Joe/CI regenerate by re-running this. ffmpeg writes proper WAV
# (incl. extensible header for >2ch), channel order follows amerge input order.
#
# Frequencies: channel k (0-based) -> (k+1)*400 Hz. All < Nyquist for 44.1k/48k.
set -euo pipefail
# This script is tracked at tests/fixtures/; the .wav fixtures it produces live in
# tests/fixtures/media/ (gitignored — binary, regenerable). The integration runner
# regenerates them on demand, so the audio battery is reproducible from source.
cd "$(dirname "$0")/media"

DUR=2

gen_multichannel () {
  # $1 = out file, $2 = sample_rate, $3.. = per-channel frequencies
  local out="$1"; shift
  local sr="$1"; shift
  local freqs=("$@")
  local n="${#freqs[@]}"
  local inputs=() filt="" labels=""
  for i in "${!freqs[@]}"; do
    inputs+=(-f lavfi -i "sine=frequency=${freqs[$i]}:duration=${DUR}:sample_rate=${sr}")
    labels+="[$i:a]"
  done
  if [ "$n" -eq 1 ]; then
    ffmpeg -y "${inputs[@]}" -c:a pcm_s16le "$out"
  else
    filt="${labels}amerge=inputs=${n}[a]"
    ffmpeg -y "${inputs[@]}" -filter_complex "$filt" -map "[a]" -c:a pcm_s16le "$out"
  fi
}

# 8-channel @ 48k: 400,800,1200,1600,2000,2400,2800,3200 Hz — per-channel extraction + >2ch
gen_multichannel synthetic_8ch_tones_48k.wav 48000 400 800 1200 1600 2000 2400 2800 3200

# stereo @ 44.1k: L=300 R=2100 — rate conversion (44.1->48k) + stereo separation
gen_multichannel synthetic_2ch_tones_44k.wav 44100 300 2100

# mono @ 48k: 660 Hz — mono -> stereo dual-mono
gen_multichannel synthetic_1ch_tone_48k.wav 48000 660

echo "Generated synthetic tone fixtures:"
for f in synthetic_8ch_tones_48k.wav synthetic_2ch_tones_44k.wav synthetic_1ch_tone_48k.wav; do
  ffprobe -v error -show_entries stream=channels,sample_rate,duration -of default=noprint_wrappers=1 "$f" | tr '\n' ' '
  echo "  <- $f"
done
