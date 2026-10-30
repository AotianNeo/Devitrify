#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <notify.h>
#include <sys/stat.h>
#include <dirent.h>
#include <fcntl.h>

#define INSTALL_DIR "/Users/Shared/.devitrify"
#define RELOAD_DIR INSTALL_DIR "/reload"
#define CURRENT_FILE RELOAD_DIR "/current"
#define DISABLED_FILE INSTALL_DIR "/disabled"
#define BYPASS_DIR INSTALL_DIR "/crash-bypass"
#define NOTIFY_NAME "com.aotianneo.devitrify.reload"

static void ensure_directories(void) {
    mkdir(INSTALL_DIR, 0755);
    mkdir(RELOAD_DIR, 0755);
    mkdir(BYPASS_DIR, 0755);
}

static void move_to_trash_or_unlink(const char *src, const char *filename) {
    const char *home = getenv("HOME");
    if (home && home[0]) {
        char dst[1024];
        snprintf(dst, sizeof(dst), "%s/.Trash/%s.%lld", home, filename, (long long)time(NULL));
        if (rename(src, dst) == 0) return;
    }
    unlink(src);
}

static void clean_old_reloads(const char *keep_name) {
    DIR *d = opendir(RELOAD_DIR);
    if (!d) return;
    struct dirent *ent;
    while ((ent = readdir(d)) != NULL) {
        if (!strncmp(ent->d_name, "DevitrifyCore.", 14) && strstr(ent->d_name, ".dylib")) {
            if (keep_name && !strcmp(ent->d_name, keep_name)) continue;
            char src[1024];
            snprintf(src, sizeof(src), "%s/%s", RELOAD_DIR, ent->d_name);
            move_to_trash_or_unlink(src, ent->d_name);
        }
    }
    closedir(d);
}

static void clear_crash_bypasses(void) {
    DIR *d = opendir(BYPASS_DIR);
    if (!d) return;
    struct dirent *ent;
    int cleared = 0;
    while ((ent = readdir(d)) != NULL) {
        if (strstr(ent->d_name, ".bypass")) {
            char src[1024];
            snprintf(src, sizeof(src), "%s/%s", BYPASS_DIR, ent->d_name);
            move_to_trash_or_unlink(src, ent->d_name);
            cleared++;
        }
    }
    closedir(d);
    if (cleared > 0) {
        printf("[Devitrify Hot-Reload] Cleared %d crash-bypass marker(s).\n", cleared);
    }
}

static void print_status(void) {
    int sys_disabled = (access(DISABLED_FILE, F_OK) == 0);
    printf("[Devitrify Status] System-wide hooks: %s\n", sys_disabled ? "DISABLED (all hooks bypassed)" : "ENABLED");

    DIR *d = opendir(BYPASS_DIR);
    if (d) {
        struct dirent *ent;
        int count = 0;
        while ((ent = readdir(d)) != NULL) {
            if (strstr(ent->d_name, ".bypass")) {
                if (count == 0) printf("[Devitrify Status] Auto-bypassed processes (crash-guarded):\n");
                printf("  - %s\n", ent->d_name);
                count++;
            }
        }
        if (count == 0) {
            printf("[Devitrify Status] Auto-bypassed processes: none (0 crashes)\n");
        }
        closedir(d);
    }
}

int main(int argc, char **argv) {
    ensure_directories();

    int mode_disable = 0;
    int mode_enable = 0;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--status") || !strcmp(argv[i], "status")) {
            print_status();
            return 0;
        } else if (!strcmp(argv[i], "--clear-bypass") || !strcmp(argv[i], "clear-bypass")) {
            clear_crash_bypasses();
        } else if (!strcmp(argv[i], "--disable") || !strcmp(argv[i], "disable") || !strcmp(argv[i], "off")) {
            mode_disable = 1;
        } else if (!strcmp(argv[i], "--enable") || !strcmp(argv[i], "enable") || !strcmp(argv[i], "on")) {
            mode_enable = 1;
        }
    }

    if (mode_disable) {
        int fd = open(DISABLED_FILE, O_CREAT | O_WRONLY | O_TRUNC, 0644);
        if (fd >= 0) {
            const char *msg = "disabled\n";
            (void)write(fd, msg, strlen(msg));
            close(fd);
        }
        printf("[Devitrify Hot-Reload] 🛑 System-wide disable marker set (%s).\n", DISABLED_FILE);
    } else if (mode_enable) {
        if (access(DISABLED_FILE, F_OK) == 0) {
            move_to_trash_or_unlink(DISABLED_FILE, "devitrify-disabled");
        }
        clear_crash_bypasses();
        printf("[Devitrify Hot-Reload] 🟢 System-wide hooks enabled.\n");
    }

    int is_currently_disabled = (access(DISABLED_FILE, F_OK) == 0);

    long long epoch = (long long)time(NULL);
    char new_dylib_name[256];
    snprintf(new_dylib_name, sizeof(new_dylib_name), "DevitrifyCore.%lld.dylib", epoch);

    char new_dylib_path[1024];
    snprintf(new_dylib_path, sizeof(new_dylib_path), "%s/%s", RELOAD_DIR, new_dylib_name);

    // Clone the installed DevitrifyCore.dylib into a new epoch generation so dlopen triggers DevitrifyInit.
    printf("[Devitrify Hot-Reload] Packaging %s...\n", new_dylib_name);
    char clone_cmd[2048];
    snprintf(clone_cmd, sizeof(clone_cmd),
        "cp -f \"%s/DevitrifyCore.dylib\" \"%s\" && "
        "install_name_tool -id \"%s\" \"%s\" 2>/dev/null && "
        "env -u DYLD_INSERT_LIBRARIES codesign -s - -f \"%s\"",
        INSTALL_DIR, new_dylib_path, new_dylib_path, new_dylib_path, new_dylib_path);
    if (system(clone_cmd) != 0) {
        fprintf(stderr, "Error: failed to package %s.\n", new_dylib_name);
        return 1;
    }

    FILE *f = fopen(CURRENT_FILE ".tmp", "w");
    if (f) {
        fprintf(f, "%s\n", new_dylib_path);
        fclose(f);
        rename(CURRENT_FILE ".tmp", CURRENT_FILE);
    }

    clean_old_reloads(new_dylib_name);

    printf("[Devitrify Hot-Reload] Broadcasting notify '%s'...\n", NOTIFY_NAME);
    notify_post(NOTIFY_NAME);

    if (is_currently_disabled) {
        printf("[Devitrify Hot-Reload] ✅ All Devitrify hooks unhooked and disabled system-wide across running apps!\n");
    } else {
        printf("[Devitrify Hot-Reload] ✅ Hot-reload complete across all running apps!\n");
    }
    return 0;
}
