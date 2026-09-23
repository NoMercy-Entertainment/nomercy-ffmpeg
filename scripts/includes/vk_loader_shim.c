/*
 * A stand-in for the Vulkan loader's few link-time symbols.
 *
 * Why this file exists: ggml's Vulkan backend links against three loader
 * symbols, and linking the real loader would make our fully static binaries
 * depend on a shared library that most machines do not have. FFmpeg's own
 * Vulkan code already solves this by opening the loader at runtime; this does
 * the same for ggml. Opening a shared library from a static executable works;
 * it is the reverse - a loaded module calling back into the executable - that
 * does not, which is why ggml's own backend modules are not an option here.
 *
 * The three symbols are not a guess: they are what `nm --undefined-only` reports
 * on the built libggml-vulkan.a. Everything else ggml needs it fetches itself
 * through vkGetInstanceProcAddr.
 *
 * The one subtlety worth knowing: when no loader is present we must NOT return
 * NULL from vkGetInstanceProcAddr. vulkan.hpp's dispatcher stores whatever it
 * gets and calls through it unconditionally, so a NULL is a null-pointer call -
 * a segfault, not a catchable error. Returning small stubs that report failure
 * keeps every call landing on a valid function, so "no driver" surfaces as an
 * ordinary Vulkan error that ggml already handles. This holds for every name
 * the shim can be asked for, known or not - see stub_vkGenericFailure below.
 *
 * Loading is lazy (first call, not link time) and happens at most once even
 * under concurrent callers: ggml initialises backends from a single thread
 * today, but this file outlives that assumption, so the load-and-resolve step
 * runs under pthread_once (POSIX) / InitOnceExecuteOnce (Windows) rather than
 * an unlocked "tried" flag. An unlocked flag is a classic broken
 * double-checked-lock: a second thread can observe "already tried" while the
 * first thread's dlopen/GetProcAddress are still in flight and read a NULL
 * function pointer that a moment later would have been valid - on a machine
 * that does have a GPU, that silently downgrades it to "no GPU" instead of
 * segfaulting or corrupting memory, which is a quieter failure and arguably
 * worse. The three real function pointers are resolved together inside the
 * one-time init, then read without further synchronisation: pthread_once and
 * InitOnceExecuteOnce both guarantee the init callback happens-before every
 * call that observes it completed, so the statics are safe to read plainly
 * afterward.
 */

#include <vulkan/vulkan_core.h>
#include <stdio.h>
#include <string.h>

static PFN_vkGetInstanceProcAddr g_real_gipa = 0;
static PFN_vkCmdCopyBuffer g_real_copy_buffer = 0;
static PFN_vkGetPhysicalDeviceFeatures2 g_real_get_features2 = 0;

#if defined(_WIN32)
#include <windows.h>

static void vk_resolve_real_symbols(HMODULE lib)
{
    g_real_gipa = (PFN_vkGetInstanceProcAddr) GetProcAddress(lib, "vkGetInstanceProcAddr");
    g_real_copy_buffer = (PFN_vkCmdCopyBuffer) GetProcAddress(lib, "vkCmdCopyBuffer");
    g_real_get_features2 = (PFN_vkGetPhysicalDeviceFeatures2) GetProcAddress(lib, "vkGetPhysicalDeviceFeatures2");
}

static BOOL CALLBACK vk_init_once_cb(PINIT_ONCE init_once, PVOID param, PVOID *context)
{
    (void) init_once; (void) param; (void) context;
    HMODULE lib = LoadLibraryA("vulkan-1.dll");
    if (lib)
        vk_resolve_real_symbols(lib);
    return TRUE;
}

static void ensure_loaded(void)
{
    static INIT_ONCE once = INIT_ONCE_STATIC_INIT;
    InitOnceExecuteOnce(&once, vk_init_once_cb, NULL, NULL);
}
#else
#include <dlfcn.h>
#include <pthread.h>

static void vk_resolve_real_symbols(void *lib)
{
    g_real_gipa = (PFN_vkGetInstanceProcAddr) dlsym(lib, "vkGetInstanceProcAddr");
    g_real_copy_buffer = (PFN_vkCmdCopyBuffer) dlsym(lib, "vkCmdCopyBuffer");
    g_real_get_features2 = (PFN_vkGetPhysicalDeviceFeatures2) dlsym(lib, "vkGetPhysicalDeviceFeatures2");
}

