#!/usr/bin/env python3
"""Collect unprivileged metrics for one Wallmotion process on macOS."""

from __future__ import annotations

import argparse
import csv
import json
import math
import re
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


class ProcessChangedError(RuntimeError):
    """Do not merge counters from a reused PID or a changed executable."""


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


def parse_cpu_time(value: str) -> tuple[int, int]:
    """Return cumulative nanoseconds and displayed quantum, without float parsing."""
    if len(value) > 128 or not re.fullmatch(r"(?:[0-9]+-)?[0-9]+(?::[0-9]+){1,2}(?:\.[0-9]{1,9})?", value):
        raise ValueError("unexpected CPU time from ps")
    whole, dot, fraction = value.partition(".")
    days = 0
    if "-" in whole:
        day_part, whole = whole.split("-", 1)
        days = int(day_part)
    parts = [int(part) for part in whole.split(":")]
    if len(parts) == 3:
        hours, minutes, seconds = parts
        if minutes >= 60:
            raise ValueError("invalid CPU minutes from ps")
    else:
        hours, (minutes, seconds) = 0, parts
    if seconds >= 60:
        raise ValueError("invalid CPU seconds from ps")
    total = ((days * 24 + hours) * 3600 + minutes * 60 + seconds) * 1_000_000_000
    total += int(fraction.ljust(9, "0")) if dot else 0
    return total, 10 ** (9 - len(fraction)) if dot else 1_000_000_000


def parse_ps_line(line: str) -> dict:
    fields = line.strip().split(None, 10)
    if len(fields) != 11:
        raise ValueError("unexpected output from ps")
    uid, cpu, rss_kib, elapsed_text, cpu_text = fields[:5]
    start = " ".join(fields[5:10])
    if not re.fullmatch(r"[A-Za-z]{3} [A-Za-z]{3} [0-9]{1,2} [0-9]{2}:[0-9]{2}:[0-9]{2} [0-9]{4}", start):
        raise ValueError("unexpected process start token from ps")
    cpu_time_ns, quantum_ns = parse_cpu_time(cpu_text)
    cpu_value, rss_value, uid_value = float(cpu), int(rss_kib), int(uid)
    if not math.isfinite(cpu_value) or cpu_value < 0 or rss_value < 0 or uid_value < 0:
        raise ValueError("invalid numeric metric from ps")
    return {
        "uid": uid_value,
        "cpu_percent": cpu_value,  # Legacy alias: still the OS decaying estimate.
        "ps_cpu_percent": cpu_value,
        "cpu_time_ns": cpu_time_ns,
        "cpu_time_seconds": cpu_time_ns / 1_000_000_000,
        "cpu_time_quantum_ns": quantum_ns,
        "rss_bytes": rss_value * 1024,
        "process_elapsed_seconds": parse_elapsed(elapsed_text),
        "process_start_token": start,
        "command": fields[10],
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
        ["ps", "-p", str(pid), "-o", "uid=", "-o", "%cpu=", "-o", "rss=", "-o", "etime=", "-o", "time=", "-o", "lstart=", "-o", "comm="],
        capture_output=True,
        text=True,
        check=False,
        env={**os.environ, "LC_ALL": "C", "TZ": "UTC"},
        timeout=5,
    )
    sampled_at = time.monotonic()
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
        raise RuntimeError(f"PID {pid} is not a validated Wallmotion process")
    row["_sample_time"] = sampled_at
    return row


def limits_report() -> dict[str, str]:
    return {
        "cpu": "cpu_percent is a legacy alias for ps_cpu_percent: the OS decaying average, not this sampling interval. cpu_interval_percent uses cumulative ps time deltas / actual monotonic query-completion deltas; first sample is null; values can exceed 100",
        "cpu_precision": "ps time is quantized (centiseconds on the tested macOS); sub-interval spikes are averaged, query timing is approximate, and zero deltas do not prove zero work",
        "identity": "current UID, command path and UTC/C-locale ps start token must stay stable; cumulative counters/elapsed time cannot decrease; this detects ordinary PID reuse, not a security identity",
        "memory": "ps RSS converted from KiB to bytes; resident process memory, sampled snapshots",
        "time": "monotonic time since collection start and ps elapsed process time",
        "power_gpu": "not collected; this tool has no verified per-process power/GPU metric and unit",
        "scope": "only the supplied current-user Wallmotion PID; no sudo, screen recording, or other app data",
        "sampling": "CPU counters average work across actual intervals; they do not reveal instantaneous spikes. RSS snapshots may miss peaks. Fixed cadence skips missed slots; a ps query can overrun the requested duration",
    }


