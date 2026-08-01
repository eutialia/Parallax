#!/usr/bin/env python3
"""Generate the Playback Lab test-media matrix with Docker ffmpeg.

Produces synthetic videos whose content doubles as measurement ground truth:
- burned-in timecode (HH:MM:SS + frame number) so any screenshot reveals the
  exact playback position
- a 440 Hz tone with a beep every second so audio dropouts are audible and
  their gaps can be matched against log timestamps
- a light noise overlay so the encoder actually consumes the target bitrate
  (realistic file sizes and seek tables; a clean test pattern compresses to
  almost nothing)
- timecode SRT subtitles, both muxed and as sidecar files, for subtitle-timing
  tests

Requires Docker with the linuxserver/ffmpeg image. Host ffmpeg is NOT needed.

Usage:
  ./gen_media.py               # full matrix into ~/Downloads/PlaybackLab
  ./gen_media.py --out DIR     # custom output directory
  ./gen_media.py --only NAME   # regenerate a single entry
  ./gen_media.py --smoke       # 10-second versions of everything (fast check)
"""

import argparse
import json
import subprocess
import sys
from pathlib import Path

IMAGE = "linuxserver/ffmpeg"
SHORT_SECONDS = 300
LONG_SECONDS = 3600

VIDEO_SRC = (
    "testsrc2=size=1920x1080:rate=24,"
    "noise=alls=8:allf=t,"
    "drawtext=text='%{pts\\:hms} f%{n}':fontsize=64:fontcolor=white:"
    "box=1:boxcolor=black@0.6:x=(w-tw)/2:y=h-th-40"
)
AUDIO_SRC = "sine=frequency=440:beep_factor=4:sample_rate=48000"

X265_SHORT = "keyint=48:min-keyint=48:bitrate=4000:vbv-maxrate=4000:vbv-bufsize=8000:log-level=error"
X265_LONG = "keyint=240:min-keyint=240:bitrate=5000:vbv-maxrate=5000:vbv-bufsize=10000:log-level=error"

SURROUND = ["aformat=channel_layouts=5.1"]
STEREO = ["aformat=channel_layouts=stereo"]


def audio_args(index, codec, layout_filter, bitrate=None, title=None, default=None, extra=None):
    """ffmpeg args for one audio stream mapped from the sine input."""
    args = ["-map", "1:a", f"-filter:a:{index}", layout_filter[0], f"-c:a:{index}", codec]
    if bitrate:
        args += [f"-b:a:{index}", bitrate]
    if extra:
        args += extra
    if title:
        args += [f"-metadata:s:a:{index}", f"title={title}"]
    args += [f"-metadata:s:a:{index}", "language=eng"]
    args += [f"-disposition:a:{index}", "default" if default else "0"]
    return args


# Each entry: output name, video args, list of audio streams, mux extras, subtitles flag.
MATRIX = [
    {
        "name": "hevc-truehd-ac3.mkv",
        "why": "the dropout repro shape: undecodable TrueHD default track + AC3 fallback",
        "video": ["-c:v", "libx265", "-preset", "ultrafast", "-x265-params", X265_SHORT],
        "audio": [
            dict(codec="truehd", layout=SURROUND, title="TrueHD", default=True),
            dict(codec="ac3", layout=SURROUND, bitrate="640k", title="Compatibility Track"),
        ],
        "subs": True,
    },
    {
        "name": "hevc-ac3.mkv",
        "why": "control: same shape without the dead default track",
        "video": ["-c:v", "libx265", "-preset", "ultrafast", "-x265-params", X265_SHORT],
        "audio": [dict(codec="ac3", layout=SURROUND, bitrate="640k", default=True)],
    },
    {
        "name": "hevc-opus.mkv",
        "why": "known-working combination",
        "video": ["-c:v", "libx265", "-preset", "ultrafast", "-x265-params", X265_SHORT],
        "audio": [dict(codec="libopus", layout=STEREO, bitrate="192k", default=True)],
    },
    {
        "name": "hevc-eac3.mkv",
        "why": "E-AC3 / Atmos-adjacent copy-through path",
        "video": ["-c:v", "libx265", "-preset", "ultrafast", "-x265-params", X265_SHORT],
        "audio": [dict(codec="eac3", layout=SURROUND, bitrate="768k", default=True)],
    },
    {
        "name": "hevc-dts.mkv",
        "why": "DTS decoder coverage",
        "video": ["-c:v", "libx265", "-preset", "ultrafast", "-x265-params", X265_SHORT],
        "audio": [dict(codec="dca", layout=SURROUND, bitrate="768k", default=True)],
    },
    {
        "name": "hevc-flac.mkv",
        "why": "lossless audio path",
        "video": ["-c:v", "libx265", "-preset", "ultrafast", "-x265-params", X265_SHORT],
        "audio": [dict(codec="flac", layout=STEREO, default=True)],
    },
    {
        "name": "h264-aac.mp4",
        "why": "AVKit-eligible control (probe/bridge path)",
        "video": ["-c:v", "libx264", "-preset", "ultrafast", "-b:v", "4M", "-g", "48"],
        "audio": [dict(codec="aac", layout=STEREO, bitrate="256k", default=True)],
        "mux": ["-movflags", "+faststart"],
    },
    {
        "name": "av1-opus.mkv",
        "why": "long-GOP AV1 seek behavior",
        "video": ["-c:v", "libsvtav1", "-preset", "10", "-crf", "40", "-svtav1-params", "keyint=240"],
        "audio": [dict(codec="libopus", layout=STEREO, bitrate="192k", default=True)],
    },
    {
        "name": "wmv2-wmav2.wmv",
        "why": "legacy ASF/WMA path (ffmpeg has no WMV3/VC-1 encoder — drop a real"
               " wmv3 file into the folder for the exact decode-failed repro)",
        "video": ["-c:v", "wmv2", "-b:v", "4M", "-g", "48"],
        "audio": [dict(codec="wmav2", layout=STEREO, bitrate="128k", default=True)],
    },
    {
        "name": "longseek-hevc-ac3.mkv",
        "why": "deep-seek / linear-read repro: 60 min, 10 s GOP, ~5 Mbps (~37 MB per minute of depth)",
        "video": ["-c:v", "libx265", "-preset", "ultrafast", "-x265-params", X265_LONG],
        "audio": [dict(codec="ac3", layout=SURROUND, bitrate="640k", default=True)],
        "subs": True,
        "long": True,
    },
]


