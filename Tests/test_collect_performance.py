import importlib.util
import pathlib
import unittest


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


if __name__ == "__main__":
    unittest.main()
