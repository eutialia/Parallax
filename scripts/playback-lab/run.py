#!/usr/bin/env python3
"""Playback Lab — host-side driver for Parallax's DEBUG `-playbackLab` harness.

Builds (or reuses) the Parallax app, installs it on a simulator, feeds it a
merged scenario JSON, captures unified-log + app telemetry while the scenario
runs, and analyzes the result for seek latency / stalls / audio-dropout
signatures.

Usage:
    ./run.py --scenario scenarios/dropout.json
    ./run.py --scenario scenarios/smoke.json --file custom.mkv --sim "iPhone 17 Pro"
    ./run.py --scenario scenarios/deepseek.json --no-build
    ./run.py --analyze results/dropout-20260731-201500
    ./run.py --selftest

STDLIB ONLY — no pip dependencies. Requires macOS + Xcode command line tools.
"""

import argparse
import collections
import datetime
import json
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

SUBSYSTEM = "com.lhdev.parallax"
DEFAULT_SIM = "iPhone 17 Pro"
DEFAULT_CONFIG = "lab-config.local.json"
DERIVED_DATA = Path.home() / "Library/Caches/ParallaxPlaybackLab/DerivedData"
LOG_TS_FORMAT = "%Y-%m-%d %H:%M:%S.%f%z"
SEEK_CMDS = ("seek", "skip", "scrub")


# --------------------------------------------------------------------------
# Config / scenario loading + merging
# --------------------------------------------------------------------------

def resolve_path(script_dir: Path, raw: str) -> Path:
    p = Path(raw)
    return p if p.is_absolute() else (script_dir / p)


def load_json(path: Path) -> dict:
    if not path.exists():
        sys.exit(f"file not found: {path}")
    return json.loads(path.read_text())


def merge_scenario(config: dict, scenario: dict, file_override: str | None) -> dict:
    return {
        "server": config["server"],
        "path": config.get("path", ""),
        "file": file_override or scenario["file"],
        "resume": scenario.get("resume", False),
        "timeline": scenario["timeline"],
    }


def redact_scenario(merged: dict) -> dict:
    redacted = json.loads(json.dumps(merged))
    server = redacted.get("server", {})
    if "password" in server:
        server["password"] = "REDACTED"
    return redacted


def default_timeout(timeline: list) -> float:
    total = 180.0
    for cmd in timeline:
        total += cmd.get("seconds", 0)
        total += cmd.get("timeoutSeconds", 60 if cmd.get("cmd") == "waitPlaying" else 0)
    return total


# --------------------------------------------------------------------------
# Xcode build
# --------------------------------------------------------------------------

def build_app(repo_root: Path, sim_name: str, derived_data: Path) -> None:
    proj = repo_root / "Parallax.xcodeproj"
    cmd = [
        "xcodebuild",
        "-project", str(proj),
        "-scheme", "Parallax",
        "-configuration", "Debug",
        "-destination", f"platform=iOS Simulator,name={sim_name}",
        "-derivedDataPath", str(derived_data),
        "build",
    ]
    print(f"[build] xcodebuild -scheme Parallax -destination 'platform=iOS Simulator,name={sim_name}' …", flush=True)
    tail = collections.deque(maxlen=40)
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
    line_count = 0
    for line in proc.stdout:
        tail.append(line.rstrip("\n"))
        line_count += 1
        if line_count % 200 == 0:
            print(f"[build] … {line_count} lines of build output so far", flush=True)
    proc.wait()
    if proc.returncode != 0:
        print("[build] FAILED — last 40 lines:", file=sys.stderr)
        print("\n".join(tail), file=sys.stderr)
        sys.exit(1)
    print(f"[build] ok ({line_count} lines)", flush=True)


def app_bundle_path(derived_data: Path) -> Path:
    return derived_data / "Build/Products/Debug-iphonesimulator/Parallax.app"


def read_bundle_id(app_path: Path) -> str:
    proc = subprocess.run(
        ["plutil", "-extract", "CFBundleIdentifier", "raw", str(app_path / "Info.plist")],
        capture_output=True, text=True, check=True,
    )
    return proc.stdout.strip()


# --------------------------------------------------------------------------
# Simulator control
# --------------------------------------------------------------------------

