#!/usr/bin/env python3
"""Build and run the isolated UI fixture, retaining samples and Instruments traces (#95).

This exports an immutable commit to temporary storage, never launches the regular app,
never replaces a checkout, and refuses to overwrite any existing evidence directory.
"""
import argparse
import hashlib
import io
import json
import math
import os
from pathlib import Path
import platform
import plistlib
import shutil
import signal
import statistics
import subprocess
import sys
import tarfile
import tempfile
import time
import uuid
import xml.etree.ElementTree as ET

SHORT_SCENARIOS = (
    "launch-cold", "launch-warm", "launch-offline", "courses-100", "courses-500",
    "reopen-sync", "activity-1000", "activity-15000", "recordings-1000",
    "recordings-5000", "progress-burst", "memory-cycles",
)
SCENARIOS = SHORT_SCENARIOS + ("idle",)
IDENTITY = "beepbar-isolated-ui-fixture-v1"


def count(value):
    try:
        result = int(value)
        if str(result) != value or result < 1:
            raise ValueError()
        return result
    except ValueError:
        raise argparse.ArgumentTypeError("must be a positive integer")


def command(args, cwd, log=None, timeout=None, env=None):
    process = subprocess.Popen(args, cwd=cwd, text=True, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, start_new_session=True, env=env)
    try:
        output, _ = process.communicate(timeout=timeout)
    except BaseException:
        # Only this owned process group (including a launched fixture) is stopped. Never leave
        # an orphan app running when Instruments times out or a caller interrupts the series.
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            output, _ = process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            output, _ = process.communicate()
        if log is not None:
            log.write_text(output)
        raise
    if log is not None:
        log.write_text(output)
    if process.returncode:
        raise RuntimeError("command failed (%d): %s; %s" %
                           (process.returncode, " ".join(map(str, args)), str(log) if log else output[-2000:]))
    return output.strip()


def export_commit(repo, sha, destination):
    result = subprocess.run(["git", "archive", sha], cwd=repo, check=True, stdout=subprocess.PIPE)
    with tarfile.open(fileobj=io.BytesIO(result.stdout)) as archive:
        for member in archive.getmembers():
            path = Path(member.name)
            if path.is_absolute() or ".." in path.parts or not (member.isdir() or member.isfile()):
                raise RuntimeError("unsafe source archive member: " + member.name)
        archive.extractall(destination)


def finite(value):
    return type(value) in (int, float) and math.isfinite(value) and value >= 0


def validate_sample(sample, scenario):
    """Refuse missing/invalid samples instead of reporting a success from an empty window."""
    if sample.get("schemaVersion") != 1 or sample.get("scenario") != scenario or sample.get("valid") is not True or sample.get("error") is not None:
        raise ValueError("invalid fixture report for " + scenario)
    expected_courses = 500 if scenario == "courses-500" else 100
    expected_activity = 15000 if scenario == "activity-15000" else 1000 if scenario == "activity-1000" else 0
    expected_recordings = 5000 if scenario == "recordings-5000" else 1000 if scenario == "recordings-1000" else 0
    if (sample.get("courseCount"), sample.get("activityCount"), sample.get("recordingsCount")) != (expected_courses, expected_activity, expected_recordings):
        raise ValueError("wrong fixture corpus")
    expected_cycles = 10 if scenario == "memory-cycles" else 2 if scenario in ("launch-warm", "reopen-sync") else 1
    cycles = sample.get("cycles")
    if not isinstance(cycles, list) or len(cycles) != expected_cycles:
        raise ValueError("wrong cycle count")
    expected_content = "expandedActivity" if scenario.startswith("activity-") else "recordings" if scenario.startswith("recordings-") else "courses"
    for index, cycle in enumerate(cycles, 1):
        if cycle.get("index") != index or not finite(cycle.get("keyMilliseconds")):
            raise ValueError("missing key window measurement")
        if not finite(cycle.get("contentMilliseconds", {}).get(expected_content)):
            raise ValueError("missing populated content measurement")
        if not finite(cycle.get("resourcesAfterClose", {}).get("footprintBytes")):
            raise ValueError("missing closed-window memory measurement")
    if sample.get("lowPowerMode") is not False or sample.get("thermalState") != 0:
        raise ValueError("requires Low Power Mode off and nominal thermal state")
    if scenario == "idle":
        if sample.get("idleSeconds") != 1800 or sample.get("fixtureRequestsDuringIdle") != 0:
            raise ValueError("idle must cover 30 minutes with no unexpected fixture requests")
        for side in ("idleBefore", "idleAfter"):
            if not isinstance(sample.get(side), dict) or not all(finite(sample[side].get(key)) for key in
                ("footprintBytes", "cpuNanoseconds", "diskBytesWritten", "logicalBytesWritten", "interruptWakeups", "idleWakeups")):
                raise ValueError("missing idle counters")
    return sample


