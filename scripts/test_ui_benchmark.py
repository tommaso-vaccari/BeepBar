#!/usr/bin/env python3
"""Offline safeguards for UI measurement evidence. No app, build or network is launched."""
import copy
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import xml.etree.ElementTree as ET

spec = importlib.util.spec_from_file_location("ui_benchmark", Path(__file__).with_name("ui-benchmark.py"))
driver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)


def sample(scenario="courses-100"):
    resources = dict(footprintBytes=10, cpuNanoseconds=2, diskBytesWritten=0,
                     logicalBytesWritten=0, interruptWakeups=0, idleWakeups=0)
    cycles = 10 if scenario == "memory-cycles" else 2 if scenario in ("launch-warm", "reopen-sync") else 1
    kind = "expandedActivity" if scenario.startswith("activity-") else "recordings" if scenario.startswith("recordings-") else "courses"
    return {"schemaVersion": 1, "scenario": scenario, "valid": True, "error": None,
            "courseCount": 500 if scenario == "courses-500" else 100,
            "activityCount": 15000 if scenario == "activity-15000" else 1000 if scenario == "activity-1000" else 0,
            "recordingsCount": 5000 if scenario == "recordings-5000" else 1000 if scenario == "recordings-1000" else 0,
            "lowPowerMode": False, "thermalState": 0,
            "cycles": [{"index": index + 1, "keyMilliseconds": 4.0,
                        "contentMilliseconds": {kind: 6.0}, "resourcesAfterClose": copy.deepcopy(resources)} for index in range(cycles)],
            "idleSeconds": 1800 if scenario == "idle" else 0,
            "fixtureRequestsDuringIdle": 0 if scenario == "idle" else None,
            "idleBefore": copy.deepcopy(resources) if scenario == "idle" else None,
            "idleAfter": copy.deepcopy(resources) if scenario == "idle" else None}


