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
        row = collector.parse_ps_line("501 12.4 2048 1-02:03:04 2:03.45 Fri Oct 30 19:25:23 2026 /Applications/Wallmotion Beta.app/Contents/MacOS/Wallmotion")
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
        "ps_cpu_percent": 4.5,
        "cpu_time_ns": 100_000_000,
        "cpu_time_seconds": 0.1,
        "cpu_time_quantum_ns": 10_000_000,
        "process_start_token": "Fri Oct 30 19:25:23 2026",
        "_sample_time": 100.0,
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


class IntervalMetricsTests(unittest.TestCase):
    def sample(self, stamp=100.0, cpu=100_000_000, **changes):
        return {**CollectionLifecycleTests.SAMPLE, "_sample_time": stamp, "cpu_time_ns": cpu, "cpu_time_seconds": cpu / 1_000_000_000, **changes}

    def test_cpu_time_precision_hours_days_and_large_minutes(self):
        self.assertEqual(collector.parse_cpu_time("0:00.50"), (500_000_000, 10_000_000))
        self.assertEqual(collector.parse_cpu_time("1:02:03.004"), (3723_004_000_000, 1_000_000))
        self.assertEqual(collector.parse_cpu_time("1-02:03:04.56"), (93784_560_000_000, 10_000_000))
        self.assertEqual(collector.parse_cpu_time("190:12"), (11412_000_000_000, 1_000_000_000))
        for value in ("nan", "-1:00", "1:60", "1:99:00", "1:02.1234567890", "1e3", "1:2.x"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                collector.parse_cpu_time(value)

    def test_first_interval_is_unavailable_and_multicore_is_not_clamped(self):
        first = self.sample(cpu=0)
        collector.add_interval_metrics(None, first)
        self.assertIsNone(first["cpu_interval_percent"])
        current = self.sample(stamp=101.0, cpu=2_000_000_000)
        collector.add_interval_metrics(first, current)
        self.assertEqual(current["cpu_interval_percent"], 200.0)
        self.assertEqual(current["sample_interval_seconds"], 1.0)
        idle = self.sample(stamp=102.0, cpu=2_000_000_000)
        collector.add_interval_metrics(current, idle)
        self.assertEqual(idle["cpu_interval_percent"], 0.0)  # Quantized counter delta, not proof of zero work.

    def test_pid_reuse_command_uid_and_counter_regression_stop_collection(self):
        first = self.sample()
        for changes in ({"process_start_token": "Fri Oct 30 19:30:00 2026"}, {"command": "/other/Wallmotion"}, {"uid": 502}, {"cpu_time_ns": 0}, {"process_elapsed_seconds": 1}):
            with self.subTest(changes=changes), self.assertRaises(collector.ProcessChangedError):
                collector.add_interval_metrics(first, self.sample(stamp=101.0, **changes))
        with self.assertRaises(RuntimeError):
            collector.add_interval_metrics(first, self.sample())

    def test_schedule_skips_slow_queries_and_cpu_summary_is_time_weighted(self):
        first = self.sample(stamp=10.0, cpu=0)
        later = [self.sample(stamp=10.35, cpu=100_000_000), self.sample(stamp=10.5, cpu=200_000_000)]
        with (
            mock.patch.object(collector, "sample_process", side_effect=later),
            mock.patch.object(collector.time, "monotonic", side_effect=[10.0, 10.35]),
            mock.patch.object(collector.time, "sleep") as sleep,
        ):
            result = collector.collect(123, .1, .5, first)
        self.assertEqual(result["status"], "completed")
        self.assertEqual(len(result["samples"]), 3)
        self.assertAlmostEqual(sleep.call_args_list[0].args[0], .1)
        self.assertAlmostEqual(sleep.call_args_list[1].args[0], .05)
        self.assertAlmostEqual(result["summary"]["cpu_interval_weighted_percent"], 40)
        self.assertAlmostEqual(result["summary"]["cpu_interval_p95_percent"], 100 / 1.5)
        self.assertEqual(result["summary"]["rss_peak_sample_bytes"], 8192)
        self.assertNotIn("_sample_time", result["samples"][0])

    def test_changed_pid_preserves_only_prior_rows(self):
        first = self.sample()
        changed = self.sample(stamp=101.0, process_start_token="Sat Oct 31 01:00:00 2026")
        with (
            mock.patch.object(collector, "sample_process", return_value=changed),
            mock.patch.object(collector.time, "monotonic", return_value=100.0),
            mock.patch.object(collector.time, "sleep"),
        ):
            result = collector.collect(123, 1, 2, first)
        self.assertEqual(result["status"], "process_changed")
        self.assertEqual(len(result["samples"]), 1)
        self.assertIsNone(result["summary"]["cpu_interval_weighted_percent"])
        self.assertEqual(result["schema_version"], 2)

    def test_csv_keeps_legacy_estimate_and_adds_null_first_interval(self):
        first = self.sample()
        collector.add_interval_metrics(None, first)
        result = {"schema_version": 2, "status": "completed", "termination_reason": "done", "requested_duration_seconds": 1, "samples": [first]}
        stream = io.StringIO()
        collector.write_output(result, "csv", stream)
        row = next(csv.DictReader(io.StringIO(stream.getvalue())))
        self.assertEqual(row["cpu_percent"], "4.5")
        self.assertEqual(row["ps_cpu_percent"], "4.5")
        self.assertEqual(row["cpu_interval_percent"], "")
        self.assertEqual(row["schema_version"], "2")

    def test_ps_uses_c_locale_utc_and_bounded_query_timeout(self):
        output = "501 12.4 2048 01:02 0:00.50 Fri Oct 30 19:25:23 2026 /Applications/Wallmotion.app/Contents/MacOS/Wallmotion"
        with (
            mock.patch.object(collector.subprocess, "run", return_value=mock.Mock(returncode=0, stdout=output)) as run,
            mock.patch.object(collector.os, "getuid", return_value=501),
            mock.patch.object(collector.time, "monotonic", return_value=100.0),
        ):
            row = collector.sample_process(123)
        self.assertEqual(run.call_args.kwargs["env"]["LC_ALL"], "C")
        self.assertEqual(run.call_args.kwargs["env"]["TZ"], "UTC")
        self.assertEqual(run.call_args.kwargs["timeout"], 5)
        self.assertEqual(row["cpu_time_ns"], 500_000_000)
        self.assertEqual(row["_sample_time"], 100.0)


if __name__ == "__main__":
    unittest.main()
