// Crashes on purpose after installing GoldenPad's crash capture, so the
// Checks workflow can confirm the crash file holds the signal, the last stage,
// a backtrace and that stdout/stderr went to the log file.
// Build: clang++ -std=c++20 Support/RecompPrototype/goldenpad_crash_capture.cpp Tests/GoldenPadCrashCaptureTest.cpp
#include <cstdint>
#include <cstdio>

extern "C" void goldenpad_crash_capture_install(const char *logsDirectory, int32_t redirectStdio);
extern "C" void goldenpad_crash_note(const char *text);
extern "C" void goldenpad_crash_test(void);

int main(int argc, char **argv) {
    if (argc < 2) return 2;
    goldenpad_crash_capture_install(argv[1], 1);
    std::printf("printed to stdout before the crash\n");
    goldenpad_crash_note("renderer: initializing (test)");
    goldenpad_crash_test();
    return 0;
}
