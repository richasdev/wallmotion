import importlib.util
import pathlib
import subprocess
import sys
import tempfile
import unittest

REPO = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = REPO / "scripts/qa-instance-runtime.py"
spec = importlib.util.spec_from_file_location("instance_runtime", SCRIPT)
qa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(qa)


class NondefaultLaunchTests(unittest.TestCase):
    def tree(self, root, delegate):
        fixture = root / "Tests/Fixtures/nondefault-launch.swift"
        fixture.parent.mkdir(parents=True)
        fixture.write_text((REPO / "Tests/Fixtures/nondefault-launch.swift").read_text())
        app = root / "Sources/Wallmotion/WallmotionApp.swift"
        app.parent.mkdir(parents=True)
        app.write_text(delegate)
        return app, fixture

    def test_injection_observes_os_flag_without_replacing_router_argument(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            app, _ = self.tree(root, "events.finishLaunching(isDefaultLaunch: isDefault)")
            qa.inject_nondefault_probe(root, root / "private-qa")
            self.assertIn("events.finishLaunching(isDefaultLaunch: isDefault)", app.read_text())
            self.assertIn("NondefaultLaunchQA.begin(self, isDefault: isDefault, flagPresent:", app.read_text())
            self.assertNotIn("__QA_ROOT_JSON__", (app.parent / "NondefaultLaunchQA.swift").read_text())

    def test_delegate_hook_refuses_missing_or_duplicate_match(self):
        for value in ["no matching hook", "events.finishLaunching(isDefaultLaunch: isDefault)" * 2]:
            with self.subTest(value=value), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                app, _ = self.tree(root, value)
                with self.assertRaises(RuntimeError):
                    qa.inject_nondefault_probe(root, root / "private-qa")
                self.assertEqual(app.read_text(), value)

    def test_fixture_root_requires_exactly_one_marker(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            _, fixture = self.tree(root, "events.finishLaunching(isDefaultLaunch: isDefault)")
            fixture.write_text("__QA_ROOT_JSON__ __QA_ROOT_JSON__")
            with self.assertRaises(RuntimeError):
                qa.inject_nondefault_probe(root, root / "private-qa")

    def test_evidence_option_does_not_bypass_required_opt_in(self):
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory) / "must-not-exist"
            result = subprocess.run([sys.executable, str(SCRIPT), "--nondefault-evidence", str(output)], capture_output=True)
            self.assertEqual(result.returncode, 2)
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
