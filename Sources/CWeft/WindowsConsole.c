#include "WindowsConsole.h"
#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

static HANDLE console_input, console_output, console_signal_event, console_bytes_event;
static DWORD saved_input_mode, saved_output_mode, saved_input_cp, saved_output_cp;
static LONG console_active, console_signal;
static WCHAR pending_surrogate;
static unsigned char pending_bytes[128];
static size_t pending_count, pending_offset;
static WORD pending_repeats;
static unsigned char repeated_bytes[128];
static size_t repeated_count;
static DWORD previous_buttons;
static int mouse_clicks, mouse_drags, mouse_motion, focus_reports;
static char output_csi[64];
static size_t output_csi_count;

static BOOL WINAPI console_control(DWORD event) {
    if (!InterlockedCompareExchange(&console_active, 0, 0)) return FALSE;
    LONG number;
    switch (event) {
        case CTRL_C_EVENT: number = 2; break;
        case CTRL_BREAK_EVENT: number = 15; break;
        case CTRL_CLOSE_EVENT: number = 1; break;
        case CTRL_LOGOFF_EVENT: case CTRL_SHUTDOWN_EVENT: number = 15; break;
        default: return FALSE;
    }
    InterlockedExchange(&console_signal, number);
    SetEvent(console_signal_event);
    return TRUE;
}

uint32_t weft_console_begin(int raw_mode) {
    if (!raw_mode) return ERROR_NOT_SUPPORTED;
    if (InterlockedCompareExchange(&console_active, 0, 0)) return ERROR_BUSY;
    console_input = GetStdHandle(STD_INPUT_HANDLE);
    console_output = GetStdHandle(STD_OUTPUT_HANDLE);
    if (!GetConsoleMode(console_input, &saved_input_mode) || !GetConsoleMode(console_output, &saved_output_mode))
        return ERROR_INVALID_HANDLE;
    saved_input_cp = GetConsoleCP();
    saved_output_cp = GetConsoleOutputCP();
    /* Keep bounded notification handles for process lifetime: a control callback may still return after end. */
    if (!console_signal_event) console_signal_event = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (!console_bytes_event) console_bytes_event = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (!console_signal_event || !console_bytes_event) return GetLastError();
    ResetEvent(console_signal_event);
    ResetEvent(console_bytes_event);
    DWORD input_mode = saved_input_mode | ENABLE_WINDOW_INPUT | ENABLE_EXTENDED_FLAGS;
    /* ReadConsoleInputW is the only reader: preserve native resize/mouse records and encode keys once. */
    input_mode &= ~(ENABLE_VIRTUAL_TERMINAL_INPUT | ENABLE_QUICK_EDIT_MODE);
    if (raw_mode) input_mode &= ~(ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT | ENABLE_PROCESSED_INPUT);
    input_mode |= ENABLE_MOUSE_INPUT;
    DWORD error = 0;
    if (!SetConsoleMode(console_input, input_mode)
        || !SetConsoleMode(console_output, saved_output_mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING | ENABLE_PROCESSED_OUTPUT)
        || !SetConsoleCP(CP_UTF8) || !SetConsoleOutputCP(CP_UTF8)) {
        error = GetLastError();
    } else if (!SetConsoleCtrlHandler(console_control, TRUE)) {
        error = GetLastError();
    }
    if (error) {
        SetConsoleMode(console_input, saved_input_mode);
        SetConsoleMode(console_output, saved_output_mode);
        SetConsoleCP(saved_input_cp);
        SetConsoleOutputCP(saved_output_cp);
        return error;
    }
    pending_count = pending_offset = repeated_count = pending_repeats = 0;
    pending_surrogate = 0;
    previous_buttons = 0;
    mouse_clicks = mouse_drags = mouse_motion = focus_reports = 0;
    output_csi_count = 0;
    InterlockedExchange(&console_signal, 0);
    InterlockedExchange(&console_active, 1);
    return 0;
}

