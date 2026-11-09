/* Test-only executable: static C++/Snappy, late-loaded C plugin. */
#include <dlfcn.h>
#include <snappy-c.h>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <thread>
#include <vector>

struct Plugin {
    int (*constructor_ok)() = nullptr;
    int (*tls_step)(unsigned, unsigned) = nullptr;
    void *(*allocate)(size_t) = nullptr;
    void (*release)(void *) = nullptr;

    bool valid() const { return constructor_ok && tls_step && allocate && release; }
};

static bool compression_ok()
{
    const char input[] = "FreeBSD static Snappy and C++ runtime fixture";
    std::vector<char> packed(snappy_max_compressed_length(sizeof(input)));
    size_t packed_size = packed.size();
    if (snappy_compress(input, sizeof(input), packed.data(), &packed_size) != SNAPPY_OK)
        return false;
    char unpacked[sizeof(input)];
    size_t unpacked_size = sizeof(unpacked);
    return snappy_uncompress(packed.data(), packed_size, unpacked, &unpacked_size) == SNAPPY_OK &&
           unpacked_size == sizeof(input) && !std::memcmp(input, unpacked, sizeof(input));
}

int main(int argc, char **argv)
{
    if (argc != 2) {
        std::fprintf(stderr, "usage: dlopen-main /absolute/path/to/plugin.so\n");
        return 2;
    }
    if (!compression_ok()) {
        std::fprintf(stderr, "Snappy round-trip failed\n");
        return 3;
    }
    Plugin plugin;
    std::mutex mutex;
    std::condition_variable changed;
    bool ready = false, run = false;
    int worker_ok = 0;
    // This thread predates dlopen: its plugin TLS must be allocated lazily.
    std::thread worker([&] {
        {
            std::unique_lock<std::mutex> lock(mutex);
            ready = true;
            changed.notify_all();
            changed.wait(lock, [&] { return run; });
        }
        if (!plugin.valid() || !plugin.constructor_ok() ||
            plugin.tls_step(17, 71) != 71 || plugin.tls_step(71, 72) != 72)
            return;
        void *from_plugin = plugin.allocate(513);
        void *from_main = std::malloc(514);
        if (!from_plugin || !from_main) {
            std::free(from_plugin);
            std::free(from_main);
            return;
        }
        std::memset(from_plugin, 0x73, 513);
        std::memset(from_main, 0x37, 514);
        std::free(from_plugin);
        plugin.release(from_main);
        worker_ok = 1;
    });
    {
        std::unique_lock<std::mutex> lock(mutex);
        changed.wait(lock, [&] { return ready; });
    }
    void *module = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    int main_ok = 0;
    if (!module) {
        std::fprintf(stderr, "dlopen failed: %s\n", dlerror());
    } else {
        plugin.constructor_ok = reinterpret_cast<int (*)()>(dlsym(module, "nm_fixture_constructor_ok"));
        plugin.tls_step = reinterpret_cast<int (*)(unsigned, unsigned)>(dlsym(module, "nm_fixture_tls_step"));
        plugin.allocate = reinterpret_cast<void *(*)(size_t)>(dlsym(module, "nm_fixture_allocate"));
        plugin.release = reinterpret_cast<void (*)(void *)>(dlsym(module, "nm_fixture_release"));
        main_ok = plugin.valid() && plugin.constructor_ok() &&
                  plugin.tls_step(17, 31) == 31 && plugin.tls_step(31, 32) == 32;
    }
    {
        std::lock_guard<std::mutex> lock(mutex);
        run = true;
    }
    changed.notify_all();
    worker.join();
    main_ok = main_ok && worker_ok && plugin.tls_step(32, 33) == 33;
    if (module)
        dlclose(module);
    if (!main_ok) {
        std::fprintf(stderr, "plugin constructor, late TLS, or cross-module allocation failed\n");
        return 4;
    }
    std::puts("PASS: static Snappy/C++, plugin constructor, late TLS on pre-existing thread, cross-module malloc/free");
    return 0;
}
