# Recordings validation — 2026-10-07

Branch: `dev`, reviewed for draft release PR #86 against `main`. Production merge remains gated on local beta testing.

## Automated checks

- `swift test`: 613 tests passed (337 core, 24 benchmark, 238 app Swift Testing, 14 app XCTest), with no known issues. Unchanged course refreshes and sync completion now satisfy the publication-count regressions directly.
- `xcodebuild -project Beepbar.xcodeproj -target Beepbar -configuration Release build CODE_SIGNING_ALLOWED=NO`: succeeded. Existing build-order, Sparkle stripping and AppIntents metadata warnings remain.
- `scripts/quit-probe.sh`: legacy menu and dispatch variants hang as expected; corrected menu and external quit variants exit. This is an isolated AppKit probe, not the installed app.
- `git diff --check`: clean.

## Regression sensitivity

In disposable source copies, each mutation produced test expectation failures, not compilation errors:

| Mutation | Failing test |
| --- | --- |
| Return every course instead of filtering enabled IDs | `sidebarExcludesDisabledCoursesInBothSections` |
| Click the next-page link instead of navigating to its URL | `theNextPageIsLoadedNotClicked` |
| Click the 100-per-page link instead of navigating to its URL | `severalPagesSwitchToAHundredAPage` |
| Remove the fallback for an entirely unsearchable course list | `selectionFallsBackWhenEveryCourseLacksCodeOrYear` |
| Start Sparkle automatically in Debug | `debugBuildDoesNotStartSparkle` |

Presentation coverage also checks title fallback, search, durations, stable chronological numbering, Monday week boundaries across daylight-saving time, empty lists and older year/month ranges.

## Independent review

The first review identified a P2: the detail pane was empty when every synchronized course lacked a code/year. The selection fallback was corrected and tested. The same reviewer re-reviewed the change and reported no remaining actionable findings. No P0 was reported.

The release review found three further issues: an older conflict with identical remote bytes could authorize recovery of a newer revision; a slow recording lookup could supersede a newer Play/Copy choice; and a failed benchmark subprocess could reuse an old successful report. All were corrected with regression coverage. The recovery and recording regressions failed before their fixes, as did the three unchanged-value publication assertions. Independent follow-up review of these fixes and the benchmark subprocess tests reported no remaining actionable findings.

## CI follow-up

The initial CI run exposed a wall-clock assertion in `menuQuitGivesUpWaitingAfterTheTimeout`: the overloaded runner resumed after the two-second threshold. The test now holds a cancellation-resistant sync at a gate and verifies that quit returns before that sync finishes. A 30-second watchdog releases the gate so a regression fails rather than hanging indefinitely. Production quit behavior is unchanged.

## Verification limits

The existing live probe is `scripts/recman-probe.sh cold <course> <year>` followed by `warm`. Real Polimi sign-in, session expiry and playback were not repeated during this completion pass. Browser tests use WebKit fixtures and controller tests use a fake browser; a Release build and passing fixtures do not establish live SSO success.

## Recordings UI follow-up

- Full `swift test`: 614 tests passed (337 core, 24 benchmark, 239 app Swift Testing, 14 app XCTest). The Release build with signing disabled also succeeded.
- All nine presentation tests passed. Returning the unprocessed course name caused four assertions in the new name-formatting regression to fail; restoring the implementation made them pass.
- Offscreen renders checked compact and wide layouts, long titles, visible Play controls, and English/light and Italian/dark appearances. These used an isolated fake browser and preferences, without launching or replacing the installed app.
- Independent review identified a P2 concerning courses with identical readable names. Keeping course code and academic year visible in the sidebar resolved it; the same reviewer reported no remaining actionable findings.

## First-use introduction follow-up

- Without reusable saved cookies, the first page visit shows the existing introduction and sign-in button before creating a browser or fetching recordings. Session checking remains deferred until the page opens; matching saved sessions still load automatically.
- Focused controller/account tests: 36 passed. Removing the production fix caused six failures in the first-use regression; restoring it made the focused suite pass again.
- Full `swift test`: 618 tests passed (337 core, 24 benchmark, 243 app Swift Testing, 14 app XCTest). The unsigned Release build and `git diff --check` passed.
- Independent Sol 6.1 medium review reported no actionable findings. Coverage includes missing, empty, expired, corrupt, unreadable and wrong-owner sessions, matching saved-session reuse, disabled behavior, page reconstruction and explicit sign-in before the first visit.
- Live Polimi sign-in and the installed beta were not exercised for this change.


## Embedded sign-in recovery and playback positions (2026-10-13)

