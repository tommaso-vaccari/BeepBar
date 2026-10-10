# Changelog

## Unreleased

### New

- Save lessons from different courses in a single Watchlist inside Recordings. Add or remove bookmarks and find your saved list again after restarting.
- An optional daily signal to TelemetryDeck helps measure active installations and app versions; it is off until enabled in Settings and contains no account, course or file information.

### Improved

- Cancelling sync stops large local file checks promptly while file changes already underway still finish safely.

- Refreshing unchanged courses avoids unnecessary interface updates while renamed courses and changed selections still appear normally.
- Opening BeepBar restores the previous sync result with less work, keeping the interface available while a large Activity summary is read.
- Repeated synchronization uses less memory and does less work when many materials are already saved.

### Fixed

- Changing selected courses keeps the next automatic sync on schedule; automatic checks stop while local recovery needs attention and resume once it is resolved.

- Cancelling a network check for Data Saver stops promptly and prevents an automatic sync from starting afterward.

- Removing a course from your selection now drops its waiting recordings request without interrupting playback actions.

## 2026-10-07

### Release highlights

- Browse lecture recordings for your synchronized Polimi courses and play them in your default browser.
- Use Data Saver to pause automatic downloads on a phone hotspot or a network with Low Data Mode; manual sync always remains available.
- Edited local files stay protected when synchronization is interrupted, and reopening BeepBar recovers more reliably.
- Large downloads use much less memory, and unchanged course lists avoid unnecessary redraws.
- Quitting from the menu bar works during synchronization, and course search is easier to deselect.

**After updating:** Recordings is enabled by default for Polimi accounts. Open Recordings and sign in with Polimi to get started, or turn it off in Settings. Automatic sync now also downloads on hotspots and networks with Low Data Mode; turn on Data Saver if you prefer to wait for another network.

### New

- Lecture recordings for synchronized Polimi courses, grouped by week, with search and playback in your default browser. Enabled by default for Polimi accounts; sign in with Polimi to get started, or turn it off in Settings. The session is saved locally between launches.

- "Risparmio dati" in Impostazioni: when it's on, automatic sync pauses while your Mac is using your phone's hotspot or a network with Low Data Mode, and picks up again by itself on another network. BeepBar shows that it's paused and why, in the window and in the menu bar. "Sincronizza ora" always downloads. It's off unless you turn it on.

- Every switch in Impostazioni, and the Frequenza menu, has an ⓘ button that explains in plain words what it does. Hover over it, or click it.

### Improved

- Recordings have clearer course names, more room for lesson titles, and a visible Play button on every row. Search stays available in its own toolbar, including courses with only a few recordings.

### Fixed

- Opening Recordings without a reusable saved session now immediately explains the feature, how to sign in with Polimi and how to turn it off in Settings.

- Quickly choosing another recording now opens or copies only your latest choice, even when the previous link is still loading.

- Refreshing courses or finishing a sync no longer redraws an unchanged course list unnecessarily.

- "Esci" in the menu bar no longer leaves BeepBar stuck when a sync is running: the sync stops and BeepBar closes within a few seconds.

- Automatic sync no longer fails with "Connessione assente" while your Mac is on a phone hotspot or a network with Low Data Mode. After updating, it downloads on these networks too, just like "Sincronizza ora"; turn on "Risparmio dati" if you'd rather it waited for another network.

- Downloading a large file (a lecture recording, an archive), or a new version of one, no longer makes BeepBar use far more memory than the file itself: a 256 MB file could take about 1 GB for a moment. Memory now stays low whatever the size of the file.

- The "Cerca corsi" field in Corsi no longer stays selected. Clicking anywhere else deselects it; Esc clears what you typed, and Esc again deselects it.

- If BeepBar was interrupted (a crash, a forced quit, a power cut) just as it found that you had edited a file Moodle had also updated, it could replace your edited copy with Moodle's at the next launch. Your copy is now always kept, and both versions appear in Conflicts.

