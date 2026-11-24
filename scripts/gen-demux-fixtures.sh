#!/bin/bash
# Regenerates the media bridge's fixtures: small MKVs, ffprobe's packet list for the two the
# demuxer and segment tests compare against, a clip whose picture is its own frame number, and
# files the bridge has to refuse.
# Usage: scripts/gen-demux-fixtures.sh    (needs macOS, ffmpeg with libx264 and libx265, ffprobe, mkvmerge, dovi_tool, oggenc and python3)
set -euo pipefail

OUT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)/Packages/ParallaxPlayback/Tests/ParallaxPlaybackTests/Fixtures/demux"
mkdir -p "$OUT"

# B-frames so decode order differs from presentation order, a 0.5 s GOP so there are many
# cues, and two audio codecs with different frame lengths. Noise keeps the encoder at its
# bitrate: the file has to be several times libavformat's 256 KB read buffer, or a test never
# leaves the buffer the open filled.
noisy_h264=(
    -f lavfi -i "testsrc2=size=160x90:rate=24,noise=alls=40:allf=t"
    -f lavfi -i "sine=frequency=440:sample_rate=48000"
    -map 0:v -map 1:a -map 1:a
    -c:v libx264 -preset veryfast -bf 2 -g 12 -keyint_min 12 -sc_threshold 0 -b:v 500k -pix_fmt yuv420p
    -c:a:0 aac -b:a:0 32k -ac:a:0 2
    -c:a:1 ac3 -b:a:1 64k -ac:a:1 2
    -bitexact -fflags +bitexact
)
ffmpeg -v error -y "${noisy_h264[@]}" -t 12 "$OUT/h264-ffmpeg.mkv"

# The same streams as mkvmerge lays them out: different clusters, cue placement and lacing.
mkvmerge --quiet --deterministic 0 -o "$OUT/h264-mkvmerge.mkv" "$OUT/h264-ffmpeg.mkv"

