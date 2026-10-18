#ifndef WEFT_POSIX_H
#define WEFT_POSIX_H

/* Expose the platform's new-session spawn flag without hard-coding its value. */
short weft_spawn_setsid_flag(void);

#include "WindowsPseudoTerminal.h"
#include "WindowsConsole.h"

#endif
