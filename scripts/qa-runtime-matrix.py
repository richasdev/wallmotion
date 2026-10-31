#!/usr/bin/env python3
"""Opt-in host CPU/RSS and power snapshots for a private instrumented native-video app."""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import math
import os
import pathlib
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid

HERE = pathlib.Path(__file__).resolve().parent
PHASES = ("active", "manual_pause", "occluded", "thermal_pause")


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


runtime = load("wallmotion_runtime", HERE / "qa-instance-runtime.py")
metrics = load("wallmotion_metrics", HERE / "collect-performance.py")
power = load("wallmotion_power", HERE / "audit-power-assertions.py")


def replace_once(path, original, replacement):
    value = path.read_text()
    if value.count(original) != 1:
        raise RuntimeError("QA source injection no longer matches exactly once")
    path.write_text(value.replace(original, replacement))


def finite_duration(value):
    number = float(value)
    if not math.isfinite(number) or not 1 <= number <= 600:
        raise argparse.ArgumentTypeError("must be finite and between 1 and 600 seconds")
    return number


def validate_status(value, pid, phase):
    if value.get("status") == "failed":
        raise RuntimeError("instrumented renderer reported failure")
    if value.get("status") != "ready" or value.get("pid") != pid or value.get("phase") != phase:
        return False
    if value.get("prevents_display_sleep") is not False or value.get("current_item_ready") is not True:
        raise RuntimeError("native item or display-sleep configuration was not verified")
    if value.get("playing") != (phase == "active") or (phase != "active" and value.get("rate") != 0):
        raise RuntimeError("native transport did not match the requested phase")
    if value.get("muted") is not True or value.get("volume") != 0:
        raise RuntimeError("QA fixture must stay silent in every phase")
    return True