def booted_device_udid() -> str | None:
    proc = subprocess.run(["xcrun", "simctl", "list", "devices", "booted", "-j"],
                           capture_output=True, text=True, check=True)
    data = json.loads(proc.stdout)
    for devices in data.get("devices", {}).values():
        for d in devices:
            if d.get("state") == "Booted":
                return d["udid"]
    return None


def find_device_by_name(name: str) -> tuple[str | None, str | None]:
    proc = subprocess.run(["xcrun", "simctl", "list", "devices", "-j"],
                           capture_output=True, text=True, check=True)
    data = json.loads(proc.stdout)
    for devices in data.get("devices", {}).values():
        for d in devices:
            if d.get("name") == name and d.get("isAvailable", True):
                return d["udid"], d.get("state")
    return None, None


def ensure_simulator_booted(sim_name: str) -> str:
    udid = booted_device_udid()
    if udid:
        return udid
    udid, state = find_device_by_name(sim_name)
    if udid is None:
        sys.exit(f"no simulator named {sim_name!r} found (see: xcrun simctl list devices)")
    if state != "Booted":
        subprocess.run(["xcrun", "simctl", "boot", udid], check=True)
    subprocess.run(["xcrun", "simctl", "bootstatus", udid, "-b"], check=True)
    return udid


def get_app_container(udid: str, bundle_id: str, attempts: int = 8, delay: float = 1.5) -> str:
    last_err = ""
    for _ in range(attempts):
        proc = subprocess.run(["xcrun", "simctl", "get_app_container", udid, bundle_id, "data"],
                               capture_output=True, text=True)
        if proc.returncode == 0:
            return proc.stdout.strip()
        last_err = proc.stderr.strip()
        time.sleep(delay)
    sys.exit(f"could not resolve app container for {bundle_id}: {last_err}")


def start_log_capture(udid: str, out_path: Path):
    out_file = open(out_path, "w")
    proc = subprocess.Popen(
        # --level debug is load-bearing: the vlc-audio tap mirrors libvlc lines
        # at debug level, and the default (info) captures none of them.
        ["xcrun", "simctl", "spawn", udid, "log", "stream", "--style", "ndjson",
         "--level", "debug", "--predicate", f'subsystem == "{SUBSYSTEM}"'],
        stdout=out_file, stderr=subprocess.DEVNULL,
    )
    return proc, out_file


def stop_log_capture(proc, out_file) -> None:
    proc.send_signal(signal.SIGTERM)
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
    out_file.close()


# --------------------------------------------------------------------------
# Telemetry polling
# --------------------------------------------------------------------------

def poll_until_done(telemetry_path: Path, timeout_s: float, poll_interval: float = 2.0) -> tuple[str, list]:
    deadline = time.time() + timeout_s
    next_note = time.time() + 30
    while time.time() < deadline:
        if telemetry_path.exists():
            lines = [l for l in telemetry_path.read_text().splitlines() if l.strip()]
            started = False
            for line in lines:
                try:
                    ev = json.loads(line)
                except json.JSONDecodeError:
                    continue
                # A terminal event only counts after this run's runStart —
                # guards against ever adopting leftover telemetry.
                if ev.get("event") == "runStart":
                    started = True
                elif started and ev.get("event") in ("done", "failed"):
                    return ev["event"], lines
        if time.time() >= next_note:
            print(f"[run] … still waiting ({int(deadline - time.time())}s left)", flush=True)
            next_note = time.time() + 30
        time.sleep(poll_interval)
    lines = [l for l in telemetry_path.read_text().splitlines() if l.strip()] if telemetry_path.exists() else []
    return "timeout", lines


# --------------------------------------------------------------------------
# Analyzer (pure functions — testable via --selftest)
# --------------------------------------------------------------------------

def parse_telemetry(lines: list) -> list:
    events = []
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            events.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return events


def parse_log_ndjson(lines: list) -> list:
    entries = []
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        message = obj.get("eventMessage", "")
        ts_raw = obj.get("timestamp")
        ts = None
        if ts_raw:
            try:
                ts = datetime.datetime.strptime(ts_raw, LOG_TS_FORMAT)
            except ValueError:
                ts = None
        entries.append({"ts": ts, "message": message})
    return entries