def cost_rows(samples, scenario):
    cycle_index = 1 if scenario in ("launch-warm", "reopen-sync") else 0
    kinds = samples[0]["cycles"][cycle_index]["contentMilliseconds"].keys()
    values = {"window key (ms)": [sample["cycles"][cycle_index]["keyMilliseconds"] for sample in samples]}
    values.update({"first %s (ms)" % kind: [sample["cycles"][cycle_index]["contentMilliseconds"][kind] for sample in samples] for kind in kinds})
    rows = []
    for metric, raw in values.items():
        if len(raw) < 5:
            rows.append((scenario, metric, len(raw), statistics.median(raw), None, min(raw), max(raw)))
        else:
            # Nearest-rank p95 of five samples is the max, not a stable tail estimate.
            rows.append((scenario, metric, len(raw), statistics.median(raw), sorted(raw)[math.ceil(.95 * len(raw)) - 1], min(raw), max(raw)))
    return rows


def window_budget(samples, scenario):
    """Report slow valid samples without erasing evidence of a budget violation."""
    warm = scenario in ("launch-warm", "reopen-sync")
    cycle_index = 1 if warm else 0
    maximum = max(sample["cycles"][cycle_index]["keyMilliseconds"] for sample in samples)
    target = 100 if warm else 250
    return {"targetMilliseconds": target, "maximumObservedMilliseconds": maximum,
            "allObservedSamplesWithinBudget": maximum <= target}


def validate_power_source(initial, observed):
    if observed != initial:
        raise ValueError("power source changed during run")


def trace_target(toc):
    root = ET.parse(toc).getroot()
    target = root.find("./run[@number='1']/info/target/process")
    if target is None or target.get("name") != "beepbar-ui-fixture" or target.get("return-exit-status") != "0":
        raise ValueError("trace does not identify a successful isolated fixture")
    pid = target.get("pid")
    if not pid or not pid.isdecimal() or int(pid) <= 0 or root.find(".//table[@schema='time-profile']") is None:
        raise ValueError("trace has no fixture CPU profile")
    # Exported evidence may be shared; hardware owner name/UUID are irrelevant to the workload.
    # The original .trace stays local because Instruments can retain device identity metadata.
    for device in root.findall(".//device"):
        device.attrib.pop("name", None); device.attrib.pop("uuid", None)
    ET.ElementTree(root).write(toc, encoding="utf-8", xml_declaration=True)
    return pid


def profile_summary(path, target_pid):
    """Stream CPU rows so large traces do not need another full in-memory XML hierarchy."""
    processes, threads, stacks = {}, {}, {}
    samples = main_samples = 0
    for _, row in ET.iterparse(path, events=("end",)):
        if row.tag != "row":
            continue
        for process in row.iter("process"):
            if process.get("id"):
                processes[process.get("id")] = process.findtext("pid")
        for thread in row.iter("thread"):
            if thread.get("id"):
                threads[thread.get("id")] = thread.get("fmt", "").startswith("Main Thread")
        for stack in row.iter("tagged-backtrace"):
            if stack.get("id"):
                stacks[stack.get("id")] = stack.find("frame") is not None
        process = row.find("process"); thread = row.find("thread"); stack = row.find("tagged-backtrace")
        if process is not None and thread is not None and stack is not None:
            samples += 1
            pid = processes.get(process.get("ref") or process.get("id"))
            main = threads.get(thread.get("ref") or thread.get("id"), False)
            has_stack = stacks.get(stack.get("ref") or stack.get("id"), False)
            if pid == target_pid and main and has_stack:
                main_samples += 1
        row.clear()
    if main_samples == 0:
        raise ValueError("trace has no usable fixture main-thread CPU samples")
    return {"cpuSamples": samples, "fixtureMainThreadSamplesWithStacks": main_samples}