void weft_console_end(void) {
    if (!InterlockedExchange(&console_active, 0)) return;
    SetConsoleCtrlHandler(console_control, FALSE);
    SetConsoleMode(console_input, saved_input_mode);
    SetConsoleMode(console_output, saved_output_mode);
    SetConsoleCP(saved_input_cp);
    SetConsoleOutputCP(saved_output_cp);
    /* Waiters own duplicate handles, so cancelling a source cannot race handle reuse here. */
    SetEvent(console_signal_event);
    ResetEvent(console_bytes_event);
    pending_count = pending_offset = repeated_count = pending_repeats = 0;
    pending_surrogate = 0;
    InterlockedExchange(&console_signal, 0);
}

int32_t weft_console_signal(void) { return InterlockedCompareExchange(&console_signal, 0, 0); }
void weft_console_drain_signal(void) { if (console_signal_event) ResetEvent(console_signal_event); }

void weft_console_size(int32_t *columns, int32_t *rows) {
    CONSOLE_SCREEN_BUFFER_INFO info;
    HANDLE output = InterlockedCompareExchange(&console_active, 0, 0) ? console_output : GetStdHandle(STD_OUTPUT_HANDLE);
    *columns = 80; *rows = 24;
    if (GetConsoleScreenBufferInfo(output, &info)) {
        int width = info.srWindow.Right - info.srWindow.Left + 1;
        int height = info.srWindow.Bottom - info.srWindow.Top + 1;
        if (width > 0 && height > 0) { *columns = width; *rows = height; }
    }
}

/* Track only input reporting policies; ordinary VT output still goes unchanged to the console. */
static void inspect_output(const uint8_t *bytes, size_t count) {
    for (size_t index = 0; index < count; ++index) {
        unsigned char byte = bytes[index];
        if (byte == 27) { output_csi_count = 1; output_csi[0] = 27; continue; }
        if (!output_csi_count) continue;
        if (output_csi_count == 1 && byte != '[') { output_csi_count = 0; continue; }
        if (output_csi_count + 1 >= sizeof(output_csi)) { output_csi_count = 0; continue; }
        output_csi[output_csi_count++] = (char)byte;
        if (byte < 0x40 || byte > 0x7e || output_csi_count <= 2) continue;
        output_csi[output_csi_count] = 0;
        int enabled = byte == 'h';
        if (enabled || byte == 'l') {
            if (strncmp(output_csi, "\033[?1000", 7) == 0) mouse_clicks = enabled;
            if (strncmp(output_csi, "\033[?1002", 7) == 0) mouse_drags = enabled;
            if (strncmp(output_csi, "\033[?1003", 7) == 0) mouse_motion = enabled;
            if (strncmp(output_csi, "\033[?1004", 7) == 0) focus_reports = enabled;
        }
        output_csi_count = 0;
    }
}

int weft_console_write(const uint8_t *bytes, size_t count) {
    size_t offset = 0;
    HANDLE output = InterlockedCompareExchange(&console_active, 0, 0) ? console_output : GetStdHandle(STD_OUTPUT_HANDLE);
    while (offset < count) {
        DWORD written = 0;
        DWORD portion = count - offset > MAXDWORD ? MAXDWORD : (DWORD)(count - offset);
        if (!WriteFile(output, bytes + offset, portion, &written, NULL) || !written) return 0;
        inspect_output(bytes + offset, written);
        offset += written;
    }
    return 1;
}

static void set_pending(const char *text) {
    pending_count = strlen(text);
    memcpy(pending_bytes, text, pending_count);
    pending_offset = 0;
    SetEvent(console_bytes_event);
}