def run_summary(events: list) -> dict:
    run_start = next((e for e in events if e.get("event") == "runStart"), None)
    terminal = next((e for e in reversed(events) if e.get("event") in ("done", "failed")), None)
    t0 = run_start["t"] if run_start else (events[0]["t"] if events else None)
    t1 = terminal["t"] if terminal else (events[-1]["t"] if events else None)
    duration = (t1 - t0) if (t0 is not None and t1 is not None) else None
    return {
        "file": run_start.get("file") if run_start else None,
        "path": run_start.get("path") if run_start else None,
        "terminal_event": terminal.get("event") if terminal else None,
        "error": terminal.get("error") if terminal else None,
        "wall_duration_s": duration,
        "t0": t0,
    }


def phase_timeline(events: list, t0: float | None) -> list:
    out = []
    for e in events:
        if e.get("event") == "phaseChange":
            out.append({
                "rel_t": (e["t"] - t0) if t0 is not None else None,
                "phase": e.get("phase"),
            })
    return out


def seek_latencies(events: list, t0: float | None) -> list:
    beats = [e for e in events if e.get("event") == "beat"]
    results = []
    for e in events:
        if e.get("event") != "command" or e.get("cmd") not in SEEK_CMDS:
            continue
        cmd = e["cmd"]
        t_cmd = e["t"]

        prior_candidates = [b for b in beats if b["t"] < t_cmd and b.get("positionMs", -1) >= 0]
        prior_pos = prior_candidates[-1]["positionMs"] if prior_candidates else None

        if cmd == "skip":
            if prior_pos is None:
                results.append({
                    "cmd": cmd,
                    "rel_t": (t_cmd - t0) if t0 is not None else None,
                    "target_s": None, "latency_s": None,
                    "direction": "unknown", "note": "no baseline beat before command",
                })
                continue
            by_seconds = e.get("bySeconds", 0)
            target = prior_pos + by_seconds * 1000
            direction = "forward" if by_seconds >= 0 else "backward"
        else:
            target = e.get("toSeconds", 0) * 1000
            if prior_pos is None:
                direction = "unknown"
            else:
                direction = "forward" if target >= prior_pos else "backward"

        latency = None
        for idx, b in enumerate(beats):
            if b["t"] <= t_cmd:
                continue
            pos = b.get("positionMs", -1)
            if pos < 0:
                continue
            if abs(pos - target) < 5000 and idx + 1 < len(beats) and beats[idx + 1].get("positionMs", -1) > pos:
                latency = b["t"] - t_cmd
                break

        results.append({
            "cmd": cmd,
            "rel_t": (t_cmd - t0) if t0 is not None else None,
            "target_s": target / 1000,
            "latency_s": latency,
            "direction": direction,
        })
    return results


def stall_windows(events: list, t0: float | None) -> list:
    beats = [e for e in events if e.get("event") == "beat"]
    stalls = []
    i, n = 0, len(beats)
    while i < n:
        b = beats[i]
        if b.get("isPlaying") and b.get("positionMs", -1) >= 0:
            j = i + 1
            while j < n and beats[j].get("isPlaying") and beats[j].get("positionMs", -1) == b.get("positionMs"):
                j += 1
            if j - i >= 3:
                stalls.append({
                    "start_rel_s": (b["t"] - t0) if t0 is not None else None,
                    "duration_s": beats[j - 1]["t"] - b["t"],
                    "positionMs": b.get("positionMs"),
                })
            i = j
        else:
            i += 1
    return stalls


US_RE = re.compile(r"(\d+(?:\.\d+)?)\s*(?:µs|us|usec|microseconds)\b", re.IGNORECASE)


