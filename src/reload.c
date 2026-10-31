#import <Cocoa/Cocoa.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <notify.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <dirent.h>
#include <fcntl.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach/thread_act.h>
#include <mach/thread_status.h>
#include <mach-o/dyld_images.h>
#if __has_feature(ptrauth_calls)
#include <ptrauth.h>
#endif

#define INSTALL_DIR "/Users/Shared/.devitrify"
#define RELOAD_DIR INSTALL_DIR "/reload"
#define CURRENT_FILE RELOAD_DIR "/current"
#define DISABLED_FILE INSTALL_DIR "/disabled"
#define BYPASS_DIR INSTALL_DIR "/crash-bypass"
#define NOTIFY_NAME "com.aotianneo.devitrify.reload"

static int is_safe_boot(void) {
    int val = 0;
    size_t sz = sizeof(val);
    if (sysctlbyname("kern.safeboot", &val, &sz, NULL, 0) == 0) {
        return val != 0;
    }
    return 0;
}

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
        char cmd[2048];
        snprintf(cmd, sizeof(cmd), "/bin/mv -f \"%s\" \"%s\" 2>/dev/null", src, dst);
        if (system(cmd) == 0) return;
    }
    unlink(src);
}

static void purge_icon_cache_to_trash(void) {
    char cache_dir[PATH_MAX];
    if (confstr(_CS_DARWIN_USER_CACHE_DIR, cache_dir, sizeof(cache_dir)) > 0) {
        const char *targets[] = { "com.apple.iconservices", "com.apple.iconservicesagent", "com.apple.dock.iconcache", NULL };
        for (int i = 0; targets[i]; i++) {
            char p[PATH_MAX];
            snprintf(p, sizeof(p), "%s%s", cache_dir, targets[i]);
            if (access(p, F_OK) == 0) {
                char trash_name[256];
                snprintf(trash_name, sizeof(trash_name), "%s.%lld", targets[i], (long long)time(NULL));
                move_to_trash_or_unlink(p, trash_name);
            }
        }
    }

    char user_dir[PATH_MAX];
    if (confstr(_CS_DARWIN_USER_DIR, user_dir, sizeof(user_dir)) > 0) {
        char lp_db[PATH_MAX];
        snprintf(lp_db, sizeof(lp_db), "%s0/com.apple.dock.launchpad/db/db", user_dir);
        if (access(lp_db, F_OK) == 0) {
            char sql_cmd[PATH_MAX + 128];
            snprintf(sql_cmd, sizeof(sql_cmd),
                "/usr/bin/sqlite3 \"%s\" \"UPDATE image_cache SET size_big=0, size_mini=0, image_data=NULL, image_data_mini=NULL;\" 2>/dev/null", lp_db);
            (void)system(sql_cmd);
        }
    }
}

