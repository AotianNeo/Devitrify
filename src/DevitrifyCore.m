#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <notify.h>
#import <signal.h>
#import <setjmp.h>
#import <libkern/OSCacheControl.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <mach-o/getsect.h>
#import <sys/sysctl.h>
#import <ImageIO/ImageIO.h>
#if __has_feature(ptrauth_calls)
#import <ptrauth.h>
#endif

#define DEVITRIFY_INSTALL_DIR   @"/Users/Shared/.devitrify"
#define DEVITRIFY_DISABLED_PATH DEVITRIFY_INSTALL_DIR @"/disabled"
#define DEVITRIFY_BYPASS_DIR    DEVITRIFY_INSTALL_DIR @"/crash-bypass"
#define DEVITRIFY_BLUR_PATH     DEVITRIFY_INSTALL_DIR @"/blur-radius"
#define DEVITRIFY_CURRENT_PATH  DEVITRIFY_INSTALL_DIR @"/reload/current"
#define DEVITRIFY_CORE_PATH     DEVITRIFY_INSTALL_DIR @"/DevitrifyCore.dylib"

static volatile int s_core_hooks_disabled = 0;

static BOOL dv_isSafeBoot(void) {
    int val = 0;
    size_t sz = sizeof(val);
    if (sysctlbyname("kern.safeboot", &val, &sz, NULL, 0) == 0) {
        return val != 0;
    }
    return NO;
}

static inline Class dv_hostClass(void) {
    return objc_getClass("NSApplication") ?: (objc_getClass("NSProcessInfo") ?: objc_getClass("NSObject"));
}

static void dv_setLoaderSystemDisabled(BOOL disabled) {
    s_core_hooks_disabled = disabled ? 1 : 0;
    void (*fn)(int) = dlsym(RTLD_DEFAULT, "devitrify_set_system_disabled");
    if (fn) fn(disabled ? 1 : 0);
}

static BOOL dv_isSystemDisabledOnDisk(void) {
    return [NSFileManager.defaultManager fileExistsAtPath:DEVITRIFY_DISABLED_PATH];
}

static NSString *dv_processBypassMarkerPath(void) {
    const char *(*fn)(void) = dlsym(RTLD_DEFAULT, "devitrify_process_bypass_marker_path");
    const char *cpath = fn ? fn() : NULL;
    if (cpath) return [NSString stringWithUTF8String:cpath];
    NSString *exe = [NSBundle.mainBundle.executablePath lastPathComponent] ?: NSProcessInfo.processInfo.processName;
    if (!exe.length) return nil;
    return [NSString stringWithFormat:@"%@/%@.bypass", DEVITRIFY_BYPASS_DIR, exe];
}

static BOOL dv_isProcessBypassedOnDisk(void) {
    NSString *path = dv_processBypassMarkerPath();
    return path && [NSFileManager.defaultManager fileExistsAtPath:path];
}

