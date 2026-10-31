// libDevitrify.dylib is what DYLD_INSERT_LIBRARIES points at, so it is loaded into
// every process launched in the user session, including command-line tools. It links
// nothing beyond libSystem and only loads DevitrifyCore.dylib (which links AppKit)
// into processes that already have AppKit loaded, i.e. apps.

#include <dlfcn.h>
#include <fcntl.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <setjmp.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <unistd.h>

#define DEVITRIFY_INSTALL_DIR "/Users/Shared/.devitrify"
#define DEVITRIFY_DISABLED_FILE DEVITRIFY_INSTALL_DIR "/disabled"
#define DEVITRIFY_BYPASS_DIR DEVITRIFY_INSTALL_DIR "/crash-bypass"

static int s_appkit_loaded = 0;
static int s_iconservices_loaded = 0;
static volatile int s_system_disabled = 0;
static volatile int s_process_bypassed = 0;

static int is_safe_boot(void) {
    int val = 0;
    size_t sz = sizeof(val);
    if (sysctlbyname("kern.safeboot", &val, &sz, NULL, 0) == 0) {
        return val != 0;
    }
    return 0;
}

const char *devitrify_process_bypass_marker_path(void) {
    static char s_marker[PATH_MAX];
    if (s_marker[0]) return s_marker;

    char executable[PATH_MAX];
    uint32_t size = sizeof(executable);
    if (_NSGetExecutablePath(executable, &size) != 0) return NULL;

    const char *base = strrchr(executable, '/');
    base = base ? base + 1 : executable;

    char safe_name[256];
    size_t j = 0;
    for (size_t i = 0; base[i] && j + 1 < sizeof(safe_name); i++) {
        char c = base[i];
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
            (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-') {
            safe_name[j++] = c;
        } else {
            safe_name[j++] = '_';
        }
    }
    safe_name[j] = '\0';
    if (!safe_name[0]) return NULL;

    snprintf(s_marker, sizeof(s_marker), "%s/%s.bypass", DEVITRIFY_BYPASS_DIR, safe_name);
    return s_marker;
}

static void check_disable_and_bypass_state(void) {
    if (is_safe_boot()) {
        s_system_disabled = 1;
        return;
    }
    s_system_disabled = (access(DEVITRIFY_DISABLED_FILE, F_OK) == 0) ? 1 : 0;
    const char *marker = devitrify_process_bypass_marker_path();
    if (marker && access(marker, F_OK) == 0) {
        s_process_bypassed = 1;
    }
}

void devitrify_set_system_disabled(int disabled) {
    s_system_disabled = disabled ? 1 : 0;
}

static void detect_loaded_frameworks(void) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name) {
            if (strstr(name, "/AppKit.framework/")) {
                s_appkit_loaded = 1;
            }
            if (strstr(name, "/IconServices.framework/")) {
                s_iconservices_loaded = 1;
            }
            if (s_appkit_loaded && s_iconservices_loaded) break;
        }
    }
}

extern bool _os_feature_enabled_impl(const char *domain, const char *feature);

// When Solarium is disabled system-wide, AppKit and SwiftUI controls must stay classic
// (Solarium.isEnabled == false, Solarium.useMetrics == false), while explicit .glassEffect(...)
// views (such as Calculator's keypad buttons) still need DesignLibrary.GlassMaterialProvider
// to resolve their background layers instead of returning an empty layer array [].
// SwiftUICore's Solarium.computeValues computes EnablementEntry = { level: .compatibility (1),
// criteria: 0x5 } when the SwiftUI/Solarium feature flag is true (via libswiftFeatureFlags)
// and the subsequent Semantics.v7 dyld_program_sdk_at_least check returns false.
static volatile int s_in_solarium_compute_values = 0;

static bool devitrify_caller_is_swift_feature_flags(const void *address) {
    Dl_info info;
    if (!dladdr(address, &info) || !info.dli_fname) return false;
    return strstr(info.dli_fname, "/SwiftUICore.framework/") != NULL ||
           strstr(info.dli_fname, "FeatureFlags") != NULL;
}

static bool devitrify_feature_enabled(const char *domain, const char *feature) {
    if (s_system_disabled || s_process_bypassed) {
        return _os_feature_enabled_impl(domain, feature);
    }
    if (domain && feature) {
        if (!strcmp(domain, "SwiftUI") && !strcmp(feature, "flexiGlassMacOS")) return true;
        if (!strcmp(domain, "SwiftUI") && !strcmp(feature, "Solarium")) {
            const void *ret = __builtin_return_address(0);
            if (s_appkit_loaded && devitrify_caller_is_swift_feature_flags(ret)) {
                s_in_solarium_compute_values = 1;
                return true;
            }
        }
    }
    return _os_feature_enabled_impl(domain, feature);
}

#define DYLD_INTERPOSE(replacement, replacee) \
    __attribute__((used)) static struct { const void *replacement; const void *replacee; } _interpose_##replacee \
    __attribute__((section("__DATA,__interpose"))) = { (const void *)(unsigned long)&replacement, (const void *)(unsigned long)&replacee }
DYLD_INTERPOSE(devitrify_feature_enabled, _os_feature_enabled_impl);

typedef struct { uint32_t platform; uint32_t version; } devitrify_build_version;
extern bool dyld_program_sdk_at_least(devitrify_build_version version);

#define DEVITRIFY_COMPATIBILITY_SDK 0x000F0000
#define DEVITRIFY_COMPATIBILITY_VERSION_SET 0x07E8FFFF