static void restart_iconservicesagent_if_needed(void) {
    pid_t uid = getuid();
    char cmd[512];
    snprintf(cmd, sizeof(cmd),
        "/usr/bin/killall -9 iconservicesagent 2>/dev/null; "
        "/bin/launchctl kickstart -k gui/%d/com.apple.iconservices.iconservicesagent 2>/dev/null; "
        "/usr/bin/killall Finder 2>/dev/null; "
        "/usr/bin/killall Dock 2>/dev/null", (int)uid);
    (void)system(cmd);
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

static uintptr_t strip_ptr(const void *p) {
#if __has_feature(ptrauth_calls)
    return (uintptr_t)ptrauth_strip((void *)p, ptrauth_key_function_pointer);
#else
    return (uintptr_t)p & 0x00007fffffffffffULL;
#endif
}

static int inspect_process_images(pid_t pid, int *out_has_appkit, int *out_has_devitrify) {
    if (out_has_appkit) *out_has_appkit = 0;
    if (out_has_devitrify) *out_has_devitrify = 0;

    mach_port_t task = MACH_PORT_NULL;
    if (task_for_pid(mach_task_self(), pid, &task) != KERN_SUCCESS) {
        return 0;
    }

    struct task_dyld_info dyld_info;
    mach_msg_type_number_t count = TASK_DYLD_INFO_COUNT;
    if (task_info(task, TASK_DYLD_INFO, (task_info_t)&dyld_info, &count) != KERN_SUCCESS) {
        mach_port_deallocate(mach_task_self(), task);
        return 0;
    }

    struct dyld_all_image_infos infos;
    mach_vm_size_t out_sz = 0;
    if (mach_vm_read_overwrite(task, dyld_info.all_image_info_addr, sizeof(infos),
                               (mach_vm_address_t)&infos, &out_sz) != KERN_SUCCESS) {
        mach_port_deallocate(mach_task_self(), task);
        return 0;
    }

    uint32_t n = infos.infoArrayCount;
    if (n > 2500) n = 2500;
    size_t arr_bytes = n * sizeof(struct dyld_image_info);
    struct dyld_image_info *arr = malloc(arr_bytes);
    if (arr && mach_vm_read_overwrite(task, (mach_vm_address_t)infos.infoArray, arr_bytes,
                                      (mach_vm_address_t)arr, &out_sz) == KERN_SUCCESS) {
        for (uint32_t i = 0; i < n; i++) {
            mach_vm_address_t p = ((mach_vm_address_t)arr[i].imageFilePath) & 0x00007fffffffffffULL;
            if (!p) continue;
            char path[256] = {0};
            mach_vm_size_t page_rem = 0x4000 - (p & 0x3fff);
            mach_vm_size_t read_len = page_rem < 255 ? page_rem : 255;
            if (mach_vm_read_overwrite(task, p, read_len, (mach_vm_address_t)path, &out_sz) != KERN_SUCCESS) {
                page_rem = 0x1000 - (p & 0xfff);
                read_len = page_rem < 255 ? page_rem : 255;
                if (mach_vm_read_overwrite(task, p, read_len, (mach_vm_address_t)path, &out_sz) != KERN_SUCCESS) {
                    continue;
                }
            }
            {
                path[255] = '\0';
                if (out_has_appkit && strstr(path, "/AppKit.framework/")) {
                    *out_has_appkit = 1;
                }
                if (out_has_devitrify && strstr(path, "DevitrifyCore")) {
                    *out_has_devitrify = 1;
                }
                if ((!out_has_appkit || *out_has_appkit) && (!out_has_devitrify || *out_has_devitrify)) {
                    break;
                }
            }
        }
    }
    free(arr);
    mach_port_deallocate(mach_task_self(), task);
    return 1;
}

static const uint32_t s_inject_code[] = {
    // 0x00 (index 0): mach_thread_entry(x0 = page_base)
    0xaa0003f3, // 0x00: mov x19, x0                 (x19 = page_base)
    0xf9409674, // 0x04: ldr x20, [x19, #0x128]      (x20 = remote_stack_base, RW)
    0x91040280, // 0x08: add x0, x20, #0x100         (dummy pthread struct in RW stack)
    0xf9408268, // 0x0c: ldr x8, [x19, #0x100]       (_pthread_set_self)
    0xd63f0100, // 0x10: blr x8
    0x91004280, // 0x14: add x0, x20, #0x10          (&pthread_t in RW stack page)
    0xd2800001, // 0x18: mov x1, #0                  (attr = NULL)
    0x100001a2, // 0x1c: adr x2, 0x50                (pc + 0x34 = 0x50 -> pthread_entry)
    0xdac123e2, // 0x20: paciza x2                   (sign x2 with target's IA key)
    0xaa1303e3, // 0x24: mov x3, x19                 (arg = page_base)
    0xf9408668, // 0x28: ldr x8, [x19, #0x108]       (pthread_create_from_mach_thread)
    0xd63f0100, // 0x2c: blr x8
    0x34000060, // 0x30: cbz w0, 0x3c                (if 0, jump to loop)
    0xd2800048, // 0x34: mov x8, #2
    0xf9000288, // 0x38: str x8, [x20, #0]           (done_flag = 2)
    // 0x3c (index 15): terminate loop
    0xf9408a68, // 0x3c: ldr x8, [x19, #0x110]       (mach_thread_self)
    0xd63f0100, // 0x40: blr x8
    0xf9408e68, // 0x44: ldr x8, [x19, #0x118]       (thread_terminate)
    0xd63f0100, // 0x48: blr x8
    0x17fffffc, // 0x4c: b 0x3c

    // 0x50 (index 20): pthread_entry(x0 = page_base)
    0xa9be4ff4, // 0x50: stp x20, x19, [sp, #-32]!
    0xa9017bfd, // 0x54: stp x29, x30, [sp, #16]
    0x910043fd, // 0x58: add x29, sp, #16
    0xaa0003f3, // 0x5c: mov x19, x0                 (x19 = page_base)
    0xf9409674, // 0x60: ldr x20, [x19, #0x128]      (x20 = remote_stack_base, RW)
    0x91180260, // 0x64: add x0, x19, #0x600         (sandbox_token)
    0x39400008, // 0x68: ldrb w8, [x0]
    0x34000068, // 0x6c: cbz w8, 0x78
    0xf9409e68, // 0x70: ldr x8, [x19, #0x138]       (sandbox_extension_consume)
    0xd63f0100, // 0x74: blr x8
    0x91080260, // 0x78: add x0, x19, #0x200         (dylib_path)
    0xd2800041, // 0x7c: mov x1, #2                  (RTLD_NOW)
    0xf9409268, // 0x80: ldr x8, [x19, #0x120]       (dlopen)
    0xd63f0100, // 0x84: blr x8
    0xf9000680, // 0x88: str x0, [x20, #8]           (dlopen_ret = x0)
    0xd2800028, // 0x8c: mov x8, #1
    0xf9000288, // 0x90: str x8, [x20, #0]           (done_flag = 1)
    0xd2800000, // 0x94: mov x0, #0
    0xa9417bfd, // 0x98: ldp x29, x30, [sp, #16]
    0xa8c24ff4, // 0x9c: ldp x20, x19, [sp], #32
    0xd65f03c0, // 0xa0: ret
};

static int inject_dylib_into_pid(pid_t pid, const char *dylib_path) {
    mach_port_t task = MACH_PORT_NULL;
    if (task_for_pid(mach_task_self(), pid, &task) != KERN_SUCCESS) {
        return 0;
    }

    mach_vm_address_t remote_page = 0, remote_stack = 0;
    if (mach_vm_allocate(task, &remote_page, 0x4000, VM_FLAGS_ANYWHERE) != KERN_SUCCESS) {
        mach_port_deallocate(mach_task_self(), task);
        return 0;
    }
    if (mach_vm_allocate(task, &remote_stack, 0x10000, VM_FLAGS_ANYWHERE) != KERN_SUCCESS) {
        mach_vm_deallocate(task, remote_page, 0x4000);
        mach_port_deallocate(mach_task_self(), task);
        return 0;
    }

    uint8_t local_page[0x4000];
    memset(local_page, 0, sizeof(local_page));
    memcpy(local_page, s_inject_code, sizeof(s_inject_code));
    *(uint64_t *)(local_page + 0x100) = strip_ptr(dlsym(RTLD_DEFAULT, "_pthread_set_self"));
    *(uint64_t *)(local_page + 0x108) = strip_ptr(dlsym(RTLD_DEFAULT, "pthread_create_from_mach_thread"));
    *(uint64_t *)(local_page + 0x110) = strip_ptr(dlsym(RTLD_DEFAULT, "mach_thread_self"));
    *(uint64_t *)(local_page + 0x118) = strip_ptr(dlsym(RTLD_DEFAULT, "thread_terminate"));
    *(uint64_t *)(local_page + 0x120) = strip_ptr(dlsym(RTLD_DEFAULT, "dlopen"));
    *(uint64_t *)(local_page + 0x128) = (uint64_t)remote_stack;
    *(uint64_t *)(local_page + 0x130) = strip_ptr(dlsym(RTLD_DEFAULT, "dlerror"));
    *(uint64_t *)(local_page + 0x138) = strip_ptr(dlsym(RTLD_DEFAULT, "sandbox_extension_consume"));
    strlcpy((char *)(local_page + 0x200), dylib_path, 0x400);

    char * (*fn_issue)(const char *, const char *, uint32_t) =
        (char * (*)(const char *, const char *, uint32_t))dlsym(RTLD_DEFAULT, "sandbox_extension_issue_file");
    if (fn_issue) {
        char *tok = fn_issue("com.apple.app-sandbox.read", INSTALL_DIR, 0);
        if (tok) {
            strlcpy((char *)(local_page + 0x600), tok, 0x400);
            free(tok);
        }
    }

    if (mach_vm_write(task, remote_page, (vm_offset_t)local_page, sizeof(local_page)) != KERN_SUCCESS ||
        mach_vm_protect(task, remote_page, 0x4000, FALSE, VM_PROT_READ | VM_PROT_EXECUTE) != KERN_SUCCESS) {
        mach_vm_deallocate(task, remote_page, 0x4000);
        mach_vm_deallocate(task, remote_stack, 0x10000);
        mach_port_deallocate(mach_task_self(), task);
        return 0;
    }

    thread_act_t th = MACH_PORT_NULL;
    if (thread_create(task, &th) != KERN_SUCCESS) {
        mach_vm_deallocate(task, remote_page, 0x4000);
        mach_vm_deallocate(task, remote_stack, 0x10000);
        mach_port_deallocate(mach_task_self(), task);
        return 0;
    }

    arm_thread_state64_t state, conv_state;
    memset(&state, 0, sizeof(state));
    memset(&conv_state, 0, sizeof(conv_state));
    state.__x[0] = (uint64_t)remote_page;
    void *entry_fptr = (void *)(uintptr_t)remote_page;
    void *sp_ptr = (void *)(uintptr_t)(remote_stack + 0xf000);
#if __has_feature(ptrauth_calls)
    entry_fptr = ptrauth_sign_unauthenticated(entry_fptr, ptrauth_key_function_pointer, 0);
#endif
    __darwin_arm_thread_state64_set_pc_fptr(state, entry_fptr);
    __darwin_arm_thread_state64_set_sp(state, sp_ptr);

    mach_msg_type_number_t conv_cnt = ARM_THREAD_STATE64_COUNT;
    if (thread_convert_thread_state(th, THREAD_CONVERT_THREAD_STATE_FROM_SELF, ARM_THREAD_STATE64,
                                    (thread_state_t)&state, ARM_THREAD_STATE64_COUNT,
                                    (thread_state_t)&conv_state, &conv_cnt) != KERN_SUCCESS) {
        conv_state = state;
    }

    if (thread_set_state(th, ARM_THREAD_STATE64, (thread_state_t)&conv_state, ARM_THREAD_STATE64_COUNT) != KERN_SUCCESS ||
        thread_resume(th) != KERN_SUCCESS) {
        thread_terminate(th);
        mach_port_deallocate(mach_task_self(), th);
        mach_port_deallocate(mach_task_self(), task);
        return 0;
    }

    int ok = 0;
    for (int i = 0; i < 150; i++) {
        usleep(10000);
        uint64_t res[3] = {0, 0, 0};
        mach_vm_size_t out_sz = 0;
        if (mach_vm_read_overwrite(task, remote_stack, sizeof(res), (mach_vm_address_t)res, &out_sz) == KERN_SUCCESS) {
            if (res[0] != 0) {
                ok = (res[0] == 1 && res[1] != 0) ? 1 : 0;
                break;
            }
        }
    }

    mach_port_deallocate(mach_task_self(), th);
    mach_port_deallocate(mach_task_self(), task);
    return ok;
}

static int is_exe_bypassed(NSString *exeName) {
    if (!exeName || exeName.length == 0) return 0;
    NSString *bypassPath = [NSString stringWithFormat:@"%s/%@.bypass", BYPASS_DIR, exeName];
    return access(bypassPath.UTF8String, F_OK) == 0;
}

static int is_pid_translated(pid_t pid) {
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, pid };
    struct kinfo_proc kp;
    size_t len = sizeof(kp);
    if (sysctl(mib, 4, &kp, &len, NULL, 0) == 0 && len > 0) {
        return (kp.kp_proc.p_flag & P_TRANSLATED) != 0;
    }
    return 0;
}

