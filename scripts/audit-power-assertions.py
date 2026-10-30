#!/usr/bin/env python3
"""Inspect one current-user Wallmotion PID for display-sleep assertions on macOS."""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import pathlib
import re
import subprocess
import sys
from datetime import datetime, timezone

_spec = importlib.util.spec_from_file_location("wallmotion_metrics", pathlib.Path(__file__).with_name("collect-performance.py"))
metrics = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(metrics)
MAX_OUTPUT_BYTES = 4 * 1024 * 1024


def parse_assertions(output: str, pid: int) -> dict[str, int]:
    """Return type counts only; never retain names, assertion IDs or other PIDs."""
    if len(output.encode("utf-8")) > MAX_OUTPUT_BYTES:
        raise ValueError("assertion output exceeded the supported size")
    in_processes = False
    finished = False
    counts: dict[str, int] = {}
    for line in output.splitlines():
        if line.strip() == "Listed by owning process:":
            if in_processes or finished:
                raise ValueError("duplicate owning-process section")
            in_processes = True
            continue
        if not in_processes:
            continue
        if line.strip().startswith("Kernel Assertions:") or line.strip() == "No kernel assertions.":
            finished = True
            break
        owner = re.match(r"\s*pid\s+([0-9]+)\(", line)
        if owner is None:
            if re.match(r"\s*pid\b", line):
                raise ValueError("unrecognized process ownership row")
            continue
        if int(owner[1]) != pid:
            continue
        assertion = re.fullmatch(r'\s*pid\s+[0-9]+\(.*\):\s+\[0x[0-9a-fA-F]+\]\s+[0-9]+:[0-9]{2}:[0-9]{2}\s+([A-Za-z][A-Za-z0-9]*)\s+named:.*', line)
        if assertion is None:
            raise ValueError("unrecognized assertion row for the target PID")
        kind = assertion[1]
        counts[kind] = counts.get(kind, 0) + 1
    if not in_processes or not finished:
        raise ValueError("complete owning-process section not found")
    return counts


def audit(pid: int) -> dict:
    before = metrics.sample_process(pid)
    result = subprocess.run(
        ["/usr/bin/pmset", "-g", "assertions"], capture_output=True, text=True,
        timeout=5, check=False, env={**os.environ, "LC_ALL": "C", "TZ": "UTC"},
    )
    if result.returncode != 0:
        # pmset stderr may include global diagnostics. Do not forward it.
        raise RuntimeError("pmset could not query assertions")
    counts = parse_assertions(result.stdout, pid)
    after = metrics.sample_process(pid)
    metrics.add_interval_metrics(before, after)
    display = counts.get("PreventUserIdleDisplaySleep", 0)
    return {
        "schema_version": 1,
        "timestamp_utc": datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
        "pid": pid,
        "status": "display_sleep_assertion_present" if display else "no_display_sleep_assertion_observed",
        "assertion_type_counts": counts,
        "display_sleep_assertion_count": display,
        "limits": [
            "Single pmset snapshot for the validated host PID; assertions may change immediately.",
            "No WebKit helpers, descendant attribution, GPU, energy or actual display-sleep test.",
            "No assertion names/IDs, command paths or other process records are exported.",
            "Absence of an observed assertion does not establish zero energy use or sleep compliance.",
            "Locale-stable human-readable pmset format; unsupported/incomplete output is an error, not a clean result.",
            "Pre/post UID, command, start token and counters detect ordinary PID changes, not a security identity.",
        ],
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid", required=True, type=int)
    args = parser.parse_args(argv)
    if args.pid <= 1:
        parser.error("--pid must be greater than 1")
    if sys.platform != "darwin":
        parser.error("this audit requires macOS")
    try:
        report = audit(args.pid)
    except (RuntimeError, ValueError, OSError, subprocess.TimeoutExpired):
        # Fail closed without echoing process records or global pmset output.
        print("Power assertion audit unavailable: process changed, query failed or output was unsupported.", file=sys.stderr)
        return 2
    json.dump(report, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 3 if report["display_sleep_assertion_count"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
