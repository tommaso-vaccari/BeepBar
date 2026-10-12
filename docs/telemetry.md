# Minimal daily telemetry (#128)

BeepBar uses TelemetryDeck's [Ingest API v2](https://telemetrydeck.com/docs/ingest/v2/) directly through URLSession. No SDK, backend or additional dependency is required.

## Configuration and user choice

`App/Info.plist` holds the public App ID and organization namespace (`com.beepbar`). These are ingest identifiers, not credentials. Missing or invalid configuration disables telemetry. `BeepBarTelemetryDefaultEnabled` is true: new and existing installations with no saved choice send automatically on their first Release launch after updating. The Telemetry switch in Settings lets users disable it; a saved opt-out always takes precedence over the build default. The info button explains the purpose, the monthly identifier, every transmitted field and that turning telemetry off deletes the identifier, in Italian and English.

Debug builds, tests and UI previews do not use production configuration. Release builds send only when the setting is enabled. Tests inject their own isolated preferences, sender, clock and scheduler. Nothing requires the installed app or its data.

## Signal and identity

One JSON array containing one signal is POSTed to `https://nom.telemetrydeck.com/v2/namespace/com.beepbar/`:

- `appID`: the public app identifier.
- `clientUser`: SHA-256 of the App ID and a random UUID that lives for one UTC calendar month. The UUID is never transmitted. When the UTC month changes, in either direction (a clock moved back included), it is replaced by a fresh random UUID, not derived from the previous one, so neither the Mac nor the server can link two months. Turning telemetry off deletes it; turning it on again starts a new one. The permanent installation UUID of the first `dev` build (`dailyTelemetryInstallationID`, never released) is deleted on launch. TelemetryDeck's Swift SDK states in a code comment that the server hashes and salts `clientUser` again; its public ingest documentation does not say so, so this document does not rely on it.
- `type`: `BeepBar.dailyActive`.
- `payload`, all values as strings:

| Key | Value | Why this key |
| --- | --- | --- |
| `TelemetryDeck.AppInfo.version` | `CFBundleShortVersionString` | SDK key: the dashboard's version insights read it |
| `TelemetryDeck.Device.platform` / `TelemetryDeck.Device.operatingSystem` | `macOS` | SDK keys, constant |
| `TelemetryDeck.Device.systemMajorVersion` | `macOS 15` (major version only, SDK format) | SDK key |
| `TelemetryDeck.RunContext.language` | `it` or `en`, BeepBar's language at send time | SDK key |
| `BeepBar.automaticSync` | `true` / `false` | custom |
| `BeepBar.automaticSyncInterval` | seconds, one of the Settings options | custom |
| `BeepBar.dataSaver` | `true` / `false` | custom |
| `BeepBar.recordings` | `true` / `false` (read without creating the Recordings controller) | custom |
| `BeepBar.launchAtLogin` | `true` / `false`; omitted while macOS has not reported the login item | custom |

The SDK keys reuse TelemetryDeck's standard names and formats so the built-in insights work; TelemetryDeck's advice to avoid the `TelemetryDeck.` scope concerns inventing new keys there. No other SDK default is sent: no device model, screen, architecture, time zone, region, locale, full OS build or retention counters. Settings are read when the signal is sent, so a change made during a day appears in the next day's signal.

There is no account, university, course, file, device model, location or session metadata in the payload. Every field has few possible values, which keeps the combination with a month-long identifier low-information. Like any HTTPS receiver, the service necessarily receives network connection information, including the source IP. Use TelemetryDeck's [privacy information](https://telemetrydeck.com/privacy/) for its handling; hashing is not a guarantee that network traffic contains no identifying information.

## Scheduling and limits

A running, enabled app attempts a signal on startup and then near the next UTC midnight using a one-shot `NSBackgroundActivityScheduler`, with background QoS and a tolerance window whose earliest edge follows midnight. Wake/activation notifications provide another opportunity if the day changed. The previous attempt date is stored before sending, preventing repeated attempts on relaunch, wake or failure. A failed or cancelled attempt consumes that day's slot; there are no queues, catch-up signals or same-day retries. The app does not wake a sleeping Mac.

A request has a 10-second request timeout and a 15-second resource timeout. The session is ephemeral, with no cookies, credentials or cache, blocks redirects and opts out of expensive/constrained networks. Only response headers are required and the session is cancelled afterward. Disabling invalidates scheduling, removes observers and cancels the sender without waiting. Telemetry adds no wait to app termination.

This is a best-effort measure of **running installations**, not people or user interaction. Offline days, disabled telemetry and scheduler delays can undercount activity. Rolling the system clock backward postpones further attempts until it passes the recorded day.

## Dashboard recipes

Filter all production queries to `type = BeepBar.dailyActive` and exclude Test Mode:

| Question | Measurement |
| --- | --- |
| Daily active installations | Number of signals per UTC day: each installation sends at most one. |
| Monthly active installations | Distinct users per **calendar month**. Never count distinct users across a month boundary: the identifier changes there, so a rolling 7 / 30 day window that spans two months counts each installation twice. |
| Weekly activity | Average daily signals over the week, not distinct users. |
| App version / macOS / language adoption | Built-in insights, or signals grouped by `TelemetryDeck.AppInfo.version`, `TelemetryDeck.Device.systemMajorVersion`, `TelemetryDeck.RunContext.language`, per day. |
| Settings in use | Signals per day grouped by a `BeepBar.*` key; divide by that day's signals for a share. |

Recent Events shows a fixed set of columns: `TelemetryDeck.Device.modelName` stays empty because it is never sent, and other payload keys appear after adding them as columns or opening an event. Signals sent before this change carry `BeepBar.appVersion` instead of `TelemetryDeck.AppInfo.version`. The free plan currently offers 50,000 signals/month and three months of queryable history; longer historical trends require exporting aggregates or a different plan. Verify current limits in the dashboard's billing page before a release; the free tier is not realtime.

## Verification

On 2026-10-10 the owner confirmed two manually authorized synthetic signals in Explore → Recent Events with Test Mode enabled: `BeepBar.integrationCheck` (namespaced endpoint, boolean `isTestMode = true`) and `BeepBar.sdkFormatTest` (generic endpoint, string `isTestMode = "true"`). Both used the configured App ID. This verifies ingestion, processing and dashboard visibility without an SDK; the earlier empty results did not establish a payload-format failure. No production signal was submitted during development.

The free namespace status warns that processing occurs between once an hour and once a day. HTTP 200 / `OK` means the ingest endpoint accepted the request; dashboard visibility can lag. Default dashboards for device/system/app-version metadata can remain empty because the minimal payload omits those SDK fields. Use the custom version query above.
