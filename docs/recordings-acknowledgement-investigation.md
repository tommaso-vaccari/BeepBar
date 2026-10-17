# R06 — Recordings acknowledgement CI investigation

Issue: [#114](https://github.com/tommaso-vaccari/BeepBar/issues/114). Investigation date: 2026-10-09.
Branch: `test/recordings-acknowledgement-race`.
Inspected dev SHA: `ac68333265a68b3f1e01e7f0958c3aae31cc7850`.

## Observed failure

[Run 37899467406, attempt 1](https://github.com/tommaso-vaccari/BeepBar/actions/runs/37899467406/attempts/1)
failed on `39683c2ba7b173672ece501f57054e37085a45d5`. Its app test run reported
244 tests and one issue: `onlyRecordingsPublishedLaterAreNew`, at
`RecordingsControllerTests.swift:894`, after `markSeen(course)`:

```swift
#expect(!makeController().isNew(recording("c")))
```

The diagnostic dump includes a newly created controller with
`acknowledgedOrder == ["a", "b"]`, baseline `058167-2026`, and two recorded
writes to the acknowledged defaults key. The write log records keys, not the
values written. The same diagnostic also prints the negated expression as
`true` and its inner `isNew` result as `false`. Preserve these conflicting
details: neither the rendered expression nor the dump alone establishes the
cause, evaluation order, or persisted values at the failing assertion.

[Attempt 2](https://github.com/tommaso-vaccari/BeepBar/actions/runs/37899467406/attempts/2)
passed tests and the Release build on the same SHA. A successful retry does
not resolve the original failure. The controller and its test file are
unchanged between that SHA and the inspected dev SHA.

Evidence retrieval:

```sh
gh run view 37899467406 --attempt 1 --repo tommaso-vaccari/BeepBar --log-failed
gh run view 37899467406 --attempt 1 --repo tommaso-vaccari/BeepBar --json headSha,conclusion,attempt,jobs
gh run view 37899467406 --attempt 2 --repo tommaso-vaccari/BeepBar --json headSha,conclusion,attempt,jobs
git diff 39683c2ba7b173672ece501f57054e37085a45d5 ac68333265a68b3f1e01e7f0958c3aae31cc7850 -- Sources/BeepbarApp/RecordingsController.swift Tests/BeepbarAppTests/RecordingsControllerTests.swift
```

## Source ordering and fixture isolation

- `drain` awaits the fake browser's listing, checks generation, then calls
  `record`. `record` assigns the listing, inserts and saves a missing course
  baseline, and calls `acknowledge` for the initial list, in that order.
- `acknowledge` updates the ID order, assigns the published acknowledged set,
  then calls `defaults.set`. `markSeen` calls this synchronously. These functions
  are main actor isolated and contain no suspension point. There is no proof
  that a separately scheduled main actor task interleaves those statements;
  synchronous publication callbacks remain a distinct observation boundary.
- Saving the browser session happens later in `drain`, after an `await` of
  `browser.cookies()`. The cookies file and the acknowledgement defaults are
  separate stores; waiting for session persistence does not prove that an
  acknowledgement read was correct.
- The existing test uses `settle` to wait for the first listing and the later
  new count, then calls `markSeen` and creates a controller immediately. It does
  not subscribe to publication callbacks. Its initial saved IDs and later
  unmodified defaults are asserted, but the defaults values immediately after
  `markSeen` are not captured independently before creating the last controller.
- Each test fixture gets a UUID session folder and a UUID absolute-path defaults
  suite via `CountingDefaults.throwaway` / `throwawayDefaultsSuite`. Within a
  test, all controllers use the same defaults object. Fixtures use the synthetic
  account ID `42`; the requested parallel matrix of **distinct account IDs** has
  not been executed. `CountingDefaults` records write keys before delegating to
  `UserDefaults`, so its log alone cannot prove visibility or disk durability.

## Local execution attempts

Machine: Mac17,3, arm64; Apple Swift 6.4 (`swiftlang-6.4.0.34.1`), macOS SDK 27.0.
The active developer directory is `/Library/Developer/CommandLineTools`; no
Xcode application was found under `/Applications`. Runs used the isolated
worktree and existing synthetic fixtures; no installed app was launched.

| Command | Outcome on inspected dev SHA |
| --- | --- |
| `swift test --filter RecordingsControllerTests` | Build failed before tests: `TestingMacros` plugin not found. |
| `swift test --build-system native --filter RecordingsControllerTests` | Build failed before tests: module `Testing` not found. |
| Native build with explicit Testing framework, plugin and linker paths | Build failed before tests: `SwiftUIMacros.StateMacro` plugin not found. |
| Default build with explicit Testing plugin path | Build failed before tests: `SwiftUIMacros.StateMacro` plugin not found. |
| `swift test` | Build failed before tests on the same toolchain. |
| `xcodebuild -project Beepbar.xcodeproj -target Beepbar -configuration Release build CODE_SIGNING_ALLOWED=NO` | Cannot run: selected developer directory is Command Line Tools, not Xcode. |

The two diagnostic fallback invocations were:

```sh
swift test --build-system native \
  -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing \
  -Xlinker -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  --filter RecordingsControllerTests
swift test -Xswiftc -plugin-path \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing \
  --filter RecordingsControllerTests
```

These are environment failures, **not passing tests or unsuccessful reproductions**.
There are zero completed local repetitions. The historical green CI belongs to
`39683c2`, not to the current branch. No performance change is proposed; base
dev → HEAD and main → HEAD performance measurements are not applicable to this
documentation delivery. UI latency, resource use and live SSO are unmeasured.

## Decision and next experiment

The original CI failure is verified; its cause remains unconfirmed. Make no
production change, remove no assertion, and add no sleep. Keep #114 open: this
report preserves a partial investigation, not completion of its required proofs.

Resume on a machine or runner with the repository's Xcode 27 toolchain. First
repeat the unchanged failing test in isolation, then the recordings suites with
their existing parallel execution:

```sh
swift test --filter onlyRecordingsPublishedLaterAreNew --maximum-repetitions 50 --repeat-until fail
swift test --filter 'RecordingsControllerTests|RecordingsAccountTests|RecordingsSessionStoreTests' --maximum-repetitions 20 --repeat-until fail
```

Next add a diagnostic fixture matrix with distinct synthetic account IDs and
independent UUID defaults/session roots. Capture callback order, published IDs,
baseline and acknowledged defaults immediately before and after `markSeen` and
before the immediate restart; keep assertions on the actual restored behavior.
Use gates for browser completion rather than additional sleeps. Distinguish
same-object defaults visibility, reopening the same suite, and a genuine process
restart: the existing test proves only controller reconstruction in one process.

If a trace reproduces the failure, reduce it to a deterministic regression and
apply the smallest justified fix, with a mutation proving the regression fails
without it. Otherwise retain repetition counts, exact SHA, toolchain, traces and
an explicitly inconclusive decision. Complete focused tests, full `swift test`,
Release build and independent review on the final candidate; record its online
CI separately. No production or test behavior is changed by this report.