def signpost_summary(path, scenario):
    values, names = {}, {}
    for _, row in ET.iterparse(path, events=("end",)):
        if row.tag != "row":
            continue
        for value in row:
            if value.tag in ("subsystem", "category", "signpost-name") and value.get("id"):
                values[value.get("id")] = value.text
        def field(name):
            value = row.find(name)
            return None if value is None else values.get(value.get("ref") or value.get("id"))
        if field("subsystem") == "io.github.tvaccari.beepbar.performance" and field("category") == "ui":
            name = field("signpost-name")
            if name:
                names[name] = names.get(name, 0) + 1
        row.clear()
    cycles = 10 if scenario == "memory-cycles" else 2 if scenario in ("launch-warm", "reopen-sync") else 1
    content = "ui.firstExpandedActivityContent" if scenario.startswith("activity-") else "ui.firstRecordingsContent" if scenario.startswith("recordings-") else "ui.firstCourseContent"
    required = {"ui.iconReady": 1, "ui.fixtureOpen": cycles, "ui.windowKey": cycles, content: cycles}
    if scenario.startswith("activity-"):
        required["ui.firstActivityContent"] = cycles
    if scenario == "progress-burst":
        required["ui.fixtureProgressBurst"] = 2  # begin and end of the interval
    if any(names.get(name, 0) < count for name, count in required.items()):
        raise ValueError("trace lacks required fixture UI signposts")
    return names


def validate_trace(trace, scenario, cwd, output_prefix):
    if not trace.is_dir() or not any(path.is_file() and path.stat().st_size > 0 for path in trace.rglob("*")):
        raise ValueError("missing or empty required trace")
    toc = output_prefix.with_suffix(".toc.xml")
    profile = output_prefix.with_suffix(".cpu.xml")
    signposts = output_prefix.with_suffix(".signposts.xml")
    command(["xcrun", "xctrace", "export", "--input", str(trace), "--toc", "--output", str(toc)], cwd,
            output_prefix.with_suffix(".toc.log"), timeout=60)
    pid = trace_target(toc)
    for schema, output in (("time-profile", profile), ("os-signpost", signposts)):
        command(["xcrun", "xctrace", "export", "--input", str(trace), "--xpath",
                 "/trace-toc/run[@number='1']/data/table[@schema='%s']" % schema, "--output", str(output)], cwd,
                output.with_suffix(".log"), timeout=180)
    result = profile_summary(profile, pid)
    result["uiSignposts"] = signpost_summary(signposts, scenario)
    return result


def power(repo):
    output = command(["pmset", "-g", "batt"], repo)
    if "'AC Power'" not in output:
        raise RuntimeError("measurements require AC power")
    return output.splitlines()[0]


