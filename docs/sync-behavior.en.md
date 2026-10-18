# Sync behavior

This document describes what BeepBar does in every sync situation and what the user sees. It is the reference for development and code review: a PR that changes any of these behaviors updates this document (and the Italian version, [`sync-behavior.it.md`](sync-behavior.it.md)) in the same change.

## Guarantees

These hold in every case described below.

1. **No local file is overwritten or deleted without your choice.** When BeepBar cannot know what you would prefer, it leaves the file where it is and asks.
2. **Only what Moodle actually showed is evaluated.** A course that did not load in that sync (not accessible, server error, no network), a course you turned off, or one you are no longer enrolled in causes no change to its files.
3. **Every action re-checks the state at the moment it runs.** If the file changed in the meantime, the action does nothing and stays pending. If the destination got taken, nothing is overwritten: a file moved to follow Moodle arrives with a number (section 4.1), any other action does nothing.
4. **An app update never reorganizes anything on its own.** New rules apply to what happens on Moodle from then on.

## Terms

- **Tracked file**: a file BeepBar downloaded, whose contents and location it remembers.
- **Edited**: the contents on the Mac differ from what BeepBar last downloaded (for example, notes on a PDF).
- **Place on Moodle**: the section and module the teacher put the file in. They decide the local folder.

## 1. New and updated materials

| Situation | What BeepBar does | What you see |
|---|---|---|
| New material on Moodle | Downloads it into the folder matching its section and module | "New" in Activity |
| The name is already taken by another file in that folder | Downloads it with a number, e.g. `Slides (1).pdf` | "New" |
| The teacher updates a file you have not edited | Replaces the copy on the Mac with the new one | "Updated" |
| You edited a file and it did not change on Moodle | Leaves your version alone | "Your changes" |
| You edited a file and the teacher updates it | Keeps your version and stores the new one separately: a conflict (section 3) | Entry in Conflicts |
| Only the date or revision changes on Moodle, not the contents | Nothing, and it does not download it again | Nothing new |
| Material that cannot be downloaded (external file, link carrying credentials) | Does not download it | — |

## 2. Things you do on the Mac

| Situation | What BeepBar does | What you see |
|---|---|---|
| You delete a tracked file | Downloads it again into the same place on the next sync | "New" |
| You move or rename a tracked file in Finder | Treats it as deleted: downloads the original again at the old place; the moved copy is no longer tracked | "New" |
| You delete a course folder | Recreates it and downloads the materials again | "New" |
| A folder now sits where a tracked file was | Skips that file, the others continue | "Not updated" |

To move files so that BeepBar keeps tracking them, use "Organizza cartelle" or rename the course folder (section 5).

## 3. Conflicts

A conflict happens when a file was edited both by you and on Moodle. Moodle's version is kept separately; yours stays in place until you choose.

| Choice | What happens |
|---|---|
| **Mantieni la mia** (keep mine) | Your version stays; Moodle's copy is discarded. A later update by the teacher opens a new conflict. |
| **Usa la versione remota** (use the remote version) | Moodle's version replaces yours. If you edited the file again in the meantime, one updated conflict remains, never two. |

While a conflict is open, that file is neither moved nor updated (see section 4).

## 4. The teacher reorganizes or removes materials

Every choice in this section appears on the **Conflicts** page, under **Moved or removed on Moodle**, and stays there until you choose. An entry disappears on its own when it is no longer needed (the file is back where it was on Moodle, or you moved or deleted it yourself).

### 4.1 The same file changes place (moved to another section, module renamed)

| Your file | What BeepBar does | What you see |
|---|---|---|
| Not edited | Moves it to the new folder without downloading it again. The old folder is removed if left empty | "Moved" in Activity |
| Edited | Leaves it alone | Entry in Conflicts: **Move my version to the new folder** / **Leave it here** |
| Has an open conflict | Waits until the conflict is resolved, then applies the "not edited" or "edited" row | — |