class ReportValidationTests(unittest.TestCase):
    def test_key_window_cannot_replace_populated_content(self):
        value = sample("activity-15000")
        value["cycles"][0]["contentMilliseconds"] = {"activity": 1.0}
        with self.assertRaisesRegex(ValueError, "populated content"):
            driver.validate_sample(value, "activity-15000")

    def test_reduced_corpus_and_missing_cycles_are_not_comparable(self):
        for name in ("courses-500", "recordings-5000", "memory-cycles"):
            value = sample(name)
            if name == "memory-cycles":
                value["cycles"].pop()
            elif name == "courses-500":
                value["courseCount"] = 100
            else:
                value["recordingsCount"] = 1000
            with self.assertRaises(ValueError):
                driver.validate_sample(value, name)

    def test_nonfinite_negative_bool_and_failed_values_are_refused(self):
        for bad in (float("nan"), float("inf"), -1, True, None):
            value = sample()
            value["cycles"][0]["keyMilliseconds"] = bad
            with self.assertRaises(ValueError):
                driver.validate_sample(value, "courses-100")
        value = sample(); value["valid"] = False
        with self.assertRaises(ValueError):
            driver.validate_sample(value, "courses-100")

    def test_idle_requires_full_window_and_request_accounting(self):
        self.assertEqual(driver.validate_sample(sample("idle"), "idle")["idleSeconds"], 1800)
        for key, bad in (("idleSeconds", 60), ("fixtureRequestsDuringIdle", 1), ("idleAfter", None)):
            value = sample("idle"); value[key] = bad
            with self.assertRaises(ValueError):
                driver.validate_sample(value, "idle")

    def test_conditions_cannot_change_silently(self):
        for key, bad in (("lowPowerMode", True), ("thermalState", 1)):
            value = sample(); value[key] = bad
            with self.assertRaises(ValueError):
                driver.validate_sample(value, "courses-100")

    def test_warm_metric_uses_second_window_and_small_samples_have_no_p95(self):
        values = [sample("launch-warm") for _ in range(5)]
        for index, value in enumerate(values):
            value["cycles"][0]["keyMilliseconds"] = 1000
            value["cycles"][1]["keyMilliseconds"] = index + 1
        rows = driver.cost_rows(values, "launch-warm")
        self.assertEqual(rows[0][3:5], (3, 5))
        self.assertIsNone(driver.cost_rows(values[:1], "launch-warm")[0][4])

    def test_subprocess_failure_is_retained_and_success_is_not_inferred(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with self.assertRaisesRegex(RuntimeError, "command failed"):
                driver.command(["/usr/bin/false"], root, root / "failure.log")
            self.assertTrue((root / "failure.log").exists())

    def test_budget_violation_is_reported_without_invalidating_the_sample(self):
        value = sample("launch-warm")
        value["cycles"][0]["keyMilliseconds"] = 999
        self.assertTrue(driver.window_budget([value], "launch-warm")["allObservedSamplesWithinBudget"])
        value["cycles"][1]["keyMilliseconds"] = 101
        driver.validate_sample(value, "launch-warm")
        self.assertFalse(driver.window_budget([value], "launch-warm")["allObservedSamplesWithinBudget"])

    def test_changed_power_after_the_final_run_invalidates_the_series(self):
        driver.validate_power_source("AC Power", "AC Power")
        with self.assertRaisesRegex(ValueError, "power source changed"):
            driver.validate_power_source("AC Power", "Battery Power")

    def test_missing_empty_and_unreadable_trace_are_refused(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); trace = root / "sample.trace"
            for exists in (False, True):
                if exists:
                    trace.mkdir()
                with self.assertRaisesRegex(ValueError, "missing or empty"):
                    driver.validate_trace(trace, "courses-100", root, root / "sample")
            (trace / "junk").write_text("not an Instruments recording")
            with mock.patch.object(driver, "command", side_effect=RuntimeError("unreadable trace")):
                with self.assertRaisesRegex(RuntimeError, "unreadable trace"):
                    driver.validate_trace(trace, "courses-100", root, root / "sample")

    def test_trace_requires_fixture_target_and_strips_device_identity(self):
        with tempfile.TemporaryDirectory() as temporary:
            toc = Path(temporary) / "toc.xml"
            xml = '<trace-toc><run number="1"><info><target><device name="private" uuid="private" model="M5"/><process name="beepbar-ui-fixture" pid="7" return-exit-status="0"/></target></info><data><table schema="time-profile"/></data></run></trace-toc>'
            toc.write_text(xml)
            self.assertEqual(driver.trace_target(toc), "7")
            device = ET.parse(toc).find(".//device")
            self.assertEqual(device.attrib, {"model": "M5"})
            toc.write_text(xml.replace('name="beepbar-ui-fixture"', 'name="another-process"'))
            with self.assertRaisesRegex(ValueError, "successful isolated fixture"):
                driver.trace_target(toc)

    def test_cpu_profile_requires_main_thread_stacks_and_resolves_references(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "cpu.xml"
            xml = '<trace-query-result><node><row><thread id="1" fmt="Main Thread"><process id="2"><pid>7</pid></process></thread><process ref="2"/><tagged-backtrace id="3"><frame name="render"/></tagged-backtrace></row><row><thread ref="1"/><process ref="2"/><tagged-backtrace ref="3"/></row></node></trace-query-result>'
            path.write_text(xml)
            self.assertEqual(driver.profile_summary(path, "7")["fixtureMainThreadSamplesWithStacks"], 2)
            for bad in (xml.replace('fmt="Main Thread"', 'fmt="worker"'), xml.replace('<frame name="render"/>', ''), xml.replace('<pid>7</pid>', '<pid>8</pid>')):
                path.write_text(bad)
                with self.assertRaisesRegex(ValueError, "main-thread CPU samples"):
                    driver.profile_summary(path, "7")

    def test_trace_requires_ui_markers_for_the_requested_content(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "signposts.xml"
            rows = '<row><subsystem id="1">io.github.tvaccari.beepbar.performance</subsystem><category id="2">ui</category><signpost-name id="3">ui.iconReady</signpost-name></row>'
            for index, name in enumerate(("ui.fixtureOpen", "ui.windowKey", "ui.firstCourseContent"), 4):
                rows += '<row><subsystem ref="1"/><category ref="2"/><signpost-name id="%d">%s</signpost-name></row>' % (index, name)
            xml = '<trace-query-result><node>' + rows + '</node></trace-query-result>'
            path.write_text(xml)
            self.assertEqual(driver.signpost_summary(path, "courses-100")["ui.windowKey"], 1)
            with self.assertRaisesRegex(ValueError, "required fixture UI signposts"):
                driver.signpost_summary(path, "recordings-1000")
            path.write_text(xml.replace("ui.firstCourseContent", "unrelated"))
            with self.assertRaisesRegex(ValueError, "required fixture UI signposts"):
                driver.signpost_summary(path, "courses-100")


if __name__ == "__main__":
    unittest.main()