static bool devitrify_version_after_compat(devitrify_build_version version) {
    uint32_t limit = (version.platform == 0xFFFFFFFFU) ? DEVITRIFY_COMPATIBILITY_VERSION_SET : DEVITRIFY_COMPATIBILITY_SDK;
    return version.version > limit;
}

static bool devitrify_caller_draws_interface(const void *address) {
    Dl_info info;
    if (!dladdr(address, &info) || !info.dli_fname) return false;
    return strstr(info.dli_fname, "/AppKit.framework/") || strstr(info.dli_fname, "/SwiftUI.framework/") ||
           strstr(info.dli_fname, "/SwiftUICore.framework/");
}

static bool devitrify_program_sdk_at_least(devitrify_build_version version) {
    if (s_system_disabled || s_process_bypassed) {
        return dyld_program_sdk_at_least(version);
    }
    if (s_in_solarium_compute_values && devitrify_version_after_compat(version) &&
        devitrify_caller_draws_interface(__builtin_return_address(0))) {
        s_in_solarium_compute_values = 0;
        return false;
    }
    return dyld_program_sdk_at_least(version);
}

DYLD_INTERPOSE(devitrify_program_sdk_at_least, dyld_program_sdk_at_least);

// Crash-guard for dlopen(DevitrifyCore): if loading or initializing hooks triggers SIGSEGV/SIGBUS/SIGILL/SIGABRT,
// record a per-process bypass marker and longjmp back so the host app continues running cleanly without hooks.
static sigjmp_buf s_load_jmp_buf;
static volatile sig_atomic_t s_load_guard_active = 0;

static void devitrify_load_signal_handler(int sig) {
    if (s_load_guard_active) {
        s_load_guard_active = 0;
        s_process_bypassed = 1;
        mkdir(DEVITRIFY_BYPASS_DIR, 0755);
        const char *marker = devitrify_process_bypass_marker_path();
        if (marker) {
            int fd = open(marker, O_CREAT | O_WRONLY | O_TRUNC, 0644);
            if (fd >= 0) {
                char msg[64];
                int len = snprintf(msg, sizeof(msg), "signal=%d\n", sig);
                if (len > 0) (void)write(fd, msg, (size_t)len);
                close(fd);
            }
        }
        siglongjmp(s_load_jmp_buf, sig);
    }
}

static void safe_dlopen_core(const char *dylib_path) {
    struct sigaction sa_new, sa_old_segv, sa_old_bus, sa_old_ill, sa_old_trap, sa_old_abrt;
    memset(&sa_new, 0, sizeof(sa_new));
    sa_new.sa_handler = devitrify_load_signal_handler;
    sigemptyset(&sa_new.sa_mask);
    sa_new.sa_flags = 0;

    sigaction(SIGSEGV, &sa_new, &sa_old_segv);
    sigaction(SIGBUS,  &sa_new, &sa_old_bus);
    sigaction(SIGILL,  &sa_new, &sa_old_ill);
    sigaction(SIGTRAP, &sa_new, &sa_old_trap);
    sigaction(SIGABRT, &sa_new, &sa_old_abrt);

    s_load_guard_active = 1;
    if (sigsetjmp(s_load_jmp_buf, 1) == 0) {
        dlopen(dylib_path, RTLD_NOW | RTLD_LOCAL);
    }
    s_load_guard_active = 0;

    sigaction(SIGSEGV, &sa_old_segv, NULL);
    sigaction(SIGBUS,  &sa_old_bus,  NULL);
    sigaction(SIGILL,  &sa_old_ill,  NULL);
    sigaction(SIGTRAP, &sa_old_trap, NULL);
    sigaction(SIGABRT, &sa_old_abrt, NULL);
}

__attribute__((constructor))
static void devitrify_load_core(void) {
    const char *sb_tok = getenv("DEVITRIFY_SANDBOX_TOKEN");
    if (sb_tok && sb_tok[0]) {
        int64_t (*fn_consume)(const char *) =
            (int64_t (*)(const char *))dlsym(RTLD_DEFAULT, "sandbox_extension_consume");
        if (fn_consume) {
            (void)fn_consume(sb_tok);
        }
    }

    check_disable_and_bypass_state();
    if (s_process_bypassed) return;

    Dl_info info;
    char path[PATH_MAX];
    if (!dladdr((const void *)devitrify_load_core, &info) || !realpath(info.dli_fname, path)) return;

    char *slash = strrchr(path, '/');
    if (!slash) return;
    *slash = '\0';
    detect_loaded_frameworks();

    if (is_safe_boot()) return;
    if (!s_appkit_loaded && !s_iconservices_loaded) return;

    // Even if s_system_disabled is currently 1, we still load DevitrifyCore so the process
    // registers the hot-reload listener and can be re-enabled live via `devitrify-reload --enable`.
    char reload_path[PATH_MAX];
    snprintf(reload_path, sizeof(reload_path), "%s/reload/current", path);
    FILE *f = fopen(reload_path, "r");
    if (f) {
        char line[PATH_MAX] = "";
        if (fgets(line, sizeof(line), f)) {
            line[strcspn(line, "\r\n")] = '\0';
            if (line[0] && access(line, R_OK) == 0) {
                fclose(f);
                safe_dlopen_core(line);
                return;
            }
        }
        fclose(f);
    }

    strlcat(path, "/DevitrifyCore.dylib", sizeof(path));
    safe_dlopen_core(path);
}