Local worktree `fix/recordings-signin-recovery` starts from dev `0c9d033b322e0eec272cbc83567461c091307db9`; the delivery is committed for integration into dev; the installed app is unchanged. The delivery PR records the final commit and CI results. The screenshot reports “Il servizio richiesto non è presente.” A cookie-free GET of service 2314 returned the normal sign-in page. This does not prove the server-side cause of the user's earlier failure: no personal SSO session was replayed.

- Explicit sign-in after `needsSignIn` creates the existing nonpersistent browser with no saved cookies, while retaining session-owner checks. A still-reusable session keeps its warm path.
- The visible service-unavailable text on a trusted Polimi login host finishes the navigator with failure, including after the sign-in window has appeared. Hidden page text does not trigger it. The existing error UI permits retry.
- Disabling Recordings previously removed `resumePointsKey`. It now closes the player while the playback identity is still valid, stores the final checkpoint, and preserves positions across re-enable/relaunch. Disconnect, university change and account change still clear positions and refuse the closing player's final report. Already removed positions cannot be reconstructed by this fix.
- Tests use synthetic preferences, cookies and WebKit fixtures. Live Polimi/SPID login and actual Apple Passwords selection have not been validated.

## Apple Passwords with an internal window: API investigation (2026-10-13)

The required experience is Apple Passwords suggestions directly in the website fields inside the existing BeepBar window, as in Safari. Neither opening Safari nor adding a separate native credential panel meets the clarified requirement. The following APIs have different roles and must not be treated as interchangeable switches.

| Mechanism | Public support / constraint | Decision for BeepBar |
| --- | --- | --- |
| HTML `autocomplete=username/current-password/one-time-code` | Apple documents semantic hints for web inputs. They help a supported AutoFill implementation identify fields; they do not themselves enable the macOS Passwords picker in a WKWebView. | Verify actual login markup before changing hints. No blanket rewriting of third-party forms. |
| AppKit `NSTextField.contentType = .username`, `NSSecureTextField.contentType = .password` | Apple explicitly documents AppKit AutoFill since macOS 11; these declarations are present in the local SDK. | Applies to native AppKit fields, not HTML fields in WKWebView. A separate native credential panel does not meet the clarified requirement and will not be added. |
| `ASAuthorizationPasswordProvider` | Available on macOS, but website credential sharing requires the app/site association and user consent. The request has no arbitrary target-domain parameter in the SDK. | Cannot independently request the user's Polimi/Sielte password by adding a domain to BeepBar's entitlement; the site administrator must approve the app in its AASA file. |
| System AutoFill context menu | WWDC24 describes inserting usernames, passwords or codes into text fields. Its `ProvidesTextToInsert` configuration belongs to a credential-provider extension. | Preserve WebKit's default context menu. BeepBar is a consumer; adding provider plist keys does not grant access to Apple Passwords. Generic manual selection differs from domain-filtered suggestions. |
| `performAutoFillAssistedRequests()` | The local AuthenticationServices header marks it unavailable on macOS. | Not a macOS WKWebView solution. |
| `ASCredentialDataManager.save(password:for:title:anchor:)` and `ASAutoFillURLScope` | Save/update credentials; requires webcredentials association or the browser entitlement. | No read/select-credentials API; not a solution for filling an existing Polimi password. |
| `ASAuthorizationWebBrowserPublicKeyCredentialManager` | Browser access to passkeys / WebAuthn challenges. | Does not expose saved ordinary passwords. |
| macOS 27 `WKContentWorld.Configuration.autofillScriptingEnabled` | Enables extra capabilities for app-authored autofill scripts; Apple's documentation says it does not change default WebKit behavior. | Not an Apple Passwords enablement flag. |
| `ASWebAuthenticationSession` | System-mediated web authentication, requiring an appropriate callback contract. | Does not meet the retained embedded WKWebView/cookie flow as a drop-in replacement. |

The code retains the WebKit context menu and routes Cmd-V through the responder chain; there is no existing overridden context menu suppressing Passwords. No public API was identified that guarantees Safari-style password suggestions for arbitrary third-party domains in this macOS WKWebView. This is a scoped research result, not proof that every future system context-menu path is impossible.

The earlier native-panel recommendation is withdrawn following the clarified requirement. No panel or credential-transfer bridge was added. Direct in-page Apple Passwords suggestions remain unimplemented: the documented native-field APIs do not establish support for this WKWebView, and HTML autocomplete hints alone are not evidence of a working integration. The branch does not advertise Apple Passwords integration or add private APIs.

Primary sources consulted:

- [Apple: AutoFill everywhere, WWDC20](https://developer.apple.com/videos/play/wwdc2020/10115/) — AppKit fields and content types.
- [Apple: HTML AutoFill hints](https://developer.apple.com/documentation/security/enabling-password-autofill-on-an-html-input-element).
- [Apple Platform Security: app access to saved passwords](https://support.apple.com/en-ca/guide/security/sec8762eb992/web) — mutual app/site approval and consent.
- [Apple: credential managers, WWDC24](https://developer.apple.com/videos/play/wwdc2024/10125/) — text insertion and provider capabilities.
- [Apple: ProvidesTextToInsert](https://developer.apple.com/documentation/bundleresources/information-property-list/providestexttoinsert).
- [Apple: credential save API](https://developer.apple.com/documentation/authenticationservices/ascredentialdatamanager/save(password:for:title:anchor:)).
- [Apple: browser WebAuthn support](https://developer.apple.com/documentation/authenticationservices/password-use-in-web-browsers).
- [Apple: WKContentWorld.Configuration](https://developer.apple.com/documentation/webkit/wkcontentworld/configuration).

Verification: the complete suite passed 1,104 tests (530 core Swift Testing, 31 benchmark Swift Testing, 529 app Swift Testing, 14 app XCTest); the unsigned Release build and `git diff --check` passed. Independent review found an account-owner cleanup edge case after disabling; it was fixed and the same reviewer reported no remaining actionable findings. The regression covers retaining positions for the same account and removing them for another account even with no remaining Polimi session.

In a disposable source copy, removing fresh-cookie retry, service-error classification and toggle preservation caused assertion failures in their new regressions. Separately removing owner cleanup while retaining toggle preservation failed the owner-change regression. No compilation failure was counted as regression evidence. The complete suite passed again on the original sources after those mutations (the same 1,104 tests). No app-wide performance claim is made; comparative performance measurements are not applicable to these correctness fixes.

## How to run the live sync measurement

`scripts/recman-probe.sh sync` measures one background refresh the way the app does it at a sync: one entry into the archive from the saved probe session (`RecmanWebSession.recordings(for:)` enters in the background on its first call), then each requested course listed in turn. It is the evidence step of the Recordings cost model; **it contacts Polimi with the owner's saved session, so it runs only on the owner's explicit go, never by an agent or in CI.**

```
scripts/recman-probe.sh warm 058167 2026                      # once, if there is no saved session yet (cold signs in by hand)
scripts/recman-probe.sh sync 058167 2026                      # one course
scripts/recman-probe.sh sync 058167 2026 051234 2025          # several courses, sequential, one entry
scripts/recman-probe.sh sync 058167 2026 --dry-run            # no network: checks arguments and output format only
scripts/recman-probe.sh sync --help
```

Course codes are 6 digits and years 4 digits; anything else prints the usage and exits 2 before anything is built. Exit 0 means every listing completed; 1 means a failure, `needs-sign-in` (run `cold`) or no saved session.

What the lines mean:

- `ENTRY`: time, finished page loads and failed loads for the background entry, number of entries (more than 1 means the session lapsed mid-run and the app's retry fired), and the navigator's outcome.
- `COURSE n`: listing time with the entry subtracted, page loads, result pages read, recordings found (a count), whether the listing was complete, and whether the entry happened inside this course's call (normally only course 1).
- `TOTAL`: web session opened to last listing.
- `MEMORY`: resident size of the WebKit helper processes (WebContent, Networking, GPU) started by the run, before, at peak (sampled every 250 ms) and after closing the web view plus a 2 s settle. Helpers are XPC services, not children, so they are identified as "appeared after the run began and answer to the same responsible process as the probe"; helpers that already existed are not counted. Run it with no other WebKit app starting at the same time. A helper or two may still be alive after the settle: that is WebKit's own lingering and is part of the answer.
- `COOKIES`: whether the session cookie fingerprint (value and expiry hashed, never printed) differs between the start and the end, using the same rule as `RecmanSessionVault`. `yes` means every sync would rewrite the session file; the counts say whether values or only expiries moved.
- `SIGN-IN`: whether the entry needed the user. The mode never shows a window and never types; it reports `needs-sign-in` instead.

Not printed, by construction: any address (even redacted), cookie name or value, ticket, title, course code or e-mail. Courses are numbered, and every line passes a guard that withholds anything URL-, mail- or ticket-shaped. Not measurable from WKWebView: bytes received and sub-resource requests (printed as `n/a`); "page loads" are finished main-frame loads only. The saved session is read, never rewritten, so the run can be repeated.