# ffprobe's packets, the demuxer tests' oracle, timed in whole milliseconds.
packet_list() {
    ffprobe -v error -show_packets -show_data_hash md5 -of json "$OUT/$1.${2:-mkv}" \
        | python3 -c '
import json, sys
packets = json.load(sys.stdin)["packets"]
# An AVI gives a packet only the time it is decoded.
rows = [[p["stream_index"], round(float(p.get("pts_time", p["dts_time"])) * 1e6) // 1000, int(p["size"]), "K" in p["flags"], p["data_hash"].split(":")[1]]
        for p in packets]
json.dump(rows, sys.stdout, separators=(",", ":"))
' > "$OUT/$1.packets.json"
}
packet_list h264-ffmpeg
packet_list h264-mkvmerge
# Each frame draws its own number as 16 squares, least significant bit on the left, so a test
# can read which source frame a player is showing. One minute with a keyframe every 2 s gives
# 30 segments: enough that a seek lands far past what a player buffered.
ffmpeg -v error -y \
    -f lavfi -i "color=black:size=160x90:rate=24,format=gray,geq=lum='if(mod(floor(N/pow(2\,floor(X/10)))\,2)\,235\,16)',format=yuv420p" \
    -f lavfi -i "sine=frequency=440:sample_rate=48000" \
    -t 60 -map 0:v -map 1:a \
    -c:v libx264 -preset veryfast -bf 2 -g 48 -keyint_min 48 -sc_threshold 0 -pix_fmt yuv420p \
    -c:a aac -b:a 24k -ac 1 \
    -bitexact -fflags +bitexact \
    "$OUT/frame-numbers.mkv"

# The same picture as HEVC with x265's defaults, which real files have: an open GOP and a
# B-frame pyramid. AC-3 audio, so one clip takes both through a player.
numbered_hevc=(
    -f lavfi -i "color=black:size=160x90:rate=24,format=gray,geq=lum='if(mod(floor(N/pow(2\,floor(X/10)))\,2)\,235\,16)',format=yuv420p"
    -f lavfi -i "sine=frequency=440:sample_rate=48000"
    -t 60 -map 0:v -map 1:a
    -c:v libx265 -preset veryfast -x265-params "keyint=48:min-keyint=48:scenecut=0:log-level=error" -pix_fmt yuv420p
    -c:a ac3 -b:a 64k -ac 2
    -bitexact -fflags +bitexact
)
ffmpeg -v error -y "${numbered_hevc[@]}" "$OUT/frame-numbers-hevc.mkv"

# One keyframe interval of 32 s, as an x264 encode with keyint=infinite has over a still scene,
# then a keyframe every 2 s. The Cues list every keyframe; clusters still close every 5 s, so
# the long span holds several.
ffmpeg -v error -y \
    -f lavfi -i "color=black:size=160x90:rate=24,format=gray,geq=lum='if(mod(floor(N/pow(2\,floor(X/10)))\,2)\,235\,16)',format=yuv420p" \
    -f lavfi -i "sine=frequency=440:sample_rate=48000" \
    -t 60 -map 0:v -map 1:a \
    -c:v libx264 -preset veryfast -bf 2 -g 100000 -keyint_min 100000 -sc_threshold 0 -pix_fmt yuv420p \
    -force_key_frames "0,32,34,36,38,40,42,44,46,48,50,52,54,56,58" \
    -c:a aac -b:a 24k -ac 1 \
    -bitexact -fflags +bitexact \
    "$OUT/long-span.mkv"
packet_list long-span

# A 50 s keyframe interval whose clusters close every 30 s: none lies in the eight seconds
# before the keyframe at 50 s, and one at 30 s lies after the span's start.
ffmpeg -v error -y \
    -f lavfi -i "color=black:size=160x90:rate=24,format=gray,geq=lum='if(mod(floor(N/pow(2\,floor(X/10)))\,2)\,235\,16)',format=yuv420p" \
    -f lavfi -i "sine=frequency=440:sample_rate=48000" \
    -t 60 -map 0:v -map 1:a \
    -c:v libx264 -preset veryfast -bf 2 -g 100000 -keyint_min 100000 -sc_threshold 0 -pix_fmt yuv420p \
    -force_key_frames "0,50,52,54,56,58" \
    -c:a aac -b:a 24k -ac 1 \
    -cluster_time_limit 30000 -cluster_size_limit 100000000 \
    -bitexact -fflags +bitexact \
    "$OUT/sparse-clusters.mkv"

# Numbered frames, as frame-numbers-hevc, in a B-pyramid of eight: the second picture decoded
# is the ninth shown, though the stream declares a reorder depth of 2.
ffmpeg -v error -y \
    -f lavfi -i "color=black:size=160x90:rate=24,format=gray,geq=lum='if(mod(floor(N/pow(2\,floor(X/10)))\,2)\,235\,16)',format=yuv420p" \
    -f lavfi -i "sine=frequency=440:sample_rate=48000" \
    -t 60 -map 0:v -map 1:a \
    -c:v libx265 -preset veryfast -x265-params "keyint=48:min-keyint=48:scenecut=0:bframes=8:b-adapt=0:b-pyramid=1:log-level=error" -pix_fmt yuv420p \
    -c:a aac -b:a 24k -ac 1 \
    -bitexact -fflags +bitexact \
    "$OUT/deep-pyramid-hevc.mkv"

# Two seconds at 59.94 frames a second, then four at 23.976, under a track header that declares
# 23.976 for all of it, as an old mkvmerge writes. mkvmerge keeps the times from the list it is
# given, and the declared duration is then written over by hand: mkvmerge derives it from the
# times, and forcing one retimes the frames.
ffmpeg -v error -y \
    -f lavfi -i "testsrc2=size=160x90:rate=60000/1001:duration=2" \
    -f lavfi -i "testsrc2=size=160x90:rate=24000/1001:duration=4" \
    -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=6" \
    -filter_complex "[0:v]settb=1/120000[a];[1:v]settb=1/120000[b];[a][b]concat=n=2:v=1:a=0[v]" -map "[v]" -map 2:a \
    -c:v libx264 -preset veryfast -bf 2 -g 12 -keyint_min 12 -sc_threshold 0 -pix_fmt yuv420p -b:v 100k \
    -fps_mode passthrough -c:a aac -b:a 24k -bitexact -fflags +bitexact "$OUT/rate-above-declared-source.mkv"
{
    echo "# timestamp format v2"
    ffprobe -v error -select_streams v:0 -show_entries packet=pts_time -of csv=p=0 "$OUT/rate-above-declared-source.mkv" \
        | sort -n | awk '{ printf "%.3f\n", $1 * 1000 }'
} > "$OUT/rate-above-declared-times.txt"
mkvmerge --quiet --deterministic 0 -o "$OUT/rate-above-declared.mkv" \
    --timestamps "0:$OUT/rate-above-declared-times.txt" "$OUT/rate-above-declared-source.mkv"
rm "$OUT/rate-above-declared-source.mkv" "$OUT/rate-above-declared-times.txt"
python3 - "$OUT/rate-above-declared.mkv" <<'PYTHON'
import sys

data = bytearray(open(sys.argv[1], "rb").read())
# DefaultDuration, four bytes of nanoseconds: the 17 ms mkvmerge derived, made 41,708,333.
derived = b"\x23\xe3\x83\x84" + (17_000_000).to_bytes(4, "big")
assert data.count(derived) == 1
at = data.index(derived) + 4
data[at:at + 4] = (41_708_333).to_bytes(4, "big")
open(sys.argv[1], "wb").write(data)
PYTHON

# The same file with its index cut after 32 s, as a file whose Cues stop after its start. The
# CuePoints are overwritten with an EBML Void of the same length, so no position moves.
python3 - "$OUT/long-span.mkv" "$OUT/index-stops.mkv" <<'PYTHON'
import sys

data = bytearray(open(sys.argv[1], "rb").read())

def vint(at):
    first = data[at]
    length = 8 - first.bit_length() + 1
    value = first & ((1 << (8 - length)) - 1)
    for byte in data[at + 1:at + length]:
        value = value << 8 | byte
    return value, length

def element(at):
    ident_length = 8 - data[at].bit_length() + 1
    ident = bytes(data[at:at + ident_length])
    size, size_length = vint(at + ident_length)
    body = at + ident_length + size_length
    return ident, body, body + size

_, _, at = element(0)
_, at, _ = element(at)
while element(at)[0] != b"\x1c\x53\xbb\x6b":
    at = element(at)[2]
_, at, end = element(at)
while at < end:
    ident, body, after = element(at)
    if ident == b"\xbb":
        _, time_body, time_end = element(body)
        if int.from_bytes(data[time_body:time_end], "big") > 32000:
            length = after - at
            data[at:after] = b"\xec" + bytes([0x80 | (length - 2)]) + bytes(length - 2)
    at = after
open(sys.argv[2], "wb").write(data)
PYTHON

# Audio that stops a second before the video does, as most real files' audio stops a little
# before their video.
ffmpeg -v error -y \
    -f lavfi -i "color=black:size=160x90:rate=24,format=gray,geq=lum='if(mod(floor(N/pow(2\,floor(X/10)))\,2)\,235\,16)',format=yuv420p" \
    -f lavfi -t 11 -i "sine=frequency=440:sample_rate=48000" \
    -t 12 -map 0:v -map 1:a \
    -c:v libx264 -preset veryfast -bf 2 -g 48 -keyint_min 48 -sc_threshold 0 -pix_fmt yuv420p \
    -c:a aac -b:a 24k -ac 1 \
    -bitexact -fflags +bitexact \
    "$OUT/audio-ends-early.mkv"

# Audio that stops four seconds before the video does, so the last two segments hold none.
ffmpeg -v error -y \
    -f lavfi -i "color=black:size=160x90:rate=24,format=gray,geq=lum='if(mod(floor(N/pow(2\,floor(X/10)))\,2)\,235\,16)',format=yuv420p" \
    -f lavfi -t 8 -i "sine=frequency=440:sample_rate=48000" \
    -t 12 -map 0:v -map 1:a \
    -c:v libx264 -preset veryfast -bf 2 -g 48 -keyint_min 48 -sc_threshold 0 -pix_fmt yuv420p \
    -c:a aac -b:a 24k -ac 1 \
    -bitexact -fflags +bitexact \
    "$OUT/audio-ends-two-segments-early.mkv"

clip() {
    local name=$1; shift
    ffmpeg -v error -y \
        -f lavfi -i "testsrc2=size=160x90:rate=24" -f lavfi -i "sine=frequency=440:sample_rate=48000" \
        -t 2 -map 0:v -map 1:a "$@" -bitexact -fflags +bitexact "$OUT/$name.mkv"
}
x264=(-c:v libx264 -preset veryfast -g 12 -pix_fmt yuv420p -b:v 100k)
# TTA, which the bridge's libavcodec has no decoder for.
clip refused-tta-audio "${x264[@]}" -c:a tta -ac 2
# The same beside AAC: a file that plays without one of its tracks.
ffmpeg -v error -y \
    -f lavfi -i "testsrc2=size=160x90:rate=24" -f lavfi -i "sine=frequency=440:sample_rate=48000" \
    -t 2 -map 0:v -map 1:a -map 1:a "${x264[@]}" -c:a:0 aac -b:a:0 24k -c:a:1 tta -ac 2 \
    -bitexact -fflags +bitexact "$OUT/aac-and-tta.mkv"
# 10-bit H.264, which the bridge delivers to a device that decodes it.
clip h264-high10 -c:v libx264 -preset veryfast -g 12 -pix_fmt yuv420p10le -b:v 100k -c:a aac -b:a 24k
# AAC Low Delay, object type 23, which only AudioToolbox's encoder writes. AVPlayer does not
# take it from a playlist, so the bridge converts it.
clip ld-aac "${x264[@]}" -c:a aac_at -profile:a 22 -ac 2
# HE-AAC and HE-AAC v2, object types 5 and 29, which the bridge delivers. Four seconds make two
# segments.
for profile in "he-aac 4" "he-aac-v2 28"; do
    set -- $profile
    ffmpeg -v error -y \
        -f lavfi -i "testsrc2=size=160x90:rate=24" -f lavfi -i "sine=frequency=440:sample_rate=48000" \
        -t 4 -map 0:v -map 1:a "${x264[@]}" -c:a aac_at -profile:a "$2" -ac 2 -bitexact -fflags +bitexact "$OUT/$1.mkv"
done
# The other audio codecs the bridge delivers, and AV1 video. ALAC is the last it copies: the
# ones after it are converted to FLAC.
for codec in "flac flac" "eac3 eac3 -b:a 96k" "opus libopus -b:a 32k" "alac alac" \
    "mp3 libmp3lame -b:a 64k" "mp2 mp2 -b:a 64k" "vorbis vorbis -strict -2" "wma wmav2 -b:a 64k"; do
    set -- $codec
    name=$1; shift
    ffmpeg -v error -y \
        -f lavfi -i "testsrc2=size=160x90:rate=24" -f lavfi -i "sine=frequency=440:sample_rate=48000" \
        -t 4 -map 0:v -map 1:a "${x264[@]}" -c:a "$@" -ac 2 -bitexact -fflags +bitexact "$OUT/$name.mkv"
done
# MP3 at 44.1 kHz, whose frame of 1152 samples is no whole number of the file's milliseconds.
ffmpeg -v error -y \
    -f lavfi -i "testsrc2=size=160x90:rate=24" -f lavfi -i "sine=frequency=440:sample_rate=44100" \
    -t 6 -map 0:v -map 1:a "${x264[@]}" -c:a libmp3lame -b:a 64k -ac 2 -bitexact -fflags +bitexact "$OUT/mp3-44k.mkv"
# E-AC-3 of three blocks a frame, 768 samples, which an MP4 sample holds two of. No encoder here
# writes them, so six-block frames are relabeled, with the CRC that guards each frame redone:
# the times are right and the sound is not.
# mkvmerge muxes them, because ffmpeg cannot decode the relabeled frames to find their rate.
# Two-second segments of 125 frames each end on an odd count. The second file stops after 126
# frames: its last pair, frames 124 and 125, starts before the boundary at 2 s and ends after it.
ffmpeg -v error -y -f lavfi -i "sine=frequency=440:sample_rate=48000" -t 12 \
    -c:a eac3 -b:a 96k -ac 2 -bitexact -fflags +bitexact -f eac3 "$OUT/eac3-six-blocks.eac3"
python3 - "$OUT/eac3-six-blocks.eac3" "$OUT/eac3-three-blocks.eac3" "$OUT/eac3-three-blocks-ends-early.eac3" <<'PYTHON'
import sys

def crc16(bytes):
    crc = 0
    for byte in bytes:
        crc ^= byte << 8
        for _ in range(8):
            crc = (crc << 1 ^ 0x8005 if crc & 0x8000 else crc << 1) & 0xFFFF
    return crc

data = bytearray(open(sys.argv[1], "rb").read())
at = 0
ends = []
while at < len(data):
    assert data[at:at + 2] == b"\x0b\x77"
    size = (((data[at + 2] & 0x07) << 8 | data[at + 3]) + 1) * 2
    # numblkscod, after fscod in the fifth byte: 2 is three blocks, 3 is six.
    data[at + 4] = data[at + 4] & 0xCF | 0x20
    # The last two bytes make the frame after its syncword CRC to zero.
    data[at + size - 2:at + size] = crc16(data[at + 2:at + size - 2]).to_bytes(2, "big")
    at += size
    ends.append(at)
open(sys.argv[2], "wb").write(data)
open(sys.argv[3], "wb").write(data[:ends[125]])
PYTHON
ffmpeg -v error -y -f lavfi -i "testsrc2=size=160x90:rate=24" -t 6 \
    "${x264[@]}" -bitexact -fflags +bitexact "$OUT/eac3-three-blocks-video.mkv"
mkvmerge --quiet --deterministic 0 -o "$OUT/eac3-three-blocks.mkv" \
    "$OUT/eac3-three-blocks-video.mkv" "$OUT/eac3-three-blocks.eac3"
mkvmerge --quiet --deterministic 0 -o "$OUT/eac3-three-blocks-ends-early.mkv" \
    "$OUT/eac3-three-blocks-video.mkv" "$OUT/eac3-three-blocks-ends-early.eac3"
rm "$OUT/eac3-six-blocks.eac3" "$OUT/eac3-three-blocks.eac3" "$OUT/eac3-three-blocks-ends-early.eac3" \
    "$OUT/eac3-three-blocks-video.mkv"
ffmpeg -v error -y \
    -f lavfi -i "testsrc2=size=160x90:rate=24" -f lavfi -i "sine=frequency=440:sample_rate=48000" \
    -t 4 -map 0:v -map 1:a -c:v libsvtav1 -preset 10 -g 12 -svtav1-params "lp=1" -pix_fmt yuv420p \
    -c:a aac -b:a 24k -bitexact -fflags +bitexact "$OUT/av1.mkv" 2>/dev/null
# Vorbis as libvorbis encodes it: bursts of noise make it change frame length, which ffmpeg's
# own encoder never does.
ffmpeg -v error -y \
    -f lavfi -i "aevalsrc=exprs='0.125*sin(2*PI*440*t)+0.5*(random(0)-0.5)*gt(mod(t\,0.5)\,0.45)*gt(t\,1)':s=48000:c=stereo" \
    -t 4 -f wav - | oggenc --quiet --quality 3 --serial 1 -o "$OUT/vorbis-bursts.ogg" -
ffmpeg -v error -y -f lavfi -i "testsrc2=size=160x90:rate=24" -i "$OUT/vorbis-bursts.ogg" \
    -t 4 -map 0:v -map 1:a "${x264[@]}" -c:a copy -bitexact -fflags +bitexact "$OUT/vorbis-bursts.mkv"
rm "$OUT/vorbis-bursts.ogg"
# PCM at 8 kHz whose packets change length after the opening: 1024 samples, then 500.
ffmpeg -v error -y -f lavfi -i "sine=frequency=440:sample_rate=8000" -t 1.536 -af asetnsamples=n=1024 \
    -c:a pcm_s16le -ac 1 "$OUT/pcm-uneven-1.mka"
ffmpeg -v error -y -f lavfi -i "sine=frequency=330:sample_rate=8000" -t 3 -af asetnsamples=n=500 \
    -c:a pcm_s16le -ac 1 "$OUT/pcm-uneven-2.mka"
ffmpeg -v error -y -f lavfi -i "testsrc2=size=160x90:rate=24" \
    -f concat -safe 0 -i <(printf "file '%s'\nfile '%s'\n" "$OUT/pcm-uneven-1.mka" "$OUT/pcm-uneven-2.mka") \
    -t 4.5 -map 0:v -map 1:a "${x264[@]}" -c:a copy -bitexact -fflags +bitexact "$OUT/pcm-uneven.mkv"
rm "$OUT/pcm-uneven-1.mka" "$OUT/pcm-uneven-2.mka"
# MP2 with no packets from 1.5 s to 2.7 s, across the join of the first two segments.
ffmpeg -v error -y -i "$OUT/mp2.mkv" -map 0 -c copy -bsf:a "noise=drop='between(pts*tb\,1.5\,2.7)'" \
    -bitexact -fflags +bitexact "$OUT/mp2-hole.mkv"
# Audio the bridge converts, with a different tone in each channel so a test can tell them
# apart. A subwoofer channel gets 60 Hz: DTS keeps nothing above 120 Hz of it. The lossless
# clips come with the hash of their samples as ffmpeg decodes them, 24 bits in the top of 32.
tones() {
    local level=$1 expressions=""; shift
    for hertz in "$@"; do expressions+="${expressions:+|}$level*sin(2*PI*$hertz*t)"; done
    echo "$expressions"
}
lossless() {
    local name=$1 rate=$2 layout=$3 seconds=$4 level=$5 codec=$6; shift 6
    ffmpeg -v error -y \
        -f lavfi -i "testsrc2=size=160x90:rate=24" \
        -f lavfi -i "aevalsrc=exprs='$(tones "$level" "$@")':s=$rate:c=$layout" \
        -t "$seconds" -map 0:v -map 1:a "${x264[@]}" -c:a "$codec" -strict -2 -bitexact -fflags +bitexact "$OUT/$name.tmp.mkv"
    # mkvmerge's layout, which is what a disc's copy has, with the audio 7 ms late, as a track
    # with a delay is. The frame a segment's read starts at then falls half way between two of
    # the container's milliseconds, where its time alone does not say which frame it is.
    mkvmerge --quiet --deterministic 0 -o "$OUT/$name.mkv" --sync 1:7 "$OUT/$name.tmp.mkv"
    rm "$OUT/$name.tmp.mkv"
    ffmpeg -v error -i "$OUT/$name.mkv" -map 0:a:0 -c:a pcm_s32le -f hash -hash sha256 - \
        | cut -d= -f2 | tr -d '\n' > "$OUT/$name.samples.sha256"
}
# TrueHD is 40 samples a frame at 48 kHz, shorter than Matroska's millisecond. Quiet tones keep
# the file small. The Mac's ffmpeg encodes TrueHD up to 5.1, so the 7.1 clip is PCM.
lossless truehd-51 48000 "5.1(side)" 4.5 0.004 truehd 300 400 500 60 600 700
lossless truehd-96k 96000 "5.1(side)" 2.5 0.004 truehd 300 400 500 60 600 700
lossless pcm-71 48000 7.1 2.5 0.125 pcm_s24le 300 400 500 60 600 700 800 900
# Layouts FLAC has no speakers for at their channel count: a subwoofer with no center, and one
# rear speaker.
for clip in "truehd-21 2.1 300 400 60" "truehd-40 4.0 300 400 500 650"; do
    set -- $clip
    name=$1 layout=$2; shift 2
    ffmpeg -v error -y \
        -f lavfi -i "testsrc2=size=160x90:rate=24" \
        -f lavfi -i "aevalsrc=exprs='$(tones 0.004 "$@")':s=48000:c=$layout" \
        -t 2.5 -map 0:v -map 1:a "${x264[@]}" -c:a truehd -strict -2 -bitexact -fflags +bitexact "$OUT/$name.mkv"
done
# HEVC Main 10 with AC-3 5.1 and DTS 5.1, the DTS marked as the default.
ffmpeg -v error -y \
    -f lavfi -i "testsrc2=size=160x90:rate=24" \
    -f lavfi -i "aevalsrc=exprs='$(tones 0.125 300 400 500 60 600 700)':s=48000:c=5.1(side)" \
    -t 6 -map 0:v -map 1:a -map 1:a \
    -c:v libx265 -preset veryfast -x265-params "keyint=12:log-level=error" -pix_fmt yuv420p10le -b:v 100k \
    -c:a:0 ac3 -b:a:0 192k -c:a:1 dca -strict -2 -b:a:1 768k \
    -disposition:a:0 0 -disposition:a:1 default -bitexact -fflags +bitexact "$OUT/ac3-dts-51.mkv"
# Four audio tracks, each with its own tone: untitled English AAC at 440 Hz, the file's default
# track in AC-3 5.1 at 880 Hz with a title, DTS at 440 Hz, and untitled FLAC
# at 660 Hz whose language is "ger", the older of the two codes for German, which mkvmerge writes.
ffmpeg -v error -y \
    -f lavfi -i "testsrc2=size=160x90:rate=24" \
    -f lavfi -i "sine=frequency=440:sample_rate=48000" -f lavfi -i "sine=frequency=880:sample_rate=48000" \
    -f lavfi -i "sine=frequency=660:sample_rate=48000" \
    -t 6 -map 0:v -map 1:a -map 2:a -map 1:a -map 3:a "${x264[@]}" \
    -c:a:0 aac -b:a:0 64k -ac:a:0 2 -c:a:1 ac3 -b:a:1 192k -ac:a:1 6 \
    -c:a:2 dca -strict -2 -ac:a:2 2 -c:a:3 flac -ac:a:3 2 \
    -metadata:s:a:0 language=eng -metadata:s:a:1 language=jpn -metadata:s:a:1 title=Surround \
    -metadata:s:a:2 language=jpn -metadata:s:a:3 language=ger \
    -disposition:a:0 0 -disposition:a:1 default -disposition:a:2 0 -disposition:a:3 0 \
    -bitexact -fflags +bitexact "$OUT/four-audio-tracks.mkv"
# Pixels a third wider than they are tall: 160 by 90 stored, 213 by 90 shown.
ffmpeg -v error -y \
    -f lavfi -i "testsrc2=size=160x90:rate=24" -f lavfi -i "sine=frequency=440:sample_rate=48000" \
    -t 2 -map 0:v -map 1:a -vf setsar=4/3 "${x264[@]}" -c:a aac -b:a 24k -bitexact -fflags +bitexact "$OUT/anamorphic.mkv"
# HDR video as its transfer function alone: PQ, which HDR10 and Dolby Vision use, and HLG. The
# picture is the test pattern. The declared function is all a playlist reads.
for range in "pq smpte2084" "hlg arib-std-b67"; do
    set -- $range
    ffmpeg -v error -y \
        -f lavfi -i "testsrc2=size=160x90:rate=24" -f lavfi -i "sine=frequency=440:sample_rate=48000" \
        -t 2 -map 0:v -map 1:a \
        -c:v libx265 -preset veryfast -pix_fmt yuv420p10le \
        -x265-params "keyint=12:log-level=error:colorprim=bt2020:transfer=$2:colormatrix=bt2020nc" \
        -c:a aac -b:a 24k -bitexact -fflags +bitexact "$OUT/hdr-$1.mkv"
done
# Dolby Vision profile 5. No encoder here writes it, so the record is written by hand: a `dvcC`
# box added to the sample entry of a plain Main 10 MP4, which ffmpeg then carries into Matroska.
# The picture is not Dolby Vision. The record is all the bridge reads.
ffmpeg -v error -y \
    -f lavfi -i "testsrc2=size=160x90:rate=24" -f lavfi -i "sine=frequency=440:sample_rate=48000" \
    -t 2 -map 0:v -map 1:a \
    -c:v libx265 -preset veryfast -x265-params "keyint=12:log-level=error" -pix_fmt yuv420p10le -tag:v hvc1 \
    -c:a aac -b:a 24k -bitexact -fflags +bitexact "$OUT/main10.mp4"
python3 - "$OUT/main10.mp4" "$OUT/dolby-vision-5.mp4" <<'PYTHON'
import struct, sys
data = bytearray(open(sys.argv[1], "rb").read())
# Version 1.0, then profile 5, level 6, with an RPU and a base layer and no enhancement layer.
record = bytes([1, 0]) + struct.pack(">H", 5 << 9 | 6 << 3 | 0b101) + bytes(20)
box = struct.pack(">I4s", 8 + len(record), b"dvcC") + record

def child(start, end, kind):
    while start + 8 <= end:
        size, found = struct.unpack_from(">I4s", data, start)
        if found == kind:
            return start, size
        start += size
    raise SystemExit(f"no {kind} box")

# Each box on the way down grows by the new box. ffmpeg writes `moov` after the media, so no
# sample offset moves.
grown, start, end = [], 0, len(data)
for kind, header in ((b"moov", 8), (b"trak", 8), (b"mdia", 8), (b"minf", 8), (b"stbl", 8), (b"stsd", 16), (b"hvc1", 86)):
    at, size = child(start, end, kind)
    grown.append(at)
    start, end = at + header, at + size
for at in grown:
    struct.pack_into(">I", data, at, struct.unpack_from(">I", data, at)[0] + len(box))
data[end:end] = box
open(sys.argv[2], "wb").write(data)
PYTHON
ffmpeg -v error -y -i "$OUT/dolby-vision-5.mp4" -map 0 -c copy -bitexact -fflags +bitexact "$OUT/refused-dolby-vision-5.mkv"
rm "$OUT/main10.mp4" "$OUT/dolby-vision-5.mp4"
# Dolby Vision profile 8.1, over an HDR10 base layer, 8.4, over an HLG one, and 8.2, over an SDR
# one, which Apple's players do not take as Dolby Vision. An RPU is on every frame: AVPlayer shows
# nothing of a stream whose record promises RPUs it does not carry. The colour goes into the
# stream itself, where mkvmerge reads the base layer's kind from.
ffmpeg -v error -y -f lavfi -i "sine=frequency=440:sample_rate=48000" -t 2 -c:a aac -b:a 24k "$OUT/tone.m4a"
# Name, the RPU's profile, then the transfer function and primaries as H.265 numbers them.
for dolby in "8-1 8.1 16 9" "8-4 8.4 18 9" "8-2 8.1 1 1"; do
    set -- $dolby
    printf '{"cm_version": "V40", "length": 48, "profile": "%s", "level6": {"max_display_mastering_luminance": 1000, "min_display_mastering_luminance": 1, "max_content_light_level": 1000, "max_frame_average_light_level": 400}}' "$2" > "$OUT/rpu.json"
    dovi_tool generate -j "$OUT/rpu.json" -o "$OUT/rpu.bin" > /dev/null
    ffmpeg -v error -y -f lavfi -i "testsrc2=size=160x90:rate=24" -t 2 \
        -c:v libx265 -preset veryfast -pix_fmt yuv420p10le -x265-params "keyint=12:log-level=error" \
        -bsf:v "hevc_metadata=colour_primaries=$4:transfer_characteristics=$3:matrix_coefficients=$4" -f hevc "$OUT/base.hevc"
    dovi_tool inject-rpu -i "$OUT/base.hevc" --rpu-in "$OUT/rpu.bin" -o "$OUT/dolby-vision.hevc" > /dev/null
    mkvmerge -q -o "$OUT/dolby-vision-$1.mkv" --default-duration 0:24fps "$OUT/dolby-vision.hevc" "$OUT/tone.m4a"
    rm "$OUT/rpu.json" "$OUT/rpu.bin" "$OUT/base.hevc" "$OUT/dolby-vision.hevc"
done
rm "$OUT/tone.m4a"
clip refused-one-keyframe "${x264[@]}" -g 1000 -c:a aac -b:a 24k
# A live recording: no Cues and no Duration. libavformat still indexes the keyframes it passes
# while opening the file, so the missing length is what gives it away.
clip refused-no-duration "${x264[@]}" -c:a aac -b:a 24k -live 1
# A file whose times start at ten minutes, as a cut from a longer recording does. mkvmerge
# writes Duration as the length (4 s), where ffmpeg writes the last end time.
clip late-start-source "${x264[@]}" -c:a aac -b:a 24k -t 4
mkvmerge --quiet --deterministic 0 -o "$OUT/late-start.mkv" \
    --sync 0:600000 --sync 1:600000 "$OUT/late-start-source.mkv"
rm "$OUT/late-start-source.mkv"

# The streams of h264-ffmpeg.mkv in an MPEG transport stream: no index, H.264 with start codes
# and its parameter sets in the stream, AAC with ADTS headers. Encoded again, not copied from
# the MKV, whose times are rounded to its millisecond.
ffmpeg -v error -y "${noisy_h264[@]}" -t 12 -f mpegts "$OUT/ts-h264.ts"
packet_list ts-h264 ts
# The same video with MP2 audio, as a broadcast recording has it.
ffmpeg -v error -y \
    -f lavfi -i "testsrc2=size=160x90:rate=24,noise=alls=40:allf=t" -f lavfi -i "sine=frequency=440:sample_rate=48000" \
    -t 12 -map 0:v -map 1:a -c:v libx264 -preset veryfast -bf 2 -g 12 -keyint_min 12 -sc_threshold 0 -b:v 500k -pix_fmt yuv420p \
    -c:a mp2 -b:a 64k -ac 2 -bitexact -fflags +bitexact -f mpegts "$OUT/ts-mp2.ts"
# And as a Blu-ray or a camcorder stores one: four bytes ahead of each 188-byte packet.
ffmpeg -v error -y "${noisy_h264[@]}" -t 4 -f mpegts -mpegts_m2ts_mode 1 "$OUT/m2ts-h264.m2ts"
packet_list m2ts-h264 m2ts
# The streams of frame-numbers-hevc.mkv, x265's open GOP, in a transport stream: each keyframe
# after the first is a CRA picture, with pictures stored after it that display before it.
ffmpeg -v error -y "${numbered_hevc[@]}" -f mpegts "$OUT/ts-hevc-open-gop.ts"
# A transport stream copied from a Matroska file keeps the times the MKV rounded to its
# millisecond.
ffmpeg -v error -y -i "$OUT/frame-numbers-hevc.mkv" -t 6 -map 0 -c copy -bitexact -fflags +bitexact -f mpegts "$OUT/ts-copied-from-mkv.ts"
# Two four-second parts joined into one file, as a downloaded HLS stream is. The video runs
# on. The second part's audio starts 187 and a half frames after the first part's, behind a
# hole: each part's audio is cut at 3.9 s.
part() {
    ffmpeg -v error -y \
        -f lavfi -i "color=black:size=160x90:rate=24,format=gray,geq=lum='if(mod(floor((N+$1)/pow(2\,floor(X/10)))\,2)\,235\,16)',format=yuv420p" \
        -f lavfi -i "sine=frequency=440:sample_rate=48000" \
        -t 4 -map 0:v -map 1:a \
        -c:v libx264 -preset veryfast -bf 2 -g 48 -keyint_min 48 -sc_threshold 0 -pix_fmt yuv420p \
        -c:a aac -b:a 24k -ac 1 -af atrim=end=3.9 -bitexact -fflags +bitexact \
        -muxdelay 0 -output_ts_offset "$2" -f mpegts "$OUT/$3"
}
part 0 0 part-0.ts
# The first part's pictures start two frames in, where its decode times start at zero.
part 96 4.083333333 part-1.ts
cat "$OUT/part-0.ts" "$OUT/part-1.ts" > "$OUT/ts-audio-gap.ts"
rm "$OUT/part-0.ts" "$OUT/part-1.ts"
# x264's open GOP: keyframes after the first are I pictures with a recovery point, not IDR.
ffmpeg -v error -y \
    -f lavfi -i "color=black:size=160x90:rate=24,format=gray,geq=lum='if(mod(floor(N/pow(2\,floor(X/10)))\,2)\,235\,16)',format=yuv420p" \
    -f lavfi -i "sine=frequency=440:sample_rate=48000" \
    -t 60 -map 0:v -map 1:a \
    -c:v libx264 -preset veryfast -bf 2 -g 48 -keyint_min 48 -sc_threshold 0 -x264-params open-gop=1 -pix_fmt yuv420p \
    -c:a aac -b:a 24k -ac 1 -bitexact -fflags +bitexact -f mpegts "$OUT/ts-h264-open-gop.ts"
# Two programs in one transport stream, as a recording of a whole multiplex has: the second
# program's audio is AC-3 at 880 Hz and is not the first program's to play.
ffmpeg -v error -y \
    -f lavfi -i "testsrc2=size=160x90:rate=24" -f lavfi -i "sine=frequency=440:sample_rate=48000" \
    -f lavfi -i "testsrc2=size=160x90:rate=24" -f lavfi -i "sine=frequency=880:sample_rate=48000" \
    -t 4 -map 0:v -map 1:a -map 2:v -map 3:a \
    "${x264[@]}" -c:a:0 aac -b:a:0 24k -c:a:1 ac3 -b:a:1 64k \
    -program title=first:st=0:st=1 -program title=second:st=2:st=3 \
    -bitexact -fflags +bitexact -f mpegts "$OUT/ts-two-programs.ts"
# A transport stream's clock is 33 bits of 90 kHz and wraps after 95,443.7 s. This one starts
# 2.3 s before that, so libavformat times its start below zero.
ffmpeg -v error -y -f lavfi -i "testsrc2=size=160x90:rate=24" -f lavfi -i "sine=frequency=440:sample_rate=48000" \
    -t 4 -map 0:v -map 1:a "${x264[@]}" -bf 2 -keyint_min 12 -sc_threshold 0 -c:a aac -b:a 24k \
    -bitexact -fflags +bitexact -output_ts_offset 95440 -f mpegts "$OUT/ts-clock-wraps.ts"
# AAC at 44.1 kHz: a frame is 2089.8 ticks of the 90 kHz clock, so each is timed up to a tick
# off where it plays.
ffmpeg -v error -y -f lavfi -i "testsrc2=size=160x90:rate=24" -f lavfi -i "sine=frequency=440:sample_rate=44100" \
    -t 4 -map 0:v -map 1:a "${x264[@]}" -c:a aac -b:a 24k \
    -bitexact -fflags +bitexact -f mpegts "$OUT/ts-aac-44100.ts"
# One video and one audio stream, as FLV holds, with the noise of h264-ffmpeg.mkv.
noisy_pair=(
    -f lavfi -i "testsrc2=size=160x90:rate=24,noise=alls=40:allf=t"
    -f lavfi -i "sine=frequency=440:sample_rate=48000"
    -t 12 -map 0:v -map 1:a
    -c:v libx264 -preset veryfast -g 12 -keyint_min 12 -sc_threshold 0 -b:v 500k -pix_fmt yuv420p
    -bitexact -fflags +bitexact
)
# FLV: no index, H.264 and AAC in the form an MP4 holds them.
ffmpeg -v error -y "${noisy_pair[@]}" -bf 2 -c:a aac -b:a 32k -ac 2 "$OUT/flv-h264.flv"
packet_list flv-h264 flv
# AVI: an index of every frame, H.264 with start codes, and no presentation times. Without
# B-frames a picture shows when it is decoded.
ffmpeg -v error -y "${noisy_pair[@]}" -bf 0 -c:a ac3 -b:a 64k -ac 2 "$OUT/avi-h264.avi"
packet_list avi-h264 avi
# ASF: no index libavformat lists, times in milliseconds, and decode times only for H.264.
ffmpeg -v error -y "${noisy_pair[@]}" -bf 0 -c:a ac3 -b:a 64k -ac 2 "$OUT/asf-h264.asf"
packet_list asf-h264 asf
# Files the bridge opens to say what stops them. With B-frames an AVI's pictures have no
# times to show at.
short=(-f lavfi -i "testsrc2=size=160x90:rate=24" -f lavfi -i "sine=frequency=440:sample_rate=48000" -t 2 -map 0:v -map 1:a)
ffmpeg -v error -y "${short[@]}" "${x264[@]}" -bf 2 -c:a ac3 -b:a 64k -bitexact -fflags +bitexact "$OUT/refused-avi-b-frames.avi"
# Clips for converted video: the numbered picture in codecs no Apple decoder takes, or takes on
# some devices only. Twelve seconds with a keyframe every two make six segments.
numbered() {
    local file=$1 seconds=$2; shift 2
    ffmpeg -v error -y \
        -f lavfi -i "color=black:size=160x90:rate=24,format=gray,geq=lum='if(mod(floor(N/pow(2\,floor(X/10)))\,2)\,235\,16)',format=yuv420p" \
        -f lavfi -i "sine=frequency=440:sample_rate=48000" \
        -t "$seconds" -map 0:v -map 1:a -c:a aac -b:a 24k -ac 1 "$@" -bitexact -fflags +bitexact "$OUT/$file"
}
# A minute, for a seek past what a player buffered.
numbered numbered-av1.mkv 60 -c:v libsvtav1 -preset 10 -g 48 -svtav1-params "lp=1:keyint=48:scd=0" -pix_fmt yuv420p10le 2>/dev/null
# MPEG-2 as its encoder writes it: every group of pictures open, so the two pictures shown
# before each keyframe are stored after it and need the group before to decode.
numbered numbered-mpeg2-open-gop.ts 60 -c:v mpeg2video -bf 2 -g 48 -sc_threshold 0 -b:v 60k -pix_fmt yuv420p -muxrate 0 -f mpegts
numbered numbered-vp9.mkv 12 -c:v libvpx-vp9 -g 48 -keyint_min 48 -b:v 100k -deadline realtime -pix_fmt yuv420p
numbered numbered-vp8.mkv 12 -c:v libvpx -g 48 -keyint_min 48 -b:v 100k -deadline realtime -auto-alt-ref 0 -pix_fmt yuv420p
numbered numbered-mpeg4.mkv 12 -c:v mpeg4 -bf 2 -g 48 -sc_threshold 0 -b:v 100k
numbered numbered-wmv2.mkv 12 -c:v wmv2 -g 48 -sc_threshold 0 -b:v 100k
numbered numbered-h264-high10.mkv 12 -c:v libx264 -preset veryfast -bf 2 -g 48 -keyint_min 48 -sc_threshold 0 -pix_fmt yuv420p10le
numbered numbered-h264-422.mkv 12 -c:v libx264 -preset veryfast -bf 2 -g 48 -keyint_min 48 -sc_threshold 0 -pix_fmt yuv422p
numbered numbered-flv1.flv 12 -c:v flv -g 48 -sc_threshold 0 -b:v 100k -ar 44100
# MPEG-4 part 2 is what an old AVI holds. Without B-frames a picture shows when it is decoded,
# which is the only time an AVI gives it. AC-3, because the AVI muxer puts an empty picture
# after the first to make up for an MP3 encoder's delay, and every later one is a frame late.
numbered numbered-mpeg4.avi 12 -c:v mpeg4 -bf 0 -g 48 -sc_threshold 0 -b:v 100k -c:a ac3 -b:a 64k
# An MPEG program stream, as a DVD's VOB is. At a constant 800 kbit/s each picture starts a PES
# packet of its own and so has a time, as in real files; at the encoder's own low rate a third
# of them have none.
numbered numbered-mpeg2.mpg 12 -c:v mpeg2video -bf 2 -g 48 -sc_threshold 0 -b:v 800k -minrate 800k -maxrate 800k -bufsize 200k -pix_fmt yuv420p -c:a ac3 -b:a 64k -ac 2 -f vob
# H.264 in a program stream, each picture with a time of its own as above.
numbered numbered-h264.mpg 12 -c:v libx264 -preset veryfast -bf 2 -g 48 -keyint_min 48 -sc_threshold 0 -pix_fmt yuv420p -b:v 600k -minrate 600k -maxrate 600k -bufsize 150k -x264-params nal-hrd=cbr -c:a mp2 -b:a 64k -f vob
# AC-3 in a program stream, a minute long, for a seek past what a player buffered. 9 of its
# 1,876 frames start in one PES packet and end in the next, and libavformat gives each the next
# one's time. At a constant rate each picture has a time, down to 100 kbit/s.
numbered numbered-h264-ac3.mpg 60 -c:v libx264 -preset veryfast -bf 2 -g 48 -keyint_min 48 -sc_threshold 0 -pix_fmt yuv420p -b:v 100k -minrate 100k -maxrate 100k -bufsize 50k -x264-params nal-hrd=cbr -c:a ac3 -b:a 64k -ac 2 -f vob
packet_list numbered-h264-ac3 mpg
# A program stream whose second audio stream plays from 20 s to 24 s only, so libavformat finds
# it neither at open nor at the end, as a DVD's subtitles are. Three files joined byte for byte,
# as a DVD's VOBs are. The first is delayed 0.583 s and the others are moved by as much, so the
# times run on across each join, and each one's audio ends with its video.
late_part() {
    local file=$1 start=$2 seconds=$3 streams=$4
    local audio offset=0 extra=() maps=(-map 0:v -map 1:a)
    audio=$(echo "$seconds - 0.03" | bc)
    [ "$start" != 0 ] && offset=$(echo "$start + 0.583333" | bc)
    if [ "$streams" = 2 ]; then
        extra=(-f lavfi -i "sine=frequency=880:sample_rate=48000:duration=$audio")
        maps+=(-map 2:a)
    fi
    ffmpeg -v error -y \
        -f lavfi -i "color=black:size=160x90:rate=24,format=gray,geq=lum='if(mod(floor((N+$((start * 24)))/pow(2\,floor(X/10)))\,2)\,235\,16)',format=yuv420p" \
        -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=$audio" "${extra[@]}" \
        -t "$seconds" "${maps[@]}" -c:v libx264 -preset veryfast -bf 2 -g 48 -keyint_min 48 -sc_threshold 0 -pix_fmt yuv420p \
        -b:v 100k -minrate 100k -maxrate 100k -bufsize 50k -x264-params nal-hrd=cbr -c:a ac3 -b:a 64k -ac 2 \
        -output_ts_offset "$offset" -f vob -bitexact -fflags +bitexact "$file"
}
late_parts=$(mktemp -d)
late_part "$late_parts/1.mpg" 0 20 1
late_part "$late_parts/2.mpg" 20 4 2
late_part "$late_parts/3.mpg" 24 16 1
cat "$late_parts/1.mpg" "$late_parts/2.mpg" "$late_parts/3.mpg" > "$OUT/numbered-h264-late-audio.mpg"
rm -r "$late_parts"
# Sixteen seconds with a keyframe every half second, enough to be sampled for its keyframes.
numbered numbered-mpeg2-mp2.mpg 16 -c:v mpeg2video -bf 2 -g 12 -b:v 800k -minrate 800k -maxrate 800k -bufsize 200k -pix_fmt yuv420p -c:a mp2 -b:a 64k -f vob
# MPEG-4 with B-pictures where the container stores decode times only, as DivX and Xvid are in
# an AVI. Closed groups of pictures, as those encoders write. The AVI is a minute long, for a
# seek past what a player buffered, with its keyframes forced: -g 48 with B-pictures puts one
# every 46 pictures.
numbered numbered-mpeg4-b.avi 60 -c:v mpeg4 -bf 2 -flags +cgop -g 480 -force_key_frames 'expr:eq(mod(n,48),0)' -sc_threshold 1000000000 -b:v 100k -c:a ac3 -b:a 64k -ac 2
# Files with no audio stream, a minute long: H.264 that is copied, and MPEG-4 with B-pictures in
# an AVI that is converted.
numbered numbered-h264-silent.mkv 60 -c:v libx264 -preset veryfast -bf 2 -g 48 -keyint_min 48 -sc_threshold 0 -pix_fmt yuv420p -an
numbered numbered-mpeg4-silent.avi 60 -c:v mpeg4 -bf 2 -flags +cgop -g 480 -force_key_frames 'expr:eq(mod(n,48),0)' -sc_threshold 1000000000 -b:v 100k -an
numbered numbered-mpeg4-b.asf 12 -c:v mpeg4 -bf 2 -flags +cgop -g 48 -sc_threshold 1000000000 -b:v 200k -c:a wmav2 -b:a 32k -ac 2
# WMV with WMA is what an ASF holds.
numbered numbered-wmv2.asf 12 -c:v wmv2 -g 48 -sc_threshold 0 -b:v 100k -c:a wmav2 -b:a 32k -ac 2
# Video stored as fields: fifty numbered pictures a second woven into 25 frames, the even
# picture on the top field. Each field keeps its own number on its own rows. Both encoders code
# fields only at a height that divides by 32 (MPEG-2) or four (x264).
fields() {
    local file=$1; shift
    ffmpeg -v error -y \
        -f lavfi -i "color=black:size=160x96:rate=50,format=gray,geq=lum='if(mod(floor(N/pow(2\,floor(X/10)))\,2)\,235\,16)',format=yuv420p" \
        -f lavfi -i "sine=frequency=440:sample_rate=48000" \
        -t 12 -map 0:v -map 1:a -vf "tinterlace=interleave_top,fieldorder=tff" -flags +ilme+ildct -bf 2 -g 24 -sc_threshold 0 \
        -pix_fmt yuv420p "$@" -c:a aac -b:a 24k -ac 1 -bitexact -fflags +bitexact -f mpegts "$OUT/$file"
}
fields numbered-interlaced-mpeg2.ts -c:v mpeg2video -b:v 150k -muxrate 0
fields numbered-interlaced-h264.ts -c:v libx264 -preset veryfast -x264-params tff=1:open-gop=1 -keyint_min 24
ls -l "$OUT"
