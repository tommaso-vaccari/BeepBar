#!/usr/bin/env python3
"""Exercise the unsigned Release executable with synthetic defaults and networking denied.

The injected interceptor records NSURLSession attempts and chooses alert responses. This
is instrumentation, not a production packet capture or an unmodified GUI interaction.
"""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import socket
import subprocess
import sys
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "build/Release/Beepbar.app"
assert APP.is_dir(), "Build the unsigned Xcode Release target first"
with tempfile.TemporaryDirectory(prefix="beepbar-privacy-probe-") as temporary:
    work = Path(temporary).resolve()
    app = work / "Beepbar.app"
    subprocess.run(["ditto", str(APP), str(app)], check=True)
    library = work / "intercept.dylib"
    subprocess.run(["clang", "-fobjc-arc", "-dynamiclib", "-framework", "AppKit",
                    str(Path(__file__).with_name("intercept.m")), "-o", str(library)], check=True)
    profile = work / "isolation.sb"
    real_state = Path.home() / "Library/Application Support/Beepbar"
    real_preferences = Path.home() / "Library/Preferences/io.github.tvaccari.beepbar.plist"
    profile.write_text('(version 1)(allow default)(deny network*)'
                       f'(deny file-read* file-write* (subpath "{real_state}") (literal "{real_preferences}"))'
                       '(deny file-write*)'
                       f'(allow file-write* (subpath "{work}"))')
    # A controlled listening socket distinguishes a sandbox denial from a closed port.
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        listener.listen(2)
        port = listener.getsockname()[1]
        with socket.create_connection(("127.0.0.1", port), timeout=1):
            pass
        denied = subprocess.run(["sandbox-exec", "-f", str(profile), sys.executable, "-c",
                                 f"import socket; socket.create_connection(('127.0.0.1', {port}), timeout=1)"],
                                capture_output=True, text=True)
        assert denied.returncode != 0 and "Operation not permitted" in denied.stderr, denied.stderr
    results = []
    for choice in ["saved-disabled", "close"]:
        home = work / choice
        home.mkdir()
        info = app / "Contents/Info.plist"
        data = plistlib.loads(info.read_bytes())
        data["CFBundleIdentifier"] = "io.github.tvaccari.beepbar.privacyprobe." + uuid.uuid4().hex
        info.write_bytes(plistlib.dumps(data))
        for launch in [1, 2]:
            trace = work / f"{choice}-{launch}.jsonl"
            env = dict(os.environ, CFFIXED_USER_HOME=str(home),
                       BEEPBAR_PROBE_TRACE=str(trace), BEEPBAR_PROBE_CHOICE=choice)
            run = subprocess.run(["sandbox-exec", "-f", str(profile), "/usr/bin/env", "DYLD_INSERT_LIBRARIES=" + str(library), str(app / "Contents/MacOS/Beepbar")],
                                 env=env, capture_output=True, text=True, timeout=20)
            assert run.returncode == 0, run.stderr[-2000:]
            events = [json.loads(line) for line in trace.read_text().splitlines()]
            updater, = [e for e in events if e["kind"] == "updater"]
            assert updater["feedURL"] == "https://github.com/tommaso-vaccari/Beepbar/releases/latest/download/appcast.xml", updater
            assert updater["sendsSystemProfile"] is False, updater
            assert updater["automaticallyChecksForUpdates"] is True, updater
            assert updater["httpHeaders"] == {} and updater["hasDelegate"] is False, updater
            alerts = [e for e in events if e["kind"] == "alert"]
            requests = [e for e in events if e["kind"] == "request" and "nom.telemetrydeck.com" in e["url"]]
            assert len(alerts) == (1 if choice == "close" and launch == 1 else 0), events
            assert len(requests) == (1 if choice == "close" and launch == 1 else 0), events
            state = next(e for e in events if e["kind"] == "state")
            assert state["effectiveTelemetryEnabled"] == (choice == "close"), state
            assert state.get("dailyTelemetryDisclosureVersion", 0) == (1 if choice == "close" else 0), state
            if alerts:
                assert alerts[0]["buttons"] in (["Chiudi"], ["Close"]), alerts
                assert any(label in alerts[0]["summary"] for label in ["Impostazioni → Telemetria", "Settings → Telemetry"]), alerts
                details = " ".join(alerts[0]["details"])
                assert "TelemetryDeck" in details and "tommaso.vaccari@mail.polimi.it" in details
            if requests:
                assert events.index(alerts[0]) < events.index(requests[0]), events
                signal, = json.loads(requests[0]["body"])
                assert signal["clientUser"] == "aggregate", signal
                assert signal["type"] == "BeepBar.monthlyActive.v2", signal
                assert set(signal["payload"]) == {"TelemetryDeck.AppInfo.version", "TelemetryDeck.Device.platform",
                                                  "TelemetryDeck.Device.operatingSystem", "TelemetryDeck.Device.systemMajorVersion"}, signal
            results.append({"choice":choice,"launch":launch,"alerts":len(alerts),"telemetryAttempts":len(requests)})
    assert hashlib.sha256((APP / "Contents/MacOS/Beepbar").read_bytes()).digest() == hashlib.sha256((app / "Contents/MacOS/Beepbar").read_bytes()).digest()
    print(json.dumps({"executableUnchanged": True, "networkDenied": True, "instrumented": True, "updaterConfigurationVerified": True,
                      "scenarios":results}, indent=2))
