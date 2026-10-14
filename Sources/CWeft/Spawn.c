#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE
#endif

#include "CWeft.h"
#include <spawn.h>

short weft_spawn_setsid_flag(void) {
    return POSIX_SPAWN_SETSID;
}
