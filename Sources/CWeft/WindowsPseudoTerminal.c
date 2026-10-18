#if defined(_WIN32)
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#include <windows.h>
#include <stdlib.h>
#include <string.h>
#include "WindowsPseudoTerminal.h"

#define OUTPUT_CAPACITY 1048576
#define INPUT_CAPACITY 8192

struct weft_windows_pty {
    CRITICAL_SECTION lock, consoleLock;
    CONDITION_VARIABLE room;
    HPCON console;
    HANDLE input, output, process, job;
    HANDLE reader, writer, monitor;
    HANDLE readable, writable, inputReady;
    BYTE outputQueue[OUTPUT_CAPACITY];
    size_t outputStart, outputCount;
    BYTE inputQueue[INPUT_CAPACITY];
    DWORD inputCount, readError, writeError;
    int eof, closing;
};

static DWORD WINAPI read_output(void *context) {
    weft_windows_pty *pty = context;
    BYTE packet[8192];
    DWORD count, error = ERROR_SUCCESS;
    while (1) {
        if (!ReadFile(pty->output, packet, sizeof(packet), &count, NULL)) { error = GetLastError(); break; }
        if (!count) break;
        size_t copied = 0;
        EnterCriticalSection(&pty->lock);
        while (copied < count && !pty->closing) {
            while (pty->outputCount == OUTPUT_CAPACITY && !pty->closing)
                SleepConditionVariableCS(&pty->room, &pty->lock, INFINITE);
            if (pty->closing) break;
            size_t end = (pty->outputStart + pty->outputCount) % OUTPUT_CAPACITY;
            size_t amount = count - copied;
            if (amount > OUTPUT_CAPACITY - pty->outputCount) amount = OUTPUT_CAPACITY - pty->outputCount;
            if (amount > OUTPUT_CAPACITY - end) amount = OUTPUT_CAPACITY - end;
            memcpy(pty->outputQueue + end, packet + copied, amount);
            pty->outputCount += amount;
            copied += amount;
            SetEvent(pty->readable);
        }
        LeaveCriticalSection(&pty->lock);
        /* Teardown discards buffered bytes but continues draining ClosePseudoConsole's final frame. */
    }
    EnterCriticalSection(&pty->lock);
    pty->eof = 1;
    if (error != ERROR_BROKEN_PIPE && error != ERROR_OPERATION_ABORTED && error != ERROR_SUCCESS)
        pty->readError = error;
    SetEvent(pty->readable);
    LeaveCriticalSection(&pty->lock);
    return 0;
}

static DWORD WINAPI write_input(void *context) {
    weft_windows_pty *pty = context;
    BYTE packet[INPUT_CAPACITY];
    while (WaitForSingleObject(pty->inputReady, INFINITE) == WAIT_OBJECT_0) {
        EnterCriticalSection(&pty->lock);
        if (pty->closing) { LeaveCriticalSection(&pty->lock); break; }
        DWORD count = pty->inputCount;
        memcpy(packet, pty->inputQueue, count);
        ResetEvent(pty->inputReady);
        LeaveCriticalSection(&pty->lock);
        DWORD written = 0, error = 0;
        while (written < count) {
            DWORD amount = 0;
            if (!WriteFile(pty->input, packet + written, count - written, &amount, NULL) || !amount) {
                error = GetLastError();
                if (!error) error = ERROR_BROKEN_PIPE;
                break;
            }
            written += amount;
        }
        EnterCriticalSection(&pty->lock);
        pty->inputCount = 0;
        pty->writeError = error;
        SetEvent(pty->writable);
        LeaveCriticalSection(&pty->lock);
        if (error) break;
    }
    return 0;
}

static DWORD WINAPI monitor_process(void *context) {
    weft_windows_pty *pty = context;
    WaitForSingleObject(pty->process, INFINITE);
    EnterCriticalSection(&pty->consoleLock);
    HPCON console = pty->console;
    pty->console = NULL;
    LeaveCriticalSection(&pty->consoleLock);
    /* Reader stays alive during ClosePseudoConsole, including when its bounded queue fills. */
    if (console) ClosePseudoConsole(console);
    return 0;
}

static void close_handle(HANDLE handle) { if (handle && handle != INVALID_HANDLE_VALUE) CloseHandle(handle); }

