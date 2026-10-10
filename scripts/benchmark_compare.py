"""Ref orchestration for benchmark.sh; all workloads run the existing Swift harness."""
import argparse
import contextlib
import difflib
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import signal
import statistics
import subprocess
import sys
import tarfile
import tempfile

MEASUREMENT = ('Sources/BeepbarBenchmarkKit', 'Sources/BeepbarBenchmarks')
LIMITS = ['Core synthetic workloads only; no UI, idle, real network or app-wide speed claim.',
          'Sequential runs on one machine; noise and run order can affect timings.',
          'p95 uses nearest rank; with five samples it is the maximum.',
          'Positive cost reduction is improvement; negative is regression. Zero baseline has no percentage.',
          'Metrics absent from the selected harness are unmeasured, never inferred.']


class InvalidComparison(Exception):
    pass


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + '\n')


def run(command, cwd, log, records, env=None):
    """Keep diagnostics and kill the whole child group before temporary source cleanup."""
    record = {'command': list(map(str, command)), 'cwd': str(cwd), 'log': str(log)}
    records.append(record)
    with log.open('wb') as output:
        process = subprocess.Popen(command, cwd=cwd, env=env, stdout=output,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        try:
            record['exit'] = process.wait()
        except BaseException:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            raise
    if record['exit'] != 0:
        # A failed parent may leave descendants holding fixture/build files.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        raise InvalidComparison(f'subprocess failed ({record["exit"]}); see {log}')
    return log.read_text()


def tree_identity(root):
    files = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
             for folder in MEASUREMENT for p in sorted((root / folder).rglob('*')) if p.is_file()}
    if not files or any(not (root / folder).is_dir() for folder in MEASUREMENT):
        raise InvalidComparison('ref lacks the existing benchmark harness')
    return files


def harmonize(root, harness, authorized, patches):
    """Only measurement sources can be overlaid, and every changed byte has a retained diff."""
    before, after = tree_identity(root), tree_identity(harness)
    if before != after and not authorized:
        raise InvalidComparison('native harness/fixture mismatch; select --harness-ref explicitly')
    differences = []
    for name in sorted(before.keys() | after.keys()):
        old, new = root / name, harness / name
        differences.extend(difflib.unified_diff(old.read_text().splitlines(True) if old.exists() else [],
                                              new.read_text().splitlines(True) if new.exists() else [],
                                              fromfile='a/' + name, tofile='b/' + name))
    patches.write_text(''.join(differences))
    if before != after:
        for folder in MEASUREMENT:
            shutil.rmtree(root / folder)
            shutil.copytree(harness / folder, root / folder)
    return {'native': before, 'effective': after, 'adjusted': before != after}


def saved_overrides(harness):
    """Explicit fixture normalization for old harnesses without persisted folder overrides."""
    path = harness / MEASUREMENT[0] / 'Scenarios.swift'
    text = path.read_text()
    anchor = '        let fixture = try await BenchmarkFixture(corpus: corpus)\n        defer { fixture.remove() }\n'
    if text.count(anchor) != 1 or 'commitModuleMove(PendingModuleMove' in text:
        raise InvalidComparison('saved-folder adjustment requires the known unadjusted fixture')
    block = '''        for course in 1...Int64(corpus.courses) {
            for ordinal in 0..<Int64(corpus.modulesPerCourse) {
                let name = "Materiali \\(ordinal + 1)"
                try await fixture.database.commitModuleMove(PendingModuleMove(rootID: fixture.rootID, courseID: course, moduleID: BenchmarkUpstream.moduleID(course: course, ordinal: ordinal), action: .set, oldFolder: nil, newFolder: name, lastKnownName: name, files: []))
            }
        }
'''
    path.write_text(text.replace(anchor, anchor + block))


def distribution(values):
    if not values or any(type(x) not in (int, float) or not math.isfinite(x) for x in values):
        raise InvalidComparison('empty/non-finite metric samples')
    ordered = sorted(values)
    return {'median': statistics.median(ordered), 'p95': ordered[math.ceil(.95 * len(ordered)) - 1],
            'min': ordered[0], 'max': ordered[-1], 'count': len(ordered)}


def metrics(harness):
    import re
    text = (harness / MEASUREMENT[0] / 'Scenarios.swift').read_text()
    found = re.findall(r'Metric\(name: "([^"]+)", unit: "([^"]*)"\)', text)
    if not found or len(dict(found)) != len(found):
        raise InvalidComparison('unsupported metric definitions')
    return dict(found)


