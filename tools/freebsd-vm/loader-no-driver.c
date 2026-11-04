/* Test-only Vulkan loader probe. Never ship the loader fixture with FFmpeg. */
#include <dlfcn.h>
#include <stdio.h>
#include <vulkan/vulkan_core.h>

int main(int argc, char **argv)
{
    if (argc != 2) return 2;
    void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!library) {
        fprintf(stderr, "dlopen: %s\n", dlerror());
        return 3;
    }
    PFN_vkEnumerateInstanceVersion version = (PFN_vkEnumerateInstanceVersion)dlsym(library, "vkEnumerateInstanceVersion");
    PFN_vkCreateInstance create = (PFN_vkCreateInstance)dlsym(library, "vkCreateInstance");
    if (!version || !create) return 4;
    uint32_t api = 0;
    VkResult result = version(&api);
    if (result != VK_SUCCESS) return 5;
    printf("Real Vulkan loader API: %u.%u.%u\n", VK_API_VERSION_MAJOR(api), VK_API_VERSION_MINOR(api), VK_API_VERSION_PATCH(api));
    if (api != VK_HEADER_VERSION_COMPLETE) return 7;
    VkApplicationInfo application = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_0 };
    VkInstanceCreateInfo info = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &application };
    VkInstance instance = VK_NULL_HANDLE;
    result = create(&info, NULL, &instance);
    printf("vkCreateInstance with no ICD: %d\n", result);
    dlclose(library);
    if (result != VK_ERROR_INCOMPATIBLE_DRIVER) return 6;
    puts("PASS: real FreeBSD Vulkan loader reports no compatible driver cleanly");
    return 0;
}
