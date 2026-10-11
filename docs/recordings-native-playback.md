# Native recordings playback — investigation and design (#148)

Issue: [#148](https://github.com/tommaso-vaccari/BeepBar/issues/148). Integration branch: `feature/recordings-native-playback` (local until the feature is mature, then one PR to `dev`).

Goal: Play on a recording streams it in a native BeepBar window instead of opening Webex in the browser. Webex sign-in happens automatically in the hidden Recman web view (the Polimi single sign-on is already there), using the user's confirmed Polimi email. Anything that fails falls back to the browser, as before. The feature exists in memory only while used.

All findings below come from `scripts/recman-probe.sh play` / `lab` runs on 2026-10-11 with the account owner's authorization. Outputs are reduced to hosts, paths with ids masked, field names, key names and types: no tokens, cookie values, ids, titles or emails. Webex's web-player API is internal and can change without notice: every step must fail safe to the browser.

## How Webex gets from the player link to the stream

1. The Recman preview gives `https://politecnicomilano.webex.com/<…>/ldr.php?RCID=<id>`.
2. `ldr.php` answers **`302`** with `Location: …/sites/politecnicomilano/recording/playback/<uuid>` (32 hex) **when the request's `Accept` includes `*/*`** — no cookies needed, any User-Agent. With a `text/html`-only `Accept` it answers `200` with a 15 KB page that does not contain the uuid (this misled the first probe). So **no web view is needed for the uuid**: a no-follow GET with `Accept: */*`. A `200` means "unknown layout" → browser fallback. (If a web view were ever needed, cancelling the main-frame navigation to `/recording/playback/<uuid>` yields it in ~0.8 s.)
3. Stream API: `GET https://politecnicomilano.webex.com/webappng/api/v1/recordings/<uuid>/stream?siteurl=politecnicomilano`.
   - Signed out: `403` with a JSON body (`requireLogin`, `canPlayback`, `preventPlayback`, `passwordProtected`, `needPassword`, `preventDownload`, …).
   - Signed in: `200`, with `downloadRecordingInfo.downloadInfo.{hlsURL, mp4URL, dashURL, audioURL, playerCoverURL}`, `mp4StreamOption`, `duration`, `recordName`, `chapterLayout`, `transcriptStatus`, `mediaDetectInfo`, `playerPanels`, `showAISummary`, … (shapes only).
   - Works from a plain `URLSession` with cookies only (no CSRF header, no Referer, no page context). The **only cookie required is `ticket` on `.webex.com`** (session cookie): without it `403`, with it alone `200` (confirmed again ~25 min after sign-in).
   - `requireLogin` is **not** a signed-out flag (it reads 1 on the 200 and 0 on the 403): decide on the HTTP status and on the presence of `hlsURL`.
4. `hlsURL` (`https://nfg1wss.webex.com/nbr/…/hls.m3u8?trackingID=…`) is a single-level HLS playlist of byte-range segments of one 1080p mp4. **AVPlayer plays it without any cookie** (ready in ~5 s; 136-min test lecture). The same URL still played 10 minutes later; longer lifetimes are not measured.

## Webex sign-in

- Signed-out chain: playback page → `webappng/sites/politecnicomilano/login?siteurl,viewFrom,login_return_url` → `idbroker-eu.webex.com/idb/…` → `doSSO.jsp` **email page** (`input#IDToken1[type=email]`, `button#IDButton2[name=btnOK]`) → `idbroker-eu…/globalLogin` → `shibidp.polimi.it` → `aunicalogin.polimi.it`, which **completes on its own with the Polimi SSO cookies** already in the Recman store → back to the playback page.
- The email page comes back whenever Webex's session cookies are missing, even with persistent cookies such as `CK_LastLogin` (1 year); it is never prefilled.
- **Passing the email in the webappng login URL (`…/login?…&email=<address>`) skips the email page** and goes straight to Polimi's IdP (tested with a placeholder address, stopped before the IdP). So no form filling by script is needed.
- With Polimi cookies plus idbroker's session cookies (`cisPRODEUiPlanetDirectoryPro`, `amlbcookie`, `amlbcookiesm`, idbroker `JSESSIONID`) the sign-in is **silent** (no email page): login → idbroker → server redirect → webappng → playback, stream API `200` after ~7 s, and the new `ticket` works from `URLSession`.
- The `email` hint routes by domain: with a `mail.polimi.it` placeholder idbroker posts straight to Polimi's IdP; with `example.com` it shows its own password page; `login_hint` alone is ignored. A full sign-in with a **placeholder** address stalled on a blank `idbroker-eu…/idb/Consumer/metaAlias/<id>/sp` after the Polimi SSO completed (probably because the asserted identity differs from the hint). **Whether the hint with the user's real email completes unattended is unverified** and must be confirmed live with the owner's consent; keep the visible-window fallback.
- Every Webex cookie that matters is a session cookie (`ticket`, `accessToken`, `userHubToken`, the idbroker ones); persistent ones are only `CK_LastLogin`, `wxidIstio`, `CisTrackingID`, `WBX_ttm…`. The v2 session file keeps session cookies, so after a relaunch: `ticket` alive → no sign-in at all; only idbroker alive → silent ~7 s sign-in; nothing alive → hinted sign-in.
- After sign-in Webex sets ~15 cookies (`.webex.com`, `idbroker-eu.webex.com`, `nfg1wss.webex.com`, `politecnicomilano.webex.com`), mostly session cookies; a few short-lived trackers.

## Chosen design

1. `URLSession`, no cookies, no redirects followed, `Accept: */*`: GET `ldr.php` → `302` → uuid from `Location`. Never load the player page (it pulls u2c catalogs, device registration, KMS, telemetry and Amplitude, and would play audio hidden).
2. `URLSession` to the stream API with the Webex cookies of the Recman store (only `ticket` matters) → `hlsURL` → native player (cookie-less).
3. On `403`: sign in to Webex in the hidden Recman web view through the webappng login URL with `email=<confirmed Polimi email>`; Polimi SSO completes; wait for `ticket`; retry step 2 once. If a page asks for the user, the existing sign-in window flow applies. A `200` without `hlsURL` (no HLS for this recording) → browser, without signing in: live, signed out was only ever a `403`.
   - After the sign-in, whatever its outcome, the hidden web view is reset to `about:blank`, so no Webex page keeps running. Whether the final webappng → playback hop is a main-frame navigation (which the navigation policy can cancel) must be confirmed live; if it were in-page (SPA) routing, the `about:blank` reset still bounds its cost to the moments before the ticket is seen.
4. Any unexpected page, status or shape → open the player link in the browser as today.

## Packages and decisions

| Package | Content | State |
|---|---|---|
| A | `PolimiEmail` (only `mail.polimi.it` / `polimi.it`, redacted description) and `WeBeepAPIClient.fetchOwnEmail` (`core_user_get_users_by_field`) | integrated |
| B | `RecmanSessionCodec` v2: email + Webex cookies (`webex.com` on a label boundary), Webex cookies expiring within 12 h not kept; v1 still read | integrated |
| C | `RecordingPlayerController`: one window, nothing before first Play, full release on close, 30 s forward buffer; AVKit loaded with `dlopen` on first Play (linking it adds ~335 dyld images to every launch; images 656 → 920 after dlopen → 1151 with the player); failures reported `.beforeReady` (window closed) / `.duringPlayback(position:)` (paused, window kept); app `.regular` while the player is open | integrated |
| G | Player MVP in `RecordingPlayerController` / `RecordingPlayerControls`: speeds 0.5–3x (`defaultRate`, `timeDomain` pitch set explicitly, last speed in `recordingPlayerSpeed`, written only on change; 2.5x/3x only when the item reports `canPlayFastForward`, 0.5x/0.75x only with `canPlaySlowForward`, both followed by KVO), ±10/30 s skips with a 1 s seek tolerance, window-level shortcuts (decided synchronously from the event, run through a main-actor hop; physical J/K/L/F/M on non-Latin layouts), a title-bar speed menu listing the shortcuts, `play(…, startAt:, recordingID:)`, `onPositionCheckpoint(recordingID, position, duration)` and `onFailure(recordingID, failure)` (checkpoints on pause, close, replacement, mid-playback failure; never periodic, nothing before the item is ready; while a seek or the resume is in flight its target is the position) | on `feature/rnp-player-mvp` |
| D | Core parsing of Webex pages and the stream API answer, URL policy | waits for this investigation |
| E | `RecmanWebSession.stream(for:email:)` per the design above | waits for D |
| F | Controller/UI integration, settings email confirmation, specs, CHANGELOG, compliance wiki, measurements | last |

Decisions by the product owner: native window (not QuickTime Player); email read from the WeBeep profile and confirmed by the user; player MVP = system controls (PiP, AirPlay, Now Playing), speed 0.5–3x, ±10/30 s skips and shortcuts, resume where you left off (saved on pause/close only, tied to the watchlist/seen state), recovery after errors or expired URLs. v2: transcript (VTT) with search, chapters, audio-only (`audioURL`), bookmarks, slide capture, next-lecture queue, floating window. Out: adaptive bitrate (single level), offline download (#87, honour `preventDownload`).

Product decision (2026-10-11): when Webex needs a sign-in and no confirmed Polimi email is available (`RecmanBrowserError.needsEmail`), Play shows the error «Non è stato possibile aprire questa registrazione.» / "Couldn't open this recording." — no Webex email page is shown to the user.

Product decision (2026-10-11): no name/surname field. BeepBar does not store the user's name, username or email today (only the numeric Moodle user id); deriving the email from a name is unreliable (homonyms get numbered addresses, accents, apostrophes, double surnames) and would add personal data. Instead the Recordings settings section gets one **email field**, prefilled from the WeBeep profile (`fetchOwnEmail`, only when `availableFunctions` lists it), confirmed or corrected by the user (validated by `PolimiEmail`), with an explanation that it is used only to sign in to Webex automatically for in-app playback. It is stored only in `recordings-session.plist` and deleted with it (turn off, logout, site or account change). If the profile read fails the field stays empty for the user to fill in.

Requirements recorded for F by reviews: carry the email through the controller's save path and its fingerprint; verify a relaunch reaches the stream without a new Webex sign-in (the 12 h floor must not drop the cookie that matters — `ticket` is a session cookie, so it is kept); any `fetchOwnEmail` failure means "ask the user", never a sync error; specs IT/EN and compliance wiki must say the session file also holds Webex cookies and the Polimi email; measure `otool -L` (no AVKit), dyld images and launch, 30-min idle wakeups, memory after 1 and 10 play/close cycles, `scripts/quit-probe.sh` with the player open.

Player ownership and lifecycle for F (from C's review): the long-lived `RecordingsController` owns the player; call `close()` on logout, Recordings disable and account change (the stream belongs to the old identity), but **not** from `windowClosed()` (a lecture keeps playing with the settings window closed). The player has no deinit teardown. While BeepBar is `.regular`, ⌘Q from the main menu and Dock Quit become new quit entry points: rerun `scripts/quit-probe.sh` and try both by hand with the player open during a sync. `WeBeepAuthenticationController.chooseRoot` restores `.accessory` unconditionally after its modal panel and can drop the Dock icon if a Play started meanwhile: make it restore only if still `.regular`.

## Player findings (package G, macOS 27, verified in tests or a spike)

- `AVPlayerItem.audioTimePitchAlgorithm` defaults to `timeDomain` (apps built for macOS 12+); the player sets it anyway, so a future default cannot switch lectures to the costlier `spectral`.
- `AVPlayerView` (macOS 13+) has `speeds` (system default 0.5, 1, 1.25, 1.5, 2), `selectedSpeed` and `selectSpeed:`; `selectSpeed:` sets the player's `defaultRate`, and `defaultRate` is KVO-observable, so the view's own speed menu is followed. The `AVPlaybackSpeed` objects are built at runtime (no AVKit link). Whether the floating controls actually show a speed menu could not be checked without showing a window: the title-bar menu is the guaranteed path.
- `AVPlayerView`'s own keys: Space toggles playback, ←/→ pause and step one frame, J/K/L shuttle (J plays backwards); Shift+arrows, F, M, digits and `<`/`>` do nothing. The window takes all the player's shortcut keys first (`RecordingPlayerWindow`), replacing frame stepping and reverse play, which are useless for a lecture and costly on a stream; ⌘/⌃/⌥ chords pass through.
- AVFoundation guarantees only 1.0–2.0 for every ready item: above 2.0 needs `canPlayFastForward`, below 1.0 `canPlaySlowForward` (AVPlayerItem.h). The local MP4 fixture has both; whether Webex's single-level HLS does is **unverified** and must be checked live (if not, those speeds simply stay disabled).
- For F: `onPositionCheckpoint` also fires synchronously at the start of a `play` that replaces the lecture on screen, with the old lecture's `recordingID`, so every report says which recording it is about. During a resume, play/pause requests only set whether playback starts once the resume seek lands. Quitting reports nothing (not on the quit path): the last pause is what survives.

## Open items

- Lifetime of `hlsURL` beyond 10 min and server-side lifetime of `ticket` / idbroker sessions beyond ~30 min.
- Live confirmation (with consent) that the `email=` hint with the real address completes the sign-in unattended.
- The `viewFrom` value of the webappng login URL (packages D/E leave the parameter out), and the unit of the stream API's `duration` (read as seconds).
- Energy comparison native player vs Webex web page (measurement in progress).