"Leave it here": BeepBar keeps tracking the file where you left it; later updates by the teacher arrive there.

Renaming a section or a module counts as a move: every file in it follows the new name.

If a file with the same name already sits at the new place, nothing is overwritten:

- If that file is itself moving in the same sync (for example the teacher swapped the names of two sections), BeepBar moves the files in the right order, and exchanges files that swapped places in a single step, with no temporary names. In the end every file is in its place with its own name. Only on a disk that cannot exchange two files in one step (some network or external drives) does one of them arrive with a number.
- If it is a different file (another material with the same name, or a file of yours), the download rule applies: the moved file arrives with a number, e.g. `text (1).pdf`. This also applies to "Move my version to the new folder".

If BeepBar is interrupted halfway through a move (for example the Mac shuts down), the next sync looks at the files: if the move happened, it keeps following them at their new place even if you have since edited one of them (or, if two files had swapped places, deleted one of the two); otherwise it follows them where they are. Your edits are kept either way. If one of the two paths can't be read (for example a symbolic link, which the Finder shows as an alias, or a folder sits where the file should be), sync stops for all courses, and both choices in Conflicts about files Moodle moved, removed or uploaded again and "Organizza cartelle" fail, until you fix it; the window says which path.

### 4.2 The file is deleted and uploaded again elsewhere with the same contents

To Moodle this is a new file; BeepBar recognizes it because the contents are identical.

| Your file | What BeepBar does | What you see |
|---|---|---|
| Not edited | Moves it to the new place instead of downloading a second copy | "Moved" |
| Edited | Downloads the new copy at the new place and leaves yours alone | Entry in Conflicts: **Replace the new copy with my version** / **Keep both** / **Move mine to the Trash** |

If the file is uploaded again in exactly the same place, BeepBar keeps tracking the copy you have, edited or not: it does not download it again and asks nothing, since its contents did not change on Moodle.

If the new copy could not be downloaded, retry synchronization before moving your old copy to the Trash. BeepBar only allows this choice once a separate regular downloaded copy exists; editing that new copy does not prevent you from keeping it.

"Replace" moves the freshly downloaded copy (which you never touched) to the Trash and puts yours in its place; from then on an update by the teacher becomes a conflict. If your file changes or the destination gets taken during this action, your file stays where it is and the choice stays open. The downloaded copy remains recoverable in the Trash; the next sync restores it if its place is still empty.

BeepBar only recognizes a file uploaded again in the same course, and only when Moodle reports the file's content fingerprint. If the same contents appear in more than one place, BeepBar does not guess: the new copy downloads normally and the old file is treated as removed (4.3). The same happens if the unedited copy cannot be moved (for example because something else took its new place in the meantime).

### 4.3 The file is removed from Moodle

| Your file | What BeepBar does | What you see |
|---|---|---|
| Edited or not | Never deletes it on its own | Entry in Conflicts: **Keep** / **Move to the Trash** (the entry says so if you edited it) |

- **Keep**: the file stays and leaves the sync: it becomes an ordinary file of yours and is not reported again. If it later reappears on Moodle with the same contents, BeepBar tracks it again; with different contents it becomes a conflict.
- **Move to the Trash**: the file goes to the macOS Trash, where it can be recovered.
- A file still visible on Moodle but no longer downloadable is not considered removed.
- A temporarily hidden module looks removed; if it becomes visible again before you choose, the entry disappears.
- A file counts as removed only when Moodle showed its course in full: if a section, a module or an entry of that module was omitted or could not be read in that sync, nothing in it is considered removed, and entries already open stay as they are.

### 4.4 What never moves anything

- Changes, in a new app version, to the rules BeepBar uses to build paths.
- Renaming a course folder, and "Organizza cartelle" rules (section 5).
- The first sync after updating: BeepBar records where every file is and only follows later moves. Files already in an old folder stay where they are; they join the other files of their module only if that module is moved again on Moodle.

