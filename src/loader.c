// libDevitrify.dylib is what DYLD_INSERT_LIBRARIES points at, so it is loaded into
// every process launched in the user session, including command-line tools. It links
// nothing beyond libSystem and only loads DevitrifyCore.dylib (which links AppKit)
// into processes that already have AppKit loaded, i.e. apps.

#include <crt_externs.h>
#include <dlfcn.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <fcntl.h>
#include <libkern/OSByteOrder.h>
#include <mach-o/fat.h>
#include <mach-o/loader.h>
#include <sys/mman.h>
#include <sys/stat.h>
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
    if (domain && feature) {
        if (!strcmp(domain, "SwiftUI") && !strcmp(feature, "flexiGlassMacOS")) return true;
        if (s_keep_liquid_glass && !strcmp(domain, "SwiftUI") && !strcmp(feature, "Solarium")) return true;
    }
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

// Kept for backward compatibility when inspecting Mach-O glass effect imports.
__attribute__((unused)) static int executable_uses_glass_effect(const char *path) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return 0;
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size < (off_t)sizeof(struct mach_header_64)) { close(fd); return 0; }
    const uint8_t *base = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (base == MAP_FAILED) return 0;

    int found = 0;
    const uint8_t *image = base;
    uint32_t magic = *(const uint32_t *)base;
    if (magic == FAT_CIGAM) {
        const struct fat_header *fat = (const struct fat_header *)base;
        const struct fat_arch *arch = (const struct fat_arch *)(base + sizeof(*fat));
        image = NULL;
        for (uint32_t i = 0; i < OSSwapBigToHostInt32(fat->nfat_arch); i++) {
            if (OSSwapBigToHostInt32(arch[i].cputype) == CPU_TYPE_ARM64) {
                image = base + OSSwapBigToHostInt32(arch[i].offset);
                break;
            }
        }
    }
    if (image && *(const uint32_t *)image == MH_MAGIC_64) {
        const struct mach_header_64 *header = (const struct mach_header_64 *)image;
        const struct load_command *command = (const struct load_command *)(header + 1);
        for (uint32_t i = 0; i < header->ncmds; i++) {
            if (command->cmd == LC_SYMTAB) {
                const struct symtab_command *symtab = (const struct symtab_command *)command;
                const char *strings = (const char *)image + symtab->stroff;
                found = memmem(strings, symtab->strsize, "11glassEffect", 13) != NULL ||
                        memmem(strings, symtab->strsize, "GlassEffectContainer", 20) != NULL;
                break;
            }
            command = (const struct load_command *)((const uint8_t *)command + command->cmdsize);
        }
    }
    munmap((void *)base, (size_t)st.st_size);
    return found;
}

// Each source of a decision is "on" (compatibility mode), "stable", "off" or absent.
enum { CHOICE_NONE, CHOICE_COMPAT, CHOICE_STABLE, CHOICE_OFF };

static int choice_from_text(const char *text) {
    if (!strncmp(text, "off", 3)) return CHOICE_OFF;
    if (!strncmp(text, "stable", 6)) return CHOICE_STABLE;
    return CHOICE_COMPAT;
}

static void keep_liquid_glass_if_listed(const char *dir) {
    // Processes that already have Solarium enabled (system-wide or via FEATUREFLAGS_ENABLED,
    // such as ControlCenter and NotificationCenter) must not be forced into macOS 15 SDK
    // compatibility mode.
    if (_os_feature_enabled_impl("SwiftUI", "Solarium")) return;

    char executable[PATH_MAX];
    uint32_t size = sizeof(executable);
    if (_NSGetExecutablePath(executable, &size) != 0) return;

    int choice = CHOICE_NONE;
    if (strstr(executable, ".app/Contents/MacOS/")) {
        const char *home = getenv("HOME");
        if (home && strstr(home, "/Library/Containers/")) {
            // Sandboxed apps can't read liquid-glass-apps. Their HOME is their container, where
            // Help > Keep Liquid Glass leaves a marker file.
            char marker[PATH_MAX];
            snprintf(marker, sizeof(marker), "%s/Library/Application Support/devitrify-keep-liquid-glass", home);
            FILE *file = fopen(marker, "r");
            if (file) {
                char text[16] = "";
                if (!fgets(text, sizeof(text), file)) text[0] = '\0';
                choice = choice_from_text(text);
                fclose(file);
            }
        } else {
            char list[PATH_MAX];
            snprintf(list, sizeof(list), "%s/liquid-glass-apps", dir);
            FILE *file = fopen(list, "r");
            char line[256];
            while (file && fgets(line, sizeof(line), file)) {
                line[strcspn(line, "\r\n")] = '\0';
                if (line[0] == '\0' || line[0] == '#') continue;
                char *space = strrchr(line, ' ');
                const char *option = "";
                if (space && (!strcmp(space + 1, "off") || !strcmp(space + 1, "stable") || !strcmp(space + 1, "compat"))) {
                    *space = '\0';
                    option = space + 1;
                }
                char needle[PATH_MAX];
                snprintf(needle, sizeof(needle), "/%s.app/Contents/MacOS/", line);
                if (!strstr(executable, needle)) continue;
                choice = choice_from_text(option);
                break;
            }
            if (file) fclose(file);
        }
    }

    if (choice == CHOICE_COMPAT || choice == CHOICE_STABLE) s_keep_liquid_glass = 1;
    if (choice == CHOICE_COMPAT) s_compatibility_mode = 1;
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

    // Check if a hot-reloaded core generation is active
    char reload_path[PATH_MAX];
    snprintf(reload_path, sizeof(reload_path), "%s/reload/current", path);
    FILE *f = fopen(reload_path, "r");
    if (f) {
        char line[PATH_MAX] = "";
        if (fgets(line, sizeof(line), f)) {
            line[strcspn(line, "\r\n")] = '\0';
            if (line[0] && access(line, R_OK) == 0) {
                fclose(f);
                dlopen(line, RTLD_NOW | RTLD_LOCAL);
                return;
            }
        }
        fclose(f);
    }

    strlcat(path, "/DevitrifyCore.dylib", sizeof(path));
    dlopen(path, RTLD_NOW | RTLD_LOCAL);
}
