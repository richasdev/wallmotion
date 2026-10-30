#!/usr/bin/env python3
"""Collect low-overhead, unprivileged metrics for one Wallmotion process on macOS."""

from __future__ import annotations

import argparse
import csv
import json
import os
import pathlib
import subprocess
import sys
import time
from datetime import datetime, timezone


MIN_INTERVAL = 0.1
MAX_INTERVAL = 3600.0
MAX_DURATION = 86400.0
MAX_SAMPLES = 100_000
EXIT_COMPLETED = 0
EXIT_EARLY = 3
EXIT_INTERRUPTED = 130


class ProcessUnavailableError(RuntimeError):
    """The validated PID disappeared or could no longer be queried."""


def positive_float(value: str) -> float:
    try:
        number = float(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("must be a number") from exc
    if not (number > 0 and number < float("inf")):
        raise argparse.ArgumentTypeError("must be a finite number greater than zero")
    return number


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid", required=True, type=int, help="PID of the Wallmotion app")
    parser.add_argument("--interval", required=True, type=positive_float, help="sampling interval in seconds (0.1–3600)")
    parser.add_argument("--duration", required=True, type=positive_float, help="total sampling duration in seconds (maximum 86400)")
    parser.add_argument("--format", choices=("csv", "json"), default="csv")
    parser.add_argument("--output", help="write output to this path; default is stdout")
    return parser


def validate_args(args: argparse.Namespace, parser: argparse.ArgumentParser) -> None:
    if args.pid <= 1:
        parser.error("--pid must be greater than 1")
    if not MIN_INTERVAL <= args.interval <= MAX_INTERVAL:
        parser.error("--interval must be between 0.1 and 3600 seconds")
    if args.duration > MAX_DURATION:
        parser.error("--duration must not exceed 86400 seconds")
    if int(args.duration / args.interval) + 2 > MAX_SAMPLES:
        parser.error(f"requested run may exceed the {MAX_SAMPLES} sample safety limit")


def parse_ps_line(line: str) -> dict[str, float | int | str]:
    fields = line.strip().split(None, 4)
    if len(fields) != 5:
        raise ValueError("unexpected output from ps")
    uid, cpu, rss_kib, elapsed_text, command = fields
    return {
        "uid": int(uid),
        "cpu_percent": float(cpu),
        "rss_bytes": int(rss_kib) * 1024,
        "process_elapsed_seconds": parse_elapsed(elapsed_text),
        "command": command,
    }


def parse_elapsed(value: str) -> int:
    # macOS ps etime: [[dd-]hh:]mm:ss
    days = 0
    if "-" in value:
        day_part, value = value.split("-", 1)
        days = int(day_part)
    parts = [int(part) for part in value.split(":")]
    if len(parts) == 3:
        hours, minutes, seconds = parts
    elif len(parts) == 2:
        hours, (minutes, seconds) = 0, parts
    else:
        raise ValueError("unexpected elapsed time from ps")
    return days * 86400 + hours * 3600 + minutes * 60 + seconds


def sample_process(pid: int) -> dict[str, float | int | str]:
    result = subprocess.run(
        ["ps", "-p", str(pid), "-o", "uid=", "-o", "%cpu=", "-o", "rss=", "-o", "etime=", "-o", "comm="],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0 or not result.stdout.strip():
        raise ProcessUnavailableError(f"PID {pid} exited or became unavailable to ps")
    try:
        row = parse_ps_line(result.stdout)
    except (ValueError, IndexError) as exc:
        raise RuntimeError(f"could not parse process metrics: {exc}") from exc
    if row["uid"] != os.getuid():
        raise RuntimeError("PID belongs to another user; only the current user's process is allowed")
    command = str(row["command"]).rstrip("/").split("/")[-1]
    if not command.lower().startswith("wallmotion"):
        raise RuntimeError(f"PID {pid} is {row['command']!r}, not a Wallmotion process")
    return row


def limits_report() -> dict[str, str]:
    return {
        "cpu": "ps %cpu; OS process estimate, may exceed 100 on multicore systems",
        "memory": "ps RSS converted from KiB to bytes; resident process memory, sampled snapshots",
        "time": "monotonic time since collection start and ps elapsed process time",
        "power_gpu": "not collected; this tool has no verified per-process power/GPU metric and unit",
        "scope": "only the supplied current-user Wallmotion PID; no sudo, screen recording, or other app data",
        "sampling": "samples are snapshots; short spikes between intervals can be missed",
    }


def collect(pid: int, interval: float, duration: float, first_sample: dict) -> dict:
    started = time.monotonic()
    deadline = started + duration
    rows = []
    status = "completed"
    reason = "requested duration reached"
    next_sample = first_sample
    while True:
        now = time.monotonic()
        try:
            row = next_sample if next_sample is not None else sample_process(pid)
            next_sample = None
            row["elapsed_seconds"] = round(now - started, 3)
            row["timestamp_utc"] = datetime.now(timezone.utc).isoformat(timespec="milliseconds")
            rows.append(row)
            if now >= deadline:
                break
            time.sleep(min(interval, deadline - now))
        except ProcessUnavailableError as exc:
            status = "process_unavailable"
            reason = str(exc)
            break
        except (RuntimeError, OSError) as exc:
            status = "sampling_error"
            reason = str(exc)
            break
        except KeyboardInterrupt:
            status = "interrupted"
            reason = "collection interrupted by user"
            break
    return {
        "status": status,
        "termination_reason": reason,
        "requested_duration_seconds": duration,
        "samples": rows,
    }


def write_output(result: dict, fmt: str, stream) -> None:
    if fmt == "json":
        json.dump({**result, "limits": limits_report()}, stream, indent=2)
        stream.write("\n")
        return
    fields = (
        "timestamp_utc",
        "elapsed_seconds",
        "cpu_percent",
        "rss_bytes",
        "process_elapsed_seconds",
        "collection_status",
        "termination_reason",
        "requested_duration_seconds",
    )
    writer = csv.DictWriter(stream, fieldnames=fields, extrasaction="ignore", lineterminator="\n")
    writer.writeheader()
    metadata = {
        "collection_status": result["status"],
        "termination_reason": result["termination_reason"],
        "requested_duration_seconds": result["requested_duration_seconds"],
    }
    writer.writerows({**row, **metadata} for row in result["samples"])


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    validate_args(args, parser)
    if sys.platform != "darwin":
        parser.error("this collector requires macOS ps")
    # Reject invalid initial PIDs before creating any output. Later loss is a partial result.
    try:
        first_sample = sample_process(args.pid)
    except (RuntimeError, OSError) as exc:
        parser.error(str(exc))
    result = collect(args.pid, args.interval, args.duration, first_sample)
    if args.output:
        destination = pathlib.Path(args.output)
        with destination.open("w", newline="", encoding="utf-8") as stream:
            write_output(result, args.format, stream)
    else:
        write_output(result, args.format, sys.stdout)
    if args.format == "csv":
        print("Limits: " + json.dumps(limits_report(), ensure_ascii=False), file=sys.stderr)
    print(
        f"Collection {result['status']}: {result['termination_reason']} "
        f"({len(result['samples'])} sample(s))",
        file=sys.stderr,
    )
    if result["status"] == "completed":
        return EXIT_COMPLETED
    if result["status"] == "interrupted":
        return EXIT_INTERRUPTED
    return EXIT_EARLY


if __name__ == "__main__":
    raise SystemExit(main())