On the first sync after updating, the files the teacher removed from Moodle before the update, and that are still on your Mac, appear in Conflicts as removed, all at once: nothing is deleted, and you choose file by file. Files tracked by very old versions of BeepBar, which did not record their course, are never reported as removed.

## 5. Folders and organization

| Action | What happens |
|---|---|
| You rename a course folder | It is renamed on disk; BeepBar keeps tracking every file, including after a restore or copy changed the folder’s identity. The folder is checked again before moving it. If the name is taken, it says so and changes nothing. If the folder is renamed on disk but the rename cannot be made durable, syncing, other renames and "Organizza cartelle" stay paused, with a message asking to restart BeepBar, until BeepBar is restarted: the rename is completed at launch. No file is touched meanwhile |
| "Organizza cartelle": you give a module its own folder | Preview, then the module's files are moved; edited files are moved without being overwritten; a taken destination blocks the operation |
| "Ripristina layout Moodle" | Brings the module's files back to Moodle's structure, with the same preview |

## 6. Courses, network and automatic sync

- A course Moodle refuses (no longer enrolled, hidden, restricted) does not block the others; it shows as "Corso non accessibile" in the details.
- If every course fails because of the site or the connection, the sync is reported as failed and no file is touched.
- Automatic sync uses any network, your phone's hotspot included, like "Sincronizza ora".
- Automatic sync is postponed, not skipped, under Low Power Mode or while another operation runs.
- After every materials sync (automatic and “Sincronizza ora”), with Recordings on and a Polimi account, BeepBar also refreshes the recordings lists of the selected courses in the background. It is separate work: it does not change the sync result, “Esci” does not wait for it, and it respects the same pauses (Low Power Mode, Data Saver, no connection, cancellation). Details in “Lecture recordings”.
- Changing selected courses while at least one remains selected preserves the next automatic deadline. An empty selection or blocked local recovery stops scheduling; selecting a course or resolving recovery restores it. Callbacks from a removed schedule cannot start work.
- With "Risparmio dati" (Data Saver) on (Settings, off by default), automatic sync pauses while the Mac uses a phone hotspot or a network with Low Data Mode, and resumes by itself on another network. If the Mac moves to one of these networks during an automatic sync, the sync stops at the next download and is postponed without reporting an error: files already downloaded stay, and the last result stays visible (an earlier error is not shown again, since that sync got past it). A connection that is really down still shows "Connessione assente". "Sincronizza ora" always downloads, on any network.
- The pause only takes the place of "Pronto", the result of a completed sync or "Connessione assente": conflicts, materials not updated, other errors, an expired sign-in and a folder to choose stay in front. It goes away when an automatic sync starts, with "Sincronizza ora", when you turn off Data Saver or automatic sync, change Frequenza or which courses are selected, or when the account or the folder changes.