static void encode_character(WCHAR character, DWORD modifiers) {
    WCHAR utf16[2];
    int length = 1;
    utf16[0] = character;
    if (character >= 0xd800 && character <= 0xdbff) { pending_surrogate = character; return; }
    if (character >= 0xdc00 && character <= 0xdfff && pending_surrogate) {
        utf16[0] = pending_surrogate; utf16[1] = character; length = 2;
    }
    pending_surrogate = 0;
    pending_offset = pending_count = 0;
    /* AltGr produces text; do not turn it into an Alt chord. */
    if ((modifiers & (LEFT_ALT_PRESSED | RIGHT_ALT_PRESSED))
        && !((modifiers & RIGHT_ALT_PRESSED) && (modifiers & LEFT_CTRL_PRESSED)))
        pending_bytes[pending_count++] = 27;
    int count = WideCharToMultiByte(CP_UTF8, 0, utf16, length,
        (char *)pending_bytes + pending_count, (int)(sizeof(pending_bytes) - pending_count), NULL, NULL);
    if (count > 0) pending_count += (size_t)count;
    if (pending_count) SetEvent(console_bytes_event);
}

static void encode_key(const KEY_EVENT_RECORD *key) {
    if (!key->bKeyDown) return;
    DWORD modifiers = key->dwControlKeyState;
    int parameter = 1 + ((modifiers & SHIFT_PRESSED) ? 1 : 0)
        + ((modifiers & (LEFT_ALT_PRESSED | RIGHT_ALT_PRESSED)) ? 2 : 0)
        + ((modifiers & (LEFT_CTRL_PRESSED | RIGHT_CTRL_PRESSED)) ? 4 : 0);
    char sequence[32];
    const char *final = NULL;
    int tilde = 0;
    switch (key->wVirtualKeyCode) {
        case VK_UP: final = "A"; break; case VK_DOWN: final = "B"; break;
        case VK_RIGHT: final = "C"; break; case VK_LEFT: final = "D"; break;
        case VK_HOME: final = "H"; break; case VK_END: final = "F"; break;
        case VK_INSERT: tilde = 2; break; case VK_DELETE: tilde = 3; break;
        case VK_PRIOR: tilde = 5; break; case VK_NEXT: tilde = 6; break;
        case VK_F1: final = "P"; break; case VK_F2: final = "Q"; break;
        case VK_F3: final = "R"; break; case VK_F4: final = "S"; break;
        case VK_F5: tilde = 15; break; case VK_F6: tilde = 17; break;
        case VK_F7: tilde = 18; break; case VK_F8: tilde = 19; break;
        case VK_F9: tilde = 20; break; case VK_F10: tilde = 21; break;
        case VK_F11: tilde = 23; break; case VK_F12: tilde = 24; break;
        case VK_TAB:
            if (modifiers & SHIFT_PRESSED) { set_pending("\033[Z"); goto repeat; }
            break;
    }
    if (final) {
        if (parameter > 1) snprintf(sequence, sizeof(sequence), "\033[1;%d%s", parameter, final);
        else snprintf(sequence, sizeof(sequence), key->wVirtualKeyCode >= VK_F1 && key->wVirtualKeyCode <= VK_F4
            ? "\033O%s" : "\033[%s", final);
        set_pending(sequence);
    } else if (tilde) {
        if (parameter > 1) snprintf(sequence, sizeof(sequence), "\033[%d;%d~", tilde, parameter);
        else snprintf(sequence, sizeof(sequence), "\033[%d~", tilde);
        set_pending(sequence);
    } else if (key->uChar.UnicodeChar) {
        encode_character(key->uChar.UnicodeChar, modifiers);
    } else if (key->wVirtualKeyCode == VK_SPACE && (modifiers & (LEFT_CTRL_PRESSED | RIGHT_CTRL_PRESSED))) {
        pending_bytes[0] = 0; pending_count = 1; pending_offset = 0;
    }
repeat:
    if (pending_count) {
        SetEvent(console_bytes_event);
        memcpy(repeated_bytes, pending_bytes, pending_count);
        repeated_count = pending_count;
        pending_repeats = key->wRepeatCount > 0 ? key->wRepeatCount - 1 : 0;
    }
}

