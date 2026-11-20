// Crash capture for devices where no crash report reaches us (Apple TV:
// TestFlight on tvOS has no feedback screen and there is no Mac to read the
// device's crash logs). Installed once at launch:
//   - stdout/stderr go to Logs/stdio-latest.log, so runtime, Metal and Swift
//     runtime messages ("Fatal error: ...", "failed assertion ...") are kept;
//   - fatal signals append the signal, fault address, last stage and a
//     backtrace to Logs/crash-latest.txt, then re-raise so the system still
//     records its own report;
//   - an uncaught C++ exception is written there with its message.
// The previous launch's files are rotated to *-previous.* for the app to show.
#include <TargetConditionals.h>
#include <cerrno>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <exception>
#include <execinfo.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <unistd.h>
#if TARGET_OS_IPHONE
#include <os/proc.h>
#endif

namespace {
char crashPath[1024];
char stage[256] = "launch";
bool installed = false;
int stdioFd = -1;
constexpr int kSignals[] = {SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGFPE, SIGTRAP, SIGSYS};

// Signal-safe writers (no malloc, no stdio).
void put(int fd, const char *text) {
    size_t length = std::strlen(text);
    while (length > 0) {
        ssize_t written = write(fd, text, length);
        if (written <= 0) return;
        text += written;
        length -= static_cast<size_t>(written);
    }
}

void putHex(int fd, uintptr_t value) {
    char buffer[2 + sizeof(uintptr_t) * 2 + 1];
    buffer[0] = '0';
    buffer[1] = 'x';
    for (size_t i = 0; i < sizeof(uintptr_t) * 2; ++i) {
        const unsigned digit = (value >> ((sizeof(uintptr_t) * 2 - 1 - i) * 4)) & 0xF;
        buffer[2 + i] = static_cast<char>(digit < 10 ? '0' + digit : 'a' + digit - 10);
    }
    buffer[sizeof(buffer) - 1] = 0;
    put(fd, buffer);
}

void putDecimal(int fd, long value) {
    char buffer[24];
    char *end = buffer + sizeof(buffer) - 1;
    *end = 0;
    bool negative = value < 0;
    unsigned long magnitude = negative ? static_cast<unsigned long>(-value) : static_cast<unsigned long>(value);
    do {
        *--end = static_cast<char>('0' + magnitude % 10);
        magnitude /= 10;
    } while (magnitude != 0);
    if (negative) *--end = '-';
    put(fd, end);
}

const char *signalName(int signal) {
    switch (signal) {
    case SIGSEGV: return "SIGSEGV (bad memory access)";
    case SIGBUS: return "SIGBUS (bad memory access)";
    case SIGILL: return "SIGILL (illegal instruction)";
    case SIGABRT: return "SIGABRT (abort)";
    case SIGFPE: return "SIGFPE (arithmetic)";
    case SIGTRAP: return "SIGTRAP (trap: Swift runtime error or breakpoint)";
    case SIGSYS: return "SIGSYS (bad system call)";
    default: return "signal";
    }
}

void writeBacktrace(int fd) {
    void *frames[96];
    const int count = backtrace(frames, 96);
    put(fd, "backtrace:\n");
    backtrace_symbols_fd(frames, count, fd);
    // (frames in the stripped app binary print as offsets; the slide lets them
    // be matched to a symbol map of the same build)
    put(fd, "main image slide ");
    putHex(fd, static_cast<uintptr_t>(_dyld_get_image_vmaddr_slide(0)));
    put(fd, "\n");
}

void onSignal(int signal, siginfo_t *info, void *) {
    const int fd = open(crashPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        put(fd, "crash: ");
        put(fd, signalName(signal));
        put(fd, " signal=");
        putDecimal(fd, signal);
        put(fd, " code=");
        putDecimal(fd, info ? info->si_code : 0);
        put(fd, " address=");
        putHex(fd, reinterpret_cast<uintptr_t>(info ? info->si_addr : nullptr));
        put(fd, "\nlast stage: ");
        put(fd, stage);
        put(fd, "\n");
        writeBacktrace(fd);
        close(fd);
    }
    if (stdioFd >= 0) {
        put(STDERR_FILENO, "[GoldenPad] crash: ");
        put(STDERR_FILENO, signalName(signal));
        put(STDERR_FILENO, "\n");
    }
    // Let the system handle it too (its crash report, the normal exit).
    struct sigaction fallback {};
    fallback.sa_handler = SIG_DFL;
    sigemptyset(&fallback.sa_mask);
    sigaction(signal, &fallback, nullptr);
    raise(signal);
}

void onTerminate() {
    const int fd = open(crashPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        put(fd, "crash: uncaught C++ exception: ");
        try {
            if (auto current = std::current_exception()) std::rethrow_exception(current);
            put(fd, "(none; std::terminate called directly)");
        } catch (const std::exception &error) {
            put(fd, error.what());
        } catch (...) {
            put(fd, "(not a std::exception)");
        }
        put(fd, "\nlast stage: ");
        put(fd, stage);
        put(fd, "\n");
        close(fd);
    }
    std::abort();
}

void rotate(const char *directory, const char *latest, const char *previous, char *latestPath, size_t size) {
    char previousPath[1024];
    std::snprintf(latestPath, size, "%s/%s", directory, latest);
    std::snprintf(previousPath, sizeof(previousPath), "%s/%s", directory, previous);
    unlink(previousPath);
    rename(latestPath, previousPath);
}
}  // namespace