def sample_metric(sample, metric):
    fields = {
        'wall': ('wallMilliseconds', 1), 'cpu': ('resources.cpuNanoseconds', 1e6),
        'instructions': ('resources.instructions', 1e6),
        'disk.written': ('resources.diskBytesWritten', 1024),
        'disk.logicalWritten': ('resources.logicalBytesWritten', 1024),
        'memory.peak': ('peakFootprint', 1048576), 'memory.peakGrowth': ('peakFootprintGrowth', 1048576),
        'db.commits': ('database.commits', 1), 'db.rowChanges': ('database.rowChanges', 1),
        'db.pagesWritten': ('database.pagesWritten', 1),
        'db.ownershipBackfill.transactions': ('ownershipBackfill.transactions', 1),
        'db.ownershipBackfill.updates': ('ownershipBackfill.updates', 1),
        'db.moduleOverride.updates': ('moduleOverrideUpdates', 1),
        'fs.filesHashed': ('fileStore.filesHashed', 1), 'fs.bytesHashed': ('fileStore.bytesHashed', 1048576),
        'fs.pathLookups': ('fileStore.pathLookups', 1), 'net.metadata': ('upstream.metadataBytes', 1024),
        'net.downloaded': ('upstream.downloadBytes', 1048576), 'cancel.latency': ('cancelLatencyMilliseconds', 1)}
    if metric == 'net.requests':
        values = [sample['upstream'][key] for key in
                  ('contentsRequests', 'courseListRequests', 'downloads', 'otherRequests', 'siteInfoRequests')]
        if any(type(v) is not int or v < 0 for v in values):
            raise InvalidComparison('invalid request counters')
        return sum(values)
    if metric not in fields:
        raise InvalidComparison('unsupported raw metric ' + metric)
    path, scale = fields[metric]
    value = sample
    for key in path.split('.'):
        value = value[key]
    if (type(value) not in (int, float) or not math.isfinite(value)
            or (value < 0 and metric != 'memory.peakGrowth')):
        raise InvalidComparison('invalid raw sample')
    return value / scale


def validate(report, sha, runs, warmup, units, dirty=False):
    env = report['environment']
    if env['dirty'] is not dirty or env['commit'] != sha or env['buildConfiguration'] != 'release' or env['architecture'] != 'arm64':
        raise InvalidComparison('wrong SHA/build/architecture')
    if env['powerSource'] != 'AC Power' or env['thermalState'] != 'nominal' or env['lowPowerMode']:
        raise InvalidComparison('requires AC power, nominal thermal state and Low Power Mode off')
    if len(report['scenarios']) != 1:
        raise InvalidComparison('expected exactly one scenario')
    scenario = report['scenarios'][0]
    if (not scenario['checks'] or any(x is not True for x in scenario['checks'].values())
            or len(scenario['samples']) != runs or scenario['warmupRuns'] != warmup):
        raise InvalidComparison('failed/empty checks or mismatched sampling')
    expected = set(units) - ({'cancel.latency'} if scenario['name'] != 'cancel' else set())
    if set(scenario['summary']) != expected:
        raise InvalidComparison('missing/unknown metrics')
    for metric, summary in scenario['summary'].items():
        calculated = distribution([sample_metric(sample, metric) for sample in scenario['samples']])
        if set(summary) != set(calculated) or any(not math.isclose(summary[k], v, rel_tol=1e-9, abs_tol=1e-9)
                                                  for k, v in calculated.items()):
            raise InvalidComparison('summary does not match raw samples')
    return scenario


def compare(reports, shas, runs, warmup, units, dirty=None):
    scenarios = {label: validate(report, shas[label], runs, warmup, units, (dirty or {}).get(label, False)) for label, report in reports.items()}
    reference = reports['candidate']['environment']
    keys = ('model', 'cpu', 'memoryBytes', 'operatingSystem', 'powerSource', 'lowPowerMode',
            'thermalState', 'buildConfiguration', 'architecture')
    for label, scenario in scenarios.items():
        if any(reports[label]['environment'][k] != reference[k] for k in keys):
            raise InvalidComparison('environment mismatch')
        other = scenarios['candidate']
        if any(scenario[k] != other[k] for k in ('name', 'parameters', 'warmupRuns')) or set(scenario['checks']) != set(other['checks']):
            raise InvalidComparison('scenario/fixture/check mismatch')
    rows = []
    for metric in sorted(scenarios['candidate']['summary']):
        values = {label: s['summary'][metric] for label, s in scenarios.items()}
        deltas = {}
        for baseline in ('base-dev', 'main'):
            deltas[baseline] = {}
            for statistic in ('median', 'p95'):
                before, after = values[baseline][statistic], values['candidate'][statistic]
                deltas[baseline][statistic] = {'absolute': after - before,
                    'reductionPercent': (before - after) / before * 100 if before != 0 else None,
                    'regression': after > before}
        rows.append({'metric': metric, 'unit': units[metric] or 'count', 'values': values, 'deltas': deltas})
    return rows