static void encode_mouse(const MOUSE_EVENT_RECORD *mouse) {
    if (!(mouse_clicks || mouse_drags || mouse_motion)) { previous_buttons = mouse->dwButtonState; return; }
    DWORD buttons = mouse->dwButtonState & 0xffff;
    int code = 3;
    if (buttons & FROM_LEFT_1ST_BUTTON_PRESSED) code = 0;
    else if (buttons & FROM_LEFT_2ND_BUTTON_PRESSED) code = 1;
    else if (buttons & RIGHTMOST_BUTTON_PRESSED) code = 2;
    char final = 'M';
    if (mouse->dwEventFlags & MOUSE_WHEELED) code = (SHORT)HIWORD(mouse->dwButtonState) > 0 ? 64 : 65;
    else if (mouse->dwEventFlags & MOUSE_HWHEELED) code = (SHORT)HIWORD(mouse->dwButtonState) > 0 ? 67 : 66;
    else if (mouse->dwEventFlags & MOUSE_MOVED) {
        if (!mouse_motion && (!mouse_drags || !buttons)) { previous_buttons = buttons; return; }
        code += 32;
    } else if (!buttons && previous_buttons) {
        code = (previous_buttons & FROM_LEFT_1ST_BUTTON_PRESSED) ? 0
            : (previous_buttons & FROM_LEFT_2ND_BUTTON_PRESSED) ? 1 : 2;
        final = 'm';
    }
    previous_buttons = buttons;
    if (mouse->dwControlKeyState & SHIFT_PRESSED) code += 4;
    if (mouse->dwControlKeyState & (LEFT_ALT_PRESSED | RIGHT_ALT_PRESSED)) code += 8;
    if (mouse->dwControlKeyState & (LEFT_CTRL_PRESSED | RIGHT_CTRL_PRESSED)) code += 16;
    CONSOLE_SCREEN_BUFFER_INFO info;
    int left = 0, top = 0;
    if (GetConsoleScreenBufferInfo(console_output, &info)) { left = info.srWindow.Left; top = info.srWindow.Top; }
    char sequence[64];
    snprintf(sequence, sizeof(sequence), "\033[<%d;%d;%d%c", code,
        (int)mouse->dwMousePosition.X - left + 1, (int)mouse->dwMousePosition.Y - top + 1, final);
    set_pending(sequence);
}

int weft_console_read(uint8_t *bytes, size_t capacity, int32_t timeout_ms) {
    if (!InterlockedCompareExchange(&console_active, 0, 0) || !capacity) return -1;
    if (pending_offset == pending_count && pending_repeats) {
        memcpy(pending_bytes, repeated_bytes, repeated_count);
        pending_count = repeated_count; pending_offset = 0; --pending_repeats;
    }
    if (pending_offset < pending_count) {
        size_t count = pending_count - pending_offset;
        if (count > capacity) count = capacity;
        memcpy(bytes, pending_bytes + pending_offset, count);
        pending_offset += count;
        if (pending_offset == pending_count && !pending_repeats) ResetEvent(console_bytes_event);
        return (int)count;
    }
    pending_count = pending_offset = 0;
    HANDLE handles[] = { console_signal_event, console_input };
    DWORD result = WaitForMultipleObjects(2, handles, FALSE, timeout_ms < 0 ? INFINITE : (DWORD)timeout_ms);
    if (result == WAIT_OBJECT_0 || result == WAIT_TIMEOUT) return 0;
    if (result != WAIT_OBJECT_0 + 1) return -1;
    INPUT_RECORD record;
    DWORD count = 0;
    if (!ReadConsoleInputW(console_input, &record, 1, &count)) return -1;
    if (!count) return 0;
    if (record.EventType == KEY_EVENT) encode_key(&record.Event.KeyEvent);
    else if (record.EventType == MOUSE_EVENT) encode_mouse(&record.Event.MouseEvent);
    else if (record.EventType == FOCUS_EVENT && focus_reports)
        set_pending(record.Event.FocusEvent.bSetFocus ? "\033[I" : "\033[O");
    /* Resize records wake the shared session; GetConsoleScreenBufferInfo supplies viewport dimensions. */
    if (!pending_count) return 0;
    return weft_console_read(bytes, capacity, 0);
}

