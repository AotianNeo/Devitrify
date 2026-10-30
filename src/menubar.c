// devitrify-menubar: Enables the 33pt Solarium notched menu bar height in WindowServer
// while keeping SwiftUI/Solarium disabled system-wide.
//
// Zero hardcoded offsets: dynamically locates target instructions in SkyLight.framework
// by scanning __TEXT string cross-references and instruction patterns, so it survives
// future macOS updates and dyld shared cache rebuilds automatically.

#include <CoreGraphics/CoreGraphics.h>
#include <dlfcn.h>
#include <libproc.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach-o/dyld.h>
#include <mach-o/dyld_images.h>
#include <mach-o/loader.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern CGError SLSGetDisplayMenubarHeight(uint32_t display, uint32_t *height);
extern void SLSDumpSarlaccCGPath(void);
extern void SLSSetSarlaccPathShow(int show);

typedef struct {
    uint64_t off_solarium_bl;        // Unslid address of `bl _os_feature_enabled_impl` in WS::Features::solarium_menubar_enabled
    uint32_t orig_solarium_bl;       // Original `bl` instruction word in local shared cache
    uint64_t off_sarlacc_show_bl;    // Unslid address of `bl WSSetSarlaccDebugWindow` in _XSetSarlaccPathShow
    uint32_t orig_sarlacc_show_bl;   // Original `bl` instruction word in local shared cache
    uint64_t off_pkg_config_changed; // Unslid entry address of PKGDisplay_display_config_changed
} skylight_targets_t;

static uint64_t decode_adrp_add(const uint32_t *code, size_t idx) {
    uint32_t insn1 = code[idx];
    uint32_t insn2 = code[idx + 1];
    if ((insn1 & 0x9f000000) != 0x90000000 || (insn2 & 0xff800000) != 0x91000000) return 0;
    uint32_t rd1 = insn1 & 0x1f;
    uint32_t rn2 = (insn2 >> 5) & 0x1f;
    if (rd1 != rn2) return 0;
    int64_t immhi = (insn1 >> 5) & 0x7ffff;
    int64_t immlo = (insn1 >> 29) & 0x3;
    int64_t page_off = (immhi << 2) | immlo;
    if (page_off & (1LL << 20)) page_off |= ~((1LL << 21) - 1);
    uint64_t page = ((uint64_t)&code[idx] & ~0xfffULL) + (page_off << 12);
    uint32_t imm12 = (insn2 >> 10) & 0xfff;
    if ((insn2 >> 22) & 1) imm12 <<= 12;
    return page + imm12;
}

