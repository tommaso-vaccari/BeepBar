# Repository instructions

This file contains the general workflow and project rules shared by the team. Put all other context in `AGENTS.override.md`, including personal preferences, machine paths, private links, and current local or session state.

Read `AGENTS.override.md` first when it exists. It stays untracked and must never be copied into shared files, commits, PRs, or comments.

## Starting or resuming work

Every agent must establish context from the shared repository and GitHub before implementing a task:

1. Read [team workflow](docs/team-workflow.md) for task ownership, handoff, verification, and delivery rules, and [product direction and performance plan](docs/performance-plan.md) for priorities, dependencies, evidence, and acceptance criteria.
2. Read the relevant [behavior specification in Italian](docs/sync-behavior.it.md) and [English](docs/sync-behavior.en.md). These define the behavior to preserve; the performance plan defines improvements within those guarantees. Read [benchmark documentation](docs/benchmarks.md) before measuring performance.
3. Inspect the current [GitHub issues](https://github.com/tommaso-vaccari/BeepBar/issues), the [performance delivery tracker](https://github.com/tommaso-vaccari/BeepBar/issues/116), the selected issue's full discussion, dependencies, linked issues and PRs, and their current status. Use the task requested by the user; when asked to choose, select an unassigned issue whose prerequisites are satisfied, following the plan's priorities. Do not duplicate work already assigned or in progress. The tracker's assignee does not own every child issue.
4. Verify the checkout, branch, local changes, and current remote base. Recheck historical findings against current code; an old audit, chat, or override does not prove that a bug or dependency is still open. Before implementing, state the issue, base commit, scope, risk level (see the delivery loop), dependencies, and completion criteria.
5. Recover all context relevant to the selected task: issue bodies and comments, dependency decisions, linked PR discussions and reviews, existing reports, and related earlier chats when accessible and authorized. Search by issue number, task identifier, branch, and affected component; follow relevant references until scope, decisions, evidence, and open questions are understood. Do not assume access to other agents' chats or rely on them for essential context. Verify historical claims against current sources and preserve necessary non-private decisions or evidence in the issue, PR, or shared documentation. If required context remains unavailable, identify the gap and ask the user rather than guessing.
6. Before pausing or handing off, record the branch/commit, PR, completed work, uncommitted changes, verification results and their SHA, unresolved findings, blockers, and next step in the shared issue or PR within the authorized scope. Keep personal details in the override. Another agent must be able to resume from shared sources without this chat.

## Issue ownership and keeping the plan current

- Every PR must mention all related open issues and include `Closes #<issue>` for each issue whose acceptance criteria it fully satisfies; leave partially resolved issues open and state the remaining work. After merging into `dev` (or another non-default branch), manually close each fully resolved issue with a link to the merged PR and verify its closed state immediately, without waiting for a release to `main`; GitHub automatic closure applies when the PR reaches the default branch.
- Selecting an issue means taking responsibility for its delivery. Before implementation, assign it to the responsible team member using their authorized GitHub identity and record the working branch, base SHA, dependencies, scope, and completion criteria. Recheck ownership immediately before claiming it; never take over or reassign another member's task without agreement. If GitHub access prevents recording ownership, report the coordination blocker before starting overlapping work.
- Keep the issue, linked PR, relevant tracker entry, and `docs/performance-plan.md` consistent when work starts, scope or dependencies change, evidence changes a finding, work pauses, or delivery completes. The issue is authoritative for live ownership and operational status; the plan records the current roadmap, findings, decisions, and delivery evidence with issue/PR links. Do not store shared progress only in a chat or private override.
- Update the relevant plan sections in every performance delivery PR, including investigations ending without a fix. Record measured results, exact SHAs, commands/report references, regressions, limitations, remaining work, and the decision. Follow the plan's requirements for both base-dev → HEAD and main → HEAD comparisons; unavailable measurements stay explicitly unmeasured. An open PR is not integrated work, and integration into `dev` is not a released feature. A PR that is not performance work writes in the plan only when it changes one of the Performance budgets below or a finding the plan records; otherwise its measurements go in the PR description.
- Explain how the proposal and final result satisfy the principles below, especially any affected guarantee or trade-off. If shared sources disagree, resolve or report the discrepancy rather than silently choosing one. Coordinate edits to shared plan sections with concurrent tasks and preserve unrelated changes.

## Core product principles

BeepBar provides up-to-date course materials, protects students' local work, and makes recordings accessible through a responsive native app with minimal attention and resource use. These principles apply to every feature, fix, investigation, and review; their detailed criteria remain in the performance plan and behavior specifications. Keep these summaries aligned when an explicitly agreed product decision changes them.

1. **Protect user data.** Never lose or overwrite local changes without the specified user choice. Preserve three-way sync, containment, checks at the point of action, atomicity, journaling, and recovery.
2. **Respond immediately with useful content.** Keep menus, windows, and actions responsive during work. Show known content immediately and refresh in the background; an empty window is not useful content.
3. **Be nearly free at rest.** Avoid unnecessary CPU, network, writes, timers, and memory growth when no work is due. Release tasks and resources after completion.
4. **Make cost proportional to necessary work.** Avoid repeated reads, hashes, queries, writes, and identical publications while retaining checks required for correctness, including locally deleted files.
5. **Preserve freshness.** Respect the configured interval and acquire updates when available. Optimize each check instead of delaying or skipping it; preserve the specification's explicit network and energy policies.
6. **Bound resources during work.** Bound response reception, memory, concurrency, and queues. Stream large files and avoid UI work proportional to every list element on each event.
7. **Make cancellation real and state truthful.** Stop interruptible work promptly; finish or recover atomic changes safely. Distinguish saved, refreshing, paused, failed, cancelled, and completed states; reject stale asynchronous results.
8. **Preserve identity and compatibility.** Scope caches and results to site, account, root, and operation. Prevent old identity data returning after logout or account changes; verify migrations and rollback for users who skip releases.
9. **Prove benefits with the smallest justified change.** Reproduce or measure first, prioritize correctness and blocked user actions, and report regressions and uncertainty. Never trade guarantees for benchmark gains or infer app-wide responsiveness from Core measurements. Use isolated synthetic data; real-account validation requires explicit authorization.

## Build and verification

- Verify in proportion to the change's level (see the delivery loop below). Prefer tests that exercise real behavior and would fail without the change; avoid tests that merely repeat the implementation. Report any behavior that could not be exercised locally and why.
- Run focused tests while developing. The full suite and the CI Release build run once, in the pre-push gate, on the final commit.
- Do not sign, install, or replace an installed app unless explicitly requested. Use isolated fixtures for verification; a normal local build shares its identity and persisted data with the installed app.

## Product and releases

- BeepBar has users beyond its developer. Treat persisted data, migration paths, update behavior, and release regressions as user-facing concerns.
- Before removing compatibility code, account for users who may skip releases or leave the app unopened for months; require evidence that their stored data has been migrated or provide a safe upgrade path.

## Workflow

- Keep unrelated user changes untouched.
- Do not commit or push unless explicitly requested.
- No agent attribution anywhere: branch names never contain `claude` (or `codex`, or any tool name) — use descriptive prefixes like `feature/`, `fix/`, `perf/`; commits and PR bodies never carry `Co-Authored-By: Claude` or similar trailers. If a worktree or tool auto-creates a `claude/...` branch, rename it before pushing.

## Delivery loop: rigor proportional to risk

A check earns its time only if it can find something in the change at hand. Pick the change's level before starting, state it with the scope, and write it in the PR. A change that spans levels takes the highest one; when unsure, take the higher.

| Level | The change touches | Required |
|---|---|---|
| 1. User data | Sync, conflicts, recovery, journaling, deleting or moving files, stored-data migrations, account identity and logout cleanup, the quit path, AppKit isolation | Proving tests, mutation checks, independent review, full gate |
| 2. Product behavior | Any other app or Core code (interface, Recordings, audio, menus, performance), and the tooling that gates or ships releases (`.github/workflows`, `.githooks`, `scripts/verify.sh`, version and release-note scripts) | Proving tests where the code is testable, independent review, full gate |
| 3. Nothing shipped | Documentation, tests, benchmark harness, development scripts | Full gate |

Why the levels differ: on PR #245 (level 2) thirty mutation checks, each with its own cold build, found nothing the tests did not already cover, while the independent review found two P1s and a real end-of-file bug. Mutation checks stay where a silent gap costs a user their files.

1. **Implement** in its own worktree from `dev`, on a `feature/`, `fix/`, `perf/` or `docs/` branch, committing without pushing.
2. **Test to prove, not to pass** (levels 1 and 2). Cover the main path and the edge and failure paths this change can meet: permission denied, missing file, cancellation, a language switch, a first launch after updating, and what existing users see. For a bug, write the test first, see it fail on the unfixed code, and name it in the PR: a test seen failing needs no mutation check.
3. **Mutation checks** (level 1 only). For each guarantee the change adds or alters, remove the behavior and see a test fail. Use a temporary commit or `git apply -R`, never a bare `git stash`. Run mutations of code that deletes or moves files in a disposable copy (`git worktree add --detach` in a temporary folder), never in the working checkout: a mutated path can resolve to the current directory, and `swift test` runs from the checkout.
4. **Document for the next agent.** Code gets `///` comments on role, invariants and the reason behind non-obvious choices. Each test says what it proves and which failure it guards against.
5. **Independent review** (levels 1 and 2). One pass on the final diff by a senior subagent that did not write the code, against this file and `docs/sync-behavior.{it,en}.md`. It looks for bugs, missing edge cases and tests that would pass even when the behavior is broken, and grades each finding: P0 (data loss, a broken hard rule, a crash), P1 (wrong behavior a user can meet), P2 (anything else).
   - **P0:** fix it with a regression test, then a **different** reviewer does a full pass.
   - **P1:** fix it with a regression test; the **same** reviewer checks the fix alone, not the whole diff again.
   - **P2:** never reopens the review. Fix it in passing, accept it in the PR description with the reason, or open an issue.
   - The review is closed when no P0 or P1 is open.
6. **Present the result in chat**: the level, what was tested and reviewed, what could not be exercised. Push and open the PR to `dev` only after the user's go.
7. **The full gate runs once, at push**, on the final commit: the pre-push hook runs `bash scripts/verify.sh`. Do not run the full suite and the Release build beforehand as well. If the gate fails only in a test that passes when run alone and is listed in an open flaky-test issue (currently #243), rerun once and record the failure in that issue; if it fails again, ask the user before bypassing the hook.
8. **No bars beyond these.** Repeated full-suite runs, extra review rounds and mutation checks below level 1 are added only when the user asks or a concrete doubt about this change calls for one; name the doubt.
9. When the user has authorized merging into `dev`, require the full local gate on the exact pushed commit, a clean worktree, and a branch containing the latest `dev`. Merge with a merge commit. If the destination changes, update and verify again before merging. PRs into `dev` do not wait for online CI. Release PRs (`dev` → `main`) always wait for green online CI as well as local verification.

## Branches and releases (`dev` → `main`)

Every push to `main` that touches production paths publishes a Sparkle release to every user (`release-artifact` job in `.github/workflows/ci.yml`). `dev` exists so work can accumulate without shipping.

- `main` stays the repository's default branch: it is what visitors see and what the README and download links describe. It only ever holds released code.
- Feature branches start from `dev`, and ordinary PRs target `dev`: always `gh pr create --base dev`. Stacked PRs use the predecessor branch as described below. GitHub proposes `main` because it is the default branch, so the base must be set explicitly every time. A feature PR opened against `main` by mistake is retargeted to its intended base before merging, never merged into `main`.
- PRs into `dev` and development pushes use the local gate: install it in each clone with `git config --local core.hooksPath .githooks`. The pre-push hook requires a clean checkout of the commit being pushed and runs `bash scripts/verify.sh`. It never installs or launches the app. Hooks are a local convention and can be bypassed; they cannot enforce PR creation or GitHub UI merges.
- Online tests run only for PRs from `dev` to `main`. Pushes to `main` retain release packaging/publication but do not repeat tests. No manual CI runs. `dev` never publishes a release.
- Releasing is the user's decision alone: never open, approve, or merge a `dev` → `main` PR unless the user explicitly asks for a release. Merge it with a merge commit (not squash or rebase), so `main` and `dev` keep a shared history and later release PRs stay clean.
- Hotfix for released code: branch from `main`, PR to `main` (this ships immediately, so only on the user's request), then merge `main` back into `dev` right away. These PRs use the local gate only: online tests are deliberately limited to `dev` → `main`. If online validation is required for a hotfix, route it through `dev` → `main`.
- Release PR (`dev` → `main`) protocol:
  - Before release, complete the final GDPR/privacy review against the release code and binary using the Compliance Wiki verification plan. Update its evidence and unresolved findings; integrating the wiki into `dev` does not establish full compliance.
  - `CHANGELOG.md` must be updated in the same PR: it is what users read, since the Sparkle update dialog links to it on `main`.
  - Move the `## Unreleased` entries under a dated heading (`## YYYY-MM-DD`) and leave a fresh, empty `## Unreleased` on top. The version number is assigned by CI at merge time, so it is not written by hand: it follows the last `v*` tag (next patch), and raising `MARKETING_VERSION` in `project.pbxproj` starts a new line at patch 0 (`scripts/build-version.sh`).
  - Write for users, not developers. Describe what changed in what they see and do: what now works, what no longer goes wrong, what to expect after updating. Mention the app's own labels (e.g. "Sincronizza ora") when they help. No type, function, or file names, no database or implementation terms (baseline, hash, lease, journal…), no PR mechanics.
  - Keep each entry short: one or two sentences, most important first. Group under `### New`, `### Improved`, `### Fixed`. Merge related PRs into one entry, and drop internal-only changes (refactors, tests, CI) that users cannot notice.
  - Call out anything that happens by itself on the first launch after updating (a migration, files being moved, a one-time permission prompt), so nobody is surprised.
  - Start the dated section with `### Release highlights`: prepare about five short user-facing bullets and an optional `**After updating:**` paragraph for first-launch changes. CI publishes only this summary on GitHub and links to the full dated changelog; keep the detailed New, Improved and Fixed sections below it. A missing or empty summary blocks publication, and so do entries left under `## Unreleased` and notes identical to the last published release's (`scripts/release-notes.sh`, issue #210).
  - The PR description summarizes the release in the same terms and lists the PRs it includes.
- Feature PRs to `dev` add their user-facing entry under `## Unreleased` in the same style, so the release PR only has to tidy it up.

## Stacked PRs (when useful)

- Use a stack when a change has dependent steps that are easier to review separately. Prefer ordinary PRs for small fixes or independent changes; do not split work just to create a stack.
- The first branch starts from and targets `dev`; each subsequent branch starts from and targets its immediate predecessor. Set `gh pr create --base <predecessor>` explicitly. Every layer contains one coherent change, its relevant tests, and any required documentation or changelog update.
- Before implementing a stack, briefly explain its layers and dependencies. This does not authorize commits, pushes, PR creation, or merges: existing authorization rules still apply.
- In each PR description, link the predecessor and successor PRs when available, state the dependency and merge order, and describe only that layer's change and validation. Validate each layer with its dependencies present; keep every layer buildable and testable.
- Merge from the bottom upward. After a predecessor is merged, retarget the next PR to `dev` and update its branch so the diff contains only its own changes. If the predecessor was squash-merged or rebased, use an explicit rebase boundary (for example `git rebase --onto dev <old-predecessor-tip> <child>`) rather than replaying the predecessor's commits. Record the old boundary before updating branches.
- After updating a layer, propagate changes through its descendants, inspect each PR diff, and rerun the required checks on the resulting commits. Never rewrite shared branches without authorization; when an authorized update requires a force push, use `--force-with-lease`.
- A stack integrates into `dev` only. Release and hotfix rules remain unchanged.

## Expected sync behavior

- `docs/sync-behavior.it.md` and `docs/sync-behavior.en.md` are the agreed specification of what sync does and what the user sees. Read them before changing sync, conflict, recovery or folder code, and review PRs against them.
- A PR that changes any behavior described there updates both files in the same PR, keeping them identical in content. Behavior not yet released is marked **[non rilasciato]** in the Italian file and **[unreleased]** in the English one; the release PR (`dev` → `main`) removes those markers. Markers that carry a PR number (e.g. **[PR #236]**) were written before this rule: they mean the same and are removed the same way. The number is not needed, and it is not known until the PR is open.
- If code and document disagree, that is a bug in one of the two: raise it with the user instead of silently picking one.

## Comments are part of the change

- Critical or non-obvious code gets a comment explaining *why* and the failure it prevents (see `StatusItemController` / `menuBarSnapshot` on the SIGBUS crash, `ConfigurationWindowController.show`, `resolveNeedsOnboarding`). Cite the issue or PR number when there is one.
- Invariants a future edit could silently break are spelled out where that edit would happen (e.g. `menuBarSnapshot` lists every property that must call `refreshMenuBarSnapshot()`; update the list when adding one).
- Types and non-trivial functions get a short `///` summary of their role. Don't comment the obvious; match the surrounding density; explain the reason, not the mechanics.
- When behavior changes, update the comments that describe it in the same change.

## Hard rules

- AppKit callbacks never touch `@MainActor` state synchronously. `StatusItemController`'s `NSMenuDelegate` and target-action methods are `nonisolated`, read only `menuBarSnapshot`, and hop to the main actor with `Task { @MainActor in … }`. Data flows the other way by pushing from the main actor (e.g. `onMenuBarSymbolChange`). Breaking this brings back the wake-from-sleep SIGBUS crash (issue #30).
  - The crash returned when isolation was crossed from an AppKit callback, including after a rewrite that seemed to remove it (#31). Preserve the main-actor hop.
  - Do not replace it with `DispatchQueue.main.async`, `MainActor.assumeIsolated`, `RunLoop.main.perform`, `perform(_:with:afterDelay:)`, or by marking these methods `@MainActor`.
  - Do not point a menu item's target/action at a `@MainActor` method or at `NSApp`.
  - To fix a problem on a menu path, change what runs *inside* the hop, never the hop itself.
- Quitting from the menu must never wait inside `applicationShouldTerminate`.
  - **Mechanism:** the menu's quit runs inside the `Task { @MainActor in … }` hop, which is a main-queue job. If it calls `NSApp.terminate` and the delegate answers `.terminateLater`, AppKit spins a nested loop that never runs main-actor work. The awaited task, the 5-second cap, and every later menu action all stall, and BeepBar never quits.
  - **Evidence:** verified on 2026-10-06 with a standalone AppKit probe. `DispatchQueue.main.async` hangs the same way, so it is not a fix. Quit requests from outside arrive from the event loop and work: Sparkle's installer, logout, `osascript`.
  - **Rules:**
    - The menu path finishes its shutdown work first, then calls `terminate` only when nothing is left pending.
    - `prepareForTermination` stays cheap and synchronous: no file, WebKit, Keychain or network work, and never a task that is always present (a Recordings branch made every quit hang this way).
    - Never add work to the quit path without rerunning `scripts/quit-probe.sh`, which checks both a menu quit and an external quit against real AppKit.
    - How it is built: `quit()` keeps the hop and inside it awaits `prepareForMenuQuit()` (cancel the sync, wait at most 5 s), which sets `menuQuitDrained`; only then `NSApp.terminate`, which `terminationReply` answers `.terminateNow`.
- All user-facing text goes through `tr("italiano", "English")` from `BeepbarCore/Localization/AppLanguage.swift`, including Core-generated reasons and errors. Use `englishCount` for English plurals and `BilingualText` for app-layer text stored and shown later (failure states, errors) so it follows a language switch. Sync failure reasons in Core (`courseFailure`, `failedItems[].reason`) are plain strings in the language active during that sync; changing them means a backward-compatible `Codable` migration. Don't cache resolved strings in `static let` / `lazy var`. New menu bar text belongs in `MenuBarSnapshot`.
- Local files are never overwritten without the user's choice; sync, conflict and recovery code is built around this guarantee.

## Code structure and green checks

- Two build systems: every app source file must also be registered by hand in `Beepbar.xcodeproj/project.pbxproj`; new Core files are picked up through the Swift package.
- The single executable gate is `bash scripts/verify.sh`, used by `.githooks/pre-push` and the GitHub `Test` job. It runs tooling checks, the full Swift suite, release-note/version checks, the Release build, and arm64/plist/assets/Sparkle/signature checks. Keep local and online checks in that script instead of duplicating their command lists.
- Install the hook in each clone with `git config --local core.hooksPath .githooks`. Every non-deletion push must refer to the checked-out HEAD with a clean tree before and after verification. Commit locally as often as useful; the full gate runs at push time. Do not bypass the hook for delivery.
- Not in the gate: `scripts/quit-probe.sh` (required for quit-path changes), `scripts/linux-core-tests.sh` (requires Linux; runs in the release PR Linux Core job). The isolated recordings fixture is included in the gate.
- Put decision logic in pure `nonisolated static` functions so Swift Testing can cover it (`resolveNeedsOnboarding`, `resolveLanguage`, `menuBarSymbol(for:)`, `MenuBarActionPolicy`).
- `AppLanguage.current` is process-global and tests run in parallel: never switch it inside a test; existing assertions rely on the Italian default.

## Performance

Being fast, reactive and nearly free in the background is a product feature. Performance work follows these criteria.

- Three promises:
  - **Quiet at rest:** with the window closed, no CPU, network, disk writes or memory growth beyond the scheduled check.
  - **Instant when touched:** the menu, the icon and the window respond within a frame and show useful content straight away (cached data first, network refresh in the background).
  - **Cost proportional to what changed:** a run with nothing new costs almost nothing, locally and on the network.
- **Freshness is not a budget to cut.** Automatic checks keep running at the interval the user chose, and new files are downloaded when they appear. Idle savings come from making each check cheaper, never from checking less often, delaying downloads or skipping runs.
- Performance never trades away sync guarantees: local files never overwritten without the user's choice, three-way sync, cancellation, atomicity and recovery, compatibility of stored data. The hard rules above apply unchanged.
- Provisional budgets. Replace each one with a measured baseline once the harness exists:

  | Moment | Budget |
  |---|---|
  | Idle, 30 min, window closed | ≈0% CPU, no wakeups attributable to Beepbar, 0 bytes network, 0 disk writes (documented exception: the daily telemetry check-in, at most one request and one preferences write per UTC day; see `docs/performance-plan.md`) |
  | After 10 consecutive syncs, or after closing the window | memory back to its previous level (±2 MB), no leftover tasks or timers |
  | Launch | icon in ≤ 200 ms; main thread never blocked > 16 ms in any flow |
  | Menu | `menuNeedsUpdate` ≤ 1 ms; icon updates in the same main-actor turn as the state |
  | Window | key in ≤ 250 ms (cold) / ≤ 100 ms (warm); course list visible immediately; no hitch with 100 courses |
  | Run with nothing new | ≤ 50 ms local work per 1000 tracked files, no file hashing, no database or disk writes, minimal requests |
  | Run with new files | peak memory independent of file size; throughput bound by the network |
  | Cancel | stopped within 1 s (p95), even mid-way through a large file |

- Measurement:
  - Use `scripts/benchmark.sh compare --main origin/main --base-dev origin/dev --candidate HEAD --out PerformanceReports/<unique-name>` for both required comparisons. Follow the [single-command agent procedure](docs/benchmarks.md#reproducible-ref-comparisons-single-agent-command) for prerequisites, compatibility adjustments, validation and retained evidence; incompatible native fixtures must fail unless an explicit measurement-only adjustment is recorded.
  - Release build (arm64), synthetic corpus only, never real WeBeep data or the user's account.
  - Use the existing `PerformanceTrace` signposts and the `Beepbar-Profile` scheme.
  - Idle is observed over 30-minute sessions.
  - Report the median and p95 of five warm runs, on the same machine and power source. Record the hardware used with the results.
- Safety:
  - Never launch a locally built Release app: it shares the bundle id, and with it UserDefaults, `sync.sqlite`, the token and the scheduler id, with the user's installed copy.
  - Idle is measured passively on the installed copy, by pid, without changing its state.
  - Sync, database and filesystem work is measured at Core level, against a local fixture and a mocked `URLProtocol`.
- Harness:
  - The benchmark harness is a permanent, reusable part of the repository: corpus generator, network mock with a request counter, database write counter, idle measurement script.
  - Benchmarks run on demand and don't slow the regular `swift test`.
  - Extend the harness rather than writing one-off scripts.
- Subagent workflow:
  - Each subagent works in its own git worktree from `dev` and commits there, without pushing.
  - The main session reviews the work and presents it in chat.
  - The branch is pushed and its PR opened against `dev` only after the user's explicit go.
- Every performance PR:
  - Targets `dev`, or its predecessor branch when part of a stack that integrates into `dev`. Releasing to `main` is the user's decision alone.
  - One fix per PR. The description shows before/after numbers for the budget it touches.
  - Adds a regression test when the property is testable (e.g. "a run with nothing new writes nothing", "unchanged files are not hashed", "sync progress doesn't re-render the course list").
  - Explains the *why* in comments.
  - Adds a CHANGELOG entry only when users can notice the change.

## Compliance knowledge

For GDPR, privacy, or compliance work, first read [Compliance Wiki](docs/compliance-wiki/README.md), its [protocol](docs/compliance-wiki/PROTOCOL.md), and [index](docs/compliance-wiki/90%20Operations/Index.md). Reuse source-backed knowledge, verify affected current code, and refresh relevant official sources for legal decisions or stale/change-sensitive claims. Never store personal author data, private chats, credentials, real cookies, or user logs in this wiki.