- Sync no longer gets stuck on "Intervento richiesto" at the next launch when a downloaded file couldn't be put in its folder (for example a folder BeepBar wasn't allowed to write to), or when BeepBar was interrupted right after downloading a new file that you then edited or deleted. The next sync handles the file as usual.

- BeepBar now saves its sync progress to disk at every step. A power cut or a system crash in the middle of a sync is much less likely to make it lose track of files it had already downloaded or course folders it had already renamed.

## 2026-10-01

### Release highlights

- Open downloaded documents directly from Activity.
- Notifications take you to the relevant page and can be disabled in Settings.
- BeepBar starts at login so automatic synchronization resumes after restarting.
- Files moved or removed on WeBeep are handled more clearly, while protecting your edited copies.
- More reliable synchronization, cancellation, sign-in and course selection.

**After updating:** macOS may show a login-item notice. Your first sync may list previously removed materials in Conflicts; you decide what to keep or move to Trash.

### New

- Files a teacher removes from WeBeep are no longer left behind without a word. They appear in Conflicts, under "Spostati o rimossi su WeBeep", where you choose "Tieni" or "Sposta nel Cestino"; BeepBar never deletes anything by itself. On the first sync after updating, files removed from WeBeep in the past that are still on your Mac show up there too, all at once.

- BeepBar now opens by itself when you log in to your Mac, so automatic sync picks up again after a restart. It's on by default: on the first launch after updating, macOS shows a notice that BeepBar was added to your login items. Turn it off anytime with "Apri BeepBar al login" in Impostazioni, or in the login items list in System Settings; BeepBar won't turn it back on. If you had already added BeepBar to your login items yourself, remove that older entry so it doesn't open twice.

- Notifications can be switched off with "Notifiche" in Impostazioni; they stay on unless you turn them off. The menu bar icon and BeepBar's pages keep showing everything either way.

- Clicking a notification now opens BeepBar where it matters: Conflitti for conflicts, Attività for new materials, Corsi for sign-in and sync problems. Notifications also appear while BeepBar is in front, instead of being dropped.

- Files listed in Attività open with a click, or show in Finder from the right-click menu; hovering a file shows which of the two a click will do. A file a later sync moved still opens where it is now, and if you moved or deleted it, Attività says so. Only documents (PDF, Office, iWork, text, images, audio, video, zip) open directly; anything else, such as scripts, apps or disk images, is only shown in Finder, so these are not launched by a click in Attività.

### Improved

- The app now spells its name BeepBar in the window, the menu, onboarding, messages and notification text, and in update prompts after this update. Your sign-in, sync folder and settings carry over unchanged.

### Fixed

- Failed sign-ins now show the reason beside the sign-in button, in onboarding and Settings; an existing account is kept when a new attempt fails. University selection and account actions wait for pending checks, preventing a login from ending up on the wrong platform or an old check from undoing a disconnect.

- Conflitti now explains why a choice could not be completed, including when a file changed while the choice was open. If an error occurs after an action has partly completed, check the file and refresh before retrying.
- Clicking a file in Attività no longer follows a Finder alias substituted for the downloaded document. Files without read permission show a message on their row instead of attempting to open.
- A sync notification still waiting for a permission check is discarded if you disconnect, change the sync folder or start a newer sync; an obsolete failure no longer suppresses the next genuine failure notice.
- Choices about moved or reuploaded files now check for edits made while the choice was open. If your copy changes during replacement, it stays in its original folder and the next sync can restore the downloaded copy.
- New downloads get a numbered name when their destination is occupied. Files you previously kept can be tracked again when they return on WeBeep.
- If a reuploaded copy could not be downloaded, BeepBar keeps your old copy out of the Trash until you retry synchronization and the new copy is available.
- When WeBeep omits a module’s contents, BeepBar waits for a complete listing before treating its materials as removed.
- When a teacher moves or renames material on WeBeep, or reuploads it elsewhere, BeepBar moves your unchanged copy to the matching folder without downloading it again. Edited files wait for your choice in Conflicts, and occupied names get a numbered suffix; files already left in older folders stay where they are after updating.
- Cancelling during the final checks no longer shows a completed result afterward. Once a run completes or fails, notification delivery cannot leave “Annulla” active or let cancellation erase the result.
- Course switches stay disabled while the list refreshes, and refreshing no longer loses a selection that is still being saved. A delayed refresh also cannot replace the result of a newer sync, restore a disconnected account, or show choices from a previous sync folder.
- If saved choices or course selections cannot be read, BeepBar reports an error instead of hiding pending choices or reporting a successful sync. The last displayed choices remain visible.
- If an update was interrupted while preparing local sync information, reopening BeepBar completes that preparation so synchronization can start again.
- “Disconnetti…” also removes sign-in information left by an interrupted save. If removal fails, the account stays connected and BeepBar shows an error so you can retry.
- Courses with identical names can both be selected, each with its own folder; existing folders are not renamed.
- The preview in “Organizza cartelle” stays valid when another course synchronizes in the meantime, and its count of older files covers only the course being organized.
- Downloads that exceed the size announced by WeBeep stop as soon as they go over, instead of filling the disk before being refused.

