#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <notify.h>
#include <sys/stat.h>
#include <dirent.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach-o/loader.h>
#include <libproc.h>
#include <pthread.h>

#define INSTALL_DIR "/Users/Shared/.devitrify"
#define RELOAD_DIR INSTALL_DIR "/reload"
#define CURRENT_FILE RELOAD_DIR "/current"
#define NOTIFY_NAME "com.aotianneo.devitrify.reload"

static void ensure_directories(void) {
    mkdir(INSTALL_DIR, 0755);
    mkdir(RELOAD_DIR, 0755);
}

static void clean_old_reloads(const char *keep_name) {
    DIR *d = opendir(RELOAD_DIR);
    if (!d) return;
    struct dirent *ent;
    const char *home = getenv("HOME");
    char trash[1024];
    if (home) {
        snprintf(trash, sizeof(trash), "%s/.Trash", home);
    } else {
        trash[0] = '\0';
    }

    while ((ent = readdir(d)) != NULL) {
        if (!strncmp(ent->d_name, "DevitrifyCore.", 14) && strstr(ent->d_name, ".dylib")) {
            if (keep_name && !strcmp(ent->d_name, keep_name)) continue;
            char src[1024];
            snprintf(src, sizeof(src), "%s/%s", RELOAD_DIR, ent->d_name);
            if (trash[0]) {
                char dst[1024];
                snprintf(dst, sizeof(dst), "%s/%s", trash, ent->d_name);
                rename(src, dst);
            } else {
                unlink(src);
            }
        }
    }
    closedir(d);
}

// In-memory AppKit menu cache patch across running processes
static void patch_appkit_menu_cache_for_pid(pid_t pid) {
    mach_port_t task = MACH_PORT_NULL;
    if (task_for_pid(mach_task_self(), pid, &task) != KERN_SUCCESS || !MACH_PORT_VALID(task)) {
        return;
    }

    const uint8_t false_byte = 2; // AppKit tri-state: 0=unset, 1=true, 2=false
    // Target global addresses in AppKit for classic menu & shadow:
    mach_vm_write(task, 0x209473338ULL, (vm_offset_t)&false_byte, 1); // sGlassMenusEnabled
    mach_vm_write(task, 0x209473339ULL, (vm_offset_t)&false_byte, 1); // sGlassMenuLayoutEnabled
    mach_vm_write(task, 0x209439c20ULL, (vm_offset_t)&false_byte, 1); // sMenuUseGlassWindowStyle

    const uint64_t zero_ptr = 0;
    mach_vm_write(task, 0x20943e4b8ULL, (vm_offset_t)&zero_ptr, 8); // sReusablePopupMenuWindow

    mach_port_deallocate(mach_task_self(), task);
}

typedef struct {
    pid_t *pids;
    int start;
    int end;
} worker_arg_t;

static void *worker_patch(void *arg) {
    worker_arg_t *w = (worker_arg_t *)arg;
    for (int i = w->start; i < w->end; i++) {
        patch_appkit_menu_cache_for_pid(w->pids[i]);
    }
    return NULL;
}

static void broadcast_cache_patch(void) {
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
    (void)argc; (void)argv;
    ensure_directories();

    long long epoch = (long long)time(NULL);
    char new_dylib_name[256];
    snprintf(new_dylib_name, sizeof(new_dylib_name), "DevitrifyCore.%lld.dylib", epoch);

    char new_dylib_path[1024];
    snprintf(new_dylib_path, sizeof(new_dylib_path), "%s/%s", RELOAD_DIR, new_dylib_name);

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

    // Update the base DevitrifyCore.dylib for newly launched apps
    char copy_cmd[2048];
    snprintf(copy_cmd, sizeof(copy_cmd),
        "cp -f \"%s\" \"%s/DevitrifyCore.dylib.new\" && mv -f \"%s/DevitrifyCore.dylib.new\" \"%s/DevitrifyCore.dylib\"",
        new_dylib_path, INSTALL_DIR, INSTALL_DIR, INSTALL_DIR);
    system(copy_cmd);

    // Update current symlink/reference
    FILE *f = fopen(CURRENT_FILE ".tmp", "w");
    if (f) {
        fprintf(f, "%s\n", new_dylib_path);
        fclose(f);
        rename(CURRENT_FILE ".tmp", CURRENT_FILE);
    }

    // Clean old reloads
    clean_old_reloads(new_dylib_name);

    // Post Darwin IPC notification to all running Cocoa processes
    printf("[Devitrify Hot-Reload] Broadcasting notify '%s'...\n", NOTIFY_NAME);
    notify_post(NOTIFY_NAME);

    // Also update in-memory AppKit menu cache across all processes
    broadcast_cache_patch();

    printf("[Devitrify Hot-Reload] ✅ Hot-reload complete across all running apps!\n");
    return 0;
}