def matrix(source_ref, duration, warmup, build_log):
    repository = HERE.parent
    commit = runtime.run(["git", "rev-parse", "--verify", "--end-of-options", source_ref + "^{commit}"], cwd=repository).strip()
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise RuntimeError("source must resolve to a full commit SHA")
    root = pathlib.Path(tempfile.mkdtemp(prefix="wallmotion-matrix-qa-"))
    source, library = root / "source", root / "library"
    app, helper = source / "dist/Wallmotion.app", root / "process-helper"
    bundle = "dev.richas.wallmotion.qa." + uuid.uuid4().hex
    launched = False
    results = []
    command_id = 0

    def apps():
        deadline = time.monotonic() + 2
        while True:
            rows = [row for row in json.loads(runtime.run([str(helper), "list", bundle])) if not row.get("terminated")]
            if any(row["path"] and pathlib.Path(row["path"]).resolve() != app.resolve() for row in rows):
                raise RuntimeError("QA bundle resolved to a foreign path")
            if all(row["path"] for row in rows):
                return rows
            if time.monotonic() >= deadline:
                raise RuntimeError("QA process path remained unavailable")
            time.sleep(.05)

    def stop():
        if not apps():
            return
        runtime.run([str(helper), "terminate", bundle])
        deadline = time.monotonic() + 3
        while apps() and time.monotonic() < deadline:
            time.sleep(.1)
        for row in apps():
            try:
                os.kill(row["pid"], signal.SIGTERM)
            except ProcessLookupError:
                pass
        runtime.wait_for(lambda: not apps(), "owned QA process cleanup", timeout=5)

    def status():
        path = root / "status.json"
        if not path.exists():
            return {}
        if path.stat().st_size > 4096:
            raise RuntimeError("QA status exceeded size limit")
        return json.loads(path.read_text())

    def observe(pid, phase):
        nonlocal command_id
        command_id += 1
        temporary = root / "command.next"
        temporary.write_text(json.dumps({"id": command_id, "phase": phase}))
        temporary.replace(root / "command.json")

        def accepted():
            value = status()
            if value.get("status") == "failed":
                raise RuntimeError("instrumented renderer reported failure")
            if value.get("id") != command_id:
                return False
            return value if validate_status(value, pid, phase) else False
        return runtime.wait_for(accepted, "native phase acknowledgement", timeout=20)

    def owner_pid():
        path = library / "wallmotion-owner.json"
        if not path.exists():
            return False
        value = json.loads(path.read_text())
        if value["bundleIdentifier"] != bundle:
            raise RuntimeError("QA owner identity mismatch")
        return value["processID"]

    try:
        source.mkdir()
        archive = root / "source.tar"
        runtime.run(["git", "archive", "--format=tar", "--output", str(archive), commit], cwd=repository)
        runtime.run(["tar", "-xf", str(archive), "-C", str(source)])
        archive.unlink()
        replace_once(source / "Sources/WallmotionCore/LibraryStore.swift",
            'URL.applicationSupportDirectory.appendingPathComponent("Wallmotion", isDirectory: true)',
            'URL(fileURLWithPath: ' + json.dumps(str(library)) + ', isDirectory: true)')
        replace_once(source / "Sources/Wallmotion/ApplicationSession.swift",
            'self.makeModel = makeModel ?? { LibraryModel(store: store) }',
            'self.makeModel = makeModel ?? { RuntimeMatrixQA.makeModel(store: store) }')
        replace_once(source / "Sources/Wallmotion/WallmotionApp.swift",
            'events.finishLaunching(isDefaultLaunch: isDefault)',
            'events.finishLaunching(isDefaultLaunch: isDefault)\n        RuntimeMatrixQA.begin(session)')
        fixture = (source / "Tests/Fixtures/runtime-matrix.swift").read_text()
        if fixture.count("__QA_ROOT_JSON__") != 1:
            raise RuntimeError("committed runtime fixture is unavailable")
        injected = fixture.replace("__QA_ROOT_JSON__", json.dumps(str(root)))
        (source / "Sources/Wallmotion/RuntimeMatrixQA.swift").write_text(injected)
        info_path = source / "resources/Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        info.update(CFBundleIdentifier=bundle, CFBundleName="Wallmotion Matrix QA", CFBundleDisplayName="Wallmotion Matrix QA")
        info_path.write_bytes(plistlib.dumps(info))
        (root / "process-helper.swift").write_text(runtime.PROCESS_HELPER)
        with build_log.open("x") as log:
            runtime.run(["sh", "scripts/build-app.sh"], cwd=source, timeout=240, log=log)
            runtime.run(["swiftc", str(root / "process-helper.swift"), "-o", str(helper)], timeout=60, log=log)
        built = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        if built["CFBundleIdentifier"] != bundle or library.exists() or apps():
            raise RuntimeError("QA pre-launch isolation check failed")
        runtime.run(["codesign", "--verify", "--strict", str(app)])
        launched = True
        runtime.run(["open", "-g", "-j", "-a", str(app)])
        pid = runtime.wait_for(owner_pid, "private QA owner")
        runtime.wait_for(lambda: status().get("status") in ("ready", "failed"), "fixture encoding and native playback", timeout=40)
        if not validate_status(status(), pid, "active"):
            raise RuntimeError("initial native playback unavailable")
        for phase in PHASES:
            print("QA phase:", phase, "warmup", warmup, "sample_seconds", duration, flush=True)
            observe(pid, phase)
            time.sleep(warmup)
            before = observe(pid, phase)
            assertion_before = power.audit(pid)
            samples = metrics.collect(pid, 1.0, duration, metrics.sample_process(pid))
            after = observe(pid, phase)
            assertion_after = power.audit(pid)
            if samples["status"] != "completed" or len(apps()) != 1 or owner_pid() != pid:
                raise RuntimeError("sampling or QA process identity did not remain stable")
            if assertion_before["display_sleep_assertion_count"] or assertion_after["display_sleep_assertion_count"]:
                raise RuntimeError("display-sleep assertion observed for QA host")
            for row in samples["samples"]:
                for field in ("command", "uid", "process_start_token"):
                    row.pop(field, None)
            rss = sorted(row["rss_bytes"] for row in samples["samples"])
            samples["summary"].update(rss_mean_bytes=sum(rss) / len(rss), rss_p95_bytes=rss[math.ceil(len(rss) * .95) - 1])
            results.append({"phase": phase, "before": before, "after": after, "metrics": samples,
                "power_before": assertion_before, "power_after": assertion_after})
            print("QA completed:", phase, json.dumps(samples["summary"]), flush=True)
        return {"schema_version": 1, "status": "passed", "source_sha": commit,
            "injected_fixture_sha256": hashlib.sha256(injected.encode()).hexdigest(),
            "os_version": runtime.run(["sw_vers", "-productVersion"]).strip(), "architecture": os.uname().machine,
            "sample_interval_seconds": 1.0, "phase_duration_seconds": duration, "warmup_seconds": warmup,
            "workload": {"codec": "H.264", "width": 1280, "height": 720, "fps": 30, "loop_seconds": 4, "audio_track": False},
            "phases": results, "limits": [
                "Instrumented archived app with private library/bundle and generated video; not the unmodified user's app.",
                "One synthetic offscreen 1280x720 desktop target; visibility and thermal pressure are injected in the QA copy only.",
                "Actual AVPlayer playback and production model policy; checks of progress/readiness occur at phase boundaries.",
                "Host ps CPU/RSS only; no GPU, WindowServer, WebKit helpers, power watts, physical footprint or battery measurement.",
                "Power assertions queried at phase boundaries only; no actual sleep, physical lock, rotation, HDR or live provider certification.",
                "Fixed phase order, one run; results are descriptive, not proof of general savings or statistical significance.",
                "No user library/media, sudo, HOME changes, login items, OS permission changes or power-setting changes."]}
    except (RuntimeError, OSError, ValueError, subprocess.TimeoutExpired) as error:
        # Preserve diagnostics outside the disposable archive. Never emit a passing
        # matrix when one phase failed; raw ps command paths remain unexported.
        with build_log.open("a") as log:
            log.write("\nMatrix failure: " + type(error).__name__ + ": " + str(error) + "\n")
            log.write(json.dumps({"completed_phases": [row["phase"] for row in results], "last_status": status()}))
        raise
    finally:
        if launched:
            stop()  # Failure to stop preserves the owned archive instead of deleting a live app.
        registrar = pathlib.Path("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")
        if app.exists() and registrar.exists():
            subprocess.run([str(registrar), "-u", str(app)], capture_output=True, timeout=10)
        shutil.rmtree(root)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--source-ref", default="HEAD", help="archive a trusted committed source; ignore working edits")
    parser.add_argument("--duration", type=finite_duration, default=120.0, help="seconds per phase, 1–600")
    parser.add_argument("--warmup", type=finite_duration, default=10.0, help="seconds before each phase, 1–600")
    parser.add_argument("--output", required=True, type=pathlib.Path)
    args = parser.parse_args()
    if not args.run or sys.platform != "darwin":
        parser.error("requires macOS and explicit --run")
    if args.output.exists() or args.output.with_suffix(".build.log").exists():
        parser.error("output and build log must be new files")
    try:
        report = matrix(args.source_ref, args.duration, args.warmup, args.output.with_suffix(".build.log"))
        with args.output.open("x") as stream:
            json.dump(report, stream, indent=2);stream.write("\n")
    except (RuntimeError, OSError, ValueError, subprocess.TimeoutExpired):
        print("Runtime matrix failed; no passing report emitted. Inspect its private build log.", file=sys.stderr)
        return 1
    print("Runtime matrix passed; owned temporary app/source/library cleaned.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
