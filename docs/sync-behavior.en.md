# Sync behavior

This document describes what BeepBar does in every sync situation and what the user sees. It is the reference for development and code review: a PR that changes any of these behaviors updates this document (and the Italian version, [`sync-behavior.it.md`](sync-behavior.it.md)) in the same change.

Parts marked with **[PR #54]**, **[PR #62]** or **[PR #63]** are not in a released version yet.

## Guarantees

These hold in every case described below.

1. **No local file is overwritten or deleted without your choice.** When BeepBar cannot know what you would prefer, it leaves the file where it is and asks.
2. **Only what Moodle actually showed is evaluated.** A course that did not load in that sync (not accessible, server error, no network), a course you turned off, or one you are no longer enrolled in causes no change to its files.
3. **Every action re-checks the state at the moment it runs.** If the file changed in the meantime, the action does nothing and stays pending. If the destination got taken, nothing is overwritten: a file moved to follow Moodle arrives with a number (section 4.1), any other action does nothing. **[PR #54]**
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

## 4. The teacher reorganizes or removes materials **[PR #54]**

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

### 4.2 The file is deleted and uploaded again elsewhere with the same contents

To Moodle this is a new file; BeepBar recognizes it because the contents are identical.

| Your file | What BeepBar does | What you see |
|---|---|---|
| Not edited | Moves it to the new place instead of downloading a second copy | "Moved" |
| Edited | Downloads the new copy at the new place and leaves yours alone | Entry in Conflicts: **Replace the new copy with my version** / **Keep both** / **Move mine to the Trash** |

If the file is uploaded again in exactly the same place, BeepBar keeps tracking the copy you have, edited or not: it does not download it again and asks nothing, since its contents did not change on Moodle.

If the new copy could not be downloaded, retry synchronization before moving your old copy to the Trash. BeepBar only allows this choice once a separate regular downloaded copy exists; editing that new copy does not prevent you from keeping it. **[PR #63]**

"Replace" moves the freshly downloaded copy (which you never touched) to the Trash and puts yours in its place; from then on an update by the teacher becomes a conflict. If your file changes or the destination gets taken during this action, your file stays where it is and the choice stays open. The downloaded copy remains recoverable in the Trash; the next sync restores it if its place is still empty. **[PR #63]**

BeepBar only recognizes a file uploaded again in the same course, and only when Moodle reports the file's content fingerprint. If the same contents appear in more than one place, BeepBar does not guess: the new copy downloads normally and the old file is treated as removed (4.3). The same happens if the unedited copy cannot be moved (for example because something else took its new place in the meantime).

### 4.3 The file is removed from Moodle

| Your file | What BeepBar does | What you see |
|---|---|---|
| Edited or not | Never deletes it on its own | Entry in Conflicts: **Keep** / **Move to the Trash** (the entry says so if you edited it) |

- **Keep**: the file stays and leaves the sync: it becomes an ordinary file of yours and is not reported again. If it later reappears on Moodle with the same contents, BeepBar tracks it again; with different contents it becomes a conflict.
- **Move to the Trash**: the file goes to the macOS Trash, where it can be recovered.
- A file still visible on Moodle but no longer downloadable is not considered removed.
- A temporarily hidden module looks removed; if it becomes visible again before you choose, the entry disappears.
- A file counts as removed only when Moodle showed its course in full: if a section, a module or an entry of that module was omitted or could not be read in that sync, nothing in it is considered removed, and entries already open stay as they are. **[PR #63]**

### 4.4 What never moves anything

- Changes, in a new app version, to the rules BeepBar uses to build paths.
- Renaming a course folder, and "Organizza cartelle" rules (section 5).
- The first sync after updating: BeepBar records where every file is and only follows later moves. Files already in an old folder stay where they are; they join the other files of their module only if that module is moved again on Moodle.

On the first sync after updating, the files the teacher removed from Moodle before the update, and that are still on your Mac, appear in Conflicts as removed, all at once: nothing is deleted, and you choose file by file. Files tracked by very old versions of BeepBar, which did not record their course, are never reported as removed.

## 5. Folders and organization

| Action | What happens |
|---|---|
| You rename a course folder | It is renamed on disk; BeepBar keeps tracking every file. If the name is taken, it says so and changes nothing |
| "Organizza cartelle": you give a module its own folder | Preview, then the module's files are moved; edited files are moved without being overwritten; a taken destination blocks the operation |
| "Ripristina layout Moodle" | Brings the module's files back to Moodle's structure, with the same preview |

## 6. Courses, network and automatic sync

- A course Moodle refuses (no longer enrolled, hidden, restricted) does not block the others; it shows as "Corso non accessibile" in the details.
- If every course fails because of the site or the connection, the sync is reported as failed and no file is touched.
- Automatic sync does not use metered connections (hotspots) and honours Low Data Mode; it is postponed, not skipped, under Low Power Mode or while another operation runs.

- **[PR #62]** While courses are refreshing, their switches are disabled; a choice still being saved is applied before the refreshed list is restored.
- **[PR #62]** Cancelling during the final checks ends the run without showing a completed result or sending its notification. Once completion or failure is shown, the run has ended and notification delivery cannot leave Cancel active.
- **[PR #62]** A delayed refresh cannot replace the state of a sync started afterward, a disconnected account, or a different sync folder.
- **[PR #62]** If pending choices cannot be read, their last displayed lists stay visible and the run reports a local error; it does not record a successful sync. An unreadable course selection also fails the refresh or automatic sync instead of being treated as an empty selection.

- **[PR #67]** A notification waiting for a permission check is discarded if its account, sync folder or result has been replaced; discarding it does not mark its condition as notified.

## 7. Where you see what

| Place | Contents |
|---|---|
| **Home** | A notice leading to Conflicts while something waits for your choice, including **[PR #54]** files moved or removed on Moodle |
| **Activity** | The last sync only: new, updated, your changes, not updated, moved, and edited files moved on Moodle that now wait in Conflicts **[PR #54]**. **[PR #69]** A click opens a file where it is now, even after a later sync moved it; the right-click menu also shows it in Finder. Only documents open directly; anything else (scripts, apps, disk images, unknown types) is only shown in Finder. A file that is no longer where BeepBar put it, including one replaced with a Finder alias, is reported on its row; a file without read permission reports that problem and opens nothing |
| **Conflicts** | Everything waiting for your choice, until you choose: conflicts and **[PR #54]** files moved or removed on Moodle. A refused or failed choice shows its reason on this page; a subsequent choice clears the old message |
| **Menu bar** | The status of the last sync. No new text for moves and removals |
| **Sign-in** | **[PR #59]** Onboarding and Settings show a failed sign-in beside its button; the next attempt clears the old message. A failed attempt does not replace an existing account. University selection stays locked during sign-in; verification, a new sign-in and disconnect wait for an ongoing account check to finish |
| **Notifications** | As today (new materials, conflicts). No new notifications for moves and removals. **[PR #67]** They can be turned off in Settings: while off none is sent, and a conflict still open may be notified at the next automatic sync after they are back on. A click opens Conflicts, Activity or Courses. They also appear while BeepBar is in front |
