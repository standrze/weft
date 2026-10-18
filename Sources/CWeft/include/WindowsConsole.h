#ifndef WEFT_WINDOWS_CONSOLE_H
#define WEFT_WINDOWS_CONSOLE_H
#if defined(_WIN32)
#include <stddef.h>
#include <stdint.h>
/* Native console operations return zero on success; failures are Win32 error codes. */
uint32_t weft_console_begin(int raw_mode);
void weft_console_end(void);
int weft_console_read(uint8_t *bytes, size_t capacity, int32_t timeout_ms);
int weft_console_write(const uint8_t *bytes, size_t count);
void weft_console_size(int32_t *columns, int32_t *rows);
int32_t weft_console_signal(void);
void weft_console_drain_signal(void);
void *weft_console_waiter_create(void);
/* 1 readiness, 0 cancelled, -1 failure. No input is consumed by the waiter. */
int weft_console_waiter_wait(void *waiter);
void weft_console_waiter_cancel(void *waiter);
void weft_console_waiter_destroy(void *waiter);
/* Explicit isolated-console fixture, used only by opt-in native Windows tests. */
uint32_t weft_console_test_private(void);
void weft_console_test_private_end(void);
int weft_console_test_key(uint16_t character, uint16_t virtual_key, uint32_t modifiers);
int weft_console_test_mouse(int16_t x, int16_t y, uint32_t buttons, uint32_t flags, uint32_t modifiers);
int weft_console_test_resize(int16_t columns, int16_t rows);
void weft_console_test_state(uint32_t *input, uint32_t *output, uint32_t *input_cp, uint32_t *output_cp);
int weft_console_test_interrupt(void);
#endif
#endif
