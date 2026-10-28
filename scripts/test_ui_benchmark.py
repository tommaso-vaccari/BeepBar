#!/usr/bin/env python3
"""Offline safeguards for UI measurement evidence. No app, build or network is launched."""
import copy
import importlib.util
from pathlib import Path
import plistlib
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
    def test_zero_origin_hitches_are_invalid_evidence_not_zero_or_clipped(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); hitches = root / "hitches.xml"; updates = root / "updates.xml"
            updates.write_text('<trace-query-result><node><schema name="hitches-updates"/>'
                               '<row><start-time>1200000000</start-time><duration>17000000</duration>'
                               '<process><pid>7</pid></process></row></node></trace-query-result>')
            for duration in (16666625, 30881134000):
                hitches.write_text('<trace-query-result><node><schema name="hitches"/>'
                                   '<row><start-time id="1">0</start-time><duration>%d</duration>'
                                   '<process id="2"><pid>7</pid></process></row>'
                                   '<row><start-time ref="1"/><duration>50000000</duration>'
                                   '<process ref="2"/></row></node></trace-query-result>' % duration)
                result = driver.hitches_summary(hitches, updates, "7", (1000000000, 2000000000))
                self.assertIs(result["valid"], False)
                self.assertIn("zero timing origin", result["reason"])
                self.assertEqual(result["fixtureUpdatesDuringScroll"], 1)
                self.assertEqual(result["invalidHitchRows"], [
                    {"startNanoseconds": 0, "durationNanoseconds": duration},
                    {"startNanoseconds": 0, "durationNanoseconds": 50000000}])
                for metric in ("fixtureHitchesDuringScroll", "hitchDurationsMilliseconds",
                               "totalHitchMilliseconds", "maximumHitchMilliseconds"):
                    self.assertNotIn(metric, result)

    def test_locked_or_unknown_console_is_rejected(self):
        def registry(root):
            # `ioreg -a` prints a bare root dict; older output may wrap it in an array.
            return plistlib.dumps(root).decode()
        # Locked, unknown, unparsable, and a locked console whose nested session says unlocked.
        for output in (registry({"IOConsoleLocked": True}), registry({}), "", "not a plist",
                       registry({"IOConsoleLocked": True,
                                 "IOConsoleUsers": [{"IOConsoleLocked": False}]})):
            with mock.patch.object(driver, "command", return_value=output):
                with self.assertRaisesRegex(RuntimeError, "unlocked console"):
                    driver.require_unlocked_console(Path("."))
        for output in (registry({"IOConsoleLocked": False}),
                       plistlib.dumps([{"IOConsoleLocked": False}]).decode()):
            with mock.patch.object(driver, "command", return_value=output):
                driver.require_unlocked_console(Path("."))

    def test_scroll_summary_preserves_each_runs_worst_sample(self):
        values = [sample("activity-15000") for _ in range(5)]
        for index, value in enumerate(values):
            value["scrollWorkMilliseconds"] = [1.0] * 239 + [20.0 + index]
            value["scrollDeliveryMilliseconds"] = [16.67] * 239
        rows = {row[1]: row for row in driver.cost_rows(values, "activity-15000")}
        worst = rows["scroll synchronous work per-run maximum (ms)"]
        self.assertEqual(worst[2:], (5, 22.0, 24.0, 20.0, 24.0))

    def test_scroll_samples_must_be_complete_and_finite(self):
        value = sample("activity-15000")
        with self.assertRaises(ValueError):
            driver.validate_sample(value, "activity-15000", scroll_all=True)
        value["scrollWorkMilliseconds"] = [1.0] * 240
        value["scrollDeliveryMilliseconds"] = [16.67] * 239
        driver.validate_sample(value, "activity-15000", scroll_all=True)
        for key in ("scrollWorkMilliseconds", "scrollDeliveryMilliseconds"):
            original = value[key][:]
            for invalid in (original[:-1], original + [1], [float("nan")] * len(original), [-1] * len(original)):
                value[key] = invalid
                with self.assertRaises(ValueError):
                    driver.validate_sample(value, "activity-15000", scroll_all=True)
            value[key] = original

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

    def test_scroll_interval_requires_exact_target_begin_and_end(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "signposts.xml"
            begin = ('<row><event-time id="1">1000000000</event-time><process id="2"><pid>7</pid></process>'
                     '<event-type id="3">Begin</event-type><os-signpost-identifier id="4">1</os-signpost-identifier>'
                     '<signpost-name id="5">ui.fixtureActivityScroll</signpost-name>'
                     '<subsystem id="6">io.github.tvaccari.beepbar.performance</subsystem><category id="7">ui</category></row>')
            end = ('<row><event-time id="8">2000000000</event-time><process ref="2"/><event-type id="9">End</event-type>'
                   '<os-signpost-identifier ref="4"/><signpost-name ref="5"/><subsystem ref="6"/><category ref="7"/></row>')
            xml = '<trace-query-result><node>' + begin + end + '</node></trace-query-result>'
            path.write_text(xml)
            self.assertEqual(driver.scrolling_interval(path, "7"), (1000000000, 2000000000))
            for bad in (xml.replace('<pid>7</pid>', '<pid>8</pid>'), xml.replace(end, ''),
                        xml.replace(end, end + end), xml.replace('2000000000', '500000000'),
                        xml.replace('>End<', '>Begin<')):
                path.write_text(bad)
                with self.assertRaises(ValueError):
                    driver.scrolling_interval(path, "7")

    def test_hitches_require_target_updates_and_filter_scroll_interval(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); hitches = root / "hitches.xml"; updates = root / "updates.xml"
            def xml(schema, rows):
                return '<trace-query-result><node><schema name="' + schema + '"/>' + rows + '</node></trace-query-result>'
            first = ('<row><start-time id="1">1200000000</start-time><duration id="2">17000000</duration>'
                     '<process id="3"><pid>7</pid></process></row>')
            second = ('<row><start-time id="4">1800000000</start-time><duration ref="2"/><process ref="3"/></row>')
            outside = ('<row><start-time>2100000000</start-time><duration>99000000</duration><process ref="3"/></row>')
            other = ('<row><start-time>1500000000</start-time><duration>88000000</duration><process><pid>8</pid></process></row>')
            valid_updates = xml("hitches-updates", first + second)
            updates.write_text(valid_updates)
            hitches.write_text(xml("hitches", first + second + outside + other))
            result = driver.hitches_summary(hitches, updates, "7", (1000000000, 2000000000))
            self.assertEqual(result["fixtureUpdatesDuringScroll"], 2)
            self.assertEqual(result["hitchDurationsMilliseconds"], [17.0, 17.0])
            self.assertEqual(result["totalHitchMilliseconds"], 34.0)
            hitches.write_text(xml("hitches", ""))
            self.assertEqual(driver.hitches_summary(hitches, updates, "7", (1000000000, 2000000000))["fixtureHitchesDuringScroll"], 0)
            for bad in (xml("hitches-updates", ""), valid_updates.replace('<pid>7</pid>', '<pid>8</pid>'),
                        valid_updates.replace('1200000000', '2200000000').replace('1800000000', '2800000000'),
                        valid_updates.replace('17000000', '-1'), valid_updates.replace('hitches-updates', 'unrelated')):
                updates.write_text(bad)
                with self.assertRaises(ValueError):
                    driver.hitches_summary(hitches, updates, "7", (1000000000, 2000000000))
            updates.write_text(valid_updates)
            hitches.write_text(xml("unrelated", ""))
            with self.assertRaisesRegex(ValueError, "schema"):
                driver.hitches_summary(hitches, updates, "7", (1000000000, 2000000000))

    def test_hitches_clip_overlap_at_both_scroll_boundaries(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); hitches = root / "hitches.xml"; updates = root / "updates.xml"
            def xml(schema, timings):
                rows = ''.join('<row><start-time>%d</start-time><duration>%d</duration><process><pid>7</pid></process></row>' % pair for pair in timings)
                return '<trace-query-result><node><schema name="' + schema + '"/>' + rows + '</node></trace-query-result>'
            updates.write_text(xml("hitches-updates", [(1200000000, 1000000)]))
            hitches.write_text(xml("hitches", [(990000000, 50000000), (1990000000, 50000000),
                                               (950000000, 50000000), (2000000000, 50000000)]))
            result = driver.hitches_summary(hitches, updates, "7", (1000000000, 2000000000))
            self.assertEqual(result["fixtureHitchesDuringScroll"], 2)
            self.assertEqual(result["hitchDurationsMilliseconds"], [40.0, 10.0])
            self.assertEqual(result["totalHitchMilliseconds"], 50.0)
            self.assertEqual(result["maximumHitchMilliseconds"], 40.0)
            self.assertEqual(result["hitchDurationScope"], "overlap clipped to scroll interval")

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
