#ifndef WEFT_WINDOWS_PSEUDO_TERMINAL_H
#define WEFT_WINDOWS_PSEUDO_TERMINAL_H
#include <stdint.h>
#include <stddef.h>
#if defined(_WIN32)
typedef struct weft_windows_pty weft_windows_pty;
weft_windows_pty *weft_windows_pty_spawn(const uint16_t *executable, uint16_t *command,
    const uint16_t *environment, const uint16_t *directory, int16_t columns, int16_t rows,
    uint32_t *pid, uint32_t *error);
/* read: 1=data, 0=not ready, 2=EOF, -1=error. All buffers are bounded. */
int weft_windows_pty_read(weft_windows_pty *, uint8_t *, uint32_t, int32_t timeout, uint32_t *count, uint32_t *error);
int weft_windows_pty_write(weft_windows_pty *, const uint8_t *, uint32_t, uint32_t *count, uint32_t *error);
int weft_windows_pty_writable(weft_windows_pty *, uint32_t timeout, uint32_t *error);
int weft_windows_pty_resize(weft_windows_pty *, int16_t columns, int16_t rows, uint32_t *error);
int weft_windows_pty_status(weft_windows_pty *, uint32_t *status, uint32_t *error);
int weft_windows_pty_terminate(weft_windows_pty *, uint32_t status, uint32_t *error);
/* Blocking cleanup: caller must dispatch away from its UI/input execution context. */
void weft_windows_pty_destroy(weft_windows_pty *);
#endif
#endif
