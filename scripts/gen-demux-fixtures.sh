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
ffmpeg -v error -y \
    -f lavfi -i "testsrc2=size=160x90:rate=24,noise=alls=40:allf=t" \
    -f lavfi -i "sine=frequency=440:sample_rate=48000" \
    -t 12 -map 0:v -map 1:a -map 1:a \
    -c:v libx264 -preset veryfast -bf 2 -g 12 -keyint_min 12 -sc_threshold 0 -b:v 500k -pix_fmt yuv420p \
    -c:a:0 aac -b:a:0 32k -ac:a:0 2 \
    -c:a:1 ac3 -b:a:1 64k -ac:a:1 2 \
    -bitexact -fflags +bitexact \
    "$OUT/h264-ffmpeg.mkv"

# The same streams as mkvmerge lays them out: different clusters, cue placement and lacing.
mkvmerge --quiet --deterministic 0 -o "$OUT/h264-mkvmerge.mkv" "$OUT/h264-ffmpeg.mkv"

for name in h264-ffmpeg h264-mkvmerge; do
    ffprobe -v error -show_packets -show_data_hash md5 -of json "$OUT/$name.mkv" \
        | python3 -c '
import json, sys
packets = json.load(sys.stdin)["packets"]
rows = [[p["stream_index"], int(p["pts"]), int(p["size"]), "K" in p["flags"], p["data_hash"].split(":")[1]]
        for p in packets]
json.dump(rows, sys.stdout, separators=(",", ":"))
' > "$OUT/$name.packets.json"
done
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
ffmpeg -v error -y \
    -f lavfi -i "color=black:size=160x90:rate=24,format=gray,geq=lum='if(mod(floor(N/pow(2\,floor(X/10)))\,2)\,235\,16)',format=yuv420p" \
    -f lavfi -i "sine=frequency=440:sample_rate=48000" \
    -t 60 -map 0:v -map 1:a \
    -c:v libx265 -preset veryfast -x265-params "keyint=48:min-keyint=48:scenecut=0:log-level=error" -pix_fmt yuv420p \
    -c:a ac3 -b:a 64k -ac 2 \
    -bitexact -fflags +bitexact \
    "$OUT/frame-numbers-hevc.mkv"

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
ls -l "$OUT"
