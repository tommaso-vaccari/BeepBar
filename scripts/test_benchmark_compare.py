"""Behavior tests: invalid evidence, incompatible fixtures and subprocess cleanup cannot claim gains."""
import argparse
import json
import importlib.util
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('comparison', Path(__file__).with_name('benchmark_compare.py'))
b = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b)


def report(values=(2, 4, 6, 8, 10)):
    return {'environment': {'commit': 'a' * 40, 'dirty': False, 'model': 'test', 'cpu': 'test',
            'memoryBytes': 1024, 'operatingSystem': 'test', 'powerSource': 'AC Power',
            'lowPowerMode': False, 'thermalState': 'nominal', 'buildConfiguration': 'release', 'architecture': 'arm64'},
            'scenarios': [{'name': 'unchanged', 'parameters': {'files': '10'}, 'checks': {'nothing installed': True},
                           'warmupRuns': 1, 'samples': [{'wallMilliseconds': x} for x in values],
                           'summary': {'wall': b.distribution(list(values))}}]}


class ComparisonTests(unittest.TestCase):
    def compare(self, reports):
        return b.compare(reports, {k: 'a' * 40 for k in reports}, 5, 1, {'wall': 'ms'})

    def test_medians_p95_deltas_regressions_and_zero_baseline(self):
        reports = {'main': report((0,) * 5), 'base-dev': report(), 'candidate': report((3, 5, 7, 9, 11))}
        row = self.compare(reports)[0]
        self.assertEqual(row['values']['base-dev']['median'], 6)
        self.assertEqual(row['values']['candidate']['p95'], 11)
        self.assertEqual(row['deltas']['base-dev']['median']['absolute'], 1)
        self.assertAlmostEqual(row['deltas']['base-dev']['median']['reductionPercent'], -100 / 6)
        self.assertTrue(row['deltas']['base-dev']['p95']['regression'])
        self.assertIsNone(row['deltas']['main']['median']['reductionPercent'])
        self.assertEqual(b.distribution([2, 4])['median'], 3)

    def test_invalid_and_mismatched_evidence_is_refused(self):
        changes = [
            lambda r: r['scenarios'][0]['checks'].update({'nothing installed': False}),
            lambda r: r['scenarios'][0].update(checks={}),
            lambda r: r['scenarios'][0].update(samples=[]),
            lambda r: r['scenarios'][0].update(warmupRuns=0),
            lambda r: r['scenarios'][0]['parameters'].update(files='100'),
            lambda r: r['scenarios'][0]['summary']['wall'].update(median=999),
            lambda r: r['scenarios'][0]['samples'][0].update(wallMilliseconds=float('nan')),
            lambda r: r['scenarios'][0]['samples'][0].update(wallMilliseconds=-1),
            lambda r: r['scenarios'][0].update(summary={}),
            lambda r: r['environment'].update(commit='b' * 40),
            lambda r: r['environment'].update(dirty=True),
            lambda r: r['environment'].update(cpu='different'),
            lambda r: r['environment'].update(buildConfiguration='debug'),
            lambda r: r['environment'].update(architecture='x86_64'),
            lambda r: r['environment'].update(powerSource='Battery Power'),
            lambda r: r['environment'].update(thermalState='serious'),
            lambda r: r['environment'].update(lowPowerMode=True),
        ]
        for change in changes:
            with self.subTest(change=change):
                reports = {k: report() for k in ('main', 'base-dev', 'candidate')}
                change(reports['main'])
                with self.assertRaises(b.InvalidComparison):
                    self.compare(reports)

    def test_invalid_markdown_has_no_numeric_claim(self):
        text = b.markdown({'shas': {}, 'scenarios': {'broken': {'valid': False, 'error': 'checks failed'}}})
        self.assertIn('INVALID', text)
        self.assertIn('no claim', text)

    def test_native_mismatch_requires_explicit_adjustment_and_retains_diff(self):
        with tempfile.TemporaryDirectory() as folder:
            root, harness = Path(folder) / 'source', Path(folder) / 'harness'
            for tree, value in ((root, 'native'), (harness, 'selected')):
                for name in b.MEASUREMENT:
                    (tree / name).mkdir(parents=True)
                    (tree / name / 'file.swift').write_text(value + '\n')
            (root / 'production.swift').write_text('unchanged')
            diff = Path(folder) / 'measurement.patch'
            with self.assertRaises(b.InvalidComparison):
                b.harmonize(root, harness, False, diff)
            result = b.harmonize(root, harness, True, diff)
            self.assertTrue(result['adjusted'])
            self.assertIn('-native', diff.read_text())
            self.assertIn('+selected', diff.read_text())
            self.assertEqual((root / 'production.swift').read_text(), 'unchanged')
            self.assertEqual(b.tree_identity(root), b.tree_identity(harness))

    def test_failed_subprocess_preserves_diagnostics_and_cleans_only_owned_temp(self):
        with tempfile.TemporaryDirectory() as outer:
            sentinel = Path(outer) / 'user-file'
            sentinel.write_text('keep')
            log = Path(outer) / 'failure.log'
            records = []
            with self.assertRaises(b.InvalidComparison):
                with b.temporary_root() as root:
                    (root / 'scratch').write_text('discard')
                    b.run([sys.executable, '-c', 'print("diagnostic"); raise SystemExit(7)'], root, log, records)
            self.assertFalse(root.exists())
            self.assertEqual(sentinel.read_text(), 'keep')
            self.assertIn('diagnostic', log.read_text())
            self.assertEqual(records[0]['exit'], 7)

    def test_failed_parent_kills_surviving_descendant(self):
        with tempfile.TemporaryDirectory() as folder:
            pid_file = Path(folder) / 'child.pid'
            script = ('import subprocess,sys; from pathlib import Path; '
                      'p=subprocess.Popen([sys.executable,"-c","import time; time.sleep(30)"]); '
                      'Path(sys.argv[1]).write_text(str(p.pid)); raise SystemExit(7)')
            with self.assertRaises(b.InvalidComparison):
                b.run([sys.executable, '-c', script, str(pid_file)], Path(folder), Path(folder) / 'log', [])
            # The descendant may be a zombie until reparented; it must no longer be running.
            status = subprocess.run(['ps', '-o', 'stat=', '-p', pid_file.read_text()], text=True, stdout=subprocess.PIPE).stdout
            self.assertTrue(not status.strip() or status.strip().startswith('Z'))

    def test_impossible_metric_domains(self):
        for metric, sample in [('cpu', {'resources': {'cpuNanoseconds': -1}}),
                               ('cancel.latency', {'cancelLatencyMilliseconds': -1}),
                               ('net.requests', {'upstream': dict.fromkeys(('contentsRequests', 'courseListRequests',
                                                      'downloads', 'otherRequests', 'siteInfoRequests'), True)})]:
            with self.subTest(metric=metric), self.assertRaises(b.InvalidComparison):
                b.sample_metric(sample, metric)
        self.assertEqual(b.sample_metric({'peakFootprintGrowth': -1048576}, 'memory.peakGrowth'), -1)

    def test_interrupted_child_is_reaped_before_cleanup(self):
        with tempfile.TemporaryDirectory() as outer:
            original_wait = subprocess.Popen.wait
            calls = 0
            def interrupted(process, *args, **kwargs):
                nonlocal calls
                calls += 1
                if calls == 1:
                    raise KeyboardInterrupt()
                return original_wait(process, *args, **kwargs)
            with patch.object(subprocess.Popen, 'wait', interrupted):
                with self.assertRaises(KeyboardInterrupt):
                    with b.temporary_root() as root:
                        b.run([sys.executable, '-c', 'import time; time.sleep(30)'], root, Path(outer) / 'interrupt.log', [])
            self.assertGreaterEqual(calls, 2)
            self.assertFalse(root.exists())

    def test_orchestrator_freezes_refs_and_rejects_failed_runs_with_reports(self):
        with tempfile.TemporaryDirectory() as folder:
            out = Path(folder) / 'results'
            args = argparse.Namespace(main='main', base_dev='dev', candidate='dev', harness_ref=None,
                                      out=str(out), runs=5, warmup=1, saved_folder_overrides=False,
                                      dependency_cache=folder, smoke=True)
            def fake_run(command, cwd, log, records, env=None):
                records.append({'command': command, 'exit': 0})
                log.write_text('diagnostic')
                if command[:2] == ['git', 'archive']:
                    # Export helper extracts our tiny real tar archive into each source root.
                    import io, tarfile
                    with tarfile.open(command[3], 'w') as archive:
                        for name in b.MEASUREMENT:
                            data = b'Metric(name: "wall", unit: "ms")'
                            item = tarfile.TarInfo(name + '/Scenarios.swift')
                            item.size = len(data)
                            archive.addfile(item, io.BytesIO(data))
                if '--show-bin-path' in command:
                    return str(Path(cwd) / 'bin')
                if '--json' in command:
                    path = Path(command[command.index('--json') + 1])
                    path.write_text(json.dumps(report()))
                    raise b.InvalidComparison('failed despite emitted report')
                return 'toolchain'
            with patch.object(b.subprocess, 'check_output', return_value='a' * 40 + '\n') as resolve, \
                    patch.object(b, 'run', fake_run):
                self.assertEqual(b.execute(args), 1)
                self.assertEqual(resolve.call_count, 2)
            result = json.loads((out / 'comparison.json').read_text())
            self.assertFalse(result['valid'])
            self.assertTrue(result['cleaned'])
            self.assertEqual(len(result['scenarios']), 3)
            self.assertTrue(all(not s['valid'] and 'rows' not in s for s in result['scenarios'].values()))
            self.assertTrue((out / 'main' / 'unchanged-smoke.json').exists())

    def test_startup_scenarios_follow_the_selected_harness(self):
        # An older harness (e.g. --harness-ref origin/main) has no `startup` command: its
        # scenarios are listed as unmeasured instead of failing and invalidating the series.
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / b.MEASUREMENT[0]).mkdir(parents=True)
            for smoke, startup in ((False, {'startup-first-15k', 'startup-later-15k'}), (True, {'startup-smoke'})):
                plan, notes = b.scenario_plan(root, smoke)
                self.assertFalse({name for name, _ in plan} & startup)
                self.assertTrue(any('not measured' in note and all(n in note for n in startup) for note in notes))
            (root / b.MEASUREMENT[0] / 'StartupScenario.swift').write_text('')
            plan, notes = b.scenario_plan(root, False)
            self.assertEqual(len(plan), 7)
            self.assertIn(('startup-later-15k', ['startup', '--files', '15000', '--phase', 'later']), plan)
            self.assertFalse(any('not measured' in note for note in notes))
            plan, notes = b.scenario_plan(root, True)
            self.assertEqual([name for name, _ in plan][-1], 'startup-smoke')
            # The run's own notes stay in its result: the module's constant is never extended.
            self.assertNotIn('Smoke corpus only; not the standard performance baseline.', b.LIMITS)
            self.assertEqual(notes, ['Smoke corpus only; not the standard performance baseline.'])

    def test_saved_folder_adjustment_is_explicit_and_non_repeatable(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            path = root / b.MEASUREMENT[0] / 'Scenarios.swift'
            path.parent.mkdir(parents=True)
            path.write_text('        let fixture = try await BenchmarkFixture(corpus: corpus)\n        defer { fixture.remove() }\n')
            b.saved_overrides(root)
            self.assertIn('commitModuleMove', path.read_text())
            with self.assertRaises(b.InvalidComparison):
                b.saved_overrides(root)


if __name__ == '__main__':
    unittest.main()