def markdown(result):
    lines = ['Tooling validation only; measured costs do not establish application gains.', '',
             *[f'- {label}: `{sha}`' for label, sha in result['shas'].items()], '',
             '| Scenario | Metric | Unit | main median / p95 | base-dev median / p95 | candidate median / p95 | dev Δ median / p95 (% reduction) | main Δ median / p95 (% reduction) | Regressions |',
             '|---|---|---|---|---|---|---|---|---|']
    def value(x):
        return f'{x:.4g}'
    for scenario, entry in result['scenarios'].items():
        if not entry['valid']:
            lines.append(f'| {scenario} | INVALID: {entry["error"]} | — | — | — | — | — | — | no claim |')
            continue
        for row in entry['rows']:
            cells = [scenario, row['metric'], row['unit']]
            for label in ('main', 'base-dev', 'candidate'):
                cells.append(' / '.join(value(row['values'][label][s]) for s in ('median', 'p95')))
            regressions = []
            for label in ('base-dev', 'main'):
                parts = []
                for s in ('median', 'p95'):
                    d = row['deltas'][label][s]
                    percent = 'n/a' if d['reductionPercent'] is None else value(d['reductionPercent']) + '%'
                    parts.append(f'{value(d["absolute"])} ({percent})')
                    if d['regression']:
                        regressions.append(f'{label} {s}')
                cells.append(' / '.join(parts))
            cells.append(', '.join(regressions) or 'none')
            lines.append('| ' + ' | '.join(cells) + ' |')
    lines += ['', 'Limitations:', *['- ' + limit for limit in LIMITS]]
    return '\n'.join(lines) + '\n'


@contextlib.contextmanager
def temporary_root():
    with tempfile.TemporaryDirectory(prefix='beepbar-compare-') as folder:
        yield Path(folder)