static bool resolve_skylight_targets(skylight_targets_t *out) {
    memset(out, 0, sizeof(*out));
    dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);

    const struct mach_header_64 *mh = NULL;
    intptr_t slide = 0;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, "/SkyLight.framework/")) {
            mh = (const struct mach_header_64 *)_dyld_get_image_header(i);
            slide = _dyld_get_image_vmaddr_slide(i);
            break;
        }
    }
    if (!mh) return false;

    const uint32_t *code = NULL;
    size_t code_count = 0;
    uint64_t text_start = 0, text_end = 0;
    const uint8_t *lc = (const uint8_t *)(mh + 1);
    for (uint32_t j = 0; j < mh->ncmds; j++) {
        const struct load_command *cmd = (const struct load_command *)lc;
        if (cmd->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
            if (strcmp(seg->segname, "__TEXT") == 0) {
                text_start = seg->vmaddr + slide;
                text_end = text_start + seg->vmsize;
                code = (const uint32_t *)text_start;
                code_count = seg->vmsize / 4;
                break;
            }
        }
        lc += cmd->cmdsize;
    }
    if (!code) return false;

    for (size_t k = 0; k + 6 < code_count; k++) {
        uint64_t s1 = decode_adrp_add(code, k);
        if (s1 < text_start || s1 >= text_end) continue;

        // 1. WS::Features::solarium_menubar_enabled():
        //    adrp/add x0, "SwiftUI"; adrp/add x1, "Solarium"; bl _os_feature_enabled_impl
        if (!out->off_solarium_bl && strcmp((const char *)s1, "SwiftUI") == 0) {
            uint64_t s2 = decode_adrp_add(code, k + 2);
            if (s2 >= text_start && s2 < text_end && strcmp((const char *)s2, "Solarium") == 0) {
                if ((code[k + 4] & 0xfc000000) == 0x94000000) {
                    Dl_info info = {0};
                    dladdr((const void *)&code[k], &info);
                    if ((info.dli_sname && strstr(info.dli_sname, "solarium_menubar_enabled")) ||
                        ((code[k + 5] & 0xff000000) != 0x34000000)) {
                        out->off_solarium_bl = (uint64_t)&code[k + 4] - slide;
                        out->orig_solarium_bl = code[k + 4];
                    }
                }
            }
        }

        // 2. _XSetSarlaccPathShow: immediately precedes _XDumpSarlaccPath (which references "/tmp/sarlacc_path.txt")
        if (!out->off_sarlacc_show_bl && strcmp((const char *)s1, "/tmp/sarlacc_path.txt") == 0) {
            for (size_t b = 1; b < 64 && b <= k; b++) {
                // `ldr w0, [x0, #0x20]` (0xb9402000) followed by `bl WSSetSarlaccDebugWindow`
                if (code[k - b] == 0xb9402000 && ((code[k - b + 1] & 0xfc000000) == 0x94000000)) {
                    out->off_sarlacc_show_bl = (uint64_t)&code[k - b + 1] - slide;
                    out->orig_sarlacc_show_bl = code[k - b + 1];
                    break;
                }
            }
        }

        // 3. PKGDisplay_display_config_changed: references "PKGDisplay %{public}s is already inactive"
        if (!out->off_pkg_config_changed && strcmp((const char *)s1, "PKGDisplay %{public}s is already inactive") == 0) {
            for (size_t b = 1; b < 128 && b <= k; b++) {
                if (code[k - b] == 0xd503237f) { // pacibsp
                    out->off_pkg_config_changed = (uint64_t)&code[k - b] - slide;
                    break;
                }
            }
        }
    }

    return out->off_solarium_bl && out->off_sarlacc_show_bl && out->off_pkg_config_changed;
}

static pid_t find_windowserver_pid(void) {
    int count = proc_listallpids(NULL, 0);
    if (count <= 0) return -1;
    pid_t *pids = calloc((size_t)count * 2, sizeof(pid_t));
    if (!pids) return -1;
    count = proc_listallpids(pids, count * 2 * (int)sizeof(pid_t));
    pid_t found = -1;
    for (int i = 0; i < count; i++) {
        if (pids[i] <= 0) continue;
        char name[PROC_PIDPATHINFO_MAXSIZE] = {0};
        if (proc_name(pids[i], name, sizeof(name)) > 0 && strcmp(name, "WindowServer") == 0) {
            found = pids[i];
            break;
        }
    }
    free(pids);
    return found;
}

