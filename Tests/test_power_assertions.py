import importlib.util
import io
import json
import pathlib
import subprocess
import unittest
from unittest import mock

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "scripts" / "audit-power-assertions.py"
SPEC = importlib.util.spec_from_file_location("power_assertions", SCRIPT)
power = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(power)


def output(*rows):
    return "System-wide status: SECRET_GLOBAL\nListed by owning process:\n" + "\n".join(rows) + "\nKernel Assertions: 0x100=USB\n"


def row(pid, kind="PreventUserIdleDisplaySleep", name="PRIVATE_TITLE"):
    return f'   pid {pid}(Private App): [0x000123ab] 378:49:28 {kind} named: "{name}"'


class AssertionParsingTests(unittest.TestCase):
    def test_exact_pid_filter_exports_only_type_counts(self):
        counts = power.parse_assertions(output(row(123), row(123), row(1234), row(12), row(123, "PreventUserIdleSystemSleep")), 123)
        self.assertEqual(counts, {"PreventUserIdleDisplaySleep": 2, "PreventUserIdleSystemSleep": 1})
        self.assertNotIn("PRIVATE", json.dumps(counts))

    def test_no_target_assertions_is_valid_but_missing_section_is_not(self):
        self.assertEqual(power.parse_assertions(output(row(456)), 123), {})
        self.assertEqual(power.parse_assertions("Listed by owning process:\nNo kernel assertions.\n", 123), {})
        for text in ["", "PreventUserIdleDisplaySleep 0", "Listed by owning process:\n", "Kernel Assertions: 0"]:
            with self.subTest(text=text), self.assertRaises(ValueError):
                power.parse_assertions(text, 123)

    def test_malformed_target_duplicate_section_and_oversize_fail_closed(self):
        for text in [output("pid 123(Private App): unsupported format PRIVATE_TITLE"), output("Listed by owning process:"), output("pid 123 (format-changed): unknown"), "x" * (power.MAX_OUTPUT_BYTES + 1)]:
            with self.assertRaises(ValueError):
                power.parse_assertions(text, 123)

    def test_owner_name_parentheses_do_not_change_type_or_pid(self):
        text = output(row(123).replace("Private App", "App (private)"))
        self.assertEqual(power.parse_assertions(text, 123), {"PreventUserIdleDisplaySleep": 1})


class AssertionAuditTests(unittest.TestCase):
    SAMPLE = {"uid": 501, "command": "/private/Wallmotion", "process_start_token": "stable", "cpu_time_ns": 1_000_000, "process_elapsed_seconds": 5, "_sample_time": 10.0}

    def samples(self):
        return [dict(self.SAMPLE), {**self.SAMPLE, "_sample_time": 10.5}]

    def test_bounded_read_only_query_and_no_private_records_in_report(self):
        with mock.patch.object(power.metrics, "sample_process", side_effect=self.samples()), mock.patch.object(power.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, output(row(123), row(456, name="OTHER_APP_SECRET")), "")) as run:
            report = power.audit(123)
        self.assertEqual(report["display_sleep_assertion_count"], 1)
        self.assertEqual(report["status"], "display_sleep_assertion_present")
        self.assertNotIn("PRIVATE", json.dumps(report))
        self.assertNotIn("OTHER_APP_SECRET", json.dumps(report))
        self.assertEqual(run.call_args.args[0], ["/usr/bin/pmset", "-g", "assertions"])
        self.assertEqual(run.call_args.kwargs["timeout"], 5)
        self.assertEqual(run.call_args.kwargs["env"]["LC_ALL"], "C")

    def test_pid_change_rejects_even_clean_snapshot(self):
        samples = self.samples()
        samples[1]["process_start_token"] = "reused"
        with mock.patch.object(power.metrics, "sample_process", side_effect=samples), mock.patch.object(power.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, output(), "")), self.assertRaises(power.metrics.ProcessChangedError):
            power.audit(123)

    def test_cli_unknown_query_never_emits_clean_json_or_sensitive_error(self):
        for error in [RuntimeError("PRIVATE_TITLE"), subprocess.TimeoutExpired("PRIVATE_COMMAND", 5), ValueError("PRIVATE_LINE")]:
            with mock.patch.object(power.sys, "platform", "darwin"), mock.patch.object(power, "audit", side_effect=error), mock.patch("sys.stdout", new_callable=io.StringIO) as stdout, mock.patch("sys.stderr", new_callable=io.StringIO) as stderr:
                self.assertEqual(power.main(["--pid", "123"]), 2)
                self.assertEqual(stdout.getvalue(), "")
                self.assertNotIn("PRIVATE", stderr.getvalue())

    def test_cli_exit_codes_distinguish_observed_assertion_from_clean_snapshot(self):
        for count, expected in [(0, 0), (1, 3)]:
            with mock.patch.object(power.sys, "platform", "darwin"), mock.patch.object(power, "audit", return_value={"display_sleep_assertion_count": count}), mock.patch("sys.stdout", new_callable=io.StringIO) as stdout:
                self.assertEqual(power.main(["--pid", "123"]), expected)
                self.assertEqual(json.loads(stdout.getvalue())["display_sleep_assertion_count"], count)


if __name__ == "__main__":
    unittest.main()
