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
 * a segfault, not a catchable error. Returning small stubs that report
 * VK_ERROR_INCOMPATIBLE_DRIVER keeps every call landing on a valid function, so
 * "no driver" surfaces as an ordinary Vulkan error that ggml already handles.
 */

#include <vulkan/vulkan_core.h>
#include <stdio.h>
#include <string.h>

#if defined(_WIN32)
#include <windows.h>
static HMODULE g_vk_lib = 0;
static int g_vk_tried = 0;
static void ensure_loaded(void)
{
    if (!g_vk_tried) {
        g_vk_tried = 1;
        g_vk_lib = LoadLibraryA("vulkan-1.dll");
    }
}
static void *vk_sym(const char *name)
{
    ensure_loaded();
    if (!g_vk_lib) return 0;
    return (void *) GetProcAddress(g_vk_lib, name);
}
#else
#include <dlfcn.h>
static void *g_vk_lib = 0;
static int g_vk_tried = 0;
static void ensure_loaded(void)
{
    if (!g_vk_tried) {
        g_vk_tried = 1;
        g_vk_lib = dlopen("libvulkan.so.1", RTLD_NOW | RTLD_LOCAL);
        if (!g_vk_lib) g_vk_lib = dlopen("libvulkan.so", RTLD_NOW | RTLD_LOCAL);
    }
}
static void *vk_sym(const char *name)
{
    ensure_loaded();
    if (!g_vk_lib) return 0;
    return dlsym(g_vk_lib, name);
}
#endif

/* Used only when the loader could not be opened at all. */

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

VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL vkGetInstanceProcAddr(VkInstance instance, const char *pName)
{
    static PFN_vkGetInstanceProcAddr real = 0;
    static int tried = 0;
    if (!tried) {
        tried = 1;
        real = (PFN_vkGetInstanceProcAddr) vk_sym("vkGetInstanceProcAddr");
    }
    if (real)
        return real(instance, pName);
    if (!pName)
        return 0;
    if (!strcmp(pName, "vkCreateInstance"))
        return (PFN_vkVoidFunction) stub_vkCreateInstance;
    if (!strcmp(pName, "vkEnumerateInstanceExtensionProperties"))
        return (PFN_vkVoidFunction) stub_vkEnumerateInstanceExtensionProperties;
    if (!strcmp(pName, "vkEnumerateInstanceLayerProperties"))
        return (PFN_vkVoidFunction) stub_vkEnumerateInstanceLayerProperties;
    if (!strcmp(pName, "vkEnumerateInstanceVersion"))
        return (PFN_vkVoidFunction) stub_vkEnumerateInstanceVersion;
    return 0;
}

VKAPI_ATTR void VKAPI_CALL vkCmdCopyBuffer(VkCommandBuffer commandBuffer, VkBuffer srcBuffer,
                                           VkBuffer dstBuffer, uint32_t regionCount,
                                           const VkBufferCopy *pRegions)
{
    static PFN_vkCmdCopyBuffer real = 0;
    static int tried = 0;
    if (!tried) {
        tried = 1;
        real = (PFN_vkCmdCopyBuffer) vk_sym("vkCmdCopyBuffer");
    }
    /* Only reachable once a real device and queue exist, so the loader was found. */
    if (real)
        real(commandBuffer, srcBuffer, dstBuffer, regionCount, pRegions);
}

VKAPI_ATTR void VKAPI_CALL vkGetPhysicalDeviceFeatures2(VkPhysicalDevice physicalDevice,
                                                        VkPhysicalDeviceFeatures2 *pFeatures)
{
    static PFN_vkGetPhysicalDeviceFeatures2 real = 0;
    static int tried = 0;
    if (!tried) {
        tried = 1;
        real = (PFN_vkGetPhysicalDeviceFeatures2) vk_sym("vkGetPhysicalDeviceFeatures2");
    }
    if (real)
        real(physicalDevice, pFeatures);
}
