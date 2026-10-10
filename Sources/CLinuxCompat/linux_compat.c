#define _GNU_SOURCE
#include <stdio.h>
#include <fcntl.h>
#include "linux_compat.h"

int beepbar_renameat_noreplace(int fromfd, const char *from, int tofd, const char *to) {
    return renameat2(fromfd, from, tofd, to, RENAME_NOREPLACE);
}

int beepbar_renameat_exchange(int fromfd, const char *from, int tofd, const char *to) {
    return renameat2(fromfd, from, tofd, to, RENAME_EXCHANGE);
}
