// libDevitrify.dylib is what DYLD_INSERT_LIBRARIES points at, so it is loaded into
// every process launched in the user session, including command-line tools. It links
// nothing beyond libSystem and only loads DevitrifyCore.dylib (which links AppKit)
// into processes that already have AppKit loaded, i.e. apps.

#include <dlfcn.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdlib.h>
#include <string.h>

static int appkit_is_loaded(void) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, "/AppKit.framework/")) return 1;
    }
    return 0;
}

__attribute__((constructor))
static void devitrify_load_core(void) {
    if (!appkit_is_loaded()) return;

    Dl_info info;
    char path[PATH_MAX];
    if (!dladdr((const void *)devitrify_load_core, &info) || !realpath(info.dli_fname, path)) return;

    char *slash = strrchr(path, '/');
    if (!slash) return;
    strlcpy(slash + 1, "DevitrifyCore.dylib", sizeof(path) - (size_t)(slash + 1 - path));
    dlopen(path, RTLD_NOW | RTLD_LOCAL);
}