static void scan_or_inject_running_apps(const char *dylib_path, int do_inject, int *out_injected, int *out_uninjected) {
    if (out_injected) *out_injected = 0;
    if (out_uninjected) *out_uninjected = 0;

    @autoreleasepool {
        NSArray<NSRunningApplication *> *apps = [[NSWorkspace sharedWorkspace] runningApplications];
        pid_t self_pid = getpid();
        for (NSRunningApplication *app in apps) {
            if (app.activationPolicy == NSApplicationActivationPolicyProhibited) continue;
            pid_t pid = app.processIdentifier;
            if (pid <= 1 || pid == self_pid || is_pid_translated(pid)) continue;

            NSString *bundlePath = app.bundleURL.path;
            if (!bundlePath || ![bundlePath hasSuffix:@".app"]) continue;
            if ([bundlePath rangeOfString:@".app/Contents/"].location != NSNotFound) continue;

            NSString *bid = app.bundleIdentifier ?: @"";
            if ([bid isEqualToString:@"com.apple.loginwindow"] ||
                [bid isEqualToString:@"com.apple.dock"] ||
                [bid isEqualToString:@"com.apple.ProblemReporter"]) continue;

            NSString *exeName = app.executableURL.lastPathComponent ?: app.localizedName;
            if (is_exe_bypassed(exeName)) continue;

            int has_appkit = 0, has_devitrify = 0;
            if (!inspect_process_images(pid, &has_appkit, &has_devitrify)) continue;
            if (!has_appkit) continue;

            if (has_devitrify) {
                if (out_injected) (*out_injected)++;
            } else {
                if (do_inject && dylib_path) {
                    if (inject_dylib_into_pid(pid, dylib_path)) {
                        printf("[Devitrify Live-Inject] 💉 Injected into %s (pid %d) without restart.\n",
                               (app.localizedName ?: exeName).UTF8String, pid);
                        if (out_injected) (*out_injected)++;
                    } else {
                        if (out_uninjected) (*out_uninjected)++;
                    }
                } else {
                    if (out_uninjected) (*out_uninjected)++;
                }
            }
        }
    }
}