static void dv_markProcessBypassedOnDisk(int sig) {
    NSString *path = dv_processBypassMarkerPath();
    if (!path) return;
    [NSFileManager.defaultManager createDirectoryAtPath:DEVITRIFY_BYPASS_DIR
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
    NSString *info = [NSString stringWithFormat:@"signal=%d pid=%d\n", sig, getpid()];
    [info writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

#pragma mark - Idempotent Swizzle & Inline Patch Registry

// Process-wide map of original IMPs stored on dv_hostClass() so hot-reloads
// never chain swizzles or lose the original implementation, and can restore all hooks on demand.
static NSMutableDictionary<NSString *, NSValue *> *dv_originalIMPMap(void) {
    Class host = dv_hostClass();
    const void *key = (const void *)sel_registerName("dv_originalIMPMap");
    NSMutableDictionary *map = objc_getAssociatedObject(host, key);
    if (!map) {
        map = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(host, key, map, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return map;
}

static NSMutableDictionary<NSNumber *, NSData *> *dv_inlinePatchMap(void) {
    Class host = dv_hostClass();
    const void *key = (const void *)sel_registerName("dv_inlinePatchMap");
    NSMutableDictionary *map = objc_getAssociatedObject(host, key);
    if (!map) {
        map = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(host, key, map, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return map;
}

static NSMutableDictionary<NSNumber *, NSValue *> *dv_dynamicInterposeSlotMap(void) {
    Class host = dv_hostClass();
    const void *key = (const void *)sel_registerName("dv_dynamicInterposeSlotMap");
    NSMutableDictionary *map = objc_getAssociatedObject(host, key);
    if (!map) {
        map = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(host, key, map, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return map;
}

#pragma mark - Hardware TPRO Unlock & Dynamic Interpose (for Live-Injected Processes)

struct dv_dyld_interpose_tuple {
    const void *replacement;
    const void *replacee;
};

static inline void dv_tproMakeWritable(void) {
#if defined(__arm64__)
    uint8_t mode = *(volatile uint8_t *)0xfffffc10cULL;
    if (mode == 2 || mode == 3) {
        uint64_t val = *(volatile uint64_t *)0xfffffc0d0ULL;
        __asm__ volatile("dmb ishst\n\tmsr S3_6_C15_C1_5, %0\n\tisb" :: "r"(val) : "memory");
    }
#endif
}

static inline void dv_tproMakeReadonly(void) {
#if defined(__arm64__)
    uint8_t mode = *(volatile uint8_t *)0xfffffc10cULL;
    if (mode == 2 || mode == 3) {
        uint64_t val = *(volatile uint64_t *)0xfffffc0d8ULL;
        __asm__ volatile("dmb ishst\n\tmsr S3_6_C15_C1_5, %0\n\tisb" :: "r"(val) : "memory");
    }
#endif
}

static inline uintptr_t dv_stripFnPtr(const void *ptr) {
    if (!ptr) return 0;
#if __has_feature(ptrauth_calls)
    return (uintptr_t)ptrauth_strip((void *)ptr, ptrauth_key_function_pointer) & 0x00007fffffffffffULL;
#else
    return (uintptr_t)ptr & 0x00007fffffffffffULL;
#endif
}

static inline void *dv_signAuthGotSlot(const void *replacement, void **slot) {
#if __has_feature(ptrauth_calls)
    void *raw = ptrauth_strip((void *)replacement, ptrauth_key_function_pointer);
    return ptrauth_sign_unauthenticated(raw, ptrauth_key_asia, slot);
#else
    (void)slot;
    return (void *)replacement;
#endif
}

static uint64_t dv_decodeAdrpAdd(const uint32_t *insns, uint32_t reg);

static void dv_writeGotSlot(void **slot, void *newSignedVal, BOOL isAuthGot) {
    if (!slot) return;
    NSMutableDictionary<NSNumber *, NSValue *> *slotMap = dv_dynamicInterposeSlotMap();
    NSNumber *slotKey = @((uintptr_t)slot);
    if (!slotMap[slotKey]) {
        slotMap[slotKey] = [NSValue valueWithPointer:*slot];
    }

    if (isAuthGot) {
        dv_tproMakeWritable();
        *slot = newSignedVal;
        dv_tproMakeReadonly();
    } else {
        vm_address_t page = ((vm_address_t)slot) & ~0x3fffULL;
        if (vm_protect(mach_task_self(), page, 0x4000, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) == KERN_SUCCESS) {
            *slot = newSignedVal;
        } else {
            dv_tproMakeWritable();
            *slot = newSignedVal;
            dv_tproMakeReadonly();
        }
    }
}

static void dv_dyld_dynamic_interpose(const struct mach_header *mh_raw, const struct dv_dyld_interpose_tuple array[], size_t count) {
    if (!mh_raw || !array || count == 0) return;
    const struct mach_header_64 *mh = (const struct mach_header_64 *)mh_raw;
    NSMutableDictionary<NSNumber *, NSValue *> *slotMap = dv_dynamicInterposeSlotMap();

    unsigned long text_sz = 0;
    const uint32_t *code = (const uint32_t *)getsectiondata(mh, "__TEXT", "__text", &text_sz);
    if (code && text_sz >= 4) {
        size_t n = text_sz / 4;
        for (size_t i = 0; i < n; i++) {
            uint32_t insn = code[i];
            if ((insn & 0x7c000000) != 0x14000000) continue;
            int32_t imm26 = (int32_t)(insn & 0x03ffffff);
            if (imm26 & 0x02000000) imm26 |= 0xfc000000;
            uintptr_t stub_addr = (uintptr_t)&code[i] + ((intptr_t)imm26 * 4);
            if (stub_addr < 0x180000000ULL || stub_addr >= 0x300000000ULL) continue;
            const uint32_t *stub = (const uint32_t *)stub_addr;
            if (stub[2] != 0xf9400230 || stub[3] != 0xd71f0a11) continue;
            uint64_t slot_addr = dv_decodeAdrpAdd(stub, 17);
            if (!slot_addr) continue;

            void **slot = (void **)slot_addr;
            NSValue *savedOrig = slotMap[@(slot_addr)];
            uintptr_t cur_raw = dv_stripFnPtr(savedOrig ? savedOrig.pointerValue : *slot);

            for (size_t k = 0; k < count; k++) {
                uintptr_t target_raw = dv_stripFnPtr(array[k].replacee);
                if (target_raw && cur_raw == target_raw) {
                    dv_writeGotSlot(slot, dv_signAuthGotSlot(array[k].replacement, slot), YES);
                    break;
                }
            }
        }
    }

    const char *segs[]  = { "__AUTH_CONST", "__DATA_CONST", "__DATA", "__AUTH" };
    const char *sects[] = { "__auth_got",   "__got",        "__la_symbol_ptr", "__nl_symbol_ptr" };
    for (size_t s = 0; s < 4; s++) {
        for (size_t t = 0; t < 4; t++) {
            unsigned long sz = 0;
            void **got = (void **)getsectiondata(mh, segs[s], sects[t], &sz);
            if (!got || sz < sizeof(void *)) continue;
            BOOL isAuth = (strcmp(sects[t], "__auth_got") == 0);
            size_t cnt = sz / sizeof(void *);
            for (size_t j = 0; j < cnt; j++) {
                void **slot = &got[j];
                NSValue *savedOrig = slotMap[@((uintptr_t)slot)];
                uintptr_t cur_raw = dv_stripFnPtr(savedOrig ? savedOrig.pointerValue : *slot);
                for (size_t k = 0; k < count; k++) {
                    uintptr_t target_raw = dv_stripFnPtr(array[k].replacee);
                    if (target_raw && cur_raw == target_raw) {
                        void *newVal = isAuth ? dv_signAuthGotSlot(array[k].replacement, slot) : (void *)array[k].replacement;
                        dv_writeGotSlot(slot, newVal, isAuth);
                        break;
                    }
                }
            }
        }
    }
}

static void dv_swizzleMethod(Class cls, SEL sel, IMP newImp, IMP *outOrig, BOOL isClassMethod) {
    if (!cls || !sel || !newImp) return;
    Method m = isClassMethod ? class_getClassMethod(cls, sel) : class_getInstanceMethod(cls, sel);
    if (!m) return;
    NSString *key = [NSString stringWithFormat:@"%c[%s %s]", isClassMethod ? '+' : '-', class_getName(cls), sel_getName(sel)];
    NSMutableDictionary *map = dv_originalIMPMap();
    NSValue *val = map[key];
    if (val) {
        if (outOrig) *outOrig = (IMP)val.pointerValue;
        method_setImplementation(m, newImp);
    } else {
        IMP orig = method_setImplementation(m, newImp);
        if (orig) {
            map[key] = [NSValue valueWithPointer:(const void *)orig];
            if (outOrig) *outOrig = orig;
        }
    }
}

static inline void dv_swizzle(Class cls, SEL sel, IMP newImp, IMP *outOrig) {
    dv_swizzleMethod(cls, sel, newImp, outOrig, NO);
}

static inline void dv_swizzleClassMethod(Class cls, SEL sel, IMP newImp, IMP *outOrig) {
    dv_swizzleMethod(cls, sel, newImp, outOrig, YES);
}

static void dv_restoreAllSwizzlesAndPatches(void) {
    NSMutableDictionary<NSString *, NSValue *> *map = dv_originalIMPMap();
    for (NSString *key in [map allKeys]) {
        IMP orig = (IMP)map[key].pointerValue;
        if (!orig) continue;
        BOOL isClassMethod = [key hasPrefix:@"+["];
        NSString *inner = [key substringWithRange:NSMakeRange(2, key.length - 3)];
        NSArray<NSString *> *parts = [inner componentsSeparatedByString:@" "];
        if (parts.count != 2) continue;
        Class cls = NSClassFromString(parts[0]);
        SEL sel = NSSelectorFromString(parts[1]);
        if (!cls || !sel) continue;
        Method m = isClassMethod ? class_getClassMethod(cls, sel) : class_getInstanceMethod(cls, sel);
        if (m) {
            method_setImplementation(m, orig);
        }
    }

    NSMutableDictionary<NSNumber *, NSData *> *patches = dv_inlinePatchMap();
    for (NSNumber *addrNum in [patches allKeys]) {
        uintptr_t addr = addrNum.unsignedLongLongValue;
        NSData *origBytes = patches[addrNum];
        if (!addr || origBytes.length == 0) continue;
        vm_address_t page = addr & ~0x3fffULL;
        if (vm_protect(mach_task_self(), page, 0x4000, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) == KERN_SUCCESS) {
            memcpy((void *)addr, origBytes.bytes, origBytes.length);
            vm_protect(mach_task_self(), page, 0x4000, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
            sys_icache_invalidate((void *)addr, origBytes.length);
        }
    }

    NSMutableDictionary<NSNumber *, NSValue *> *slots = dv_dynamicInterposeSlotMap();
    for (NSNumber *slotNum in [slots allKeys]) {
        void **slot = (void **)slotNum.unsignedLongLongValue;
        void *origSignedPtr = slots[slotNum].pointerValue;
        if (!slot || !origSignedPtr) continue;
        dv_tproMakeWritable();
        *slot = origSignedPtr;
        dv_tproMakeReadonly();
    }
}

#pragma mark - Classic menu enforcement

static uint64_t dv_decodeAdrpAdd(const uint32_t *insns, uint32_t reg) {
    uint32_t i0 = insns[0], i1 = insns[1];
    if ((i0 & 0x9f00001f) != (0x90000000 | reg)) return 0;
    if ((i1 & 0xff8003ff) != (0x91000000 | (reg << 5) | reg)) return 0;
    int64_t immlo = (i0 >> 29) & 0x3;
    int64_t immhi = (int64_t)((int32_t)(i0 << 8) >> 13);
    int64_t page_off = ((immhi << 2) | immlo) << 12;
    uint64_t pc_page = ((uint64_t)insns) & ~0xfffULL;
    return (uint64_t)((int64_t)pc_page + page_off) + ((i1 >> 10) & 0xfff);
}

static NSArray<NSValue *> *dv_appKitMenuGlassCachePointers(void) {
    Class host = dv_hostClass();
    const void *assocKey = (const void *)sel_registerName("dv_appKitMenuGlassCachePointers");
    NSArray<NSValue *> *cached = objc_getAssociatedObject(host, assocKey);
    if (cached) return cached;

    NSMutableSet<NSValue *> *ptrs = [NSMutableSet set];
    NSMutableSet<NSValue *> *flexPtrs = [NSMutableSet set];
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name || !strstr(name, "/AppKit.framework/Versions/C/AppKit")) continue;
        const struct mach_header_64 *mh = (const struct mach_header_64 *)_dyld_get_image_header(i);
        unsigned long text_sz = 0, cf_sz = 0;
        const uint32_t *code = (const uint32_t *)getsectiondata(mh, "__TEXT", "__text", &text_sz);
        const uint8_t *cf = (const uint8_t *)getsectiondata(mh, "__AUTH_CONST", "__cfstring", &cf_sz);
        if (!cf) cf = (const uint8_t *)getsectiondata(mh, "__DATA_CONST", "__cfstring", &cf_sz);
        if (!code || !cf) break;
        size_t n = text_sz / 4;
        for (size_t k = 0; k + 4 < n; k++) {
            uint64_t cf_addr = dv_decodeAdrpAdd(&code[k], 0);
            if (cf_addr < (uint64_t)cf || cf_addr + 32 > (uint64_t)cf + cf_sz) continue;
            uint64_t cache_addr = dv_decodeAdrpAdd(&code[k + 2], 2);
            if (!cache_addr) continue;
            NSString *s = (__bridge NSString *)(const void *)cf_addr;
            if ([s hasPrefix:@"NSGlassMenu"] || [s isEqualToString:@"NSMenuUseGlassWindowStyle"]) {
                [ptrs addObject:[NSValue valueWithPointer:(const void *)cache_addr]];
            } else if ([s isEqualToString:@"NSEnableFlexiglass"]) {
                [flexPtrs addObject:[NSValue valueWithPointer:(const void *)cache_addr]];
            }
        }
        break;
    }
    cached = [ptrs allObjects];
    objc_setAssociatedObject(host, assocKey, cached, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    const void *flexKey = (const void *)sel_registerName("dv_appKitFlexiglassCachePointers");
    objc_setAssociatedObject(host, flexKey, [flexPtrs allObjects], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return cached;
}

static void dv_setAppKitMenuGlassCache(uint8_t val) {
    for (NSValue *v in dv_appKitMenuGlassCachePointers()) {
        uint8_t *p = (uint8_t *)v.pointerValue;
        if (p) __atomic_store_n(p, val, __ATOMIC_RELEASE);
    }
    const void *flexKey = (const void *)sel_registerName("dv_appKitFlexiglassCachePointers");
    NSArray<NSValue *> *flexPtrs = objc_getAssociatedObject(dv_hostClass(), flexKey);
    uint8_t flexVal = (val == 2) ? 3 : 0; // 3 = true for NSEnableFlexiglass when Devitrify is active
    for (NSValue *v in flexPtrs) {
        uint8_t *p = (uint8_t *)v.pointerValue;
        if (p) __atomic_store_n(p, flexVal, __ATOMIC_RELEASE);
    }
}

static IMP s_orig_boolForKey = NULL;
static BOOL swizzled_boolForKey(NSUserDefaults *self, SEL _cmd, NSString *key) {
    if ([key hasPrefix:@"NSGlassMenu"] || [key isEqualToString:@"NSMenuUseGlassWindowStyle"]) {
        return NO;
    }
    return s_orig_boolForKey ? ((BOOL (*)(id, SEL, NSString *))s_orig_boolForKey)(self, _cmd, key) : NO;
}

static NSInteger swizzled_shadowOptions(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return 2;
}

static IMP s_orig_cgsDisplay_revealedMenuBarHeight = NULL;
static CGFloat swizzled_cgsDisplay_revealedMenuBarHeight(id self, SEL _cmd) {
    CGFloat h = s_orig_cgsDisplay_revealedMenuBarHeight
        ? ((CGFloat (*)(id, SEL))s_orig_cgsDisplay_revealedMenuBarHeight)(self, _cmd)
        : 0.0;
    SEL notchSel = NSSelectorFromString(@"notchFrame");
    if ([self respondsToSelector:notchSel]) {
        NSRect notch = ((NSRect (*)(id, SEL))objc_msgSend)(self, notchSel);
        if (notch.size.height > 0.0 && h > notch.size.height + 1.0) {
            return notch.size.height + 1.0;
        }
    }
    return h;
}

#define DV_DEFINE_SCREEN_MENUBAR_SWIZZLE(fn_name, orig_var) \
    static IMP orig_var = NULL; \
    static CGFloat fn_name(id self, SEL _cmd) { \
        CGFloat h = orig_var ? ((CGFloat (*)(id, SEL))orig_var)(self, _cmd) : 0.0; \
        SEL notchSel = NSSelectorFromString(@"_notchFrame"); \
        if (h > 0.0 && [self respondsToSelector:notchSel]) { \
            NSRect notch = ((NSRect (*)(id, SEL))objc_msgSend)(self, notchSel); \
            if (notch.size.height > 0.0 && h > notch.size.height + 1.0) { \
                return notch.size.height + 1.0; \
            } \
        } \
        return h; \
    }

DV_DEFINE_SCREEN_MENUBAR_SWIZZLE(swizzled_screen_layoutMenuBarHeight, s_orig_screen_layoutMenuBarHeight)
DV_DEFINE_SCREEN_MENUBAR_SWIZZLE(swizzled_screen_revealedMenuBarHeight, s_orig_screen_revealedMenuBarHeight)
DV_DEFINE_SCREEN_MENUBAR_SWIZZLE(swizzled_screen_restingMenuBarHeight, s_orig_screen_restingMenuBarHeight)
DV_DEFINE_SCREEN_MENUBAR_SWIZZLE(swizzled_screen_layoutForcingRevealedMenuBarHeight, s_orig_screen_layoutForcingRevealedMenuBarHeight)

static void dv_installClassicMenuEnforcement(void) {
    dv_swizzle([NSUserDefaults class], @selector(boolForKey:), (IMP)swizzled_boolForKey, &s_orig_boolForKey);

    Class popupCls = NSClassFromString(@"NSPopupMenuWindow");
    if (popupCls) {
        dv_swizzle(popupCls, @selector(shadowOptions), (IMP)swizzled_shadowOptions, NULL);
    }

    Class cgsDisplayCls = NSClassFromString(@"NSCGSDisplay");
    if (cgsDisplayCls) {
        dv_swizzle(cgsDisplayCls, NSSelectorFromString(@"revealedMenuBarHeight"),
                   (IMP)swizzled_cgsDisplay_revealedMenuBarHeight, &s_orig_cgsDisplay_revealedMenuBarHeight);
    }

    Class screenCls = [NSScreen class];
    if (screenCls) {
        dv_swizzle(screenCls, NSSelectorFromString(@"_layoutMenuBarHeight"),
                   (IMP)swizzled_screen_layoutMenuBarHeight, &s_orig_screen_layoutMenuBarHeight);
        dv_swizzle(screenCls, NSSelectorFromString(@"_revealedMenuBarHeight"),
                   (IMP)swizzled_screen_revealedMenuBarHeight, &s_orig_screen_revealedMenuBarHeight);
        dv_swizzle(screenCls, NSSelectorFromString(@"_restingMenuBarHeight"),
                   (IMP)swizzled_screen_restingMenuBarHeight, &s_orig_screen_restingMenuBarHeight);
        dv_swizzle(screenCls, NSSelectorFromString(@"_layoutForcingRevealedMenuBarHeight"),
                   (IMP)swizzled_screen_layoutForcingRevealedMenuBarHeight, &s_orig_screen_layoutForcingRevealedMenuBarHeight);
    }

    [[NSUserDefaults standardUserDefaults] registerDefaults:@{
        @"NSGlassMenusEnabled": @NO,
        @"NSGlassMenuLayoutEnabled": @NO,
        @"NSMenuUseGlassWindowStyle": @NO,
        @"NSGlassMenusUsePlainBorderView": @NO,
        @"NSGlassMenuContentAboveGlass": @NO,
    }];
    dv_setAppKitMenuGlassCache(2);
}

#pragma mark - Solarium ON: glass filters -> plain Gaussian blur

static double dv_getGlassBlurRadius(void) {
    NSString *conf = [NSString stringWithContentsOfFile:DEVITRIFY_BLUR_PATH
                                               encoding:NSUTF8StringEncoding
                                                  error:nil];
    if (conf.length > 0) {
        double v = [conf doubleValue];
        if (v >= 0.0) return v;
    }
    const char *env = getenv("DEVITRIFY_BLUR_RADIUS");
    if (env) {
        double v = atof(env);
        if (v >= 0.0) return v;
    }
    return 25.0;
}

static inline BOOL dv_isGlassFilterType(NSString *type) {
    return [type isEqualToString:@"glassBackground"] || [type isEqualToString:@"glassForeground"];
}

static NSSet<NSString *> *dv_refractionKeys(void) {
    static NSSet<NSString *> *s_keys = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_keys = [NSSet setWithArray:@[
            @"inputInnerRefractionAmount",
            @"inputInnerRefractionHeight",
            @"inputOuterRefractionAmount",
            @"inputOuterRefractionHeight",
            @"inputRefractionOpacity",
            @"inputBleedAmount",
            @"inputBleedHeight",
            @"inputBleedOpacity",
            @"inputAberrationAmount",
            @"inputAberrationHeight",
            @"inputKeyFillHighlightAmount",
            @"inputKeyFillHighlightHeight",
        ]];
    });
    return s_keys;
}

static inline BOOL dv_isRefractionKey(NSString *key) {
    return key != nil && [dv_refractionKeys() containsObject:key];
}

static IMP s_orig_sdf_effect_setKeyColor = NULL;
static IMP s_orig_sdf_effect_setFillColor = NULL;

static void swizzled_sdf_effect_setKeyColor(id self, SEL _cmd, CGColorRef color) {
    (void)color;
    if (s_orig_sdf_effect_setKeyColor) {
        ((void (*)(id, SEL, CGColorRef))s_orig_sdf_effect_setKeyColor)(self, _cmd, CGColorGetConstantColor(kCGColorClear));
    }
}

static void swizzled_sdf_effect_setFillColor(id self, SEL _cmd, CGColorRef color) {
    (void)color;
    if (s_orig_sdf_effect_setFillColor) {
        ((void (*)(id, SEL, CGColorRef))s_orig_sdf_effect_setFillColor)(self, _cmd, CGColorGetConstantColor(kCGColorClear));
    }
}

static void dv_neutralizeGlassFilter(id filter) {
    @try {
        NSString *type = [filter valueForKey:@"type"];
        if (!dv_isGlassFilterType(type)) return;
        for (NSString *k in dv_refractionKeys()) {
            [filter setValue:@0 forKey:k];
        }
        if ([type isEqualToString:@"glassBackground"]) {
            [filter setValue:@(dv_getGlassBlurRadius()) forKey:@"inputBlurRadius"];
        }
    } @catch (id ex) {}
}

static IMP s_orig_filterWithType = NULL;
static id swizzled_filterWithType(id self, SEL _cmd, NSString *type) {
    id f = s_orig_filterWithType ? ((id (*)(id, SEL, NSString *))s_orig_filterWithType)(self, _cmd, type) : nil;
    if (f && dv_isGlassFilterType(type)) dv_neutralizeGlassFilter(f);
    return f;
}

static IMP s_orig_cafilter_setValueForKey = NULL;
static void swizzled_cafilter_setValueForKey(id self, SEL _cmd, id value, NSString *key) {
    NSString *type = nil;
    @try { type = [self valueForKey:@"type"]; } @catch (id ex) {}
    if (dv_isGlassFilterType(type)) {
        if (dv_isRefractionKey(key)) {
            value = @0;
        } else if ([type isEqualToString:@"glassBackground"] && [key isEqualToString:@"inputBlurRadius"]) {
            value = @(dv_getGlassBlurRadius());
        }
    }
    if (s_orig_cafilter_setValueForKey) {
        ((void (*)(id, SEL, id, NSString *))s_orig_cafilter_setValueForKey)(self, _cmd, value, key);
    }
}

static IMP s_orig_setFilters = NULL;
static void swizzled_setFilters(id self, SEL _cmd, NSArray *filters) {
    for (id f in filters) dv_neutralizeGlassFilter(f);
    if (s_orig_setFilters) ((void (*)(id, SEL, NSArray *))s_orig_setFilters)(self, _cmd, filters);
}

static IMP s_orig_setValueForKeyPath = NULL;
static void swizzled_setValueForKeyPath(id self, SEL _cmd, id value, NSString *keyPath) {
    if ([keyPath hasPrefix:@"filters.glass"]) {
        NSString *key = [[keyPath componentsSeparatedByString:@"."] lastObject];
        if (dv_isRefractionKey(key)) {
            value = @0;
        } else if ([key isEqualToString:@"inputBlurRadius"]) {
            if ([value respondsToSelector:@selector(doubleValue)] && [value doubleValue] > 0.0) {
                value = @(dv_getGlassBlurRadius());
            }
        }
    }
    if (s_orig_setValueForKeyPath) {
        ((void (*)(id, SEL, id, NSString *))s_orig_setValueForKeyPath)(self, _cmd, value, keyPath);
    }
}

static void dv_installGlassFilterNeutralization(void) {
    Class filterCls = NSClassFromString(@"CAFilter");
    if (filterCls) {
        dv_swizzleClassMethod(filterCls, @selector(filterWithType:), (IMP)swizzled_filterWithType, &s_orig_filterWithType);
        dv_swizzle(filterCls, @selector(setValue:forKey:), (IMP)swizzled_cafilter_setValueForKey, &s_orig_cafilter_setValueForKey);
    }
    Class sdfEffCls = NSClassFromString(@"CASDFKeyFillHighlightEffect");
    if (sdfEffCls) {
        dv_swizzle(sdfEffCls, NSSelectorFromString(@"setKeyColor:"), (IMP)swizzled_sdf_effect_setKeyColor, &s_orig_sdf_effect_setKeyColor);
        dv_swizzle(sdfEffCls, NSSelectorFromString(@"setFillColor:"), (IMP)swizzled_sdf_effect_setFillColor, &s_orig_sdf_effect_setFillColor);
    }
    dv_swizzle([CALayer class], @selector(setFilters:), (IMP)swizzled_setFilters, &s_orig_setFilters);
    dv_swizzle([CALayer class], @selector(setValue:forKeyPath:), (IMP)swizzled_setValueForKeyPath, &s_orig_setValueForKeyPath);
}

#pragma mark - Liquid Glass apps: classic AppKit controls

extern bool _os_feature_enabled_impl(const char *domain, const char *feature);
typedef struct { uint32_t platform; uint32_t version; } dv_build_version;
extern bool dyld_program_sdk_at_least(dv_build_version version);

static volatile int s_core_in_solarium_compute_values = 0;

static bool dv_core_caller_is_swift_feature_flags(const void *address) {
    Dl_info info;
    if (!dladdr(address, &info) || !info.dli_fname) return false;
    return strstr(info.dli_fname, "/SwiftUICore.framework/") != NULL ||
           strstr(info.dli_fname, "FeatureFlags") != NULL;
}

static bool dv_core_feature_enabled(const char *domain, const char *feature) {
    if (s_core_hooks_disabled) {
        return _os_feature_enabled_impl(domain, feature);
    }
    if (domain && feature) {
        if (!strcmp(domain, "SwiftUI") && !strcmp(feature, "flexiGlassMacOS")) return true;
        if (!strcmp(domain, "SwiftUI") && !strcmp(feature, "Solarium")) {
            if (dv_core_caller_is_swift_feature_flags(__builtin_return_address(0))) {
                s_core_in_solarium_compute_values = 1;
                return true;
            }
        }
    }
    return _os_feature_enabled_impl(domain, feature);
}

static bool dv_core_version_after_compat(dv_build_version version) {
    uint32_t limit = (version.platform == 0xFFFFFFFFU) ? 0x07E8FFFFU : 0x000F0000U;
    return version.version > limit;
}

static bool dv_core_caller_draws_interface(const void *address) {
    Dl_info info;
    if (!dladdr(address, &info) || !info.dli_fname) return false;
    return strstr(info.dli_fname, "/AppKit.framework/") || strstr(info.dli_fname, "/SwiftUI.framework/") ||
           strstr(info.dli_fname, "/SwiftUICore.framework/");
}

static bool dv_core_program_sdk_at_least(dv_build_version version) {
    if (s_core_hooks_disabled) {
        return dyld_program_sdk_at_least(version);
    }
    if (s_core_in_solarium_compute_values && dv_core_version_after_compat(version) &&
        dv_core_caller_draws_interface(__builtin_return_address(0))) {
        s_core_in_solarium_compute_values = 0;
        return false;
    }
    return dyld_program_sdk_at_least(version);
}

static void dv_installDynamicFeatureInterposeIfNeeded(void) {
    if (dlsym(RTLD_DEFAULT, "devitrify_set_system_disabled") != NULL) {
        return; // Already interposed at launch by libDevitrify.dylib
    }
    struct dv_dyld_interpose_tuple tuples[] = {
        { (const void *)dv_core_feature_enabled, (const void *)_os_feature_enabled_impl },
        { (const void *)dv_core_program_sdk_at_least, (const void *)dyld_program_sdk_at_least },
    };
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        if (strstr(name, "/AppKit.framework/") ||
            strstr(name, "/SwiftUICore.framework/") ||
            strstr(name, "/SwiftUI.framework/") ||
            strstr(name, "/UIKitCore.framework/") ||
            strstr(name, "FeatureFlags")) {
            dv_dyld_dynamic_interpose(_dyld_get_image_header(i), tuples, 2);
        }
    }
}

static void dv_syncAppKitSolariumFuncCache(const char *symName, uint8_t val) {
    void *sym = dlsym(RTLD_DEFAULT, symName);
    uintptr_t addr = dv_stripFnPtr(sym);
    if (!addr) return;
    const uint32_t *insns = (const uint32_t *)addr;
    // Expect at +16: adrp x8, page; ldrb w0, [x8, #imm12]
    uint32_t i0 = insns[4], i1 = insns[5];
    if ((i0 & 0x9f00001f) != (0x90000000 | 8)) return;
    if ((i1 & 0xffc003e0) != (0x39400000 | (8 << 5))) return;
    int64_t immlo = (i0 >> 29) & 0x3;
    int64_t immhi = (int64_t)((int32_t)(i0 << 8) >> 13);
    int64_t page_off = ((immhi << 2) | immlo) << 12;
    uint64_t pc_page = ((uint64_t)&insns[4]) & ~0xfffULL;
    uint8_t *cache_byte = (uint8_t *)((uint64_t)((int64_t)pc_page + page_off) + ((i1 >> 10) & 0xfff));
    if (cache_byte) {
        __atomic_store_n(cache_byte, val, __ATOMIC_RELEASE);
    }
}

static void dv_syncSolariumInMemoryCaches(BOOL hooksActive) {
    if (hooksActive) {
        dv_syncAppKitSolariumFuncCache("NSSolariumEnabled", 0);
        dv_syncAppKitSolariumFuncCache("NSSolariumEnabledIgnoringCompatibility", 0);
    }

    void *h = dlopen("/System/Library/Frameworks/SwiftUICore.framework/Versions/A/SwiftUICore", RTLD_NOLOAD | RTLD_LAZY);
    if (!h) return;
    void *eval_sym = dlsym(h, "$s7SwiftUI8SolariumV8evaluate6inputsSbAA12_GraphInputsV_tFZ");
    uintptr_t eval_addr = dv_stripFnPtr(eval_sym);
    if (!eval_addr) return;

    uint32_t b_insn = *(uint32_t *)eval_addr;
    if ((b_insn & 0xfc000000) != 0x14000000) return;
    int32_t imm26 = (int32_t)(b_insn & 0x03ffffff);
    if (imm26 & 0x02000000) imm26 |= 0xfc000000;
    uintptr_t target = eval_addr + ((intptr_t)imm26 * 4);

    uint64_t cached_values_addr = dv_decodeAdrpAdd((const uint32_t *)(target + 0x68), 22);
    uint64_t once_token_addr = dv_decodeAdrpAdd((const uint32_t *)(target + 0xec), 0);
    if (!cached_values_addr || !once_token_addr) return;

    intptr_t once_val = *(volatile intptr_t *)once_token_addr;
    if (once_val == -1) {
        uintptr_t storage = *(uintptr_t *)(cached_values_addr + 8);
        if (storage > 0x100000000ULL) {
            uint64_t count = *(uint64_t *)(storage + 0x10);
            for (uint64_t i = 0; i < count && i < 16; i++) {
                uint8_t *entry = (uint8_t *)(storage + 0x20 + i * 16);
                if (hooksActive) {
                    entry[1] = 1; // .compatibility
                    *(uint64_t *)(entry + 8) = 5;
                }
            }
        }
    }
}

static BOOL dv_returnNo(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return NO;
}

static IMP s_orig_partitionAdapter_dividerWidth = NULL;
static CGFloat swizzled_partitionAdapter_dividerWidth(id self, SEL _cmd) {
    SEL svSel = NSSelectorFromString(@"splitView");
    SEL idxSel = NSSelectorFromString(@"splitViewDividerIndex");
    SEL thickSel = NSSelectorFromString(@"_dividerThicknessForDividerAtIndex:");
    if ([self respondsToSelector:svSel] && [self respondsToSelector:idxSel]) {
        id sv = ((id (*)(id, SEL))objc_msgSend)(self, svSel);
        NSInteger idx = ((NSInteger (*)(id, SEL))objc_msgSend)(self, idxSel);
        if (sv && [sv respondsToSelector:thickSel]) {
            return ((CGFloat (*)(id, SEL, NSInteger))objc_msgSend)(sv, thickSel, idx);
        }
    }
    return s_orig_partitionAdapter_dividerWidth
        ? ((CGFloat (*)(id, SEL))s_orig_partitionAdapter_dividerWidth)(self, _cmd)
        : 1.0;
}

static void dv_installSplitViewTitlebarAlignmentFix(void) {
    Class adapterCls = NSClassFromString(@"_NSSplitViewPartitionAdapter");
    if (adapterCls) {
        dv_swizzle(adapterCls, NSSelectorFromString(@"dividerWidth"), (IMP)swizzled_partitionAdapter_dividerWidth, &s_orig_partitionAdapter_dividerWidth);
    }
}

static IMP s_orig_splitvc_implClass = NULL;
static Class swizzled_splitvc_implClass(id self, SEL _cmd, id splitVC) {
    Class cls = s_orig_splitvc_implClass
        ? ((Class (*)(id, SEL, id))s_orig_splitvc_implClass)(self, _cmd, splitVC)
        : nil;
    if (cls && [NSStringFromClass(cls) isEqualToString:@"UISplitViewControllerPanelImpl"]) {
        Class adaptiveCls = NSClassFromString(@"_UISplitViewControllerAdaptiveImpl");
        if (adaptiveCls) return adaptiveCls;
    }
    return cls;
}

static void dv_installSwiftUISolariumCompatibilityAllowedFix(void) {
    // Only Spotlight (SpotlightUIInternal.framework) uses StaticIf<Solarium, GlassEffect, EmptyView>
    // with no classic fallback. In all other apps (such as Apple Music), AllowedInCompatibilityKey
    // must remain false in .compatibility mode so SwiftUI controls and toolbars stay classic.
    if (!dlopen("/System/Library/PrivateFrameworks/SpotlightUIInternal.framework/Versions/A/SpotlightUIInternal", RTLD_NOLOAD | RTLD_LAZY)) {
        return;
    }
    void *h = dlopen("/System/Library/Frameworks/SwiftUICore.framework/Versions/A/SwiftUICore", RTLD_NOLOAD | RTLD_LAZY);
    if (!h) return;
    void *eval_sym = dlsym(h, "$s7SwiftUI8SolariumV8evaluate6inputsSbAA12_GraphInputsV_tFZ");
    if (!eval_sym) return;
#if __has_feature(ptrauth_calls)
    uintptr_t eval_addr = (uintptr_t)ptrauth_strip(eval_sym, ptrauth_key_function_pointer);
#else
    uintptr_t eval_addr = (uintptr_t)eval_sym & 0x00007fffffffffffULL;
#endif
    eval_addr &= 0x00007fffffffffffULL;

    uint32_t b_insn = *(uint32_t *)eval_addr;
    if ((b_insn & 0xfc000000) != 0x14000000) return; // must be unconditional branch `b`
    int32_t imm26 = (int32_t)(b_insn & 0x03ffffff);
    if (imm26 & 0x02000000) imm26 |= 0xfc000000;
    uintptr_t target = eval_addr + ((intptr_t)imm26 * 4);

    // In specialized evaluate, instruction at target + 0x0c8 is `b <AllowedInCompatibilityKey getter>`
    uint32_t b_to_getter = *(uint32_t *)(target + 0x0c8);
    if ((b_to_getter & 0xfc000000) != 0x14000000) return;
    int32_t imm_getter = (int32_t)(b_to_getter & 0x03ffffff);
    if (imm_getter & 0x02000000) imm_getter |= 0xfc000000;
    uintptr_t getter_addr = (target + 0x0c8) + ((intptr_t)imm_getter * 4);

    NSMutableDictionary<NSNumber *, NSData *> *patches = dv_inlinePatchMap();
    NSNumber *key = @(getter_addr);
    if (!patches[key]) {
        patches[key] = [NSData dataWithBytes:(const void *)getter_addr length:8];
    }

    vm_address_t page = getter_addr & ~0x3fffULL;
    kern_return_t kr = vm_protect(mach_task_self(), page, 0x4000, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr == KERN_SUCCESS) {
        *(uint32_t *)getter_addr = 0x52800020;         // mov w0, #1
        *(uint32_t *)(getter_addr + 4) = 0xd65f03c0;     // ret
        vm_protect(mach_task_self(), page, 0x4000, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
        sys_icache_invalidate((void *)getter_addr, 8);
    }
}

static void dv_installClassicAppKit(void) {
    dv_installDynamicFeatureInterposeIfNeeded();
    dv_syncSolariumInMemoryCaches(YES);
    dv_installSwiftUISolariumCompatibilityAllowedFix();
    Class cls = NSClassFromString(@"_NSSwiftUICoreFeatureFlags");
    if (cls) {
        dv_swizzleClassMethod(cls, @selector(isSolariumEnabled), (IMP)dv_returnNo, NULL);
        dv_swizzleClassMethod(cls, NSSelectorFromString(@"isSolariumEnabledIgnoringCompatibility"), (IMP)dv_returnNo, NULL);
    }
    Class uikitFeaturesCls = NSClassFromString(@"_UIKitFeatures");
    if (uikitFeaturesCls) {
        dv_swizzleClassMethod(uikitFeaturesCls, NSSelectorFromString(@"uncachedSolariumEnabledForCurrentDeviceIdiom"), (IMP)dv_returnNo, NULL);
    }
    Class splitImplProviderCls = NSClassFromString(@"UISplitViewControllerDefaultImplProvider");
    if (splitImplProviderCls) {
        dv_swizzle(splitImplProviderCls, NSSelectorFromString(@"implClassForSplitViewController:"), (IMP)swizzled_splitvc_implClass, &s_orig_splitvc_implClass);
    }
}

#pragma mark - Live State Refresh on Hot-Reload

static void dv_refreshLayersRecursively(CALayer *layer, BOOL hooksActive) {
    if (!layer) return;
    if (hooksActive && [NSStringFromClass([layer class]) isEqualToString:@"CASDFLayer"]) {
        @try {
            id eff = [layer valueForKey:@"effect"];
            if (eff && [NSStringFromClass([eff class]) isEqualToString:@"CASDFKeyFillHighlightEffect"]) {
                [eff setValue:(__bridge id)CGColorGetConstantColor(kCGColorClear) forKey:@"keyColor"];
                [eff setValue:(__bridge id)CGColorGetConstantColor(kCGColorClear) forKey:@"fillColor"];
            }
        } @catch (id ex) {}
    }
    if (layer.filters.count > 0) {
        if (hooksActive) {
            for (id f in layer.filters) dv_neutralizeGlassFilter(f);
        }
        layer.filters = [layer.filters copy];
    }
    for (CALayer *sub in layer.sublayers) {
        dv_refreshLayersRecursively(sub, hooksActive);
    }
}

static void dv_refreshSubviewsRecursively(NSView *v, BOOL hooksActive) {
    if (!v) return;
    if (v.layer) {
        dv_refreshLayersRecursively(v.layer, hooksActive);
    }
    if ([NSStringFromClass([v class]) isEqualToString:@"NSTitlebarContainerView"]) {
        SEL wscSel = NSSelectorFromString(@"windowSectionController");
        SEL ccsSel = NSSelectorFromString(@"contentControllers");
        SEL noteSel = NSSelectorFromString(@"_noteSectionStateNeedsUpdate");
        SEL updSel = NSSelectorFromString(@"updateSectionStateIfNeeded");
        SEL scUpdSel = NSSelectorFromString(@"sectionControllerNeedsUpdate:");
        if ([v respondsToSelector:wscSel]) {
            id sc = ((id (*)(id, SEL))objc_msgSend)(v, wscSel);
            if (sc && [sc respondsToSelector:ccsSel]) {
                NSArray *ccs = ((NSArray *(*)(id, SEL))objc_msgSend)(sc, ccsSel);
                for (id cc in ccs) {
                    if ([cc respondsToSelector:noteSel]) ((void (*)(id, SEL))objc_msgSend)(cc, noteSel);
                    if ([cc respondsToSelector:updSel]) ((void (*)(id, SEL))objc_msgSend)(cc, updSel);
                }
                if ([v respondsToSelector:scUpdSel]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(v, scUpdSel, sc);
                }
            }
        }
    }
    [v setNeedsLayout:YES];
    [v setNeedsDisplay:YES];
    for (NSView *sub in v.subviews) {
        dv_refreshSubviewsRecursively(sub, hooksActive);
    }
}

static void dv_refreshLiveWindows(BOOL hooksActive) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            dv_refreshLiveWindows(hooksActive);
        });
        return;
    }
    NSMenu *help = NSApp.helpMenu;
    if (help) {
        NSInteger idx = [help indexOfItemWithTitle:@"Keep Liquid Glass"];
        if (idx >= 0) {
            [help removeItemAtIndex:idx];
            if (idx > 0 && idx == help.numberOfItems && [help itemAtIndex:idx - 1].isSeparatorItem) {
                [help removeItemAtIndex:idx - 1];
            }
        }
    }
    for (NSWindow *win in [NSApp windows]) {
        NSView *root = win.contentView.superview ?: win.contentView;
        dv_refreshSubviewsRecursively(root, hooksActive);
        if ([win respondsToSelector:NSSelectorFromString(@"_glassEffectChildWindow")]) {
            NSWindow *child = ((id (*)(id, SEL))objc_msgSend)(win, NSSelectorFromString(@"_glassEffectChildWindow"));
            if (child) {
                NSView *childBorder = [child valueForKey:@"_borderView"];
                dv_refreshSubviewsRecursively(childBorder, hooksActive);
            }
        }
    }
    [NSNotificationCenter.defaultCenter postNotificationName:NSApplicationDidChangeScreenParametersNotification
                                                      object:NSApp];
}

#pragma mark - Fault-Tolerant Execution Guard & Hot-Reload Listener

static sigjmp_buf s_core_jmp_buf;
static volatile sig_atomic_t s_core_guard_active = 0;

static void dv_coreSignalHandler(int sig) {
    if (s_core_guard_active) {
        s_core_guard_active = 0;
        siglongjmp(s_core_jmp_buf, sig);
    }
}

static BOOL dv_runFaultTolerant(void (^block)(void)) {
    struct sigaction sa_new, sa_old_segv, sa_old_bus, sa_old_ill, sa_old_trap, sa_old_abrt;
    memset(&sa_new, 0, sizeof(sa_new));
    sa_new.sa_handler = dv_coreSignalHandler;
    sigemptyset(&sa_new.sa_mask);
    sa_new.sa_flags = 0;

    sigaction(SIGSEGV, &sa_new, &sa_old_segv);
    sigaction(SIGBUS,  &sa_new, &sa_old_bus);
    sigaction(SIGILL,  &sa_new, &sa_old_ill);
    sigaction(SIGTRAP, &sa_new, &sa_old_trap);
    sigaction(SIGABRT, &sa_new, &sa_old_abrt);

    BOOL ok = YES;
    s_core_guard_active = 1;
    int caught_sig = sigsetjmp(s_core_jmp_buf, 1);
    if (caught_sig == 0) {
        @try {
            block();
        } @catch (id ex) {
            ok = NO;
            dv_markProcessBypassedOnDisk(0);
        }
    } else {
        ok = NO;
        dv_markProcessBypassedOnDisk(caught_sig);
    }
    s_core_guard_active = 0;

    sigaction(SIGSEGV, &sa_old_segv, NULL);
    sigaction(SIGBUS,  &sa_old_bus,  NULL);
    sigaction(SIGILL,  &sa_old_ill,  NULL);
    sigaction(SIGTRAP, &sa_old_trap, NULL);
    sigaction(SIGABRT, &sa_old_abrt, NULL);

    if (!ok) {
        dv_setLoaderSystemDisabled(YES);
        dv_restoreAllSwizzlesAndPatches();
    }
    return ok;
}

static void dv_performHotReload(void) {
    NSString *currentPath = [NSString stringWithContentsOfFile:DEVITRIFY_CURRENT_PATH
                                                      encoding:NSUTF8StringEncoding
                                                         error:nil];
    if (currentPath) {
        currentPath = [currentPath stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    if (!currentPath || currentPath.length == 0) {
        currentPath = DEVITRIFY_CORE_PATH;
    }
    dv_runFaultTolerant(^{
        dlopen(currentPath.UTF8String, RTLD_NOW | RTLD_LOCAL);
    });
}

#pragma mark - macOS 26 Icon Jail Neutralization

static BOOL swizzled_iconStack_returnNo(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return NO;
}

static IMP s_orig_cgimage_with_data = NULL;
static CGImageRef swizzled_CGImageWithData_iconIndexInfo(id self, SEL _cmd, NSData *data, void *iconIndexInfo) {
    if (data.length >= 8) {
        const uint8_t *bytes = (const uint8_t *)data.bytes;
        // If data is modern compressed image format (PNG, JPEG 2000, JPEG, etc.),
        // decode via ImageIO rather than letting legacy QuickDraw table treat compressed bytes as raw pixels.
        if ((bytes[0] == 0x89 && bytes[1] == 'P' && bytes[2] == 'N' && bytes[3] == 'G') ||
            (bytes[0] == 0x00 && bytes[1] == 0x00 && bytes[2] == 0x00 && bytes[3] == 0x0c) ||
            (bytes[0] == 0xff && bytes[1] == 0x4f) ||
            (bytes[0] == 0xff && bytes[1] == 0xd8)) {
            CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
            if (src) {
                CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, NULL);
                CFRelease(src);
                if (img) return img;
            }
        }
    }
    if (s_orig_cgimage_with_data) {
        return ((CGImageRef(*)(id, SEL, NSData *, void *))s_orig_cgimage_with_data)(self, _cmd, data, iconIndexInfo);
    }
    return NULL;
}

static IMP s_orig_resourceWithBundleURL = NULL;
static id swizzled_resourceWithBundleURL(id self, SEL _cmd, NSURL *url, NSDictionary *dict, NSUInteger options) {
    // Clear bit 8 (0x8) which forces iconStackResourcesAllowed wrapping
    options &= ~(NSUInteger)8;
    if (s_orig_resourceWithBundleURL) {
        return ((id(*)(id, SEL, NSURL *, NSDictionary *, NSUInteger))s_orig_resourceWithBundleURL)(self, _cmd, url, dict, options);
    }
    return nil;
}

static IMP s_orig_assetCatalogResource = NULL;
static id swizzled_assetCatalogResource(id self, SEL _cmd, NSURL *url, NSString *name, NSUInteger platform, BOOL isAppLike, NSError **error) {
    // platform == 1 is macOS AppKit / standard app; disabling isAppLike prevents ISMultisizedAppAssetCatalogResource jail wrapping
    if (platform == 1) {
        isAppLike = NO;
    }
    if (s_orig_assetCatalogResource) {
        return ((id(*)(id, SEL, NSURL *, NSString *, NSUInteger, BOOL, NSError **))s_orig_assetCatalogResource)(self, _cmd, url, name, platform, isAppLike, error);
    }
    return nil;
}

static IMP s_orig_composite_imageForSize_scale = NULL;
static id swizzled_composite_imageForSize_scale(id self, SEL _cmd, CGSize size, CGFloat scale) {
    SEL wrapSel = sel_registerName("wrappedResource");
    if ([self respondsToSelector:wrapSel]) {
        id wrapped = ((id(*)(id, SEL))objc_msgSend)(self, wrapSel);
        if (wrapped && [wrapped respondsToSelector:_cmd]) {
            return ((id(*)(id, SEL, CGSize, CGFloat))objc_msgSend)(wrapped, _cmd, size, scale);
        }
    }
    if (s_orig_composite_imageForSize_scale) {
        return ((id(*)(id, SEL, CGSize, CGFloat))s_orig_composite_imageForSize_scale)(self, _cmd, size, scale);
    }
    return nil;
}

static IMP s_orig_multisizedApp_imageForSize_scale = NULL;
static id swizzled_multisizedApp_imageForSize_scale(id self, SEL _cmd, CGSize size, CGFloat scale) {
    SEL lookupSel = sel_registerName("_lookupForSize:scale:");
    if ([self respondsToSelector:lookupSel]) {
        id cuiImg = ((id(*)(id, SEL, CGSize, CGFloat))objc_msgSend)(self, lookupSel, size, scale);
        if (cuiImg && [cuiImg respondsToSelector:sel_registerName("image")]) {
            CGImageRef cgImg = ((CGImageRef(*)(id, SEL))objc_msgSend)(cuiImg, sel_registerName("image"));
            CGFloat imgScale = scale;
            if ([cuiImg respondsToSelector:sel_registerName("scale")]) {
                CGFloat s = ((CGFloat(*)(id, SEL))objc_msgSend)(cuiImg, sel_registerName("scale"));
                if (s > 0.0) imgScale = s;
            }
            if (cgImg) {
                Class isImgClass = objc_getClass("ISImage");
                if (isImgClass) {
                    id isImg = ((id(*)(id, SEL))objc_msgSend)(isImgClass, sel_registerName("alloc"));
                    return ((id(*)(id, SEL, CGImageRef, CGFloat))objc_msgSend)(isImg, sel_registerName("initWithCGImage:scale:"), cgImg, imgScale);
                }
            }
        }
    }
    if (s_orig_multisizedApp_imageForSize_scale) {
        return ((id(*)(id, SEL, CGSize, CGFloat))s_orig_multisizedApp_imageForSize_scale)(self, _cmd, size, scale);
    }
    return nil;
}

static void dv_installIconJailNeutralization(void) {
    if (objc_getClass("ISRecordResourceProvider") == Nil) {
        dlopen("/System/Library/PrivateFrameworks/IconServices.framework/Versions/A/IconServices", RTLD_LAZY | RTLD_GLOBAL);
    }
    if (objc_getClass("IFDefaults") == Nil) {
        dlopen("/System/Library/PrivateFrameworks/IconFoundation.framework/Versions/A/IconFoundation", RTLD_LAZY | RTLD_GLOBAL);
    }

    Class clsDefaults = objc_getClass("ISDefaults");
    if (clsDefaults) {
        dv_swizzle(clsDefaults, sel_registerName("iconStackAppIconsAllowed"), (IMP)swizzled_iconStack_returnNo, NULL);
    }

    Class clsIFDefaults = objc_getClass("IFDefaults");
    if (clsIFDefaults) {
        dv_swizzle(clsIFDefaults, sel_registerName("iconStackAppIconsAllowed"), (IMP)swizzled_iconStack_returnNo, NULL);
    }

    Class clsRecordProvider = objc_getClass("ISRecordResourceProvider");
    if (clsRecordProvider) {
        dv_swizzle(clsRecordProvider, sel_registerName("iconStackResourcesAllowed"), (IMP)swizzled_iconStack_returnNo, NULL);
    }

    Class clsResourceProvider = objc_getClass("ISResourceProvider");
    if (clsResourceProvider) {
        dv_swizzleClassMethod(clsResourceProvider, sel_registerName("resourceWithBundleURL:iconDictionary:options:"), (IMP)swizzled_resourceWithBundleURL, &s_orig_resourceWithBundleURL);
    }

    Class clsAssetCatalog = objc_getClass("ISAssetCatalogResource");
    if (clsAssetCatalog) {
        dv_swizzleClassMethod(clsAssetCatalog, sel_registerName("assetCatalogResourceWithURL:imageName:platform:isAppLike:error:"), (IMP)swizzled_assetCatalogResource, &s_orig_assetCatalogResource);
    }

    Class clsComposite = objc_getClass("ISIconStackCompositeResource");
    if (clsComposite) {
        dv_swizzle(clsComposite, sel_registerName("imageForSize:scale:"), (IMP)swizzled_composite_imageForSize_scale, &s_orig_composite_imageForSize_scale);
    }

    Class clsMultisized = objc_getClass("ISMultisizedAppAssetCatalogResource");
    if (clsMultisized) {
        dv_swizzle(clsMultisized, sel_registerName("imageForSize:scale:"), (IMP)swizzled_multisizedApp_imageForSize_scale, &s_orig_multisizedApp_imageForSize_scale);
    }

    Class clsIcns = objc_getClass("ISIcns");
    if (clsIcns) {
        dv_swizzle(clsIcns, sel_registerName("CGImageWithData:iconIndexInfo:"), (IMP)swizzled_CGImageWithData_iconIndexInfo, &s_orig_cgimage_with_data);
    }
}

static void dv_installHotReloadListenerIfNeeded(void) {
    Class host = dv_hostClass();
    if (!host) return;
    const void *key = (const void *)sel_registerName("dv_installHotReloadListenerIfNeeded");
    if (objc_getAssociatedObject(host, key)) return;
    objc_setAssociatedObject(host, key, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    int token = 0;
    notify_register_dispatch("com.aotianneo.devitrify.reload", &token, dispatch_get_main_queue(), ^(int t) {
        (void)t;
        dv_performHotReload();
    });
}

#pragma mark - Constructor

static void dv_runInitOnMainThread(void) {
    @autoreleasepool {
        dv_installHotReloadListenerIfNeeded();

        BOOL isSafeBoot = dv_isSafeBoot();
        BOOL sysDisabled = isSafeBoot || dv_isSystemDisabledOnDisk();
        BOOL procBypassed = dv_isProcessBypassedOnDisk();
        dv_setLoaderSystemDisabled(sysDisabled || procBypassed);

        BOOL hasAppKit = (objc_getClass("NSApplication") != Nil);

        if (sysDisabled || procBypassed) {
            dv_restoreAllSwizzlesAndPatches();
            if (hasAppKit) {
                dv_setAppKitMenuGlassCache(0);
                if (NSApp) {
                    dv_refreshLiveWindows(NO);
                }
            }
            return;
        }

        dv_runFaultTolerant(^{
            if (hasAppKit) {
                dv_installGlassFilterNeutralization();
                dv_installSplitViewTitlebarAlignmentFix();
                dv_installClassicAppKit();
                dv_installClassicMenuEnforcement();
            }

            dv_installIconJailNeutralization();

            if (hasAppKit && NSApp) {
                dv_refreshLiveWindows(YES);
            }
        });
    }
}

__attribute__((constructor))
static void DevitrifyInit(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            dv_runInitOnMainThread();
        });
        return;
    }
    dv_runInitOnMainThread();
}