- While courses are refreshing, their switches are disabled; a choice still being saved is applied before the refreshed list is restored.
- When the window opens, Corsi immediately shows the list Moodle confirmed at the last successful refresh (at most 30 days earlier), with the saved folders and selection and the note «Elenco salvato … · aggiornamento in corso…»; once Moodle answers, the current list takes its place. Without a network the saved list stays visible with the note «non ancora confermato» and the refresh error. Until it is confirmed, the switches and folder renaming are disabled. The saved list never decides what is synced: «Sincronizza ora» first asks Moodle for the current list, and automatic sync always uses that one. If the window opens during a sync, the refresh starts when the sync ends; if the window is closed first, it doesn't start. It is bound to the university, the sync folder and the sign-in: it is deleted when you sign out, change university, sign in again or when the stored credential is gone at launch (even with recovery blocked) or during a refresh, and it is never shown after another account signs in. Once older than 30 days it is deleted at launch, at every sync or when the window opens, even if the window is never opened. Choosing another folder while a list not yet confirmed is shown reloads the list from Moodle. Without a saved list, the page shows «Caricamento corsi…» from the first moment until Moodle answers.
- The course refresh error goes away for good once the list is confirmed, by a sync too; while a new attempt runs the page shows it loading instead, and the error comes back if the attempt fails. With the window open (minimized to the Dock included), a refresh that failed for lack of a connection or because the platform didn't respond is retried by itself when the network comes back (once right away if the network is already available, then at every network change) and when a sync ends; there is no need to press the refresh button. A server error is not retried by itself. With the window closed, after signing out or once the sign-in has expired, and while the app is quitting, no new attempt starts and BeepBar does not watch the network.
- Cancelling during the final checks ends the run without showing a completed result or sending its notification. Once completion or failure is shown, the run has ended and notification delivery cannot leave Cancel active.
- A delayed refresh cannot replace the state of a sync started afterward, a disconnected account, or a different sync folder.
- A sync's result belongs to the folder it synced. A folder chosen while a sync runs, including a sync that starts while the new folder is being prepared, is not adopted, and no error is shown over the sync: the current folder stays. A run whose folder changed anyway shows and saves nothing, sends no notification, and the new folder's own last result is shown.
- If pending choices cannot be read, their last displayed lists stay visible and the run reports a local error; it does not record a successful sync. An unreadable course selection also fails the refresh or automatic sync instead of being treated as an empty selection.

- A notification waiting for a permission check is discarded if its account, sync folder or result has been replaced; discarding it does not mark its condition as notified.

## 7. Where you see what

| Place | Contents |
|---|---|
| **Home** | A notice leading to Conflicts while something waits for your choice, including files moved or removed on Moodle. While Data Saver is pausing, the top card says "In pausa per Risparmio dati" and explains why and how it resumes, in place of the summary of the last sync (still in Activity); after a completed sync it still shows when that was. Status and summary stay those of the materials: refreshing recordings never changes them |
| **Activity** | The last sync only: new, updated, your changes, not updated, moved, and edited files moved on Moodle that now wait in Conflicts. A click opens a file where it is now, even after a later sync moved it; the right-click menu also shows it in Finder. Only documents open directly; anything else (scripts, apps, disk images, unknown types) is only shown in Finder. A file that is no longer where BeepBar put it, including one replaced with a Finder alias, is reported on its row; a file without read permission reports that problem and opens nothing. A course with many rows shows the first 200 when expanded; “Mostra altri” reveals more, in growing steps, down to the last one; collapsing it or a new sync goes back to the first 200 |
| **Conflicts** | Everything waiting for your choice, until you choose: conflicts and files moved or removed on Moodle. A refused or failed choice shows its reason on this page; a subsequent choice clears the old message |
| **Menu bar** | The status of the last sync. No new text for moves and removals. While Data Saver is pausing, "In pausa per Risparmio dati" and the reason: "In attesa del Wi-Fi" or "Modalità dati ridotti attiva"; the icon shows a pause symbol. Under “Sincronizza ora” sits “Open BeepBar”, then “Quit BeepBar”; no Recordings section (see “Lecture recordings”) |
| **Sign-in** | Onboarding and Settings show a failed sign-in beside its button; the next attempt clears the old message. A failed attempt does not replace an existing account. University selection stays locked during sign-in; verification, a new sign-in and disconnect wait for an ongoing account check to finish |
| **Notifications** | As today (new materials, conflicts). No new notifications for moves and removals. After a sync that finds new recordings, a single “N new recordings” notification is sent. They can be turned off in Settings: while off none is sent, and a conflict still open may be notified at the next automatic sync after they are back on. A click opens Conflicts, Activity, Courses or, for new recordings, Recordings. They also appear while BeepBar is in front |

## Lecture recordings

Without a reusable saved session, opening the page explains the feature and offers Polimi sign-in; if the account is known and has a saved watchlist, the list remains visible with a sign-in prompt above its lessons. An existing reusable session is used automatically.

