#include <dlfcn.h>
#include <gnu/libc-version.h>
#include <pthread.h>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <thread>

static pthread_key_t main_key;
static uint64_t main_value = UINT64_C(0x1111111111111111);
static unsigned main_destructors, wrong_destructor_values;

static void main_destructor(void *pointer)
{
    main_destructors++;
    if (pointer != &main_value)
        wrong_destructor_values++;
    // Compare sentinel addresses only; never dereference or free another module's value.
    std::fprintf(stderr, "main destructor: pointer=%p expected=%p\n",
                 pointer, (void *)&main_value);
}

template<typename Function>
static Function symbol(void *library, const char *name)
{
    dlerror();
    void *address = dlsym(library, name);
    const char *error = dlerror();
    if (error || !address) {
        std::fprintf(stderr, "dlsym %s: %s\n", name, error ? error : "null address");
        std::exit(2);
    }
    return reinterpret_cast<Function>(address);
}

int main(int argc, char **argv)
{
    if (argc != 3 || (std::strcmp(argv[2], "isolated") && std::strcmp(argv[2], "collision"))) {
        std::fprintf(stderr, "Usage: %s PLUGIN isolated|collision\n", argv[0]);
        return 2;
    }
    std::setvbuf(stderr, nullptr, _IONBF, 0);
    std::fprintf(stderr, "main glibc=%s expectation=%s\n", gnu_get_libc_version(), argv[2]);
    if (pthread_key_create(&main_key, main_destructor))
        return 2;
    void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!library) {
        std::fprintf(stderr, "dlopen: %s\n", dlerror());
        return 2;
    }
    auto create = symbol<int (*)(void)>(library, "plugin_create");
    auto key_id = symbol<unsigned (*)(void)>(library, "plugin_key_id");
    auto expected = symbol<void *(*)(void)>(library, "plugin_expected_value");
    auto set_value = symbol<int (*)(void)>(library, "plugin_set_value");
    auto get_value = symbol<void *(*)(void)>(library, "plugin_get_value");
    auto count = symbol<unsigned (*)(void)>(library, "plugin_destructor_count");
    auto wrong_values = symbol<unsigned (*)(void)>(library, "plugin_wrong_destructor_values");
    if (create())
        return 2;
    void *plugin_value = expected();
    if (!plugin_value || plugin_value == &main_value)
        return 2;

    int worker_error = 0;
    void *main_observed = nullptr, *plugin_observed = nullptr;
    try {
        // Exercise the static C++ runtime too, while pthread keys remain the measured state.
        std::thread worker([&] {
            if (pthread_setspecific(main_key, &main_value) || set_value()) {
                worker_error = 1;
                return;
            }
            main_observed = pthread_getspecific(main_key);
            plugin_observed = get_value();
        });
        worker.join();
    } catch (const std::exception &error) {
        std::fprintf(stderr, "thread: %s\n", error.what());
        return 2;
    }
    if (worker_error)
        return 2;

    bool collision = (unsigned)main_key == key_id();
    bool main_preserved = main_observed == &main_value;
    bool plugin_preserved = plugin_observed == plugin_value;
    bool isolated = !collision && main_preserved && plugin_preserved &&
        main_destructors == 1 && wrong_destructor_values == 0 && count() == 1 && wrong_values() == 0;
    bool corrupted = collision && main_observed == plugin_value && plugin_preserved &&
        main_destructors == 1 && wrong_destructor_values == 1 && count() == 0 && wrong_values() == 0;
    std::fprintf(stderr, "RESULT collision=%d main_preserved=%d plugin_preserved=%d "
                 "main_destructors=%u wrong_main_values=%u plugin_destructors=%u wrong_plugin_values=%u\n",
                 collision, main_preserved, plugin_preserved, main_destructors,
                 wrong_destructor_values, count(), wrong_values());
    bool matched = std::strcmp(argv[2], "isolated") == 0 ? isolated : corrupted;
    std::fprintf(stderr, "%s: %s\n", matched ? "PASS" : "FAIL", argv[2]);
    // Keep the plugin mapped. Neither destructor frees memory; no dlclose is involved.
    return matched ? 0 : 1;
}