static void vk_init_once(void)
{
    void *lib = dlopen("libvulkan.so.1", RTLD_NOW | RTLD_LOCAL);
    if (!lib) lib = dlopen("libvulkan.so", RTLD_NOW | RTLD_LOCAL);
    if (lib)
        vk_resolve_real_symbols(lib);
}

static void ensure_loaded(void)
{
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, vk_init_once);
}
#endif

/* Used only when the loader could not be opened, or was opened but does not
 * export a given name. Every branch below returns a valid function pointer -
 * never NULL - so a caller that follows the pointer it was handed lands on
 * code that reports failure instead of dereferencing 0. */

static VKAPI_ATTR VkResult VKAPI_CALL stub_vkCreateInstance(
    const VkInstanceCreateInfo *pCreateInfo, const VkAllocationCallbacks *pAllocator, VkInstance *pInstance)
{
    (void) pCreateInfo; (void) pAllocator; (void) pInstance;
    return VK_ERROR_INCOMPATIBLE_DRIVER;
}

static VKAPI_ATTR VkResult VKAPI_CALL stub_vkEnumerateInstanceExtensionProperties(
    const char *pLayerName, uint32_t *pPropertyCount, VkExtensionProperties *pProperties)
{
    (void) pLayerName; (void) pProperties;
    if (pPropertyCount) *pPropertyCount = 0;
    return VK_SUCCESS;
}

static VKAPI_ATTR VkResult VKAPI_CALL stub_vkEnumerateInstanceLayerProperties(
    uint32_t *pPropertyCount, VkLayerProperties *pProperties)
{
    (void) pProperties;
    if (pPropertyCount) *pPropertyCount = 0;
    return VK_SUCCESS;
}

static VKAPI_ATTR VkResult VKAPI_CALL stub_vkEnumerateInstanceVersion(uint32_t *pApiVersion)
{
    if (pApiVersion) *pApiVersion = VK_API_VERSION_1_0;
    return VK_SUCCESS;
}

/* Catch-all for any global-level name the four stubs above don't cover. Every
 * pre-instance Vulkan command returns VkResult, so a nullary function that
 * returns one is a safe stand-in regardless of the real signature: on the
 * calling conventions VKAPI_CALL resolves to here (cdecl on x86-64, __stdcall
 * on 32-bit Windows), unread incoming arguments are simply never touched by a
 * callee that takes none, and the VkResult this returns lands in the same
 * register the real function would have used. It exists so the fallback for
 * an unrecognised name is "a stub that reports failure", matching every other
 * branch here, rather than NULL - the shim should never again depend on a
 * name being one it happened to anticipate. */
static VKAPI_ATTR VkResult VKAPI_CALL stub_vkGenericFailure(void)
{
    return VK_ERROR_INITIALIZATION_FAILED;
}

VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL vkGetInstanceProcAddr(VkInstance instance, const char *pName)
{
    ensure_loaded();
    if (g_real_gipa)
        return g_real_gipa(instance, pName);
    if (pName) {
        if (!strcmp(pName, "vkCreateInstance"))
            return (PFN_vkVoidFunction) stub_vkCreateInstance;
        if (!strcmp(pName, "vkEnumerateInstanceExtensionProperties"))
            return (PFN_vkVoidFunction) stub_vkEnumerateInstanceExtensionProperties;
        if (!strcmp(pName, "vkEnumerateInstanceLayerProperties"))
            return (PFN_vkVoidFunction) stub_vkEnumerateInstanceLayerProperties;
        if (!strcmp(pName, "vkEnumerateInstanceVersion"))
            return (PFN_vkVoidFunction) stub_vkEnumerateInstanceVersion;
    }
    return (PFN_vkVoidFunction) stub_vkGenericFailure;
}

VKAPI_ATTR void VKAPI_CALL vkCmdCopyBuffer(VkCommandBuffer commandBuffer, VkBuffer srcBuffer,
                                           VkBuffer dstBuffer, uint32_t regionCount,
                                           const VkBufferCopy *pRegions)
{
    ensure_loaded();
    /* Only reachable once a real device and queue exist, so the loader was found. */
    if (g_real_copy_buffer)
        g_real_copy_buffer(commandBuffer, srcBuffer, dstBuffer, regionCount, pRegions);
}

VKAPI_ATTR void VKAPI_CALL vkGetPhysicalDeviceFeatures2(VkPhysicalDevice physicalDevice,
                                                        VkPhysicalDeviceFeatures2 *pFeatures)
{
    ensure_loaded();
    if (g_real_get_features2)
        g_real_get_features2(physicalDevice, pFeatures);
}
