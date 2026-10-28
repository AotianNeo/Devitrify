#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <notify.h>
#include <sys/stat.h>
#include <dirent.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach-o/loader.h>
#include <libproc.h>
#include <pthread.h>

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

// In-memory AppKit menu cache patch across running processes
static void patch_appkit_menu_cache_for_pid(pid_t pid, uint8_t menu_val) {
    mach_port_t task = MACH_PORT_NULL;
    if (task_for_pid(mach_task_self(), pid, &task) != KERN_SUCCESS || !MACH_PORT_VALID(task)) {
        return;
    }

    // AppKit tri-state: 0=unset, 1=true (glass), 2=false (classic)
    mach_vm_write(task, 0x209473338ULL, (vm_offset_t)&menu_val, 1); // sGlassMenusEnabled
    mach_vm_write(task, 0x209473339ULL, (vm_offset_t)&menu_val, 1); // sGlassMenuLayoutEnabled
    mach_vm_write(task, 0x209439c20ULL, (vm_offset_t)&menu_val, 1); // sMenuUseGlassWindowStyle

    const uint64_t zero_ptr = 0;
    mach_vm_write(task, 0x20943e4b8ULL, (vm_offset_t)&zero_ptr, 8); // sReusablePopupMenuWindow

    mach_port_deallocate(mach_task_self(), task);
}

typedef struct {
    pid_t *pids;
    int start;
    int end;
    uint8_t menu_val;
} worker_arg_t;

static void *worker_patch(void *arg) {
    worker_arg_t *w = (worker_arg_t *)arg;
    for (int i = w->start; i < w->end; i++) {
        patch_appkit_menu_cache_for_pid(w->pids[i], w->menu_val);
    }
    return NULL;
}

static void broadcast_cache_patch(uint8_t menu_val) {
    int max_pids = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (max_pids <= 0) return;
    pid_t *pids = malloc(max_pids * sizeof(pid_t));
    int bytes = proc_listpids(PROC_ALL_PIDS, 0, pids, max_pids * sizeof(pid_t));
    int count = bytes / sizeof(pid_t);

    #define NUM_THREADS 8
    pthread_t threads[NUM_THREADS];
    worker_arg_t args[NUM_THREADS];
    int chunk = (count + NUM_THREADS - 1) / NUM_THREADS;

    for (int t = 0; t < NUM_THREADS; t++) {
        args[t].pids = pids;
        args[t].start = t * chunk;
        args[t].end = (t + 1) * chunk;
        args[t].menu_val = menu_val;
        if (args[t].end > count) args[t].end = count;
        if (args[t].start < args[t].end) {
            pthread_create(&threads[t], NULL, worker_patch, &args[t]);
        } else {
            threads[t] = 0;
        }
    }
    for (int t = 0; t < NUM_THREADS; t++) {
        if (threads[t]) pthread_join(threads[t], NULL);
    }
    free(pids);
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

    // If src/DevitrifyCore.m exists in current working directory, compile a fresh generation;
    // otherwise copy the installed DevitrifyCore.dylib into a new generation so dlopen triggers DevitrifyInit.
    if (access("src/DevitrifyCore.m", R_OK) == 0) {
        printf("[Devitrify Hot-Reload] Building %s...\n", new_dylib_name);
        char compile_cmd[2048];
        snprintf(compile_cmd, sizeof(compile_cmd),
            "clang -O2 -Wall -Wextra -arch arm64 -arch arm64e -fobjc-arc -dynamiclib "
            "-framework Cocoa -framework QuartzCore "
            "-install_name \"%s\" src/DevitrifyCore.m -o \"%s\" && "
            "env -u DYLD_INSERT_LIBRARIES codesign -s - -f \"%s\"",
            new_dylib_path, new_dylib_path, new_dylib_path);

        if (system(compile_cmd) != 0) {
            fprintf(stderr, "Error: compilation failed.\n");
            return 1;
        }

        char copy_cmd[2048];
        snprintf(copy_cmd, sizeof(copy_cmd),
            "cp -f \"%s\" \"%s/DevitrifyCore.dylib.new\" && mv -f \"%s/DevitrifyCore.dylib.new\" \"%s/DevitrifyCore.dylib\"",
            new_dylib_path, INSTALL_DIR, INSTALL_DIR, INSTALL_DIR);
        system(copy_cmd);
    } else {
        printf("[Devitrify Hot-Reload] Cloning %s from installed DevitrifyCore.dylib...\n", new_dylib_name);
        char clone_cmd[2048];
        snprintf(clone_cmd, sizeof(clone_cmd),
            "cp -f \"%s/DevitrifyCore.dylib\" \"%s\" && "
            "install_name_tool -id \"%s\" \"%s\" 2>/dev/null && "
            "env -u DYLD_INSERT_LIBRARIES codesign -s - -f \"%s\"",
            INSTALL_DIR, new_dylib_path, new_dylib_path, new_dylib_path, new_dylib_path);
        if (system(clone_cmd) != 0) {
            fprintf(stderr, "Error: failed to clone DevitrifyCore.dylib.\n");
            return 1;
        }
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

    // 2 = classic menus (false), 0 = reset to system default when disabled
    broadcast_cache_patch(is_currently_disabled ? 0 : 2);

    if (is_currently_disabled) {
        printf("[Devitrify Hot-Reload] ✅ All Devitrify hooks unhooked and disabled system-wide across running apps!\n");
    } else {
        printf("[Devitrify Hot-Reload] ✅ Hot-reload complete across all running apps!\n");
    }
    return 0;
}
