# Minimal aggregate telemetry

TelemetryDeck remains enabled by default with opt-out. Production configuration is in `App/Info.plist`; missing/invalid configuration or DEBUG disables sending. Before the first configured, enabled launch, including upgrades, a one-time IT/EN notice describes the purpose, interest, data, recipient, retention limits and rights. Close acknowledges information, not consent. The notice has only that button and prominently explains how to disable telemetry in Settings → Telemetry without affecting app features. Reports may start immediately after Close, before the user opens Settings. Settings retains the switch and factual explanation; disabling cancels outstanding client work and stops future reports, but cannot retract data already received by the provider.

## Wire protocol v2

One POST per UTC day at most to the configured TelemetryDeck namespace. Exactly four payload fields: `TelemetryDeck.AppInfo.version`, `TelemetryDeck.Device.platform = macOS`, `TelemetryDeck.Device.operatingSystem = macOS`, `TelemetryDeck.Device.systemMajorVersion` (major only). `appID` identifies the app. **Every installation sends `clientUser = aggregate`**; it contains no installation UUID, account identity, language, settings, course/file information, custom timestamp or event identifier. User-Agent is `BeepBar` and Accept-Language is the fixed `en`, independent of user preferences.

The first attempted daily report in a later UTC calendar month uses `BeepBar.monthlyActive.v2`; later attempts use `BeepBar.dailyActive.v2`. A monotonic local `dailyTelemetryCountedMonth` marker replaces server deduplication. It never leaves the Mac. Both markers are persisted before sending; a failure/cancellation consumes the slot. There are no queues, catch-up reports or same-day retries. The month marker survives opt-out/re-enable; the old permanent/monthly UUID keys are deleted on construction regardless of the enabled state. An existing daily attempt from an older build still suppresses today's new report.

## Metrics and limits

| Metric | Query |
| --- | --- |
| Daily reporting installations | Count BOTH v2 event types per UTC day. |
| Monthly reporting installations | Count ONLY `BeepBar.monthlyActive.v2` per UTC calendar month. |
| Version/macOS exposure by day | Group both v2 event types by app/major OS version per UTC day. |
| First-reported monthly configuration | Group monthly events by version; this is the first attempted configuration, not every version used during the month. |

Do not use TelemetryDeck unique-user, retention or individual-funnel insights: all installations share one user value. Do not combine old `BeepBar.dailyActive` unique-ID data with the new series as if methodology were unchanged. Existing server events are not retroactively changed or deleted.

These are best-effort reporting-installation counts, not people or all installed copies. Failed first attempts undercount the month; reinstalling/resetting preferences can overcount. A clock moved forward can suppress later monthly counts until that month is passed; clock rollback never recounts an earlier month. Offline/opted-out installations undercount. Provider timestamps, small version cohorts and connection handling remain relevant privacy limitations; a shared identifier is not by itself a proof that every server operation is anonymous.

## Scheduling and transport

An energy-aware background scheduler runs no earlier than the next UTC day; activation/wake provide another opportunity. The app does not wake a sleeping Mac. Request/resource timeouts are 10/15 seconds. The ephemeral session has no cookie, credential or URL cache stores; redirects are rejected; expensive/constrained networks are excluded. Only headers are consumed and the session is cancelled afterward. Opt-out cancels the sender, observers and scheduling without waiting, preserving suppression markers. Telemetry adds no quit wait.

## Evidence and privacy decision

[Assessment and release gate](privacy-release-gate.md), [notice](privacy-notice.md). The provider [FAQ](https://telemetrydeck.com/docs/guides/privacy-faq/) states no IP storage and EU hosting, but explicitly guarantees no cold-event deletion schedule and retains analytics after customer account closure. Do not substitute plan query-history limits for deletion. The [supplemental agreement](https://telemetrydeck.com/avv/) describes SDK use; this client remains direct API and does not claim verified account-specific contractual coverage.

Earlier manually authorized synthetic v1 signals verified ingestion/dashboard visibility in October 2026. No v2 production or dashboard validation was performed in this change; automated requests use synthetic fixtures. Packaged-app network/manual checks were waived by the owner, not passed.
