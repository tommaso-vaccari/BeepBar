# Changelog

## Unreleased

### New

- Files a teacher removes from WeBeep are no longer left behind without a word. They appear in Conflicts, under "Spostati o rimossi su WeBeep", where you choose "Tieni" or "Sposta nel Cestino"; Beepbar never deletes anything by itself. On the first sync after updating, files removed from WeBeep in the past that are still on your Mac show up there too, all at once.

### Fixed

- An interrupted database upgrade no longer leaves synchronization unable to start on later launches; Beepbar completes the remaining schema changes when reopened.
- Disconnecting now removes any token left in a temporary file by an interrupted save. If the token cannot be removed, Beepbar keeps the account connected and shows an error so you can retry.
- When a teacher moves material to another section on WeBeep, renames it, or deletes it and uploads it again elsewhere, Beepbar now moves your copy to the matching folder instead of leaving it behind, without downloading it again. If the name is already taken there, it arrives with a number, as downloads do. A file you edited is never moved on its own: Conflicts asks whether to move your version or leave it where it is. Moves are followed from now on: after updating, files already sitting in an old folder stay where they are.
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
- Two courses with exactly the same name (for example two "Tesi di laurea") can now both be selected. They used to get the same folder, so the second one could never be turned on; it now gets its own folder, named after the course with its number added. Folders you already have are not renamed.
- The preview in "Organizza cartelle" no longer expires just because an automatic synchronization of another course ran in the meantime; confirming it used to fail with "I contenuti o i file locali sono cambiati dopo l'anteprima". The count of older files that are not moved now only covers the course you are organizing.
- A download that turns out larger than WeBeep announced is now stopped as soon as it goes over, instead of being written to disk in full and only then refused.

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