def run(args):
    repo = Path(__file__).resolve().parent.parent
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise RuntimeError("requires macOS Apple Silicon and Xcode")
    # Resolve once: a later fetch/branch movement cannot change this series' measured source.
    sha = command(["git", "rev-parse", args.ref + "^{commit}"], repo)
    main_sha = command(["git", "rev-parse", "origin/main^{commit}"], repo)
    base_sha = command(["git", "rev-parse", "origin/dev^{commit}"], repo)
    xcode = command(["xcodebuild", "-version"], repo)
    trace_version = command(["xcrun", "xctrace", "version"], repo)
    initial_power = power(repo)
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    series = {"schemaVersion": 1, "valid": False, "sourceSHA": sha, "mainSHA": main_sha,
              "baseDevSHA": base_sha, "runs": args.runs, "warmup": args.warmup,
              "scenarios": args.scenarios, "driverSHA256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              "xcode": xcode, "xctrace": trace_version, "machine": platform.machine(),
              "macOS": command(["sw_vers"], repo), "model": command(["sysctl", "-n", "hw.model"], repo),
              "memoryBytes": command(["sysctl", "-n", "hw.memsize"], repo), "power": initial_power,
              "conditions": "Dedicated synthetic fixture; no real scheduler/network/updater. Release arm64 with DEBUG DI seams. Controls disabled. 300ms shown + 3s after-close settling.",
              "commands": [], "limitations": ["Tooling validation is separate from app performance gains.",
                "Base-dev and main comparisons are not measured; older revisions need a reviewed equivalent UI fixture.",
                "Cold means first window in a fresh fixture process, not cold filesystem cache or production bootstrap.",
                "Content onAppear is distinct from compositor presentation. Time Profiler samples establish stacks, not a proof of every <=16ms stall.",
                "Only synthetic known-content offline refresh is covered; persisted cold offline restoration remains D10.",
                "Idle runs once, unprofiled, for 30 minutes; real scheduled checks are disabled and count zero by construction.",
                "Five measured runs cannot establish a reliable p95. Manual scrolling/actions remain required."]}
    results = {}
    try:
        with tempfile.TemporaryDirectory(prefix="BeepbarUIBuild-") as temporary:
            root = Path(temporary)
            series["temporaryRoot"] = str(root)
            source = root / "source"; source.mkdir()
            export_commit(repo, sha, source)
            scratch = root / "build"
            cache = args.dependency_cache.resolve() if args.dependency_cache else repo / ".build"
            for name in ("artifacts", "checkouts", "repositories"):
                if (cache / name).is_dir():
                    shutil.copytree(cache / name, scratch / name, symlinks=True)
            build = ["swift", "build", "--disable-sandbox", "--scratch-path", str(scratch), "-c", "release", "--arch", "arm64", "--product", "Beepbar", "-Xswiftc", "-DDEBUG", "-Xswiftc", "-DUI_PERFORMANCE_HARNESS"]
            command(build, source, out / "build.log", timeout=900)
            series["commands"].append(build)
            binpath = Path(command(["swift", "build", "--scratch-path", str(scratch), "-c", "release", "--arch", "arm64", "--show-bin-path"], source))
            bundle = root / "BeepbarUIFixture.app"
            executable = bundle / "Contents" / "MacOS" / "beepbar-ui-fixture"
            executable.parent.mkdir(parents=True)
            shutil.copy2(binpath / "Beepbar", executable)
            # SwiftPM's rpath is @loader_path; keep only its required Sparkle dependency beside
            # the renamed fixture binary. Sparkle is linked but the fixture never constructs it.
            if (binpath / "Sparkle.framework").exists():
                shutil.copytree(binpath / "Sparkle.framework", executable.parent / "Sparkle.framework", symlinks=True)
            with (bundle / "Contents" / "Info.plist").open("wb") as stream:
                plistlib.dump({"CFBundleIdentifier": "io.github.tvaccari.beepbar.ui-fixture." + uuid.uuid4().hex,
                              "CFBundleExecutable": "beepbar-ui-fixture", "CFBundleName": "BeepBar UI Fixture",
                              "CFBundlePackageType": "APPL", "CFBundleVersion": "1", "LSUIElement": False}, stream)
            # Keep the compiler's signature; no signing identity, installation or installed
            # application is modified. The temporary bundle supplies a unique fixture identity.
            if command([str(executable), "--harness-identity"], source) != IDENTITY:
                raise RuntimeError("refused to launch binary without isolated harness identity")
            series["binarySHA256"] = hashlib.sha256(executable.read_bytes()).hexdigest()
            series["architecture"] = command(["file", str(executable)], source)
            if "arm64" not in series["architecture"]:
                raise RuntimeError("not an arm64 fixture")
            fixture_parent = root / "fixtures"; fixture_parent.mkdir()
            fixture_env = dict(os.environ, BEEPBAR_UI_FIXTURE_TEMP_ROOT=str(fixture_parent))
            for scenario in args.scenarios:
                scenario_out = out / scenario; scenario_out.mkdir()
                # Idle is a single distinct 30-minute observation, never repeated as short UI samples.
                iterations = [(False, 0)] if scenario == "idle" else [(True, index) for index in range(args.warmup)] + [(False, index) for index in range(args.runs)]
                samples = []
                for warmup, index in iterations:
                    name = ("warmup-" if warmup else "run-") + str(index + 1)
                    report = scenario_out / (name + ".json")
                    stdout = scenario_out / (name + ".stdout.log")
                    launch = [str(executable), "--scenario", scenario, "--report", str(report)]
                    if scenario != "idle":
                        trace = scenario_out / (name + ".trace")
                        launch = ["xcrun", "xctrace", "record", "--template", "Time Profiler", "--instrument", "os_signpost", "--output", str(trace), "--target-stdout", str(stdout), "--env", "BEEPBAR_UI_FIXTURE_TEMP_ROOT=" + str(fixture_parent), "--launch", "--"] + launch
                    if power(repo) != initial_power:
                        raise RuntimeError("power source changed")
                    print("%s %s" % (scenario, name), flush=True)
                    started = time.time()
                    command(launch, source, scenario_out / (name + ".log"), timeout=1900 if scenario == "idle" else 180, env=fixture_env)
                    series["commands"].append({"argv": launch, "elapsedSeconds": time.time() - started, "exit": 0})
                    # A final idle run must not make a series valid after switching to battery.
                    validate_power_source(initial_power, power(repo))
                    if scenario != "idle":
                        series["commands"][-1]["trace"] = validate_trace(trace, scenario, source, scenario_out / name)
                        validate_power_source(initial_power, power(repo))
                    sample = validate_sample(json.loads(report.read_text()), scenario)
                    if not warmup:
                        samples.append(sample)
                results[scenario] = samples
            series["windowBudgets"] = {scenario: window_budget(samples, scenario)
                                       for scenario, samples in results.items()}
            series["valid"] = True
    except BaseException as error:
        series["error"] = str(error)
        raise
    finally:
        (out / "series.json").write_text(json.dumps(series, indent=2, sort_keys=True) + "\n")
        lines = ["# Isolated UI fixture series", "", "Source: `" + sha + "`", "", "Validity: **" + str(series["valid"]) + "**", "",
                 "| Scenario | Metric | n | Median | p95 (unstable) | Min | Max |", "|---|---|---:|---:|---:|---:|---:|"]
        for scenario, samples in results.items():
            for name, metric, n, median, p95, minimum, maximum in cost_rows(samples, scenario):
                lines.append("| %s | %s | %d | %.3f | %s | %.3f | %.3f |" % (name, metric, n, median, "unmeasured" if p95 is None else "%.3f" % p95, minimum, maximum))
            if scenario == "memory-cycles":
                growth = [(sample["cycles"][-1]["resourcesAfterClose"]["footprintBytes"] - sample["cycles"][0]["resourcesAfterClose"]["footprintBytes"]) / (1024 * 1024) for sample in samples]
                lines += ["", "Memory after cycle 10 minus cycle 1 (MiB), raw: " + str(growth) + ". Target ±2 MiB; synthetic workload only.", ""]
            if scenario == "idle":
                sample = samples[0]
                lines += ["", "Idle counter deltas (30 minutes, no production checks enabled):", ""]
                for key, before in sample["idleBefore"].items():
                    lines.append("- %s: %s" % (key, sample["idleAfter"][key] - before))
                lines += ["", "Fixture requests: %s; scheduled production checks: 0." % sample["fixtureRequestsDuringIdle"], ""]
        lines += ["", "## Observed window key budgets", "",
                  "| Scenario | Target ms | Maximum observed ms | All samples within budget |",
                  "|---|---:|---:|---|"]
        for scenario, samples in results.items():
            budget = window_budget(samples, scenario)
            lines.append("| %s | %d | %.3f | %s |" % (scenario, budget["targetMilliseconds"],
                         budget["maximumObservedMilliseconds"], budget["allObservedSamplesWithinBudget"]))
        lines += ["", "## Interpretation", "", "Window key targets: 250ms first-window, 100ms same-process reopen. Icon construction excludes fixture startup and must not be compared to the 200ms app launch budget. Main-thread traces require independent interpretation; this table establishes no compositor/frame-time guarantee.", ""]
        lines += ["- " + limitation for limitation in series["limitations"]]
        if "error" in series:
            lines += ["", "Error: " + series["error"]]
        (out / "series.md").write_text("\n".join(lines) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True, type=Path, help="new evidence directory")
    parser.add_argument("--ref", default="HEAD", help="committed source revision; resolved once")
    parser.add_argument("--runs", default=5, type=count)
    parser.add_argument("--warmup", default=1, type=count)
    parser.add_argument("--scenarios", nargs="+", choices=SCENARIOS, default=list(SCENARIOS))
    parser.add_argument("--dependency-cache", type=Path)
    args = parser.parse_args()
    if len(args.scenarios) != len(set(args.scenarios)):
        parser.error("duplicate scenarios")
    try:
        run(args)
    except (RuntimeError, OSError, ValueError, ET.ParseError, subprocess.SubprocessError) as error:
        print("UI benchmark failed: " + str(error), file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 130
    return 0


if __name__ == "__main__":
    sys.exit(main())
