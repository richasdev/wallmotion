#!/usr/bin/env python3
"""Opt-in real macOS file-handoff QA using an archived source and isolated bundle/library."""

from __future__ import annotations

import argparse
import os
import signal
import json
import pathlib
import plistlib
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import uuid
import zlib

PROCESS_HELPER = r"""
import AppKit
import Foundation
let args = CommandLine.arguments
precondition(args.count == 3)
let action = args[1], identifier = args[2]
precondition(identifier.hasPrefix("dev.richas.wallmotion.qa.") && identifier.count < 100)
let apps = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
if action == "terminate" { for app in apps { _ = app.terminate() } }
let rows: [[String: Any]] = apps.map { ["pid": Int($0.processIdentifier), "path": $0.bundleURL?.path ?? "", "terminated": $0.isTerminated] }
print(String(decoding: try JSONSerialization.data(withJSONObject: rows), as: UTF8.self))
"""


def run(command: list[str], *, cwd=None, timeout=30, log=None):
    result = subprocess.run(command, cwd=cwd, timeout=timeout, text=True,
                            stdout=log or subprocess.PIPE, stderr=log or subprocess.PIPE)
    if result.returncode:
        raise RuntimeError(f"QA command failed: {command[0]} (exit {result.returncode})")
    return result.stdout


def wait_for(predicate, label: str, timeout=15):
    deadline = time.monotonic() + timeout
    while True:
        try:
            value = predicate()
        except FileNotFoundError:
            value = False
        if value:
            return value
        if time.monotonic() >= deadline:
            raise RuntimeError(f"QA timed out: {label}")
        time.sleep(.1)


def write_png(path: pathlib.Path):
    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff)
    pixels = (b"\0" + bytes([100, 140, 200, 255]) * 64) * 64
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 64, 64, 8, 6, 0, 0, 0))
                     + chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b""))


