#!/bin/bash
# Regenerates the media bridge's fixtures: small MKVs, ffprobe's packet list for the two the
# demuxer and segment tests compare against, a clip whose picture is its own frame number, and
# files the bridge has to refuse.
# Usage: scripts/gen-demux-fixtures.sh    (needs macOS, ffmpeg with libx264 and libx265, ffprobe, mkvmerge, dovi_tool and python3)
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
clip refused-mpeg4-video -c:v mpeg4 -g 12 -b:v 100k -c:a aac -b:a 24k
clip refused-dts-audio "${x264[@]}" -c:a dca -strict -2 -ac 2
# 10-bit H.264, which the bridge delivers to a device that decodes it.
clip h264-high10 -c:v libx264 -preset veryfast -g 12 -pix_fmt yuv420p10le -b:v 100k -c:a aac -b:a 24k
# AAC Low Delay, object type 23, which only AudioToolbox's encoder writes.
clip refused-ld-aac "${x264[@]}" -c:a aac_at -profile:a 22 -ac 2
# HE-AAC and HE-AAC v2, object types 5 and 29, which the bridge delivers. Four seconds make two
# segments.
for profile in "he-aac 4" "he-aac-v2 28"; do
    set -- $profile
    ffmpeg -v error -y \
        -f lavfi -i "testsrc2=size=160x90:rate=24" -f lavfi -i "sine=frequency=440:sample_rate=48000" \
        -t 4 -map 0:v -map 1:a "${x264[@]}" -c:a aac_at -profile:a "$2" -ac 2 -bitexact -fflags +bitexact "$OUT/$1.mkv"
done
# The other audio codecs the bridge delivers, and AV1 video.
for codec in "flac flac" "eac3 eac3 -b:a 96k" "opus libopus -b:a 32k"; do
    set -- $codec
    name=$1; shift
    ffmpeg -v error -y \
        -f lavfi -i "testsrc2=size=160x90:rate=24" -f lavfi -i "sine=frequency=440:sample_rate=48000" \
        -t 4 -map 0:v -map 1:a "${x264[@]}" -c:a "$@" -ac 2 -bitexact -fflags +bitexact "$OUT/$name.mkv"
done
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
# Four audio tracks, each with its own tone: untitled English AAC at 440 Hz, the file's default
# track in AC-3 5.1 at 880 Hz with a title, DTS, which the bridge leaves out, and untitled FLAC
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
# Interlaced H.264, which the bridge refuses. x264 codes fields only at a height that divides by four.
ffmpeg -v error -y -f lavfi -i "testsrc2=size=160x96:rate=25" -f lavfi -i "sine=frequency=440:sample_rate=48000" \
    -t 2 -map 0:v -map 1:a -c:v libx264 -preset veryfast -flags +ilme+ildct -x264-params tff=1 -g 25 -pix_fmt yuv420p \
    -c:a aac -b:a 24k -bitexact -fflags +bitexact -f mpegts "$OUT/refused-interlaced.ts"
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
# Files the bridge opens to say what stops them. With B-frames an AVI's pictures have no
# times to show at. MPEG-4 part 2 with MP3 is what an old AVI holds, and WMV with WMA an ASF.
# H.264 and AC-3 in an ASF are codecs the bridge delivers in a container it cannot read in spans.
short=(-f lavfi -i "testsrc2=size=160x90:rate=24" -f lavfi -i "sine=frequency=440:sample_rate=48000" -t 2 -map 0:v -map 1:a)
ffmpeg -v error -y "${short[@]}" "${x264[@]}" -bf 2 -c:a ac3 -b:a 64k -bitexact -fflags +bitexact "$OUT/refused-avi-b-frames.avi"
ffmpeg -v error -y "${short[@]}" -c:v mpeg4 -g 12 -b:v 100k -c:a libmp3lame -b:a 32k -bitexact -fflags +bitexact "$OUT/refused-avi-mpeg4.avi"
ffmpeg -v error -y "${short[@]}" -c:v wmv2 -g 12 -b:v 100k -c:a wmav2 -b:a 32k -bitexact -fflags +bitexact "$OUT/refused-asf-wmv.asf"
ffmpeg -v error -y "${short[@]}" "${x264[@]}" -bf 0 -c:a ac3 -b:a 64k -bitexact -fflags +bitexact "$OUT/refused-asf-h264.asf"
# An MPEG program stream, as a DVD's VOB is: opened only to name its codec.
ffmpeg -v error -y "${short[@]}" -c:v mpeg2video -g 12 -b:v 200k -c:a mp2 -b:a 64k -bitexact -fflags +bitexact -f vob "$OUT/refused-program-stream.mpg"
ls -l "$OUT"
