// libDevitrify.dylib is what DYLD_INSERT_LIBRARIES points at, so it is loaded into
// every process launched in the user session, including command-line tools. It links
// nothing beyond libSystem and only loads DevitrifyCore.dylib (which links AppKit)
// into processes that already have AppKit loaded, i.e. apps.

#include <crt_externs.h>
#include <dlfcn.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int appkit_is_loaded(void) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, "/AppKit.framework/")) return 1;
    }
    return 0;
}

// Apps named in liquid-glass-apps (one app name per line, e.g. "AlDente") keep Liquid
// Glass while it is disabled system-wide, so their SwiftUI glass keeps its shape and
// DevitrifyCore turns it into frosted glass. DEVITRIFY_LIQUID_GLASS_APP tells
// DevitrifyCore to keep the app's AppKit controls classic. This runs before AppKit and
// SwiftUI read the feature flag.
static void keep_liquid_glass() {
    const char *enabled = getenv("FEATUREFLAGS_ENABLED");
    if (!enabled || !*enabled) {
        setenv("FEATUREFLAGS_ENABLED", "SwiftUI/Solarium", 1);
    } else if (!strstr(enabled, "SwiftUI/Solarium")) {
        char value[1024];
        snprintf(value, sizeof(value), "%s:SwiftUI/Solarium", enabled);
        setenv("FEATUREFLAGS_ENABLED", value, 1);
    }
    setenv("DEVITRIFY_LIQUID_GLASS_APP", "1", 1);
}

static void keep_liquid_glass_if_listed(const char *dir) {
    char executable[PATH_MAX];
    uint32_t size = sizeof(executable);
    if (_NSGetExecutablePath(executable, &size) != 0 || !strstr(executable, ".app/Contents/MacOS/")) return;

    // Sandboxed apps can't read liquid-glass-apps. Their HOME is their container, where
    // Help > Keep Liquid Glass leaves a marker file.
    const char *home = getenv("HOME");
    if (home && strstr(home, "/Library/Containers/")) {
        char marker[PATH_MAX];
        snprintf(marker, sizeof(marker), "%s/Library/Application Support/devitrify-keep-liquid-glass", home);
        if (access(marker, F_OK) != 0) return;

        // The feature flag of a sandboxed process is read before this runs and then cached,
        // unlike in other processes, so start the app again, with the environment set. The
        // process keeps its identity.
        const char *flags = getenv("FEATUREFLAGS_ENABLED");
        if (flags && strstr(flags, "SwiftUI/Solarium")) return;
        keep_liquid_glass();
        execv(executable, *_NSGetArgv());
        return;
    }

    char list[PATH_MAX];
    snprintf(list, sizeof(list), "%s/liquid-glass-apps", dir);
    FILE *file = fopen(list, "r");
    if (!file) return;

    char line[256];
    while (fgets(line, sizeof(line), file)) {
        line[strcspn(line, "\r\n")] = '\0';
        if (line[0] == '\0' || line[0] == '#') continue;
        char needle[PATH_MAX];
        snprintf(needle, sizeof(needle), "/%s.app/Contents/MacOS/", line);
        if (!strstr(executable, needle)) continue;
        keep_liquid_glass();
        break;
    }
    fclose(file);
}

__attribute__((constructor))
static void devitrify_load_core(void) {
    Dl_info info;
    char path[PATH_MAX];
    if (!dladdr((const void *)devitrify_load_core, &info) || !realpath(info.dli_fname, path)) return;

    char *slash = strrchr(path, '/');
    if (!slash) return;
    *slash = '\0';
    keep_liquid_glass_if_listed(path);

    if (!appkit_is_loaded()) return;
    strlcat(path, "/DevitrifyCore.dylib", sizeof(path));
    dlopen(path, RTLD_NOW | RTLD_LOCAL);
}