Recordings is enabled by default for Polimi accounts. Turning it off in Settings hides the page and preserves that choice between launches. Its sidebar shows only courses selected for synchronization, including courses whose code or year cannot be identified. Archive searches require both a course code and an academic year. A course whose local folder you renamed appears under the folder name followed by the part in parentheses at the end of its WeBeep name (usually the teacher): “Geometria algebra lineare (Rossi)” with the folder “GAL” reads “GAL (Rossi)”. Actual generated defaults for that course and recognizable older forms do not count as a rename. Custom names “gal”, “GAL”, “Gal” and hyphenated names are respected. A historical slug that can no longer be reconstructed is shown as the existing name because rename provenance is not stored. The detail header keeps the WeBeep name. A small orange dot marks courses with lectures still to watch, worked out from the saved summaries (see below): it shows at launch, even before the recordings are loaded and even without a Polimi session, and is absent when the summary is not known or everything is done. Lists are read when the page is open and, at every sync, in the background (see below); recordings are played in a BeepBar window or, when that is not possible, in the default browser; file synchronization does not download them. The Polimi session (with Webex cookies and the email, see below) is stored in a separate local file and removed when you disable Recordings, disconnect or switch accounts. An expired session requires another sign-in.

During video playback in the native player, BeepBar prevents automatic idle sleep of the display and Mac through AVFoundation. Protection follows playback: pausing, reaching the end and closing the player allow automatic sleep again. It does not change macOS power settings.

The first complete listing of each course/year is marked as already present. Later unseen IDs are new until opened or marked as seen, including publications with older lecture dates. Seen state persists exactly by account/course/year without the former shared 5,000-ID eviction; only the current list is queried in memory. History grows on disk with acknowledged recordings and is removed on disable, disconnect or account change, rather than pruning IDs that might return. On upgrade, v1 surviving IDs and baselines are preserved only with a verifiable saved session owner. Previously evicted IDs cannot be recovered and may appear new until explicitly marked as seen; unowned v1 history is discarded. A storage failure reports an error and leaves saved history and migration input available for retry. A failed refresh retains the prior successful list together with its seen state. History I/O runs on a serial worker, and dots clear once an acknowledgement is saved. Reset preserves an opaque namespace marker so even a failed history-file cleanup cannot restore old seen state after re-enable or restart; cleanup is retried on subsequent use.

Play streams the lecture in a BeepBar window (the same engine as QuickTime, with the system controls, 0.5x–2x speeds, 10 and 30 second skips and keyboard shortcuts) instead of opening Webex in the browser. Speeds above 2x are not available yet. The player does not exist in memory until the first Play. To find the stream BeepBar reads the player link in the archive and asks Webex for the video stream; if Webex needs a sign-in, it runs automatically in Recordings' hidden browser, where the Polimi sign-in is already active, passing the Polimi email in use (the WeBeep profile's or the one the user entered, see below). No Webex page is shown. If something is not recognized or not available (a Webex page or answer different from expected, a recording without a video stream), the recording opens in the default browser as before. If Webex needs a sign-in and there is no Polimi email in use, Play shows “Couldn't open this recording.” and opens nothing; if the Polimi sign-in has expired or Polimi doesn't respond, the usual messages apply. A Play pressed while another lecture's stream is still being looked up stops that search (and its sign-in window, if shown) and starts at once; a second Play of the lecture already being looked up waits for that same search instead of starting over. “Copy link” is unchanged. “Open in browser”, in a recording's menu, opens the Webex player in the default browser without trying the BeepBar window. A password-protected recording that Webex lets the signed-in user watch without asking for the password plays in BeepBar; if Webex actually asks for the password, the recording opens in the browser.