def execute(args):
    repo = Path(__file__).resolve().parent.parent
    # Freeze all identities before creating results or starting builds; no automatic ref refresh.
    resolved = {}
    shas = {}
    for label, ref in [('main', args.main), ('base-dev', args.base_dev), ('candidate', args.candidate),
                       ('harness', args.harness_ref or args.candidate)]:
        if ref not in resolved:
            resolved[ref] = subprocess.check_output(['git', 'rev-parse', '--verify', ref + '^{commit}'],
                                                    cwd=repo, text=True).strip()
        shas[label] = resolved[ref]
    out = Path(args.out).resolve()
    out.mkdir(parents=True, exist_ok=False)
    result = {'schemaVersion': 1, 'shas': shas, 'runs': args.runs, 'warmup': args.warmup,
              'commands': [], 'harnesses': {}, 'scenarios': {}, 'limitations': LIMITS,
              'valid': False, 'savedFolderOverrides': args.saved_folder_overrides,
              'driverSHA256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              'refs': {'main': args.main, 'base-dev': args.base_dev, 'candidate': args.candidate,
                       'harness': args.harness_ref or args.candidate}, 'environment': {}, 'units': {}}
    def save():
        write_json(out / 'comparison.json', result)
        (out / 'comparison.md').write_text(markdown(result))
    save()
    try:
        with temporary_root() as temp:
            result['temporaryRoot'] = str(temp)
            save()
            def export(label):
                root = temp / label
                root.mkdir()
                archive = temp / (label + '.tar')
                run(['git', 'archive', '-o', str(archive), shas[label]], repo,
                    out / (label + '-export.log'), result['commands'])
                with tarfile.open(archive) as tar:
                    # Git archives are expected to contain only regular repository files.
                    for member in tar.getmembers():
                        if (not (member.isfile() or member.isdir()) or Path(member.name).is_absolute()
                                or '..' in Path(member.name).parts):
                            raise InvalidComparison('unsafe archive member ' + member.name)
                    tar.extractall(root)
                return root
            harness = export('harness')
            if args.saved_folder_overrides:
                if not args.harness_ref:
                    raise InvalidComparison('--saved-folder-overrides requires --harness-ref')
                saved_overrides(harness)
            units = metrics(harness)
            result['units'] = units
            for name, command in [('swift-version', ['swift', '--version']), ('xcode-version', ['xcodebuild', '-version'])]:
                result['environment'][name] = run(command, repo, out / (name + '.log'), result['commands'])
            binaries = {}
            for label in ('main', 'base-dev', 'candidate'):
                root = export(label)
                result['harnesses'][label] = harmonize(root, harness, args.harness_ref is not None,
                                                      out / (label + '-measurement.patch'))
                # Reuse dependencies only, never production objects or build products.
                cache = Path(args.dependency_cache).resolve() if args.dependency_cache else repo / '.build'
                for name in ('artifacts', 'checkouts', 'repositories'):
                    if (cache / name).is_dir():
                        shutil.copytree(cache / name, root / '.build' / name, symlinks=True)
                env = dict(os.environ, TMPDIR=str(temp) + '/', CLANG_MODULE_CACHE_PATH=str(temp / 'modules'),
                           SWIFTPM_MODULECACHE_OVERRIDE=str(temp / 'modules'))
                command = ['swift', 'build', '--disable-sandbox', '--skip-update', '--disable-automatic-resolution',
                           '-c', 'release', '--arch', 'arm64', '--product', 'beepbar-bench']
                run(command, root, out / (label + '-build.log'), result['commands'], env)
                path = run(['swift', 'build', '-c', 'release', '--arch', 'arm64', '--show-bin-path'], root,
                           out / (label + '-bin-path.log'), result['commands'], env).strip()
                binaries[label] = (root, Path(path) / 'beepbar-bench', env)
            plan = [('unchanged-1k', ['unchanged', '--files', '1000']),
                    ('unchanged-15k', ['unchanged', '--files', '15000']),
                    ('large-update-64mb', ['large-update', '--size-mb', '64']),
                    ('large-update-256mb', ['large-update', '--size-mb', '256']),
                    ('cancel-mid', ['cancel', '--size-mb', '256', '--fraction', '0.5']),
                    ('startup-first-15k', ['startup', '--files', '15000', '--phase', 'first']),
                    ('startup-later-15k', ['startup', '--files', '15000', '--phase', 'later'])]
            if args.smoke:
                plan = [('unchanged-smoke', ['unchanged', '--files', '10']),
                        ('update-smoke', ['large-update', '--size-mb', '1']),
                        ('cancel-smoke', ['cancel', '--size-mb', '4', '--fraction', '0.5', '--rate-mbps', '1']),
                        ('startup-smoke', ['startup', '--files', '100', '--phase', 'first'])]
                result['limitations'].append('Smoke corpus only; not the standard performance baseline.')
            for name, workload in plan:
                reports = {}
                try:
                    for label, (root, binary, env) in binaries.items():
                        target = out / label
                        target.mkdir(exist_ok=True)
                        path = target / (name + '.json')
                        command = [str(binary), *workload, '--runs', str(args.runs), '--warmup', str(args.warmup),
                                   '--commit', shas[label], '--json', str(path)]
                        if result['harnesses'][label]['adjusted']:
                            command.append('--dirty')
                        run(command, root, target / (name + '.log'), result['commands'], env)
                        reports[label] = json.loads(path.read_text())
                        result['environment'][label + '/' + name] = reports[label]['environment']
                    result['scenarios'][name] = {'valid': True, 'rows': compare(reports, shas, args.runs, args.warmup, units,
                        {label: h['adjusted'] for label, h in result['harnesses'].items()})}
                except (InvalidComparison, KeyError, ValueError, OSError) as error:
                    result['scenarios'][name] = {'valid': False, 'error': str(error)}
                save()
            result['valid'] = bool(result['scenarios']) and all(s['valid'] for s in result['scenarios'].values())
    except BaseException as error:
        result['error'] = str(error) or type(error).__name__
        raise
    finally:
        result['cleaned'] = 'temporaryRoot' not in result or not Path(result['temporaryRoot']).exists()
        save()
    return 0 if result['valid'] else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('main', 'base-dev', 'candidate', 'out'):
        parser.add_argument('--' + name, required=True)
    parser.add_argument('--harness-ref')
    parser.add_argument('--saved-folder-overrides', action='store_true')
    parser.add_argument('--dependency-cache')
    parser.add_argument('--runs', type=int, default=5)
    parser.add_argument('--warmup', type=int, default=1)
    parser.add_argument('--smoke', action='store_true')
    try:
        args = parser.parse_args()
        if args.runs < 1 or args.warmup < 0:
            parser.error('runs must be positive and warmup non-negative')
    except SystemExit as error:
        return 64 if error.code else 0
    def interrupt(signum, frame):
        raise KeyboardInterrupt(f'signal {signum}')
    signal.signal(signal.SIGTERM, interrupt)
    try:
        return execute(args)
    except KeyboardInterrupt:
        return 130
    except (InvalidComparison, OSError, ValueError, subprocess.CalledProcessError) as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