static bool patch_word(mach_port_t task, mach_vm_address_t addr, uint32_t val) {
    mach_vm_address_t page = addr & ~0x3fffULL;
    bool suspended = (task_suspend(task) == KERN_SUCCESS);
    kern_return_t kr = mach_vm_protect(task, page, 0x4000, FALSE, VM_PROT_READ | VM_PROT_WRITE);
    if (kr != KERN_SUCCESS) {
        kr = mach_vm_protect(task, page, 0x4000, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    }
    if (kr != KERN_SUCCESS) {
        if (suspended) task_resume(task);
        return false;
    }
    kr = mach_vm_write(task, addr, (vm_offset_t)&val, sizeof(val));
    kern_return_t kr_prot = mach_vm_protect(task, page, 0x4000, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
    vm_machine_attribute_val_t mattr_val = MATTR_VAL_ICACHE_FLUSH;
    mach_vm_machine_attribute(task, page, 0x4000, MATTR_CACHE, &mattr_val);
    if (suspended) task_resume(task);
    return kr == KERN_SUCCESS && kr_prot == KERN_SUCCESS;
}

int main(int argc, char **argv) {
    bool restore = (argc >= 2 && (strcmp(argv[1], "--restore") == 0 || strcmp(argv[1], "-r") == 0));

    skylight_targets_t targets;
    if (!resolve_skylight_targets(&targets)) {
        fprintf(stderr, "devitrify-menubar: failed to resolve SkyLight targets.\n");
        return 1;
    }

    pid_t ws_pid = find_windowserver_pid();
    if (ws_pid <= 0) {
        fprintf(stderr, "devitrify-menubar: WindowServer not found.\n");
        return 1;
    }

    mach_port_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), ws_pid, &task);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "devitrify-menubar: task_for_pid(%d) failed: %s\n", ws_pid, mach_error_string(kr));
        return 1;
    }

    struct task_dyld_info dyld_info;
    mach_msg_type_number_t count = TASK_DYLD_INFO_COUNT;
    if (task_info(task, TASK_DYLD_INFO, (task_info_t)&dyld_info, &count) != KERN_SUCCESS) {
        fprintf(stderr, "devitrify-menubar: TASK_DYLD_INFO failed.\n");
        return 1;
    }

    struct dyld_all_image_infos infos;
    mach_vm_size_t out_size = 0;
    if (mach_vm_read_overwrite(task, dyld_info.all_image_info_addr, sizeof(infos),
                               (mach_vm_address_t)&infos, &out_size) != KERN_SUCCESS) {
        fprintf(stderr, "devitrify-menubar: failed to read dyld_all_image_infos.\n");
        return 1;
    }

    uintptr_t ws_slide = infos.sharedCacheSlide;
    uint64_t addr_solarium = targets.off_solarium_bl + ws_slide;
    uint64_t addr_sarlacc_show = targets.off_sarlacc_show_bl + ws_slide;
    uint64_t addr_pkg_changed = targets.off_pkg_config_changed + ws_slide;

    int64_t rel = ((int64_t)addr_pkg_changed - (int64_t)addr_sarlacc_show) >> 2;
    uint32_t bl_pkg_changed = 0x94000000U | ((uint32_t)rel & 0x03ffffffU);
    uint32_t mov_w0_1 = 0x52800020U;

    uint32_t cur_solarium = 0;
    if (mach_vm_read_overwrite(task, addr_solarium, sizeof(cur_solarium),
                               (mach_vm_address_t)&cur_solarium, &out_size) != KERN_SUCCESS) {
        fprintf(stderr, "devitrify-menubar: failed to read target instruction.\n");
        return 1;
    }
    if (cur_solarium != targets.orig_solarium_bl && cur_solarium != mov_w0_1) {
        fprintf(stderr, "devitrify-menubar: unexpected instruction 0x%08x at 0x%llx.\n", cur_solarium, addr_solarium);
        return 1;
    }

    uint32_t desired_insn = restore ? targets.orig_solarium_bl : mov_w0_1;
    if (cur_solarium != desired_insn) {
        if (!patch_word(task, addr_solarium, desired_insn)) {
            fprintf(stderr, "devitrify-menubar: failed to patch solarium_menubar_enabled.\n");
            return 1;
        }

        if (!patch_word(task, addr_sarlacc_show, bl_pkg_changed)) {
            fprintf(stderr, "devitrify-menubar: failed to patch _XSetSarlaccPathShow.\n");
            return 1;
        }

        SLSDumpSarlaccCGPath();
        usleep(100000);
        SLSSetSarlaccPathShow(0);
        usleep(200000);
        unlink("/tmp/sarlacc_path.txt");

        patch_word(task, addr_sarlacc_show, targets.orig_sarlacc_show_bl);
    }

    uint32_t h_after = 0;
    SLSGetDisplayMenubarHeight(CGMainDisplayID(), &h_after);
    printf("devitrify-menubar: menu bar height is now %u pt.\n", h_after);
    return 0;
}