The Polimi email is the WeBeep profile's, if the account allows reading it and it is a Polimi address: BeepBar uses it without asking for confirmation. It is read at the first Play (or when the field in Settings is opened) if no address is known yet, at most once per session and never at rest. So the first Play works without opening Settings. In the “Polimi email” field of Settings › Recordings, visible while Recordings is on, the address appears as in use and taken from the profile; the user can change or remove it, and their choice wins over the profile: after a removal the profile's address is not taken again for that account, not even after a relaunch, until the user enters one (or Recordings is turned off, the account disconnected or changed). If reading fails or the address is not a Polimi one, the field stays empty for the user to fill in, with no sync error, and Play shows “Couldn't open this recording.” when Webex needs a sign-in. Only `@mail.polimi.it` and `@polimi.it` addresses are accepted; an empty field removes the address. An address known before the Polimi sign-in completes belongs to the WeBeep account signed in at that time: if the account changes it is forgotten, not carried over to the new one. While no WeBeep account is known (WeBeep sign-in expired at launch) the field is disabled and asks to sign in to WeBeep again. BeepBar neither asks for nor stores a name or surname. The email is sent only to Webex for the sign-in, is never written to logs and lives only in the session file, removed with it. The session file therefore holds, besides the Polimi cookies, the Webex cookies (those expiring within 12 hours are not stored, so after a relaunch a new Webex sign-in is often unnecessary) and the email; the format is version 2. An older app does not recognize it, discards it and asks for a new Polimi sign-in, without touching course files.

Where you left off: the position is saved per account only when the player reports it (pause, closing the window, starting another lecture, an error), never at intervals. Stopping in the first 5 seconds clears the saved position; reaching within 30 seconds (or 2% of the duration, if greater) of the end counts the lecture as watched: the position is forgotten, the lecture is no longer “new” and starts from the beginning. Quitting BeepBar saves nothing: the last pause remains. Pressing Play again on the lecture already open restarts from the last saved position, not from the exact point it has reached. Turning Recordings off preserves positions, including the final checkpoint when the player closes. Positions are removed on disconnecting and on a university or account change. This rule concerns only the resume point; when a lecture counts as “done” in the progress is decided by the 90% rule described below.

While the player is open BeepBar appears in the Dock and in Cmd-Tab, then returns to the menu bar only when it closes; choosing the materials folder in the meantime does not remove the Dock icon. Closing the Settings window does not stop the lecture. Turning Recordings off, disconnecting, and changing university or account close the player (the stream belongs to the old identity). The player takes no part in quitting BeepBar.

Recovery after an error: if the stream stops during the lecture (network lost, expired address), the window stays paused, BeepBar asks Webex for a new stream once and resumes from the same position; if that fails again, or the stream never started, the recording opens in the browser and the player window, if still open, closes (without a Polimi email in use nothing opens and the message appears). When neither a new stream nor the browser can be reached (no Polimi email, Polimi not responding, Polimi session expired), the paused window shows the reason under its title in place of the course name, also when no Recordings page is open; resuming playback from the window brings the course name back, and a later interruption is handled again. Closing the Settings window or the Recordings page interrupts neither the recovery nor a Play that was started from the window, even if it is still waiting behind other work; it does cancel “Open in browser” and “Copy link” still waiting, and the lists only the page wanted (not those of a sync refresh). So the Webex sign-in window or the browser fallback may appear a few seconds after Settings was closed. Turning Recordings off, disconnecting, and changing university or account cancel everything instead, Plays included. If a new sign-in is needed, the sign-in window may appear.