def write_srt(path: Path, seconds: int) -> None:
    lines = []
    for t in range(seconds):
        h, m, s = t // 3600, (t % 3600) // 60, t % 60
        lines.append(
            f"{t + 1}\n"
            f"{h:02}:{m:02}:{s:02},000 --> {h:02}:{m:02}:{s:02},900\n"
            f"LAB t={t}s {h:02}:{m:02}:{s:02}\n"
        )
    path.write_text("\n".join(lines))


def generate(entry: dict, out: Path, smoke: bool) -> None:
    seconds = 10 if smoke else (LONG_SECONDS if entry.get("long") else SHORT_SECONDS)
    name = entry["name"]
    srt = None
    if entry.get("subs"):
        srt = out / (Path(name).stem + ".srt")
        write_srt(srt, seconds)

    cmd = [
        "docker", "run", "--rm", "-v", f"{out}:/out", IMAGE,
        "-hide_banner", "-loglevel", "error", "-stats",
        "-f", "lavfi", "-i", VIDEO_SRC,
        "-f", "lavfi", "-i", AUDIO_SRC,
    ]
    if srt:
        cmd += ["-i", f"/out/{srt.name}"]
    cmd += ["-t", str(seconds), "-map", "0:v"] + entry["video"]
    for i, a in enumerate(entry["audio"]):
        cmd += audio_args(i, a["codec"], a["layout"], a.get("bitrate"),
                          a.get("title"), a.get("default"))
    if srt:
        cmd += ["-map", "2:s", "-c:s", "srt", "-metadata:s:s:0", "title=Timecode"]
    if entry.get("mux"):
        cmd += entry["mux"]
    cmd += ["-strict", "-2", "-y", f"/out/{name}"]

    print(f"→ {name} ({seconds}s)", flush=True)
    subprocess.run(cmd, check=True)


def probe(out: Path, name: str) -> dict:
    cmd = [
        "docker", "run", "--rm", "--entrypoint", "ffprobe", "-v", f"{out}:/out", IMAGE,
        "-v", "error", "-print_format", "json", "-show_format", "-show_streams", f"/out/{name}",
    ]
    data = json.loads(subprocess.run(cmd, check=True, capture_output=True).stdout)
    streams = [
        {
            "type": s["codec_type"],
            "codec": s.get("codec_name"),
            "channels": s.get("channels"),
            "default": bool(s.get("disposition", {}).get("default")),
            "title": s.get("tags", {}).get("title"),
        }
        for s in data["streams"]
    ]
    fmt = data["format"]
    return {
        "streams": streams,
        "duration_s": round(float(fmt["duration"])),
        "size_bytes": int(fmt["size"]),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", default=str(Path.home() / "Downloads/PlaybackLab"))
    parser.add_argument("--only", help="generate a single entry by file name")
    parser.add_argument("--smoke", action="store_true", help="10-second versions")
    args = parser.parse_args()

    out = Path(args.out).resolve()
    out.mkdir(parents=True, exist_ok=True)

    entries = [e for e in MATRIX if not args.only or e["name"] == args.only]
    if not entries:
        sys.exit(f"no matrix entry named {args.only!r}")

    for entry in entries:
        generate(entry, out, args.smoke)

    manifest = {
        e["name"]: {"why": e["why"], **probe(out, e["name"])}
        for e in (entries if args.only else MATRIX)
        if (out / e["name"]).exists()
    }
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"\nmanifest → {out / 'manifest.json'}")
    total = sum(m["size_bytes"] for m in manifest.values())
    print(f"total size: {total / 1e9:.2f} GB")


if __name__ == "__main__":
    main()
