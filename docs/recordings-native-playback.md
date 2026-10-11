# Native recordings playback — investigation and design (#148)

Issue: [#148](https://github.com/tommaso-vaccari/BeepBar/issues/148). Integration branch: `feature/recordings-native-playback` (local until the feature is mature, then one PR to `dev`).

Goal: Play on a recording streams it in a native BeepBar window instead of opening Webex in the browser. Webex sign-in happens automatically in the hidden Recman web view (the Polimi single sign-on is already there), using the user's confirmed Polimi email. Anything that fails falls back to the browser, as before. The feature exists in memory only while used.

All findings below come from `scripts/recman-probe.sh play` / `lab` runs on 2026-10-11 with the account owner's authorization. Outputs are reduced to hosts, paths with ids masked, field names, key names and types: no tokens, cookie values, ids, titles or emails. Webex's web-player API is internal and can change without notice: every step must fail safe to the browser.

## How Webex gets from the player link to the stream

1. The Recman preview gives `https://politecnicomilano.webex.com/<…>/ldr.php?RCID=<id>`.
2. `ldr.php` answers `200` HTML and redirects **in JavaScript** to `/recordingservice/sites/politecnicomilano/recording/playback/<uuid>` (32 hex). No `Location` header, no uuid in the body, with or without cookies: the uuid needs a web view. In a hidden web view on the session's store the uuid appears in the second main-frame navigation after ~0.8 s; cancelling there loads nothing of the heavy player page.
3. Stream API: `GET https://politecnicomilano.webex.com/webappng/api/v1/recordings/<uuid>/stream?siteurl=politecnicomilano`.
   - Signed out: `403` with a JSON body (`requireLogin`, `canPlayback`, `preventPlayback`, `passwordProtected`, `needPassword`, `preventDownload`, …).
   - Signed in: `200`, with `downloadRecordingInfo.downloadInfo.{hlsURL, mp4URL, dashURL, audioURL, playerCoverURL}`, `mp4StreamOption`, `duration`, `recordName`, `chapterLayout`, `transcriptStatus`, `mediaDetectInfo`, `playerPanels`, `showAISummary`, … (shapes only).
   - Works from a plain `URLSession` with cookies only (no CSRF header, no page context). The **only cookie required is `ticket` on `.webex.com`** (session cookie): without it `403`, with it alone `200`.
4. `hlsURL` (`https://nfg1wss.webex.com/nbr/…/hls.m3u8?trackingID=…`) is a single-level HLS playlist of byte-range segments of one 1080p mp4. **AVPlayer plays it without any cookie** (ready in ~5 s; 136-min test lecture). Lifetime of the URL: being measured (re-test after 10+ min).

## Webex sign-in

- Signed-out chain: playback page → `webappng/sites/politecnicomilano/login?siteurl,viewFrom,login_return_url` → `idbroker-eu.webex.com/idb/…` → `doSSO.jsp` **email page** (`input#IDToken1[type=email]`, `button#IDButton2[name=btnOK]`) → `idbroker-eu…/globalLogin` → `shibidp.polimi.it` → `aunicalogin.polimi.it`, which **completes on its own with the Polimi SSO cookies** already in the Recman store → back to the playback page.
- The email page comes back whenever Webex's session cookies are missing, even with persistent cookies such as `CK_LastLogin` (1 year); it is never prefilled.
- **Passing the email in the webappng login URL (`…/login?…&email=<address>`) skips the email page** and goes straight to Polimi's IdP (tested with a placeholder address, stopped before the IdP). So no form filling by script is needed.
- With only idbroker's session cookies the sign-in went through without the email page, but the stream API still answered `403` within the 60 s limit: unresolved.
- After sign-in Webex sets ~15 cookies (`.webex.com`, `idbroker-eu.webex.com`, `nfg1wss.webex.com`, `politecnicomilano.webex.com`), mostly session cookies; a few short-lived trackers.

## Chosen design

1. Hidden Recman web view: load `ldr.php`, capture the uuid in `decidePolicyFor`, cancel. Never load the player page (it pulls u2c catalogs, device registration, KMS, telemetry and Amplitude, and would play audio hidden).
2. `URLSession` to the stream API with the store's cookies → `hlsURL` → native player (cookie-less).
3. On `403`: sign in to Webex in the same hidden web view through the webappng login URL with `email=<confirmed Polimi email>`; Polimi SSO completes; retry step 2. If Polimi asks for the user, the existing sign-in window flow applies.
4. Any unexpected page, status or shape → open the player link in the browser as today.

## Packages and decisions

| Package | Content | State |
|---|---|---|
| A | `PolimiEmail` (only `mail.polimi.it` / `polimi.it`, redacted description) and `WeBeepAPIClient.fetchOwnEmail` (`core_user_get_users_by_field`) | integrated |
| B | `RecmanSessionCodec` v2: email + Webex cookies (`webex.com` on a label boundary), Webex cookies expiring within 12 h not kept; v1 still read | integrated |
| C | `RecordingPlayerController`: one window, nothing before first Play, full release on close, 30 s forward buffer; AVKit loaded with `dlopen` on first Play (linking it adds ~335 dyld images to every launch); failures reported before/during playback | review fixes in progress |
| D | Core parsing of Webex pages and the stream API answer, URL policy | waits for this investigation |
| E | `RecmanWebSession.stream(for:email:)` per the design above | waits for D |
| F | Controller/UI integration, settings email confirmation, specs, CHANGELOG, compliance wiki, measurements | last |

Decisions by the product owner: native window (not QuickTime Player); email read from the WeBeep profile and confirmed by the user; player MVP = system controls (PiP, AirPlay, Now Playing), speed 0.5–3x, ±10/30 s skips and shortcuts, resume where you left off (saved on pause/close only, tied to the watchlist/seen state), recovery after errors or expired URLs. v2: transcript (VTT) with search, chapters, audio-only (`audioURL`), bookmarks, slide capture, next-lecture queue, floating window. Out: adaptive bitrate (single level), offline download (#87, honour `preventDownload`).

Requirements recorded for F by reviews: carry the email through the controller's save path and its fingerprint; verify a relaunch reaches the stream without a new Webex sign-in (the 12 h floor must not drop the cookie that matters — `ticket` is a session cookie, so it is kept); any `fetchOwnEmail` failure means "ask the user", never a sync error; specs IT/EN and compliance wiki must say the session file also holds Webex cookies and the Polimi email; measure `otool -L` (no AVKit), dyld images and launch, 30-min idle wakeups, memory after 1 and 10 play/close cycles, `scripts/quit-probe.sh` with the player open.

## Open items

- Lifetime of `hlsURL` and of the `ticket` cookie.
- The idbroker-only case (sign-in without email page but API still `403`).
- Energy comparison native player vs Webex web page (measurement in progress).
