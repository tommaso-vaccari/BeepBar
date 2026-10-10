#!/usr/bin/env python3
"""Offline safeguards for UI measurement evidence. No app, build or network is launched."""
import copy
import importlib.util
from pathlib import Path
import tempfile
import unittest

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


if __name__ == "__main__":
    unittest.main()