Player window. The controls sit in a compact bar along the bottom edge, which covers little of the lecture (in full screen the system’s floating panel remains). The video zooms with a pinch (1x to 4x) or with ⌘+ / ⌘= , ⌘− and ⌘0 (back to 1x); while zoomed, drag or scroll to move around. The zoom is kept across pause and recovery of the same lecture, resets to 1x for another lecture and is not saved. While the player is open, Control Center, the menu bar’s Now Playing item and the media keys show the lecture’s title, the course name and the course’s picture from WeBeep, instead of just “BeepBar”, and drive the player (play, pause, 10 second skips, scrubbing). The picture is downloaded from WeBeep after playback has started, never waited for: over HTTPS from the WeBeep host only, with the token added at request time (never logged or stored), at most 2 MB and 10 seconds, shrunk to 512 px, kept in memory only and released on close; without a picture the app’s icon is shown. Title and course name can be read by other programs on the Mac through the system’s Now Playing while the player is open, and are cleared on close. Preventing automatic sleep during playback stays as described above (Issue #157).

Progress. Each recording has a percentage: it starts at 0% and is the furthest point reached, so it never decreases (seeking ahead raises it). A lecture is “done” when the player is closed (closing the window or the player, or replacing it with ANOTHER lecture) having reached at least 90%, or when you mark it with the “Done (watched or attended in person)” checkbox, which can be unticked. Pausing, a failure and quitting BeepBar never complete a lecture. Unticking keeps the percentage and blocks automatic completion: the lecture becomes done again by itself only if, within one playback, it goes from below to above 90% and is then closed (reopening a lecture that resumes at 92% and closing it does not undo your choice). Completing a lecture also marks it as seen; watching a done lecture again leaves it done. Progress is saved per account, course and year in the same file as the “seen” state (a new table that older versions ignore) and is removed on logout, account change or when Recordings is turned off (unlike resume points, which turning it off preserves). There is no migration: after updating every lecture starts at 0% and you can mark the ones already watched. It is written to disk only at pause, close or replacement, and only when something changed; while playing, the bar in the window moves from an in-memory update about every 30 seconds of lecture time (no timer while paused or closed). Quitting BeepBar saves nothing beyond the last pause.

Rows and header. Every row (course lists and Watchlist) shows a thin bar and the “Done” checkbox; the checkbox shows only the saved value and changes once the save has happened. Rows whose state is unknown (for example in the Watchlist, until the course’s list is loaded) show neither bar nor checkbox. The course header reads, for example, “12/30 done · ~14 h left”: the time left is the sum, over the lectures not done, of duration × (1 − progress); a length above 24 hours is treated as unknown and a lecture of unknown length adds no time (so the estimate can be an underestimate). Under an hour it reads “~45 min”; with everything done, only “N/N done”.

Bulk completion. The course toolbar offers “Mark all as completed”; when every lesson in the loaded course/year listing is completed, it changes to “Mark all as unseen”. The command always applies to the whole listing, including lessons hidden by search. It follows the individual Done checkbox: completing also acknowledges new recordings; unchecking preserves playback percentage and resume positions, blocks automatic completion until a fresh threshold crossing, and does not make old publications new again. Empty or unknown progress and pending saves disable the command. Rows show committed values; while the command is saving, every checkbox of that course and the command itself are disabled. The whole listing is saved at once: if the save fails, no lesson changes and the existing history error appears. The label follows the saved state again: after a failed completion it still reads “Mark all as completed”, after a failed untick it still reads “Mark all as unseen”, and clicking again retries the whole listing.

Saved summaries. For each selected course BeepBar keeps a summary (lectures done, total, time left, new lectures) per account, used for the sidebar's orange dot at launch without the network or the Recordings controller. It is updated at every list read and at every pause, close or tick, not at every bar update, and removed with the rest of the history.

Menu-bar popup. Clicking the BeepBar icon shows sync status, the sync action, Open BeepBar and Quit, without a Recordings section or course summary rows. Recording progress remains available on the Recordings page.

Refresh at every sync. After the materials sync (automatic and “Sincronizza ora”) BeepBar re-reads the lists of the selected courses: lists and metadata only, never video (offline download stays out, #87). It runs outside the materials sync: “Esci” does not wait for it, and the menu and Home keep showing the materials result only. It adds no schedule of its own: the automatic one starts inside the existing background activity, which waits for it at most two minutes; past that the refresh carries on by itself and the next automatic sync is scheduled as usual. Turning automatic sync off, changing Frequenza or anything else that reschedules it (signing out, changing folder) while the activity is still waiting stops the refresh, unless “Sincronizza ora” started it or joined it: that refresh carries on (signing out or changing folder still stop it). Rules:
- It starts under the same conditions as the sync that triggers it: with Low Power Mode, a Data Saver pause (for an automatic run the network is read again at that moment), no connection, cancellation, a deferred or busy sync, macOS asking background work to wait (automatic only), or an unconfigured app, it is skipped silently. A problem with the materials alone (service unavailable, incompatible response) does not block it; an expired WeBeep sign-in does.
- “Sincronizza ora” ignores the lists’ 5-minute freshness; the automatic one respects it. Only selected courses are covered: deselected courses present only in the Watchlist stay on demand. Besides the maximum time of each step (30 seconds per page, 10 per script) and a single browser operation at a time, there is no cap on the number of courses.
- With Recordings off, a non-Polimi account or no account nothing happens, and the Recordings controller is not even created.
- With the Polimi session expired it never opens a window or takes focus: the last list, the dots and the summary stay, Settings › Recordings and the page show the sign-in prompt, and later syncs skip the refresh at no cost until you sign in.
- The #106 baseline applies: a course’s first complete listing is the baseline, only complete listings are published, a failed or partial refresh keeps the previous list and seen state; lectures published afterwards are “new”.
- Privacy: at most one Polimi SSO entry plus a few pages per course per sync interval, only while Recordings is on and the session is alive; no new recipient.

New recordings notification. After a sync that finds new recordings, ONE aggregated macOS notification is sent, “N new recordings” (“1 new recording” for one), with the text “They’re available in Recordings.” (“It’s available in Recordings.”). It depends on the Notifications switch and on system authorization like the others, and contains no course or lecture names. It is never sent for a course’s first listing (baseline), when the Polimi session had already expired, nor for a failure or a cancellation. New lectures already found when a refresh ends early are still announced: those of the other courses when some fail, and those of the courses listed before Polimi stopped responding or the Polimi session expired midway; those found before a cancellation are not. It has a fixed identifier: it replaces the previous notification instead of stacking, and a sync that finds nothing new sends nothing. After a relaunch, when the previous list is not in memory, the comparison is with the lecture count of the saved summary: if in that interval one lecture disappears and a new one arrives, the new one gets its dot but does not trigger a notification. A click opens Recordings; an older version of BeepBar ignores the unknown destination and opens Courses.

Watchlist, above the courses on the same page, collects only lessons manually added with the bookmark. It shows saved course, title, date and duration before courses are reloaded. Lessons remain in the list until their bookmark is removed, even after opening them. “Mark new recordings as read” only affects novelty indicators. Navigation is remembered.

Watchlist is saved locally per account and survives session expiry and disabling the feature. It is hidden after disconnecting; another account never inherits it. A successful refresh retains lessons missing from the archive and marks them unavailable; a failure or cancellation never removes them. Watchlist can contain lessons from courses no longer selected for synchronization.

## Privacy and deletion

Telemetry uses one identifier shared by all installations and sends only app version and major macOS version; language and settings are excluded. The first monthly report is a separate event counted without linking daily reports. A notice precedes the first transmission, including upgrades, with an option to disable. It remains enabled by default with opt-out, pending closure of the privacy release gate. Settings → Data and privacy describes flows and contact details. Failed session deletion stays pending across launches, is retried when the controller is created and can be retried in Settings with Recordings off. The tombstone blocks reuse of the discarded session. Logout preserves materials, database and watchlist.

Saved Polimi sessions expire ten days after initial save; updates do not renew this deadline. Removal happens at expiry while running or at next launch. Tokens and sessions are excluded from future macOS backups; earlier copies remain. Settings → Recordings → “Forget this account’s study data” erases watchlist, viewing state and resume points, closes playback and preserves materials. History deletion failures remain visible across relaunch and can be retried.