def dropout_signatures(log_entries: list) -> dict:
    flush_count = sum(1 for e in log_entries if "flushing buffers" in e["message"].lower())
    late_count = sum(1 for e in log_entries if "starting late" in e["message"].lower())

    deferring = [e for e in log_entries if e["ts"] is not None and "deferring start" in e["message"].lower()]
    deferring.sort(key=lambda e: e["ts"])
    episodes, cur = [], []
    for e in deferring:
        if cur and (e["ts"] - cur[-1]["ts"]).total_seconds() >= 2:
            episodes.append(cur)
            cur = []
        cur.append(e)
    if cur:
        episodes.append(cur)

    episode_reports = []
    for ep in episodes:
        duration = (ep[-1]["ts"] - ep[0]["ts"]).total_seconds()
        max_us = None
        for e in ep:
            for m in US_RE.finditer(e["message"]):
                val = float(m.group(1))
                if max_us is None or val > max_us:
                    max_us = val
        episode_reports.append({"duration_s": duration, "max_deferral_us": max_us, "count": len(ep)})

    clock_source = None
    for e in log_entries:
        lowered = e["message"].lower()
        if "using clock source" in lowered:
            idx = lowered.index("using clock source")
            clock_source = e["message"][idx + len("using clock source"):].strip(" :\t")
            break

    return {
        "flush_count": flush_count,
        "late_count": late_count,
        "deferring_episodes": episode_reports,
        "clock_source": clock_source,
    }


def build_verdicts(seeks: list, stalls: list, dropouts: dict) -> list:
    lines = []

    n_flush = dropouts["flush_count"]
    # Sub-second deferrals are normal renderer start latency; the pathological
    # flush-loop deferrals are ~3s. Only long ones indict the run.
    long_eps = [e for e in dropouts["deferring_episodes"]
                if (e["max_deferral_us"] or 0) > 1_000_000]
    n_ep = len(long_eps)
    if n_flush == 0 and n_ep == 0:
        lines.append("DROPOUT SIGNATURE: no flush events, no long deferrals — PASS")
    else:
        avg_us = (sum(e["max_deferral_us"] for e in long_eps) / n_ep) if n_ep else 0.0
        lines.append(
            f"DROPOUT SIGNATURE: {n_flush} flush events, {n_ep} long deferral episodes "
            f"(max ~{avg_us / 1e6:.1f}s) — FAIL"
        )

    if seeks:
        parts = []
        for s in seeks:
            if s["latency_s"] is None:
                target = f"{s['target_s']:.0f}s" if s["target_s"] is not None else "?"
                parts.append(f"{s['cmd']} → {target} never settled")
            else:
                suspect = " (linear-read suspect)" if s["direction"] == "forward" and s["latency_s"] > 10 else ""
                parts.append(f"{s['direction']} {s['target_s']:.0f}s took {s['latency_s']:.1f}s{suspect}")
        lines.append("SEEKS: " + "; ".join(parts))
    else:
        lines.append("SEEKS: none")

    if stalls:
        detail = "; ".join(f"{s['duration_s']:.1f}s @ {s['positionMs']}ms" for s in stalls)
        lines.append(f"STALLS: {len(stalls)} window(s) — {detail}")
    else:
        lines.append("STALLS: none")

    return lines


def analyze(events: list, log_entries: list) -> dict:
    summary = run_summary(events)
    t0 = summary["t0"]
    seeks = seek_latencies(events, t0)
    stalls = stall_windows(events, t0)
    dropouts = dropout_signatures(log_entries)
    return {
        "summary": summary,
        "phases": phase_timeline(events, t0),
        "seeks": seeks,
        "stalls": stalls,
        "dropouts": dropouts,
        "verdicts": build_verdicts(seeks, stalls, dropouts),
    }


def analyze_results(results_dir: Path) -> dict:
    telemetry_path = results_dir / "telemetry.jsonl"
    log_path = results_dir / "vlc-log.ndjson"
    telemetry_lines = telemetry_path.read_text().splitlines() if telemetry_path.exists() else []
    log_lines = log_path.read_text().splitlines() if log_path.exists() else []
    return analyze(parse_telemetry(telemetry_lines), parse_log_ndjson(log_lines))


