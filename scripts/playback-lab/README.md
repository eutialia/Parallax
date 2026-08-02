# Playback Lab

An autonomous simulator test harness for Parallax's playback engine. The
`Parallax` scheme has a DEBUG launch mode (`-playbackLab <scenario.json>`)
that adds an SMB source, plays a file from it, drives a scripted timeline of
playback commands, and writes JSONL telemetry to its app container. This
directory holds the host-side driver that builds the app, runs a scenario on
the simulator, captures telemetry + unified logs, and analyzes the result for
seek latency, stalls, and audio-dropout signatures.

## One-time setup

1. Copy `lab-config.local.json.example` to `lab-config.local.json` (git-ignored)
   and fill in your SMB server's host, username, password, and share.
2. Generate the test-media matrix (`./gen_media.py`, requires Docker) and copy
   its output — `~/Downloads/PlaybackLab` — onto the share, into a `Debug`
   folder (e.g. `Media/Debug/hevc-truehd-ac3.mkv`). `path` in the config
   points at that folder.

## Usage

```
./run.py --scenario scenarios/smoke.json                     # build + run
./run.py --scenario scenarios/dropout.json --no-build         # reuse last build
./run.py --scenario scenarios/deepseek.json --sim "iPhone 17 Pro"
./run.py --scenario scenarios/smoke.json --file custom-file.mkv
./run.py --analyze results/dropout-20260731-201500            # re-run analyzer only
./run.py --selftest                                            # analyzer unit checks
```

Builds land in an isolated DerivedData at
`~/Library/Caches/ParallaxPlaybackLab/DerivedData` (never Xcode's shared
default — headless builds poison its module cache).

## Scenario command vocabulary

`waitPlaying` (timeoutSeconds), `wait` (seconds), `play`, `pause`,
`seek`/`scrub` (toSeconds), `skip` (bySeconds), `audioTrack` (name — case-insensitive
substring; refused tracks are recorded, not selected), `subtitle` (name), `finish`.

A scenario may also set top-level `"resume": true` to honor the target's saved
resume position; by default runs clear it so measurements start deterministic.

## Results

Each run creates `scripts/playback-lab/results/<scenario>-<timestamp>/`
containing `scenario.json` (password redacted), `telemetry.jsonl`,
`vlc-log.ndjson`, and `analysis.json` — plus a printed report covering the
phase timeline, seek latencies, stall windows, and dropout signatures.
Exit code: `0` done, `2` failed, `3` timeout.