static void print_status(void) {
    int sys_disabled = (access(DISABLED_FILE, F_OK) == 0);
    printf("[Devitrify Status] System-wide hooks: %s\n", sys_disabled ? "DISABLED (all hooks bypassed)" : "ENABLED");

    int injected = 0, uninjected = 0;
    scan_or_inject_running_apps(NULL, 0, &injected, &uninjected);
    printf("[Devitrify Status] Running GUI apps/services: %d injected, %d uninjected\n", injected, uninjected);

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
    if (is_safe_boot()) {
        printf("[Devitrify Hot-Reload] ⚠️ System booted in Safe Mode (kern.safeboot=1). Devitrify is automatically disabled.\n");
        (void)system("/bin/launchctl unsetenv DYLD_INSERT_LIBRARIES");
        notify_post(NOTIFY_NAME);
        return 0;
    }

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
        purge_icon_cache_to_trash();
        restart_iconservicesagent_if_needed();
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

    char * (*fn_issue)(const char *, const char *, uint32_t) =
        (char * (*)(const char *, const char *, uint32_t))dlsym(RTLD_DEFAULT, "sandbox_extension_issue_file");
    if (fn_issue) {
        char *tok = fn_issue("com.apple.app-sandbox.read", INSTALL_DIR, 0);
        if (tok) {
            char setenv_cmd[1024];
            snprintf(setenv_cmd, sizeof(setenv_cmd), "/bin/launchctl setenv DEVITRIFY_SANDBOX_TOKEN \"%s\"", tok);
            (void)system(setenv_cmd);
            free(tok);
        }
    }

    printf("[Devitrify Hot-Reload] Broadcasting notify '%s'...\n", NOTIFY_NAME);
    notify_post(NOTIFY_NAME);

    if (!is_currently_disabled) {
        int injected = 0, uninjected = 0;
        scan_or_inject_running_apps(new_dylib_path, 1, &injected, &uninjected);
        purge_icon_cache_to_trash();
        restart_iconservicesagent_if_needed();
    }

    // Ensure AppleICUForce24HourTime is enabled in global preferences so loginwindow's
    // LUIClockSettingsMonitor sets shows24HourTime to true in ClockSettings.plist, causing
    // LUI2BigTimeViewController to select the 'Jmm' template instead of 'jmm' (which forcibly
    // displays unwanted AM/PM markers on the lock screen).
    CFPropertyListRef curVal = CFPreferencesCopyAppValue(CFSTR("AppleICUForce24HourTime"), kCFPreferencesAnyApplication);
    Boolean needsSet = true;
    if (curVal && CFGetTypeID(curVal) == CFBooleanGetTypeID() && CFBooleanGetValue((CFBooleanRef)curVal)) {
        needsSet = false;
    }
    if (curVal) CFRelease(curVal);
    if (needsSet) {
        CFPreferencesSetAppValue(CFSTR("AppleICUForce24HourTime"), kCFBooleanTrue, kCFPreferencesAnyApplication);
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication);
    }

    // Also broadcast distributed time/number preference notifications so long-running
    // system daemons (including loginwindow's LUIClockSettingsMonitor) resynchronize
    // and refresh lock-screen clock formatting immediately without restarting loginwindow.
    CFNotificationCenterRef dist = CFNotificationCenterGetDistributedCenter();
    if (dist) {
        CFNotificationCenterPostNotification(dist, CFSTR("AppleTimePreferencesChangedNotification"), NULL, NULL, true);
        CFNotificationCenterPostNotification(dist, CFSTR("AppleNumberPreferencesChangedNotification"), NULL, NULL, true);
    }

    if (is_currently_disabled) {
        printf("[Devitrify Hot-Reload] ✅ All Devitrify hooks unhooked and disabled system-wide across running apps!\n");
    } else {
        printf("[Devitrify Hot-Reload] ✅ Hot-reload & live injection complete across all running apps!\n");
    }
    return 0;
}