## Earlier releases — through 2.1.38

### Fixed

- When a synchronization finishes, the window returns from “Annulla” to “Sincronizza ora” instead of leaving an inactive Cancel button on screen.
- Automatic update checks now start when Beepbar launches, even if Settings is never opened.
- A scheduled daily synchronization delayed by Low Power Mode or another active operation is now retried instead of skipped until the next day.
- UI preview runs no longer write notification deduplication state into the installed app's preferences.
- Signing in no longer has to be repeated because macOS keeps asking to authorize access to the Keychain. The WeBeep token is now kept in a file that only your own user account can read, inside Beepbar's Application Support folder, instead of in the Keychain. A token stored by an earlier version is moved over automatically the first time you open this one, and the old Keychain entry is removed.
- Synchronization no longer re-reads and re-hashes every file it has already downloaded. Each run used to read the full contents of every tracked file from disk just to check that it was still there, so a large library meant reading gigabytes on every manual and scheduled sync. Beepbar now only checks that the files exist, which makes a run over an unchanged folder far faster and much lighter on the disk.
- Files you have edited locally are no longer downloaded again on every synchronization. When the material on WeBeep changed only its revision and not its contents, Beepbar discarded the download but never recorded that it had caught up, so the same file was fetched again on every following run, forever.
- A tracked file that has been replaced by a folder no longer aborts the whole synchronization. Previously a single such entry made every run fail, with no way to recover other than choosing a different sync folder.
- Deleting a local file no longer lets an unrelated new material take over its name. The name stays reserved for the material it belongs to, and a genuinely new file is given a numbered suffix instead of making the run fail with a name collision.
- Database read errors are now reported instead of being mistaken for an empty result. A busy, locked or damaged database could return a partial view that Beepbar treated as complete: with no known baselines, every file you had annotated looked like a conflict and whole courses were downloaded again into " (1)" copies. Reads now fail loudly, and a database briefly locked by another operation is waited for rather than treated as broken.
- Choosing "Usa versione remota" for a file you had edited again in the meantime no longer leaves a stale second conflict behind. Exactly one conflict remains open for that file, reflecting the current contents on disk.
- Local recovery no longer stops at the first entry it cannot repair. A single damaged item used to abort recovery completely, and because recovery gates every other operation this blocked all synchronization, conflict resolution and folder renaming. The remaining items are now recovered normally and only the damaged one stays pending.
- Naming a course folder `.BEEPBAR`, or any other capitalisation of Beepbar's own hidden folder, is now refused instead of accepted. Because macOS folder names are not case-sensitive, such a folder was the same one Beepbar uses internally for downloads in progress and for conflict copies, so course materials were written into it and its contents could be overwritten or hidden from Finder.
- Renaming a course folder to a name already taken by another folder now says so, and leaves the course renameable. The rename failed with a generic message and, worse, left the course stuck: every later attempt to rename it failed too, and the next launch reported a local recovery it could never complete.
- When recovery does remain blocked, the menu bar now offers to retry it, and the message explains what to do. The only way out used to be choosing a different sync folder, which nothing on screen mentioned. Starting a synchronization while recovery is blocked is now refused explicitly instead of silently doing nothing.
- Synchronization no longer fills the disk with leftover downloads. Every downloaded file was copied into place but its temporary copy was never removed, so a large sync could quietly take up twice the space it reported, and refused or interrupted downloads left their own leftovers behind; nothing cleaned them up until the Mac was restarted.
- A course whose material carries an implausible modification date no longer makes Beepbar quit in the middle of a synchronization, on that run and on every retry. That single entry is now reported as unreadable and the rest of the course is synchronized normally.
- Duplicate entries coming from WeBeep or from the local database no longer make Beepbar quit while preparing a synchronization or while restoring your course selection; the first entry is kept and the run continues.
- A single course that WeBeep or Moodle refuses to open (a course you are no longer enrolled in, a hidden or restricted one) no longer stops every other course from synchronizing. The other courses are synchronized normally and the refused one is listed as "Corso non accessibile" in the sync details. Scheduled synchronizations also skip courses you are no longer enrolled in, which used to make every scheduled run fail at the end of a semester.
- "Sincronizza ora" from the menu bar now works right after Beepbar starts. Until the window had been opened once, it silently did nothing and just showed "Pronto".
- A module folder move that could not be completed no longer blocks synchronization with no way out: "Abbandona spostamento…" gives up on it without moving or deleting any file, and records where each file really is (#49). A successful move now also removes the old module folder when it is left empty.
- Starting a synchronization while a rename or a folder move is in progress now says so, instead of reporting an incomplete synchronization.
- Course folders that already existed before the first synchronization can now be renamed.
- Cancelling a sign-in no longer empties the course list.
- Errors in "Organizza cartelle" are now shown in Italian instead of as a generic English system message.
- Counts now use the correct singular form: "1 conflitto da risolvere" instead of "1 conflitti da risolvere", in the menu bar and in notifications (#46).
- A scheduled check with no selected courses no longer replaces the last synchronization result with "Pronto".
- Choosing the sync folder through a symbolic link now uses the real folder, so the same folder is never tracked twice.
- Typing the name of a new folder in the "Scegli cartella" panel works again. Beepbar lives in the menu bar, and the panel could appear without receiving the keyboard; while the panel is open Beepbar now briefly shows in the Dock so the panel gets focus.

### Performance

- The course list stays responsive with many courses. Showing a single row used to recompute the default folder name of every course, compiling regular expressions from scratch each time, which meant tens of thousands of recompilations per redraw with a large course list. Those names are now computed once and the regular expressions are compiled once for the lifetime of the app.
- Repeated synchronizations no longer make Beepbar heavier over time. Each run opened a new set of network connections and kept them alive for as long as the app was running, so memory and open connections grew with every manual and scheduled sync. All runs now share a single connection pool, and scheduled syncs keep staying off metered connections and honouring Low Data Mode exactly as before.

### Added and changed

- Release numbers now move to the next minor version every hundred builds instead of growing the last number indefinitely: after 2.0.99 comes 2.1.0. Existing installs still see every new release as an update.
- Add "Disconnetti…" in Settings to remove the stored token, so another account or another university can be connected. Switching university turns off the previous university's course selection, because course numbers are only meaningful within one site.
- Keep synchronization controls visible while scrolling long course lists.
- Show how many materials were added or updated after every completed synchronization.
- Add a per-course breakdown ("Dettaglio") of what changed in the last sync, with newly-selected courses grouped to the top after syncing.
- Put the DMG first in the GitHub release assets and release notes.
- Keep the Sparkle update window compact and link directly to the changelog instead of embedding the GitHub release page.
- Build CI releases with the same Xcode 27 toolchain used for local Release builds.
- Show the changes included in each GitHub release from Beepbar's update flow.

## 2.0 beta

- Native Apple Silicon menu bar app with manual and scheduled WeBeep sync.
- Three-way synchronization that preserves local edits and exposes conflicts explicitly.
- Course selection and folder renaming, cancellable downloads, progress, and SQLite recovery.
- Keychain-backed authentication and opt-in updates through Sparkle.
