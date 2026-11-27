# BeepBar terminal API

The CLI is included in the macOS app. Invoke it directly from the bundle:

```sh
/Applications/Beepbar.app/Contents/MacOS/Beepbar --cli status --json
```

To use the shorter `beepbar` command, create a symlink in a directory on your `PATH`, for example:

```sh
mkdir -p ~/.local/bin
ln -s /Applications/Beepbar.app/Contents/MacOS/Beepbar ~/.local/bin/beepbar
```

The CLI asks the matching BeepBar copy to handle the request. If it has quit, macOS launches it into the menu bar. Sync uses the same rules as the menu’s “Sync now” action. It can use a metered network and leaves any conflict choices to you.

| Command | Result |
| --- | --- |
| `beepbar capabilities` | App version, available command syntax, and pagination limits. |
| `beepbar doctor` | Current state, readiness to start, and the first known prerequisite or next action. |
| `beepbar status` | Current state, active run ID and progress when available, known pause or failure reason, and last result. |
| `beepbar sync [--wait]` | Starts a manual sync and returns its run ID. With `--wait`, returns the outcome and available counts of that specific run. An already running sync is reported separately with its ID. |
| `beepbar runs [RUN_ID]` | Up to the last 32 finished runs in the current app session, newest first, for the current account and folder. |
| `beepbar changes --since RUN_ID [--course COURSE_ID]` | Files added, updated, or moved and known failures from completed summaries after the specified run. |
| `beepbar changes --run RUN_ID [--course COURSE_ID]` | The same file details for one specific run. |
| `beepbar courses [COURSE_ID]` | Course IDs, names, selected state, and local folders. Reports if the list was confirmed this session or comes from the saved snapshot. |
| `beepbar conflicts [CONFLICT_ID]` | Pending file conflicts and remote changes, with relative paths and the choices offered in the app. |
| `beepbar recordings [--course COURSE_ID]` | Available archive entries and linked lessons already known to the app, with per-course listing coverage and watch progress when known. |

Every response is a JSON object on standard output with `schemaVersion` (currently `1`). `--json` is accepted for explicit scripts. Machine-readable error codes appear under `error.code`. IDs are strings and dates are UTC ISO 8601. List input accepts `--offset` and `--limit` (50 by default, 200 maximum). List results return `items`, `total`, and `nextOffset`. A null `nextOffset` is the last page. If BeepBar’s state changes between requests, fetched pages can reflect different snapshots.

Archive listings are held in memory. After a restart, recordings may be unavailable until BeepBar has loaded the course listing again. An available listing with no rows is an empty result. `unavailableCourseIds` identifies coverage gaps in a partial recordings response. Only sync initiates a refresh. If a run ends without a completed materials summary, `changes` includes its ID in `incompleteRunIds`; it may still have applied changes before ending. After an app restart, `status` can show BeepBar’s saved summary when available, without a session run ID.

| Exit code | Meaning |
| --- | --- |
| `0` | Query succeeded, sync started, or the awaited run completed. |
| `1` | The command was blocked, a sync was already running, the run failed or paused, or the app could not reply. Check the JSON for the reason. |
| `2` | Invalid arguments. |
| `3` | The awaited run completed with conflicts or failures. |
| `4` | The awaited run was cancelled or replaced by an account or folder change. |

For a transport error or wait timeout after a request was sent, check `status` before trying to start another sync. Interrupting the CLI leaves the app’s sync running.