def audit(source_ref: str, check_overflow: bool = False) -> dict:
    repository = pathlib.Path(__file__).resolve().parents[1]
    commit = run(["git", "rev-parse", "--verify", "--end-of-options", source_ref + "^{commit}"], cwd=repository).strip()
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise RuntimeError("QA source must resolve to a full commit SHA")
    root = pathlib.Path(tempfile.mkdtemp(prefix="wallmotion-runtime-qa-"))
    source, library = root / "source", root / "library"
    app = source / "dist/Wallmotion.app"
    helper = root / "process-helper"
    bundle = "dev.richas.wallmotion.qa." + uuid.uuid4().hex
    launched = False
    results = []

    def apps():
        deadline = time.monotonic() + 2
        while True:
            rows = [row for row in json.loads(run([str(helper), "list", bundle])) if not row.get("terminated")]
            unexpected = [row for row in rows if row["path"] and pathlib.Path(row["path"]).resolve() != app.resolve()]
            if unexpected:
                raise RuntimeError("QA bundle identity resolved to an unexpected path: " + json.dumps(unexpected))
            if all(row["path"] for row in rows):
                return rows
            if time.monotonic() >= deadline:
                raise RuntimeError("QA process bundle path remained unavailable")
            # LaunchServices may transiently omit a starting/exiting process path.
            # Keep fail-closed validation; never treat an unknown path as owned.
            time.sleep(.05)

    def stop():
        if not apps():
            return
        run([str(helper), "terminate", bundle])
        deadline = time.monotonic() + 3
        while apps() and time.monotonic() < deadline:
            time.sleep(.1)
        # Native quit is a request, not an exit receipt. Only this freshly
        # validated, generated bundle/path may receive the cleanup fallback.
        for row in apps():
            try:
                os.kill(row["pid"], signal.SIGTERM)
            except ProcessLookupError:
                pass
        wait_for(lambda: not apps(), "temporary QA app termination after cleanup signal", timeout=5)

    def owner():
        value = json.loads((library / "wallmotion-owner.json").read_text())
        if value["bundleIdentifier"] != bundle:
            raise RuntimeError("QA library owner has an unexpected bundle identity")
        return value["processID"]

    def state_count():
        path = library / "library.json"
        return len(json.loads(path.read_text())["wallpapers"]) if path.exists() else 0

    def completed(expected, primary):
        count, live = state_count(), apps()
        if count > expected:
            raise RuntimeError("QA observed duplicate/unexpected library entries")
        return count == expected and len(live) == 1 and live[0]["pid"] == primary and owner() == primary

    try:
        source.mkdir()
        archive = root / "source.tar"
        run(["git", "archive", "--format=tar", "--output", str(archive), commit], cwd=repository)
        run(["tar", "-xf", str(archive), "-C", str(source)])
        archive.unlink()
        if check_overflow and "maximumTrackedURLs = 256" not in (source / "Sources/Wallmotion/LaunchEventRouter.swift").read_text():
            raise RuntimeError("overflow QA requires the committed 256-URL router admission policy")
        store = source / "Sources/WallmotionCore/LibraryStore.swift"
        original = 'URL.applicationSupportDirectory.appendingPathComponent("Wallmotion", isDirectory: true)'
        contents = store.read_text()
        if contents.count(original) != 1:
            raise RuntimeError("QA isolation patch no longer matches the store constructor")
        replacement = 'URL(fileURLWithPath: ' + json.dumps(str(library)) + ', isDirectory: true)'
        store.write_text(contents.replace(original, replacement))
        info_path = source / "resources/Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        info.update(CFBundleIdentifier=bundle, CFBundleName="Wallmotion Runtime QA", CFBundleDisplayName="Wallmotion Runtime QA")
        info_path.write_bytes(plistlib.dumps(info))
        (root / "process-helper.swift").write_text(PROCESS_HELPER)
        with (root / "build.log").open("w") as log:
            run(["sh", "scripts/build-app.sh"], cwd=source, timeout=180, log=log)
            run(["swiftc", str(root / "process-helper.swift"), "-o", str(helper)], timeout=60, log=log)
        built = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        if built["CFBundleIdentifier"] != bundle or library.exists() or apps():
            raise RuntimeError("QA pre-launch isolation check failed")
        first, second = root / "fixture-A.png", root / "fixture-B.png"
        write_png(first)
        write_png(second)
        launched = True
        run(["open", "-g", "-j", "-a", str(app)])
        primary = wait_for(owner, "initial QA owner")
        wait_for(lambda: completed(0, primary), "initial single QA process")
        for paths, expected in [([first], 1), ([first, second], 3)]:
            # -W waits for the newly forced secondary to exit, not just dispatch.
            run(["open", "-W", "-g", "-j", "-n", "-a", str(app), *map(str, paths)], timeout=20)
            wait_for(lambda: completed(expected, primary), "forced-secondary file delivery")
            time.sleep(.3)
            if not completed(expected, primary):
                raise RuntimeError("QA delivery did not remain stable during the observation window")
            results.append({"case": "forced_secondary", "file_count": len(paths), "library_total": expected})
        copies = list((library / "Media").iterdir())
        if len(copies) != 3 or any(path.read_bytes() != first.read_bytes() for path in copies):
            raise RuntimeError("QA managed file bytes did not match the generated fixtures")
        stop()
        run(["open", "-g", "-j", "-a", str(app), str(second)])
        previous = primary
        primary = wait_for(lambda: (current if (current := owner()) != previous else False), "cold URL owner")
        wait_for(lambda: completed(4, primary), "cold URL import")
        results.append({"case": "cold_URL_launch", "library_total": 4})
        before = (library / "library.json").read_bytes()
        run(["open", "-W", "-g", "-j", "-n", "-a", str(app)], timeout=20)
        wait_for(lambda: completed(4, primary), "default secondary exit")
        if (library / "library.json").read_bytes() != before:
            raise RuntimeError("QA no-file reopen changed the temporary library")
        results.append({"case": "default_secondary_no_URL", "library_unchanged": True})
        if check_overflow:
            overflow = [root / f"overflow-{index:03}.png" for index in range(257)]
            for path in overflow:
                path.write_bytes(first.read_bytes())
            run(["open", "-g", "-j", "-n", "-a", str(app), *map(str, overflow)])
            wait_for(lambda: len(apps()) == 2, "secondary retaining an overflow notice")
            # Require the production warning, not just a process lingering for another reason.
            executable = str((app / "Contents/MacOS/Wallmotion").resolve())
            predicate = 'subsystem == "dev.richas.wallmotion" AND category == "instance" AND processImagePath == ' + json.dumps(executable)
            warning_seen = False
            for _ in range(3):
                time.sleep(.5)
                events = json.loads(run(["/usr/bin/log", "show", "--info", "--last", "2m", "--style", "json", "--predicate", predicate], timeout=20))
                if any(event.get("eventMessage") == "Launch URL batch rejected; count=257" for event in events):
                    warning_seen = True
                    break
            if not warning_seen or len(apps()) != 2 or owner() != primary or (library / "library.json").read_bytes() != before:
                raise RuntimeError("overflow notice, primary identity or unchanged QA library was not verified")
            results.append({"case": "oversized_secondary_batch", "rejected_file_count": 257,
                            "warning_observed": True, "secondary_retained": True, "library_unchanged": True})
        return {"source_sha": commit, "status": "passed", "cases": results,
                "limits": ["Isolated archived source with only default library root and bundle metadata patched.",
                           "Uses generated PNGs and no user library, preferences or media.",
                           "OS launch/forward behavior; not a general exactly-once or restoration-without-URL guarantee.",
                           "Temporary QA windows may appear; no UI automation, permissions or power settings are changed."]}
    finally:
        if launched:
            stop()  # On failure, preserve artifacts if the owned process cannot stop.
        registrar = pathlib.Path("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")
        if app.exists() and registrar.exists():
            subprocess.run([str(registrar), "-u", str(app)], capture_output=True, timeout=10)
        shutil.rmtree(root)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true", help="explicitly build and launch isolated temporary QA instances")
    parser.add_argument("--check-overflow", action="store_true", help="also verify 257-file rejection in a source with the 256-URL router policy")
    parser.add_argument("--source-ref", default="HEAD", help="committed source to archive; working edits are excluded")
    args = parser.parse_args()
    if not args.run:
        parser.error("pass --run to opt in to building and launching temporary QA apps")
    if sys.platform != "darwin":
        parser.error("runtime QA requires macOS")
    try:
        print(json.dumps(audit(args.source_ref, args.check_overflow), indent=2))
    except (RuntimeError, OSError, ValueError, subprocess.TimeoutExpired) as error:
        print(f"Runtime QA failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