def format_report(analysis: dict) -> str:
    s = analysis["summary"]
    lines = ["=== Playback Lab Report ===",
             f"file: {s['file']}  path: {s['path']}"]
    dur = f"{s['wall_duration_s']:.1f}s" if s["wall_duration_s"] is not None else "unknown"
    err = f" ({s['error']})" if s.get("error") else ""
    lines.append(f"terminal: {s['terminal_event']}{err}  wall: {dur}")

    lines += ["", "-- phase timeline --"]
    for p in analysis["phases"]:
        rel = f"{p['rel_t']:.1f}s" if p["rel_t"] is not None else "?"
        lines.append(f"  {rel}  {p['phase']}")
    if not analysis["phases"]:
        lines.append("  (none)")

    lines += ["", "-- seek latencies --"]
    for sk in analysis["seeks"]:
        rel = f"{sk['rel_t']:.1f}s" if sk["rel_t"] is not None else "?"
        tgt = f"{sk['target_s']:.0f}s" if sk["target_s"] is not None else "?"
        lat = f"{sk['latency_s']:.1f}s" if sk["latency_s"] is not None else "never settled"
        lines.append(f"  [{rel}] {sk['cmd']} → {tgt} ({sk['direction']}): {lat}")
    if not analysis["seeks"]:
        lines.append("  (none)")

    lines += ["", "-- stall windows --"]
    for st in analysis["stalls"]:
        rel = f"{st['start_rel_s']:.1f}s" if st["start_rel_s"] is not None else "?"
        lines.append(f"  [{rel}] {st['duration_s']:.1f}s frozen @ {st['positionMs']}ms")
    if not analysis["stalls"]:
        lines.append("  (none)")

    d = analysis["dropouts"]
    lines += ["", "-- dropout signatures --",
              f"  flush events: {d['flush_count']}",
              f"  starting-late events: {d['late_count']}",
              f"  clock source: {d['clock_source'] or 'unknown'}"]
    if d["deferring_episodes"]:
        for i, ep in enumerate(d["deferring_episodes"], 1):
            maxus = f"{ep['max_deferral_us']:.0f}us" if ep["max_deferral_us"] is not None else "?"
            lines.append(f"  deferral episode {i}: {ep['duration_s']:.1f}s, {ep['count']} lines, max {maxus}")
    else:
        lines.append("  deferral episodes: none")

    lines += ["", "-- verdict --"]
    lines += [f"  {v}" for v in analysis["verdicts"]]
    return "\n".join(lines)


# --------------------------------------------------------------------------
# Self-test
# --------------------------------------------------------------------------

