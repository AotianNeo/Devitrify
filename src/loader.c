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
static int s_compatibility_mode = 0;

int devitrify_keeps_liquid_glass(void) {
    return s_keep_liquid_glass;
}

// 1 when the app runs Liquid Glass in compatibility mode, which already has classic controls.
int devitrify_compatibility_mode(void) {
    return s_compatibility_mode;
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

// Optional second level, "Name compat" in liquid-glass-apps: Liquid Glass runs in its
// compatibility mode, the way apps built with an older SDK run on macOS 26 and later, so the
// controls that SwiftUI draws stay classic as well while glass keeps its shape. dyld tells
// frameworks which SDK the app was built with, so report macOS 15. Some SwiftUI controls
// misbehave in this mode when accessibility clients are running, so it is opt-in.
typedef struct { uint32_t platform; uint32_t version; } devitrify_build_version;
extern uint32_t dyld_get_program_sdk_version(void);
extern bool dyld_program_sdk_at_least(devitrify_build_version version);

#define DEVITRIFY_COMPATIBILITY_SDK 0x000F0000

// Only the frameworks that draw the interface get the older SDK. Other frameworks, such as
// CoreFoundation, change behavior with the SDK too and misbehave when they are told one that
// the app wasn't built with.
static bool devitrify_caller_draws_interface(const void *address) {
    Dl_info info;
    if (!dladdr(address, &info) || !info.dli_fname) return false;
    return strstr(info.dli_fname, "/AppKit.framework/") || strstr(info.dli_fname, "/SwiftUI.framework/") ||
           strstr(info.dli_fname, "/SwiftUICore.framework/");
}

static uint32_t devitrify_program_sdk_version(void) {
    uint32_t real = dyld_get_program_sdk_version();
    if (s_compatibility_mode && real > DEVITRIFY_COMPATIBILITY_SDK && devitrify_caller_draws_interface(__builtin_return_address(0))) return DEVITRIFY_COMPATIBILITY_SDK;
    return real;
}

static bool devitrify_program_sdk_at_least(devitrify_build_version version) {
    if (s_compatibility_mode && version.version > DEVITRIFY_COMPATIBILITY_SDK && devitrify_caller_draws_interface(__builtin_return_address(0))) return false;
    return dyld_program_sdk_at_least(version);
}

DYLD_INTERPOSE(devitrify_program_sdk_version, dyld_get_program_sdk_version);
DYLD_INTERPOSE(devitrify_program_sdk_at_least, dyld_program_sdk_at_least);

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
        int compat = 0;
        size_t length = strlen(line);
        if (length > 7 && !strcmp(line + length - 7, " compat")) {
            compat = 1;
            line[length - 7] = '\0';
        }
        char needle[PATH_MAX];
        snprintf(needle, sizeof(needle), "/%s.app/Contents/MacOS/", line);
        if (!strstr(executable, needle)) continue;
        s_keep_liquid_glass = 1;
        s_compatibility_mode = compat;
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