void weft_windows_pty_destroy(weft_windows_pty *pty) {
    if (!pty) return;
    EnterCriticalSection(&pty->lock);
    pty->closing = 1;
    WakeAllConditionVariable(&pty->room);
    if (pty->inputReady) SetEvent(pty->inputReady);
    LeaveCriticalSection(&pty->lock);
    if (pty->job) TerminateJobObject(pty->job, 137);
    if (pty->process) WaitForSingleObject(pty->process, INFINITE);
    if (pty->monitor) WaitForSingleObject(pty->monitor, INFINITE);
    if (pty->console) { ClosePseudoConsole(pty->console); pty->console = NULL; }
    if (pty->writer) { CancelSynchronousIo(pty->writer); WaitForSingleObject(pty->writer, INFINITE); }
    close_handle(pty->input);
    if (pty->reader) WaitForSingleObject(pty->reader, INFINITE);
    close_handle(pty->output);
    close_handle(pty->reader); close_handle(pty->writer); close_handle(pty->monitor);
    close_handle(pty->process); close_handle(pty->job);
    close_handle(pty->readable); close_handle(pty->writable); close_handle(pty->inputReady);
    DeleteCriticalSection(&pty->consoleLock);
    DeleteCriticalSection(&pty->lock);
    free(pty);
}

weft_windows_pty *weft_windows_pty_spawn(const uint16_t *executable, uint16_t *command,
    const uint16_t *environment, const uint16_t *directory, int16_t columns, int16_t rows,
    uint32_t *pid, uint32_t *error) {
    weft_windows_pty *pty = calloc(1, sizeof(*pty));
    HANDLE inputRead = NULL, outputWrite = NULL, childThread = NULL;
    STARTUPINFOEXW startup = {0};
    SIZE_T attributeSize = 0;
    int initializedAttributes = 0;
    if (!pty) { *error = ERROR_NOT_ENOUGH_MEMORY; return NULL; }
    InitializeCriticalSection(&pty->lock);
    InitializeCriticalSection(&pty->consoleLock);
    InitializeConditionVariable(&pty->room);
    pty->readable = CreateEventW(NULL, TRUE, FALSE, NULL);
    pty->writable = CreateEventW(NULL, TRUE, TRUE, NULL);
    pty->inputReady = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (!pty->readable || !pty->writable || !pty->inputReady) goto failed;
    if (!CreatePipe(&inputRead, &pty->input, NULL, 0) || !CreatePipe(&pty->output, &outputWrite, NULL, 0)) goto failed;
    /* Start draining before creating HPCON; failure teardown can always drain its final frame. */
    pty->reader = CreateThread(NULL, 0, read_output, pty, 0, NULL);
    pty->writer = CreateThread(NULL, 0, write_input, pty, 0, NULL);
    if (!pty->reader || !pty->writer) goto failed;
    HRESULT result = CreatePseudoConsole((COORD){columns, rows}, inputRead, outputWrite, 0, &pty->console);
    if (FAILED(result)) { SetLastError((DWORD)result); goto failed; }
    startup.StartupInfo.cb = sizeof(startup);
    /* A console child can receive DUPLICATED redirected parent standard handles even
       with bInheritHandles=FALSE. Explicit NULL slots suppress that legacy fallback;
       the pseudoconsole connection supplies fresh console handles during startup.
       Microsoft console-team guidance: terminal/discussions/15814. Never mutate the
       parent's process-global standard handles to work around this behavior. */
    startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    startup.StartupInfo.hStdInput = NULL;
    startup.StartupInfo.hStdOutput = NULL;
    startup.StartupInfo.hStdError = NULL;
    InitializeProcThreadAttributeList(NULL, 1, 0, &attributeSize);
    startup.lpAttributeList = malloc(attributeSize);
    if (!startup.lpAttributeList) { SetLastError(ERROR_NOT_ENOUGH_MEMORY); goto failed; }
    if (!InitializeProcThreadAttributeList(startup.lpAttributeList, 1, 0, &attributeSize)) goto failed;
    initializedAttributes = 1;
    if (!UpdateProcThreadAttribute(startup.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
        pty->console, sizeof(pty->console), NULL, NULL)) goto failed;
    pty->job = CreateJobObjectW(NULL, NULL);
    if (!pty->job) goto failed;
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {0};
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (!SetInformationJobObject(pty->job, JobObjectExtendedLimitInformation, &limits, sizeof(limits))) goto failed;
    PROCESS_INFORMATION process = {0};
    if (!CreateProcessW((LPCWSTR)executable, (LPWSTR)command, NULL, NULL, FALSE,
        EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT | CREATE_SUSPENDED,
        (void *)environment, (LPCWSTR)directory, &startup.StartupInfo, &process)) goto failed;
    pty->process = process.hProcess;
    childThread = process.hThread;
    if (!AssignProcessToJobObject(pty->job, pty->process)) goto failed;
    pty->monitor = CreateThread(NULL, 0, monitor_process, pty, 0, NULL);
    if (!pty->monitor) goto failed;
    if (ResumeThread(childThread) == (DWORD)-1) goto failed;
    *pid = process.dwProcessId;
    close_handle(childThread); close_handle(inputRead); close_handle(outputWrite);
    DeleteProcThreadAttributeList(startup.lpAttributeList); free(startup.lpAttributeList);
    return pty;
failed:
    *error = GetLastError();
    if (pty->process) TerminateProcess(pty->process, 137);
    close_handle(childThread); close_handle(inputRead); close_handle(outputWrite);
    if (initializedAttributes) DeleteProcThreadAttributeList(startup.lpAttributeList);
    free(startup.lpAttributeList);
    weft_windows_pty_destroy(pty);
    return NULL;
}