def add_interval_metrics(previous: dict | None, row: dict) -> None:
    row["sample_interval_seconds"] = None
    row["cpu_delta_seconds"] = None
    row["cpu_interval_percent"] = None
    if previous is None:
        return
    if any(previous[key] != row[key] for key in ("uid", "command", "process_start_token")):
        raise ProcessChangedError("PID start identity changed; collection stopped")
    if row["cpu_time_ns"] < previous["cpu_time_ns"] or row["process_elapsed_seconds"] < previous["process_elapsed_seconds"]:
        raise ProcessChangedError("process counters decreased; collection stopped")
    interval = row["_sample_time"] - previous["_sample_time"]
    if not math.isfinite(interval) or interval <= 0:
        raise RuntimeError("sampling clock did not advance")
    row["sample_interval_seconds"] = interval
    row["cpu_delta_seconds"] = (row["cpu_time_ns"] - previous["cpu_time_ns"]) / 1_000_000_000
    row["cpu_interval_percent"] = row["cpu_delta_seconds"] / interval * 100


def summarize(rows: list[dict]) -> dict:
    intervals = [row for row in rows if row["sample_interval_seconds"] is not None]
    observed = sum(row["sample_interval_seconds"] for row in intervals)
    samples = sorted(row["cpu_interval_percent"] for row in intervals)
    return {
        "interval_observed_seconds": observed,
        "cpu_interval_weighted_percent": ((rows[-1]["cpu_time_ns"] - rows[0]["cpu_time_ns"]) / 1_000_000_000 / observed * 100) if observed else None,
        "cpu_interval_p95_percent": samples[math.ceil(len(samples) * .95) - 1] if samples else None,
        "rss_peak_sample_bytes": max((row["rss_bytes"] for row in rows), default=None),
    }


def collect(pid: int, interval: float, duration: float, first_sample: dict) -> dict:
    started = first_sample["_sample_time"]
    deadline = started + duration
    rows = []
    status = "completed"
    reason = "requested duration reached"
    next_sample = first_sample
    next_target = started
    previous = None
    while True:
        try:
            if next_sample is not None:
                row = dict(next_sample)
                next_sample = None
            else:
                delay = next_target - time.monotonic()
                if delay > 0:
                    time.sleep(delay)
                row = sample_process(pid)
            sampled_at = row["_sample_time"]
            if not math.isfinite(sampled_at) or sampled_at < started:
                raise RuntimeError("invalid sampling timestamp")
            add_interval_metrics(previous, row)
            row["elapsed_seconds"] = round(sampled_at - started, 3)
            row["timestamp_utc"] = datetime.now(timezone.utc).isoformat(timespec="milliseconds")
            rows.append({key: value for key, value in row.items() if not key.startswith("_")})
            previous = row
            if sampled_at >= deadline:
                break
            # Anchor scheduling to the original cadence. Skip missed slots;
            # never issue a catch-up burst after a slow ps query or system sleep.
            slot = math.floor((sampled_at - started) / interval) + 1
            next_target = started + slot * interval
            if next_target <= sampled_at:  # Floating-point boundary, not a catch-up slot.
                next_target = started + (slot + 1) * interval
            next_target = min(deadline, next_target)
        except ProcessChangedError as exc:
            status, reason = "process_changed", str(exc)
            break
        except ProcessUnavailableError as exc:
            status, reason = "process_unavailable", str(exc)
            break
        except (RuntimeError, OSError, subprocess.TimeoutExpired) as exc:
            status, reason = "sampling_error", str(exc)
            break
        except KeyboardInterrupt:
            status, reason = "interrupted", "collection interrupted by user"
            break
    return {
        "schema_version": 2,
        "status": status,
        "termination_reason": reason,
        "requested_duration_seconds": duration,
        "samples": rows,
        "summary": summarize(rows),
    }


def write_output(result: dict, fmt: str, stream) -> None:
    if fmt == "json":
        json.dump({**result, "limits": limits_report()}, stream, indent=2)
        stream.write("\n")
        return
    # Preserve the original column order; append the schema-v2 metrics.
    fields = (
        "timestamp_utc",
        "elapsed_seconds",
        "cpu_percent",
        "rss_bytes",
        "process_elapsed_seconds",
        "collection_status",
        "termination_reason",
        "requested_duration_seconds",
        "schema_version",
        "ps_cpu_percent",
        "cpu_time_seconds",
        "cpu_time_quantum_ns",
        "sample_interval_seconds",
        "cpu_delta_seconds",
        "cpu_interval_percent",
    )
    writer = csv.DictWriter(stream, fieldnames=fields, extrasaction="ignore", lineterminator="\n")
    writer.writeheader()
    metadata = {
        "schema_version": result["schema_version"],
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
    except (RuntimeError, OSError, subprocess.TimeoutExpired) as exc:
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
