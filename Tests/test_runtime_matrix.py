import argparse
import importlib.util
import pathlib
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("wallmotion_matrix", pathlib.Path(__file__).parents[1] / "scripts/qa-runtime-matrix.py")
matrix = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(matrix)


class RuntimeMatrixTests(unittest.TestCase):
    def test_injection_requires_exactly_one_match_and_preserves_source_on_failure(self):
        with tempfile.TemporaryDirectory() as root:
            path = pathlib.Path(root) / "source.swift"
            for text in ("no matching statement", "construct construct"):
                path.write_text(text)
                with self.assertRaises(RuntimeError):
                    matrix.replace_once(path, "construct", "isolated")
                self.assertEqual(path.read_text(), text)
            path.write_text("before construct after")
            matrix.replace_once(path, "construct", "isolated")
            self.assertEqual(path.read_text(), "before isolated after")

    def test_bounded_durations_reject_nonfinite_and_unbounded_work(self):
        for value in ("nan", "inf", "-inf", "0", "-1", "601"):
            with self.assertRaises(argparse.ArgumentTypeError):
                matrix.finite_duration(value)
        self.assertEqual(matrix.finite_duration("120"), 120)
        self.assertEqual(matrix.finite_duration("1"), 1)

    def test_a_phase_requires_actual_transport_silent_fixture_and_no_sleep_prevention(self):
        for phase in matrix.PHASES:
            value = {"status": "ready", "pid": 123, "phase": phase,
                     "prevents_display_sleep": False, "current_item_ready": True,
                     "playing": phase == "active", "rate": 1 if phase == "active" else 0,
                     "muted": True, "volume": 0}
            self.assertTrue(matrix.validate_status(value, 123, phase))
            self.assertFalse(matrix.validate_status(value, 124, phase))
            for field, broken in (("prevents_display_sleep", True), ("current_item_ready", False),
                                  ("playing", phase != "active"), ("muted", False), ("volume", .1)):
                with self.subTest(phase=phase, field=field), self.assertRaises(RuntimeError):
                    matrix.validate_status({**value, field: broken}, 123, phase)
            if phase != "active":
                with self.assertRaises(RuntimeError):
                    matrix.validate_status({**value, "rate": 1}, 123, phase)
        with self.assertRaises(RuntimeError):
            matrix.validate_status({"status": "failed"}, 123, "active")

    def test_cli_requires_explicit_opt_in_and_does_not_start_a_build(self):
        with patch.object(matrix, "matrix") as run, patch("sys.argv", ["qa-runtime-matrix.py", "--output", "/tmp/unused-wallmotion-report.json"]):
            with self.assertRaises(SystemExit) as error:
                matrix.main()
            self.assertEqual(error.exception.code, 2)
            run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
