// libDevitrify.dylib is what DYLD_INSERT_LIBRARIES points at, so it is loaded into
// every process launched in the user session, including command-line tools. It links
// nothing beyond libSystem and only loads DevitrifyCore.dylib (which links AppKit)
// into processes that already have AppKit loaded, i.e. apps.

#include <crt_externs.h>
#include <dlfcn.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdbool.h>
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
// DevitrifyCore turns it into frosted glass. DevitrifyCore asks the loader whether the
// app is one of them to keep the app's AppKit controls classic.
// Set when the app keeps Liquid Glass. The feature flag lookup below answers "enabled" for
// Liquid Glass in such apps; no environment variable is touched, and because dyld applies
// the interposition when it loads the images, it holds before anything reads or caches the flag.
static int s_keep_liquid_glass = 0;

int devitrify_keeps_liquid_glass(void) {
    return s_keep_liquid_glass;
}

extern bool _os_feature_enabled_impl(const char *domain, const char *feature);

static bool devitrify_feature_enabled(const char *domain, const char *feature) {
    if (s_keep_liquid_glass && domain && feature && !strcmp(domain, "SwiftUI") && !strcmp(feature, "Solarium")) return true;
    return _os_feature_enabled_impl(domain, feature);
}

#define DYLD_INTERPOSE(replacement, replacee) \
    __attribute__((used)) static struct { const void *replacement; const void *replacee; } _interpose_##replacee \
    __attribute__((section("__DATA,__interpose"))) = { (const void *)(unsigned long)&replacement, (const void *)(unsigned long)&replacee }
DYLD_INTERPOSE(devitrify_feature_enabled, _os_feature_enabled_impl);

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
        if (access(marker, F_OK) == 0) s_keep_liquid_glass = 1;
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
        s_keep_liquid_glass = 1;
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
