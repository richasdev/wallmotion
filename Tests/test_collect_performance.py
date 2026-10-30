import csv
import io
import importlib.util
import json
import pathlib
import tempfile
import unittest
from unittest import mock


SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "scripts" / "collect-performance.py"
SPEC = importlib.util.spec_from_file_location("collect_performance", SCRIPT)
collector = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(collector)


class ProcessParsingTests(unittest.TestCase):
    def test_parses_metrics_and_path_with_spaces(self):
        row = collector.parse_ps_line("501 12.4 2048 1-02:03:04 /Applications/Wallmotion Beta.app/Contents/MacOS/Wallmotion")
        self.assertEqual(row["uid"], 501)
        self.assertEqual(row["cpu_percent"], 12.4)
        self.assertEqual(row["rss_bytes"], 2 * 1024 * 1024)
        self.assertEqual(row["process_elapsed_seconds"], 93784)
        self.assertEqual(row["command"], "/Applications/Wallmotion Beta.app/Contents/MacOS/Wallmotion")

    def test_parses_elapsed_time_forms(self):
        self.assertEqual(collector.parse_elapsed("03:04"), 184)
        self.assertEqual(collector.parse_elapsed("02:03:04"), 7384)

    def test_rejects_unexpected_ps_row(self):
        with self.assertRaises(ValueError):
            collector.parse_ps_line("no process data")


class ArgumentTests(unittest.TestCase):
    def test_accepts_explicit_pid_interval_and_duration(self):
        args = collector.build_parser().parse_args(["--pid", "123", "--interval", "0.5", "--duration", "2"])
        self.assertEqual(args.pid, 123)
        self.assertEqual(args.interval, 0.5)
        self.assertEqual(args.duration, 2)

    def test_rejects_non_positive_or_non_finite_interval(self):
        for value in ("0", "nan", "inf", "abc"):
            with self.subTest(value=value), self.assertRaises(SystemExit):
                collector.build_parser().parse_args(["--pid", "123", "--interval", value, "--duration", "1"])

    def test_rejects_interval_outside_documented_range(self):
        parser = collector.build_parser()
        args = parser.parse_args(["--pid", "123", "--interval", "0.01", "--duration", "1"])
        with self.assertRaises(SystemExit):
            collector.validate_args(args, parser)

    def test_rejects_invalid_pid_duration_and_excessive_sample_count(self):
        cases = (("1", "1", "1"), ("123", "0.1", "86401"), ("123", "0.1", "10000"))
        for pid, interval, duration in cases:
            parser = collector.build_parser()
            args = parser.parse_args(["--pid", pid, "--interval", interval, "--duration", duration])
            with self.subTest(pid=pid, interval=interval, duration=duration), self.assertRaises(SystemExit):
                collector.validate_args(args, parser)


class CollectionLifecycleTests(unittest.TestCase):
    SAMPLE = {
        "uid": 501,
        "cpu_percent": 4.5,
        "rss_bytes": 8192,
        "process_elapsed_seconds": 12,
        "command": "/Applications/Wallmotion.app/Contents/MacOS/Wallmotion",
    }

    def test_process_exit_preserves_partial_json_and_reports_early_exit(self):
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory) / "metrics.json"
            stderr = io.StringIO()
            with (
                mock.patch.object(collector.sys, "platform", "darwin"),
                mock.patch.object(collector, "sample_process", side_effect=[self.SAMPLE.copy(), collector.ProcessUnavailableError("PID 123 exited")]),
                mock.patch.object(collector.time, "monotonic", side_effect=[100.0, 100.0, 100.0]),
                mock.patch.object(collector.time, "sleep"),
                mock.patch("sys.stderr", stderr),
            ):
                status = collector.main(["--pid", "123", "--interval", "0.1", "--duration", "1", "--format", "json", "--output", str(output)])

            result = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(status, collector.EXIT_EARLY)
            self.assertEqual(result["status"], "process_unavailable")
            self.assertEqual(result["termination_reason"], "PID 123 exited")
            self.assertEqual(len(result["samples"]), 1)
            self.assertIn("1 sample(s)", stderr.getvalue())

    def test_process_exit_preserves_partial_csv_and_status_columns(self):
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory) / "metrics.csv"
            with (
                mock.patch.object(collector.sys, "platform", "darwin"),
                mock.patch.object(collector, "sample_process", side_effect=[self.SAMPLE.copy(), collector.ProcessUnavailableError("PID 123 exited")]),
                mock.patch.object(collector.time, "monotonic", side_effect=[100.0, 100.0, 100.0]),
                mock.patch.object(collector.time, "sleep"),
                mock.patch("sys.stderr", io.StringIO()),
            ):
                status = collector.main(["--pid", "123", "--interval", "0.1", "--duration", "1", "--format", "csv", "--output", str(output)])

            with output.open(encoding="utf-8", newline="") as stream:
                rows = list(csv.DictReader(stream))
            self.assertEqual(status, collector.EXIT_EARLY)
            self.assertEqual(len(rows), 1)
            self.assertEqual(rows[0]["collection_status"], "process_unavailable")
            self.assertEqual(rows[0]["termination_reason"], "PID 123 exited")

    def test_invalid_initial_pid_fails_without_creating_output(self):
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory) / "metrics.json"
            with (
                mock.patch.object(collector.sys, "platform", "darwin"),
                mock.patch.object(collector, "sample_process", side_effect=collector.ProcessUnavailableError("PID 123 is not running")),
                mock.patch("sys.stderr", io.StringIO()),
                self.assertRaises(SystemExit) as raised,
            ):
                collector.main(["--pid", "123", "--interval", "0.1", "--duration", "1", "--format", "json", "--output", str(output)])

            self.assertEqual(raised.exception.code, 2)
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
