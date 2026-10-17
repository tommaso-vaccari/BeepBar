#ifndef BEEPBAR_LINUX_COMPAT_H
#define BEEPBAR_LINUX_COMPAT_H

/// Linux-only helpers for `FileStore` (see `Sources/BeepbarCore/Portability/LinuxCompat.swift`).
/// Glibc's Swift overlay does not export `renameat2`, the one syscall behind `RENAME_NOREPLACE`
/// (macOS `RENAME_EXCL`) and `RENAME_EXCHANGE` (macOS `RENAME_SWAP`), which the atomic install
/// and swap paths depend on.

/// `renameat2(2)` with `RENAME_NOREPLACE`: fails with `EEXIST` when the destination exists.
int beepbar_renameat_noreplace(int fromfd, const char *from, int tofd, const char *to);

/// `renameat2(2)` with `RENAME_EXCHANGE`: both paths must exist and are swapped atomically.
int beepbar_renameat_exchange(int fromfd, const char *from, int tofd, const char *to);

#endif