int weft_windows_pty_read(weft_windows_pty *pty, uint8_t *bytes, uint32_t capacity, int32_t timeout,
    uint32_t *count, uint32_t *error) {
    DWORD ready = WaitForSingleObject(pty->readable, timeout < 0 ? INFINITE : (DWORD)timeout);
    if (ready == WAIT_TIMEOUT) return 0;
    if (ready != WAIT_OBJECT_0) { *error = GetLastError(); return -1; }
    EnterCriticalSection(&pty->lock);
    size_t amount = pty->outputCount < capacity ? pty->outputCount : capacity;
    for (size_t i = 0; i < amount; i++) bytes[i] = pty->outputQueue[(pty->outputStart + i) % OUTPUT_CAPACITY];
    pty->outputStart = (pty->outputStart + amount) % OUTPUT_CAPACITY;
    pty->outputCount -= amount;
    *count = (uint32_t)amount;
    if (!pty->outputCount && !pty->eof) ResetEvent(pty->readable);
    WakeAllConditionVariable(&pty->room);
    int result = amount ? 1 : pty->readError ? -1 : pty->eof ? 2 : 0;
    *error = pty->readError;
    LeaveCriticalSection(&pty->lock);
    return result;
}
int weft_windows_pty_write(weft_windows_pty *pty, const uint8_t *bytes, uint32_t count,
    uint32_t *written, uint32_t *error) {
    EnterCriticalSection(&pty->lock);
    if (pty->writeError || pty->closing) {
        *error = pty->writeError ? pty->writeError : ERROR_BROKEN_PIPE;
        LeaveCriticalSection(&pty->lock); return -1;
    }
    *written = 0;
    if (!pty->inputCount && count) {
        *written = count < INPUT_CAPACITY ? count : INPUT_CAPACITY;
        memcpy(pty->inputQueue, bytes, *written);
        pty->inputCount = *written;
        ResetEvent(pty->writable); SetEvent(pty->inputReady);
    }
    LeaveCriticalSection(&pty->lock); return 0;
}
int weft_windows_pty_writable(weft_windows_pty *pty, uint32_t timeout, uint32_t *error) {
    DWORD result = WaitForSingleObject(pty->writable, timeout);
    if (result == WAIT_FAILED) { *error = GetLastError(); return -1; }
    EnterCriticalSection(&pty->lock);
    *error = pty->writeError;
    LeaveCriticalSection(&pty->lock);
    if (*error) return -1;
    return result == WAIT_OBJECT_0;
}
int weft_windows_pty_resize(weft_windows_pty *pty, int16_t columns, int16_t rows, uint32_t *error) {
    /* Keep console lifetime stable without blocking the output-reader queue lock. */
    EnterCriticalSection(&pty->consoleLock);
    HRESULT result = pty->console ? ResizePseudoConsole(pty->console, (COORD){columns, rows}) : HRESULT_FROM_WIN32(ERROR_BROKEN_PIPE);
    LeaveCriticalSection(&pty->consoleLock);
    if (FAILED(result)) { *error = (DWORD)result; return -1; }
    return 0;
}
int weft_windows_pty_status(weft_windows_pty *pty, uint32_t *status, uint32_t *error) {
    DWORD ready = WaitForSingleObject(pty->process, 0);
    if (ready == WAIT_TIMEOUT) return 0;
    if (ready != WAIT_OBJECT_0 || !GetExitCodeProcess(pty->process, (DWORD *)status)) {
        *error = GetLastError(); return -1;
    }
    return 1;
}
int weft_windows_pty_terminate(weft_windows_pty *pty, uint32_t status, uint32_t *error) {
    if (TerminateJobObject(pty->job, status)) return 0;
    *error = GetLastError(); return -1;
}
#endif