def selftest() -> None:
    t0 = 1000.0
    events = [
        {"t": t0, "event": "runStart", "file": "test.mkv", "path": "Debug"},
        {"t": t0 + 0.1, "event": "phaseChange", "phase": "loading"},
        {"t": t0 + 1.0, "event": "phaseChange", "phase": "playing"},
        {"t": t0 + 1.0, "event": "beat", "positionMs": 0, "durationMs": 600000, "isPlaying": True, "phase": "playing"},
        {"t": t0 + 1.5, "event": "beat", "positionMs": 500, "durationMs": 600000, "isPlaying": True, "phase": "playing"},
        {"t": t0 + 2.0, "event": "beat", "positionMs": 1000, "durationMs": 600000, "isPlaying": True, "phase": "playing"},
        {"t": t0 + 2.5, "event": "beat", "positionMs": 1000, "durationMs": 600000, "isPlaying": True, "phase": "playing"},
        {"t": t0 + 3.0, "event": "beat", "positionMs": 1000, "durationMs": 600000, "isPlaying": True, "phase": "playing"},
        {"t": t0 + 3.5, "event": "beat", "positionMs": 1000, "durationMs": 600000, "isPlaying": True, "phase": "playing"},
        {"t": t0 + 4.0, "event": "beat", "positionMs": 1500, "durationMs": 600000, "isPlaying": True, "phase": "playing"},
        {"t": t0 + 5.0, "event": "command", "cmd": "scrub", "toSeconds": 120},
        {"t": t0 + 5.0, "event": "commandDone", "cmd": "scrub", "elapsedMs": 5},
        {"t": t0 + 6.0, "event": "beat", "positionMs": 60000, "durationMs": 600000, "isPlaying": True, "phase": "playing"},
        {"t": t0 + 8.0, "event": "beat", "positionMs": 118000, "durationMs": 600000, "isPlaying": True, "phase": "playing"},
        {"t": t0 + 8.5, "event": "beat", "positionMs": 119000, "durationMs": 600000, "isPlaying": True, "phase": "playing"},
        {"t": t0 + 9.0, "event": "command", "cmd": "skip", "bySeconds": 30},
        {"t": t0 + 9.5, "event": "beat", "positionMs": 148500, "durationMs": 600000, "isPlaying": True, "phase": "playing"},
        {"t": t0 + 10.0, "event": "beat", "positionMs": 149200, "durationMs": 600000, "isPlaying": True, "phase": "playing"},
        {"t": t0 + 10.5, "event": "beat", "positionMs": 150000, "durationMs": 600000, "isPlaying": True, "phase": "playing"},
        {"t": t0 + 11.0, "event": "done"},
    ]
    log_lines_raw = [
        json.dumps({"eventMessage": "flushing buffers due to underrun", "timestamp": "2026-07-31 20:31:29.000000-0700"}),
        json.dumps({"eventMessage": "deferring start by 1500 us", "timestamp": "2026-07-31 20:31:29.500000-0700"}),
        json.dumps({"eventMessage": "deferring start by 3200 us", "timestamp": "2026-07-31 20:31:30.200000-0700"}),
        json.dumps({"eventMessage": "starting late for stream", "timestamp": "2026-07-31 20:31:31.000000-0700"}),
        json.dumps({"eventMessage": "using clock source: audio", "timestamp": "2026-07-31 20:31:31.500000-0700"}),
        "not json, should be skipped",
    ]

    log_entries = parse_log_ndjson(log_lines_raw)
    assert len(log_entries) == 5  # the trailing non-JSON line is skipped
    analysis = analyze(events, log_entries)

    s = analysis["summary"]
    assert s["file"] == "test.mkv"
    assert s["terminal_event"] == "done"
    assert abs(s["wall_duration_s"] - 11.0) < 1e-6

    assert [p["phase"] for p in analysis["phases"]] == ["loading", "playing"]
    assert abs(analysis["phases"][0]["rel_t"] - 0.1) < 1e-6
    assert abs(analysis["phases"][1]["rel_t"] - 1.0) < 1e-6

    assert len(analysis["stalls"]) == 1
    stall = analysis["stalls"][0]
    assert stall["positionMs"] == 1000
    assert abs(stall["start_rel_s"] - 2.0) < 1e-6
    assert abs(stall["duration_s"] - 1.5) < 1e-6

    seeks = analysis["seeks"]
    assert len(seeks) == 2
    scrub, skip = seeks
    assert scrub["cmd"] == "scrub" and abs(scrub["target_s"] - 120.0) < 1e-6
    assert scrub["latency_s"] is not None and abs(scrub["latency_s"] - 3.0) < 1e-6
    assert skip["cmd"] == "skip" and abs(skip["target_s"] - 149.0) < 1e-6
    assert skip["direction"] == "forward"
    assert skip["latency_s"] is not None and abs(skip["latency_s"] - 0.5) < 1e-6

    d = analysis["dropouts"]
    assert d["flush_count"] == 1
    assert d["late_count"] == 1
    assert d["clock_source"] == "audio"
    assert len(d["deferring_episodes"]) == 1
    ep = d["deferring_episodes"][0]
    assert ep["count"] == 2
    assert abs(ep["duration_s"] - 0.7) < 1e-6
    assert abs(ep["max_deferral_us"] - 3200) < 1e-6

    verdicts_text = "\n".join(analysis["verdicts"])
    assert "FAIL" in verdicts_text
    assert "SEEKS:" in verdicts_text

    report = format_report(analysis)
    assert "Playback Lab Report" in report

    print("selftest OK")


# --------------------------------------------------------------------------
# Full run orchestration
# --------------------------------------------------------------------------

def make_results_dir(script_dir: Path, scenario_name: str) -> Path:
    ts = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    d = script_dir / "results" / f"{scenario_name}-{ts}"
    d.mkdir(parents=True, exist_ok=True)
    return d