typedef struct { HANDLE cancel, input, signal, bytes; int signal_delivered; } console_waiter;
void *weft_console_waiter_create(void) {
    if (!InterlockedCompareExchange(&console_active, 0, 0)) return NULL;
    console_waiter *waiter = (console_waiter *)calloc(1, sizeof(console_waiter));
    if (!waiter) return NULL;
    HANDLE process = GetCurrentProcess();
    waiter->cancel = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (!waiter->cancel || !DuplicateHandle(process, console_input, process, &waiter->input, 0, FALSE, DUPLICATE_SAME_ACCESS)
        || !DuplicateHandle(process, console_signal_event, process, &waiter->signal, 0, FALSE, DUPLICATE_SAME_ACCESS)
        || !DuplicateHandle(process, console_bytes_event, process, &waiter->bytes, 0, FALSE, DUPLICATE_SAME_ACCESS)) {
        weft_console_waiter_destroy(waiter); return NULL;
    }
    return waiter;
}
int weft_console_waiter_wait(void *opaque) {
    console_waiter *waiter = (console_waiter *)opaque;
    /* Termination is sticky at the session layer. Do not spin on unread input after delivery. */
    if (weft_console_signal()) {
        if (!waiter->signal_delivered) { waiter->signal_delivered = 1; return 1; }
        return WaitForSingleObject(waiter->cancel, INFINITE) == WAIT_OBJECT_0 ? 0 : -1;
    }
    HANDLE handles[] = { waiter->cancel, waiter->signal, waiter->input, waiter->bytes };
    DWORD result = WaitForMultipleObjects(4, handles, FALSE, INFINITE);
    if (result == WAIT_OBJECT_0 + 1) waiter->signal_delivered = 1;
    return result == WAIT_OBJECT_0 ? 0 : result >= WAIT_OBJECT_0 + 1 && result <= WAIT_OBJECT_0 + 3 ? 1 : -1;
}
void weft_console_waiter_cancel(void *opaque) { if (opaque) SetEvent(((console_waiter *)opaque)->cancel); }
void weft_console_waiter_destroy(void *opaque) {
    console_waiter *waiter = (console_waiter *)opaque;
    if (!waiter) return;
    if (waiter->cancel) CloseHandle(waiter->cancel);
    if (waiter->input) CloseHandle(waiter->input);
    if (waiter->signal) CloseHandle(waiter->signal);
    if (waiter->bytes) CloseHandle(waiter->bytes);
    free(waiter);
}

static HANDLE fixture_saved_input, fixture_saved_output, fixture_saved_error;
static HANDLE fixture_input, fixture_output;
static HANDLE fixture_allocated_input, fixture_allocated_output, fixture_allocated_error;
static int fixture_active;

void weft_console_test_private_end(void) {
    if (!fixture_active) return;
    weft_console_end();
    HANDLE handles[] = {fixture_input, fixture_output, fixture_allocated_input,
        fixture_allocated_output, fixture_allocated_error};
    for (size_t index = 0; index < sizeof(handles) / sizeof(handles[0]); ++index) {
        HANDLE handle = handles[index];
        if (!handle || handle == INVALID_HANDLE_VALUE || handle == fixture_saved_input
            || handle == fixture_saved_output || handle == fixture_saved_error) continue;
        int duplicate = 0;
        for (size_t prior = 0; prior < index; ++prior) if (handles[prior] == handle) duplicate = 1;
        if (!duplicate) CloseHandle(handle);
    }
    fixture_input = fixture_output = NULL;
    fixture_allocated_input = fixture_allocated_output = fixture_allocated_error = NULL;
    FreeConsole();
    SetStdHandle(STD_INPUT_HANDLE, fixture_saved_input);
    SetStdHandle(STD_OUTPUT_HANDLE, fixture_saved_output);
    SetStdHandle(STD_ERROR_HANDLE, fixture_saved_error);
    fixture_active = 0;
}

