# Minimal daily telemetry (#128)

BeepBar uses TelemetryDeck's [Ingest API v2](https://telemetrydeck.com/docs/ingest/v2/) directly through URLSession. No SDK, backend or additional dependency is required.

## Configuration and user choice

`App/Info.plist` holds the public App ID and organization namespace (`com.beepbar`). These are ingest identifiers, not credentials. Missing or invalid configuration disables telemetry. `BeepBarTelemetryDefaultEnabled` is false: new and existing installations send nothing until the user enables the setting. The Statistics section in Settings lets users change the saved preference; a saved opt-out always takes precedence over the build default. The toggle and explanation are available in Italian and English.

Debug builds, tests and UI previews do not use production configuration. Release builds send only when the setting is enabled. Tests inject their own isolated preferences, sender, clock and scheduler. Nothing requires the installed app or its data.

## Signal and identity

One JSON array containing one signal is POSTed to `https://nom.telemetrydeck.com/v2/namespace/com.beepbar/`:

- `appID`: the public app identifier.
- `clientUser`: SHA-256 of the App ID and a random UUID stored in the app's preferences. The UUID is never transmitted. It survives restarts and updates; separate installs/preferences may create separate identities.
- `type`: `BeepBar.dailyActive`.
- `payload`: only `BeepBar.appVersion`, containing `CFBundleShortVersionString`.

There is no account, university, course, file, device model, operating system, location or session metadata in the application payload. Like any HTTPS receiver, the service necessarily receives network connection information, including the source IP. Use TelemetryDeck's [privacy information](https://telemetrydeck.com/privacy/) for its handling; hashing is not a guarantee that network traffic contains no identifying information.

## Scheduling and limits

A running, enabled app attempts a signal on startup and then near the next UTC midnight using a one-shot `NSBackgroundActivityScheduler`, with background QoS and a tolerance window whose earliest edge follows midnight. Wake/activation notifications provide another opportunity if the day changed. The previous attempt date is stored before sending, preventing repeated attempts on relaunch, wake or failure. A failed or cancelled attempt consumes that day's slot; there are no queues, catch-up signals or same-day retries. The app does not wake a sleeping Mac.

A request has a 10-second request timeout and a 15-second resource timeout. The session is ephemeral, with no cookies, credentials or cache, blocks redirects and opts out of expensive/constrained networks. Only response headers are required and the session is cancelled afterward. Disabling invalidates scheduling, removes observers and cancels the sender without waiting. Telemetry adds no wait to app termination.

This is a best-effort measure of **running installations**, not people or user interaction. Offline days, disabled telemetry and scheduler delays can undercount activity. Rolling the system clock backward postpones further attempts until it passes the recorded day.

## Dashboard recipes

Filter all production queries to `type = BeepBar.dailyActive` and exclude Test Mode:

| Question | Measurement |
| --- | --- |
| Active installations in the last 7 / 30 days | Distinct users over the entire selected interval. Do not sum daily unique counts. |
| Weekly / monthly growth | A timeseries of distinct users per calendar week / month. These periods differ from rolling 7 / 30 day totals. |
| App version adoption | Distinct users grouped by `BeepBar.appVersion`, over a stated interval. An installation that upgraded during the interval may appear in multiple version groups. |

Custom payload keys are intentional: predefined SDK dashboards expecting `TelemetryDeck.*` metadata need custom queries for `BeepBar.appVersion`. The free plan currently offers 50,000 signals/month and three months of queryable history; longer historical trends require exporting aggregates or a different plan. Verify current limits in the dashboard's billing page before a release; the free tier is not realtime.

## Verification

On 2026-10-10 the owner confirmed two manually authorized synthetic signals in Explore → Recent Events with Test Mode enabled: `BeepBar.integrationCheck` (namespaced endpoint, boolean `isTestMode = true`) and `BeepBar.sdkFormatTest` (generic endpoint, string `isTestMode = "true"`). Both used the configured App ID. This verifies ingestion, processing and dashboard visibility without an SDK; the earlier empty results did not establish a payload-format failure. No production signal was submitted during development.

The free namespace status warns that processing occurs between once an hour and once a day. HTTP 200 / `OK` means the ingest endpoint accepted the request; dashboard visibility can lag. Default dashboards for device/system/app-version metadata can remain empty because the minimal payload omits those SDK fields. Use the custom version query above.