def cmd_run(args) -> int:
    script_dir = Path(__file__).resolve().parent
    repo_root = script_dir.parent.parent

    scenario_path = resolve_path(script_dir, args.scenario)
    config_path = resolve_path(script_dir, args.config)
    config = load_json(config_path)
    scenario = load_json(scenario_path)
    merged = merge_scenario(config, scenario, args.file)

    results_dir = make_results_dir(script_dir, scenario_path.stem)
    (results_dir / "scenario.json").write_text(json.dumps(redact_scenario(merged), indent=2) + "\n")

    tmp_dir = Path(tempfile.mkdtemp(prefix="playback-lab-"))
    tmp_scenario_path = tmp_dir / "scenario.json"
    tmp_scenario_path.write_text(json.dumps(merged, indent=2))

    if not args.no_build:
        build_app(repo_root, args.sim, DERIVED_DATA)
    app_path = app_bundle_path(DERIVED_DATA)
    if not app_path.exists():
        sys.exit(f"app bundle not found at {app_path} — run once without --no-build first")
    bundle_id = read_bundle_id(app_path)

    udid = ensure_simulator_booted(args.sim)
    print(f"[run] installing on {udid}…", flush=True)
    subprocess.run(["xcrun", "simctl", "install", udid, str(app_path)], check=True)

    log_path = results_dir / "vlc-log.ndjson"
    log_proc, log_file = start_log_capture(udid, log_path)

    terminal = "timeout"
    telemetry_lines = []
    try:
        subprocess.run(["xcrun", "simctl", "terminate", udid, bundle_id], capture_output=True)
        time.sleep(0.5)

        # Resolve the container and clear the previous run's telemetry BEFORE
        # launching — polling a stale file makes the driver adopt the last
        # run's terminal event as this run's result.
        container = get_app_container(udid, bundle_id)
        telemetry_path = Path(container) / "Documents/PlaybackLab/telemetry.jsonl"
        telemetry_path.unlink(missing_ok=True)

        print(f"[run] launching {bundle_id} -playbackLab {tmp_scenario_path}", flush=True)
        subprocess.run(["xcrun", "simctl", "launch", udid, bundle_id, "-playbackLab", str(tmp_scenario_path)]
                       + args.app_arg, check=True)

        timeout_s = args.timeout if args.timeout else default_timeout(merged.get("timeline", []))
        print(f"[run] polling telemetry (timeout {timeout_s:.0f}s)…", flush=True)
        terminal, telemetry_lines = poll_until_done(telemetry_path, timeout_s)

        telemetry_out = results_dir / "telemetry.jsonl"
        if telemetry_path.exists():
            shutil.copy(telemetry_path, telemetry_out)
        else:
            telemetry_out.write_text("\n".join(telemetry_lines) + ("\n" if telemetry_lines else ""))
    finally:
        subprocess.run(["xcrun", "simctl", "terminate", udid, bundle_id], capture_output=True)
        # log stream flushes with seconds of latency; killing it immediately on a
        # fast failure loses everything it buffered.
        time.sleep(4)
        stop_log_capture(log_proc, log_file)
        shutil.rmtree(tmp_dir, ignore_errors=True)

    analysis = analyze_results(results_dir)
    report = format_report(analysis)
    print("\n" + report)
    (results_dir / "analysis.json").write_text(json.dumps(analysis, indent=2, default=str) + "\n")
    print(f"\n[run] results: {results_dir}")

    if terminal == "done":
        return 0
    if terminal == "failed":
        return 2
    return 3


def cmd_analyze(results_dir_raw: str) -> int:
    results_dir = Path(results_dir_raw).resolve()
    analysis = analyze_results(results_dir)
    print(format_report(analysis))
    (results_dir / "analysis.json").write_text(json.dumps(analysis, indent=2, default=str) + "\n")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--scenario", help="path to a scenario JSON (relative to this script unless absolute)")
    parser.add_argument("--file", help="override the scenario's media file name")
    parser.add_argument("--sim", default=DEFAULT_SIM, help=f"simulator name (default: {DEFAULT_SIM!r})")
    parser.add_argument("--no-build", action="store_true", help="reuse the last build in the isolated DerivedData")
    parser.add_argument("--config", default=DEFAULT_CONFIG, help="lab config JSON (relative to this script unless absolute)")
    parser.add_argument("--timeout", type=float, help="override the computed run timeout, in seconds")
    parser.add_argument("--app-arg", action="append", default=[],
                        help="extra launch argument for the app (repeatable), e.g. --app-arg -smbNativeVLC")
    parser.add_argument("--analyze", metavar="RESULTS_DIR", help="re-run the analyzer on a saved results dir")
    parser.add_argument("--selftest", action="store_true", help="run the analyzer self-test and exit")
    args = parser.parse_args()

    if args.selftest:
        selftest()
        return 0
    if args.analyze:
        return cmd_analyze(args.analyze)
    if not args.scenario:
        parser.error("--scenario is required (or use --analyze/--selftest)")
    return cmd_run(args)


if __name__ == "__main__":
    sys.exit(main())