uint32_t weft_console_test_private(void) {
    if (fixture_active) return ERROR_BUSY;
    fixture_saved_input = GetStdHandle(STD_INPUT_HANDLE);
    fixture_saved_output = GetStdHandle(STD_OUTPUT_HANDLE);
    fixture_saved_error = GetStdHandle(STD_ERROR_HANDLE);
    /* Detach this test process only. Inherited pipe handles remain valid for the test reporter. */
    FreeConsole();
    fixture_active = 1;
    if (!AllocConsole()) {
        DWORD error = GetLastError();
        weft_console_test_private_end();
        return error;
    }
    fixture_allocated_input = GetStdHandle(STD_INPUT_HANDLE);
    fixture_allocated_output = GetStdHandle(STD_OUTPUT_HANDLE);
    fixture_allocated_error = GetStdHandle(STD_ERROR_HANDLE);
    fixture_input = CreateFileW(L"CONIN$", GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
        NULL, OPEN_EXISTING, 0, NULL);
    fixture_output = CreateFileW(L"CONOUT$", GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
        NULL, OPEN_EXISTING, 0, NULL);
    if (fixture_input == INVALID_HANDLE_VALUE || fixture_output == INVALID_HANDLE_VALUE) {
        DWORD error = GetLastError();
        weft_console_test_private_end();
        return error;
    }
    if (!SetStdHandle(STD_INPUT_HANDLE, fixture_input) || !SetStdHandle(STD_OUTPUT_HANDLE, fixture_output)
        || !SetStdHandle(STD_ERROR_HANDLE, fixture_saved_error)) {
        DWORD error = GetLastError();
        weft_console_test_private_end();
        return error;
    }
    return 0;
}
int weft_console_test_key(uint16_t character, uint16_t virtual_key, uint32_t modifiers) {
    INPUT_RECORD record = {0}; DWORD written;
    record.EventType = KEY_EVENT;
    record.Event.KeyEvent.bKeyDown = TRUE;
    record.Event.KeyEvent.wRepeatCount = 1;
    record.Event.KeyEvent.wVirtualKeyCode = virtual_key;
    record.Event.KeyEvent.uChar.UnicodeChar = character;
    record.Event.KeyEvent.dwControlKeyState = modifiers;
    return WriteConsoleInputW(GetStdHandle(STD_INPUT_HANDLE), &record, 1, &written) && written == 1;
}
int weft_console_test_resize(int16_t columns, int16_t rows) {
    HANDLE output = GetStdHandle(STD_OUTPUT_HANDLE);
    CONSOLE_SCREEN_BUFFER_INFO info;
    if (!GetConsoleScreenBufferInfo(output, &info)) return 0;
    SMALL_RECT window = {0, 0, (SHORT)(columns - 1), (SHORT)(rows - 1)};
    COORD size = {columns > info.dwSize.X ? columns : info.dwSize.X, rows > info.dwSize.Y ? rows : info.dwSize.Y};
    if (!SetConsoleScreenBufferSize(output, size) || !SetConsoleWindowInfo(output, TRUE, &window)) return 0;
    INPUT_RECORD record = {0}; DWORD written;
    record.EventType = WINDOW_BUFFER_SIZE_EVENT;
    record.Event.WindowBufferSizeEvent.dwSize = size;
    return WriteConsoleInputW(GetStdHandle(STD_INPUT_HANDLE), &record, 1, &written) && written == 1;
}
void weft_console_test_state(uint32_t *input, uint32_t *output, uint32_t *input_cp, uint32_t *output_cp) {
    DWORD input_mode = 0, output_mode = 0;
    GetConsoleMode(GetStdHandle(STD_INPUT_HANDLE), &input_mode);
    GetConsoleMode(GetStdHandle(STD_OUTPUT_HANDLE), &output_mode);
    *input = (uint32_t)input_mode; *output = (uint32_t)output_mode;
    *input_cp = GetConsoleCP(); *output_cp = GetConsoleOutputCP();
}
int weft_console_test_interrupt(void) { return GenerateConsoleCtrlEvent(CTRL_C_EVENT, 0); }
#endif