extern "C" void goldenpad_crash_note(const char *text) {
    if (text == nullptr) return;
    std::strncpy(stage, text, sizeof(stage) - 1);
    stage[sizeof(stage) - 1] = 0;
    if (stdioFd < 0) return;
    // Unbuffered, so the line is on disk even if the next instruction crashes.
    char line[512];
    std::snprintf(line, sizeof(line), "[GoldenPad] stage: %s\n", stage);
    put(STDERR_FILENO, line);
}

extern "C" void goldenpad_crash_capture_install(const char *logsDirectory, int32_t redirectStdio) {
    if (installed || logsDirectory == nullptr) return;
    installed = true;
    mkdir(logsDirectory, 0755);
    rotate(logsDirectory, "crash-latest.txt", "crash-previous.txt", crashPath, sizeof(crashPath));
    char stdioPath[1024];
    rotate(logsDirectory, "stdio-latest.log", "stdio-previous.log", stdioPath, sizeof(stdioPath));
    if (redirectStdio != 0) {
        const int fd = open(stdioPath, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd >= 0) {
            std::fflush(stdout);
            std::fflush(stderr);
            dup2(fd, STDOUT_FILENO);
            dup2(fd, STDERR_FILENO);
            close(fd);
            setvbuf(stdout, nullptr, _IOLBF, 0);
            stdioFd = STDERR_FILENO;
        }
    }

    uint64_t physical = 0;
    size_t length = sizeof(physical);
    sysctlbyname("hw.memsize", &physical, &length, nullptr, 0);
    char model[64] = "unknown";
    length = sizeof(model);
    sysctlbyname("hw.machine", model, &length, nullptr, 0);
    unsigned long long available = 0;
#if TARGET_OS_IPHONE
    if (__builtin_available(iOS 13.0, tvOS 13.0, *)) available = os_proc_available_memory();
#endif
    std::fprintf(stderr, "[GoldenPad] crash capture ready: device=%s memory=%llu MB available_to_app=%llu MB time=%ld\n",
        model, static_cast<unsigned long long>(physical >> 20), available >> 20, static_cast<long>(std::time(nullptr)));

    static char alternateStack[128 * 1024];
    stack_t stack {};
    stack.ss_sp = alternateStack;
    stack.ss_size = sizeof(alternateStack);
    sigaltstack(&stack, nullptr);
    for (int signal : kSignals) {
        struct sigaction action {};
        action.sa_sigaction = onSignal;
        action.sa_flags = SA_SIGINFO | SA_ONSTACK;
        sigemptyset(&action.sa_mask);
        sigaction(signal, &action, nullptr);
    }
    std::set_terminate(onTerminate);
}

// For the simulator test: crash on purpose after capture is installed.
extern "C" void goldenpad_crash_test(void) {
    goldenpad_crash_note("crash test (on purpose)");
    raise(SIGSEGV);
}
