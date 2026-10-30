"""Cleanup scope checks use temporary trees and mock compiler commands only."""
import json
import os
from pathlib import Path
import shutil
import shlex
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "clean-builds.sh"


class CleanBuildsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="WallmotionCleanupQA-")
        self.parent = Path(self.temporary.name)
        self.root = self.parent / "checkout with spaces"
        (self.root / "scripts").mkdir(parents=True)
        (self.root / "crates/wallmotion-media").mkdir(parents=True)
        shutil.copyfile(SCRIPT, self.root / "scripts/clean-builds.sh")
        (self.root / "Package.swift").write_text("// fixture only\n")
        (self.root / "crates/wallmotion-media/Cargo.toml").write_text("# fixture only\n")
        self.trace = self.parent / "trace.jsonl"
        commands = self.parent / "commands"
        commands.mkdir()
        logger = self.parent / "record-command.py"
        logger.write_text("import json,os,sys\nwith open(os.environ['WALLMOTION_CLEAN_TRACE'],'a') as f: f.write(json.dumps({'command':[os.path.basename(sys.argv[1])]+sys.argv[2:],'swift_override':os.environ.get('SWIFTPM_BUILD_DIR'),'cwd':os.getcwd()})+'\\n')\nsys.exit(int(os.environ.get('WALLMOTION_CLEAN_MOCK_EXIT','0')))\n")
        for name in ("cargo", "swift"):
            command = commands / name
            command.write_text("#!/bin/sh\nexec " + shlex.quote(sys.executable) + " " + shlex.quote(str(logger)) + ' "$0" "$@"\n')
            command.chmod(0o700)
        self.env = os.environ.copy()
        self.env.pop("WALLMOTION_CLEAN_MOCK_EXIT", None)
        self.env.update(PATH=str(commands) + os.pathsep + self.env.get("PATH", ""),
                        WALLMOTION_CLEAN_TRACE=str(self.trace), SWIFTPM_BUILD_DIR=str(self.parent / "external-scratch"))

    def tearDown(self):
        self.temporary.cleanup()

    def run_clean(self, *arguments):
        return subprocess.run(["/bin/sh", str(self.root / "scripts/clean-builds.sh"), *arguments],
                              cwd=self.parent, env=self.env, capture_output=True, text=True, timeout=5)

    def calls(self):
        return [json.loads(line)["command"] for line in self.trace.read_text().splitlines()] if self.trace.exists() else []

    def test_default_preserves_release_and_full_uses_explicit_scratch(self):
        self.assertEqual(self.run_clean().returncode, 0)
        self.assertEqual(self.calls(), [["cargo", "clean", "--profile", "dev", "--manifest-path",
                                         "crates/wallmotion-media/Cargo.toml", "--target-dir", ".build/native"]])
        self.trace.unlink()
        (self.root / "crates/wallmotion-media/target").mkdir()
        app = self.root / "dist/Wallmotion.app"
        app.mkdir(parents=True)
        sentinel = app / "keep"
        sentinel.write_text("packaged-app")
        self.assertEqual(self.run_clean("--all").returncode, 0)
        calls = self.calls()
        self.assertEqual(calls[1], ["swift", "package", "--scratch-path", ".build", "clean"])
        records = [json.loads(line) for line in self.trace.read_text().splitlines()]
        self.assertIsNone(records[1]["swift_override"])
        self.assertIsNotNone(self.env["SWIFTPM_BUILD_DIR"])
        self.assertEqual(calls[2][-2:], ["--target-dir", "crates/wallmotion-media/target"])
        self.assertEqual(sentinel.read_text(), "packaged-app")

    def test_symlinked_build_ancestor_rejects_before_any_tool(self):
        outside = self.parent / "outside"
        outside.mkdir()
        sentinel = outside / "keep"
        sentinel.write_text("outside-data")
        (self.root / ".build").symlink_to(outside, target_is_directory=True)
        self.assertEqual(self.run_clean("--all").returncode, 2)
        self.assertEqual(self.calls(), [])
        self.assertEqual(sentinel.read_text(), "outside-data")

    def test_native_and_duplicate_targets_reject_even_broken_symlinks(self):
        for relative in (".build/native", "crates/wallmotion-media/target"):
            with self.subTest(path=relative):
                target = self.root / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.symlink_to(self.parent / "missing", target_is_directory=True)
                self.assertEqual(self.run_clean("--all").returncode, 2)
                self.assertEqual(self.calls(), [])
                target.unlink()

    def test_crate_ancestor_and_manifest_symlinks_reject_before_any_tool(self):
        crate = self.root / "crates/wallmotion-media"
        outside = self.parent / "other-crate"
        crate.rename(outside)
        crate.symlink_to(outside, target_is_directory=True)
        self.assertEqual(self.run_clean().returncode, 2)
        self.assertEqual(self.calls(), [])
        crate.unlink()
        outside.rename(crate)
        manifest = crate / "Cargo.toml"
        manifest.unlink()
        manifest.symlink_to(self.parent / "missing-manifest")
        self.assertEqual(self.run_clean().returncode, 2)
        self.assertEqual(self.calls(), [])

    def test_unexpected_directory_type_and_missing_marker_reject(self):
        build = self.root / ".build"
        build.write_text("not-a-directory")
        self.assertEqual(self.run_clean().returncode, 2)
        build.unlink()
        (self.root / "Package.swift").unlink()
        self.assertEqual(self.run_clean("--all").returncode, 2)
        self.assertEqual(self.calls(), [])

    def test_bad_arguments_reject_with_otherwise_valid_checkout(self):
        for arguments in (("--invalid",), ("--all", "extra")):
            self.assertEqual(self.run_clean(*arguments).returncode, 2)
        self.assertEqual(self.calls(), [])

    def test_cdpath_cannot_select_another_checkout(self):
        outside = self.parent / "another-checkout"
        (outside / "scripts").mkdir(parents=True)
        self.env["CDPATH"] = str(outside)
        result = subprocess.run(["/bin/sh", "scripts/clean-builds.sh"], cwd=self.root,
                                env=self.env, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        records = [json.loads(line) for line in self.trace.read_text().splitlines()]
        self.assertEqual(records[0]["cwd"], str(self.root.resolve()))

    def test_all_entry_scripts_anchor_to_requested_checkout_despite_cdpath(self):
        names = ("build-native.sh", "build-app.sh", "check.sh", "run.sh", "clean-builds.sh")
        outside = self.parent / "other-project"
        (outside / "scripts").mkdir(parents=True)
        (outside / "crates/wallmotion-media").mkdir(parents=True)
        (outside / "Package.swift").write_text("// other fixture")
        (outside / "crates/wallmotion-media/Cargo.toml").write_text("# other fixture")
        for name in names:
            shutil.copyfile(SCRIPT.parent / name, self.root / "scripts" / name)
            shutil.copyfile(SCRIPT.parent / name, outside / "scripts" / name)
        self.env.update(CDPATH=str(outside), WALLMOTION_CLEAN_MOCK_EXIT="73")
        for name in names:
            with self.subTest(script=name):
                if self.trace.exists():
                    self.trace.unlink()
                result = subprocess.run(["/bin/sh", "scripts/" + name], cwd=self.root,
                                        env=self.env, capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, 73, result.stderr)
                records = [json.loads(line) for line in self.trace.read_text().splitlines()]
                self.assertEqual(records[0]["cwd"], str(self.root.resolve()))

    def test_symlinked_script_directory_rejects_before_changing_project_root(self):
        scripts = self.root / "scripts"
        moved = self.parent / "external-scripts"
        scripts.rename(moved)
        scripts.symlink_to(moved, target_is_directory=True)
        self.assertEqual(self.run_clean("--all").returncode, 2)
        self.assertEqual(self.calls(), [])


@unittest.skipUnless(shutil.which("cargo") and shutil.which("swift"), "real Cargo/Swift toolchains required")
class CleanBuildsIntegrationTests(unittest.TestCase):
    def test_real_cleaners_keep_external_scratch_and_packaged_app(self):
        # Everything, including the deliberately external sentinel, belongs to
        # this temporary tree. No app checkout or global cache is cleaned.
        with tempfile.TemporaryDirectory(prefix="WallmotionCleanScope-") as temporary:
            parent = Path(temporary)
            root = parent / "checkout with spaces"
            (root / "scripts").mkdir(parents=True)
            (root / "crates/wallmotion-media/src").mkdir(parents=True)
            (root / "Sources/CleanupFixture").mkdir(parents=True)
            shutil.copyfile(SCRIPT, root / "scripts/clean-builds.sh")
            (root / "crates/wallmotion-media/Cargo.toml").write_text('[package]\nname="wallmotion-clean-fixture"\nversion="0.1.0"\nedition="2024"\n')
            (root / "crates/wallmotion-media/src/lib.rs").write_text("")
            (root / "Package.swift").write_text('// swift-tools-version: 6.0\nimport PackageDescription\nlet package=Package(name:"CleanupFixture",targets:[.target(name:"CleanupFixture")])\n')
            (root / "Sources/CleanupFixture/CleanupFixture.swift").write_text("public let value=1\n")
            external = parent / "external-build"
            sentinel = external / "native/debug/keep"
            sentinel.parent.mkdir(parents=True)
            sentinel.write_text("external-data")
            (root / ".build").symlink_to(external, target_is_directory=True)
            env = os.environ.copy()

            def clean(*arguments):
                return subprocess.run(["/bin/sh", str(root / "scripts/clean-builds.sh"), *arguments],
                                      env=env, capture_output=True, text=True, timeout=20)

            result = clean()
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertEqual(sentinel.read_text(), "external-data")
            (root / ".build").unlink()
            for profile in ("debug", "release"):
                marker = root / ".build/native" / profile / "keep"
                marker.parent.mkdir(parents=True)
                marker.write_text(profile)
            app = root / "dist/Wallmotion.app/keep"
            app.parent.mkdir(parents=True)
            app.write_text("packaged-app")
            result = clean()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse((root / ".build/native/debug/keep").exists())
            self.assertEqual((root / ".build/native/release/keep").read_text(), "release")
            external_scratch = parent / "external-swift"
            external_scratch.mkdir()
            swift_marker = external_scratch / "keep"
            swift_marker.write_text("external-swift-data")
            env["SWIFTPM_BUILD_DIR"] = str(external_scratch)
            result = clean("--all")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(swift_marker.read_text(), "external-swift-data")
            self.assertEqual(app.read_text(), "packaged-app")


if __name__ == "__main__":
    unittest.main()
