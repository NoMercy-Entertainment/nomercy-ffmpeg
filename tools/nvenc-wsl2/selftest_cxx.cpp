/* C++ exception test: what _dl_find_object exists for.
 *
 * A null _dl_find_object stub links, the version string looks right, and
 * the first throw aborts (measured: "Aborted (core dumped)"). Only a real
 * dl_iterate_phdr-backed implementation lets the unwinder find the FDE for
 * a PC and actually catch. The research measured 1001 throws including one
 * from a second thread; this test reproduces that shape.
 */
#include <cstdio>
#include <stdexcept>
#include <thread>
#include <atomic>

static std::atomic<int> fails{0};

static void thrower()
{
    throw std::runtime_error("nmcompat selftest exception");
}

/* Throw and catch across a function boundary, so the unwinder must walk at
 * least one frame using the shimmed _dl_find_object. */
static bool throw_and_catch()
{
    try {
        thrower();
    } catch (const std::exception &e) {
        return true;
    }
    return false;
}

int main()
{
    const int N = 1000;
    int ok = 0;

    for (int i = 0; i < N; ++i) {
        if (throw_and_catch())
            ++ok;
        else
            ++fails;
    }
    printf("main-thread throws:   %d/%d ok\n", ok, N);

    bool thread_ok = false;
    std::thread t([&thread_ok]() { thread_ok = throw_and_catch(); });
    t.join();
    printf("second-thread throw:  %s\n", thread_ok ? "ok" : "FAIL");
    if (!thread_ok)
        ++fails;

    int total_ok = ok + (thread_ok ? 1 : 0);
    printf("total throws caught:  %d/%d\n", total_ok, N + 1);

    int f = fails.load();
    printf("%s\n", f ? "SELFTEST_CXX FAILED" : "SELFTEST_CXX PASSED");
    return f != 0;
}
