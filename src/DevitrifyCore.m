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
#import <sys/mman.h>
#import <sys/stat.h>
#if __has_feature(ptrauth_calls)
#import <ptrauth.h>
#endif

#define DEVITRIFY_INSTALL_DIR @"/Users/Shared/.devitrify"
#define DEVITRIFY_DISABLED_PATH @"/Users/Shared/.devitrify/disabled"
#define DEVITRIFY_BYPASS_DIR @"/Users/Shared/.devitrify/crash-bypass"

@interface CAFilter : NSObject
+ (instancetype)filterWithType:(NSString *)type;
- (NSString *)type;
- (NSArray *)inputKeys;
@end

extern bool _os_feature_enabled_impl(const char *domain, const char *feature);

// libDevitrify.dylib (the loader) knows whether this app keeps Liquid Glass.
static BOOL dv_compatibilityModeViaLoader(void) {
    int (*compat)(void) = dlsym(RTLD_DEFAULT, "devitrify_compatibility_mode");
    return compat && compat();
}

static BOOL dv_keepsLiquidGlassViaLoader(void) {
    int (*keeps)(void) = dlsym(RTLD_DEFAULT, "devitrify_keeps_liquid_glass");
    return keeps && keeps();
}

static void dv_setLoaderSystemDisabled(BOOL disabled) {
    void (*fn)(int) = dlsym(RTLD_DEFAULT, "devitrify_set_system_disabled");
    if (fn) fn(disabled ? 1 : 0);
}

static BOOL dv_isSystemDisabledOnDisk(void) {
    return [NSFileManager.defaultManager fileExistsAtPath:DEVITRIFY_DISABLED_PATH];
}

static NSString *dv_processBypassMarkerPath(void) {
    NSString *exe = NSProcessInfo.processInfo.processName ?: @"unknown";
    NSMutableString *safe = [NSMutableString stringWithCapacity:exe.length];
    for (NSUInteger i = 0; i < exe.length; i++) {
        unichar c = [exe characterAtIndex:i];
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
            (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-') {
            [safe appendFormat:@"%C", c];
        } else {
            [safe appendString:@"_"];
        }
    }
    return [DEVITRIFY_BYPASS_DIR stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.bypass", safe]];
}

static BOOL dv_isProcessBypassedOnDisk(void) {
    return [NSFileManager.defaultManager fileExistsAtPath:dv_processBypassMarkerPath()];
}

static void dv_markProcessBypassedOnDisk(int sig) {
    [NSFileManager.defaultManager createDirectoryAtPath:DEVITRIFY_BYPASS_DIR
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
    NSString *info = [NSString stringWithFormat:@"signal=%d pid=%d\n", sig, getpid()];
    [info writeToFile:dv_processBypassMarkerPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static BOOL s_hooksDisabled = NO;

#pragma mark - Idempotent Swizzle & Inline Patch Registry

// Process-wide map of original IMPs stored on [NSApplication class] so hot-reloads
// never chain swizzles or lose the original implementation, and can restore all hooks on demand.
static NSMutableDictionary<NSString *, NSValue *> *dv_originalIMPMap(void) {
    Class host = [NSApplication class];
    const void *key = (const void *)sel_registerName("dv_originalIMPMap");
    NSMutableDictionary *map = objc_getAssociatedObject(host, key);
    if (!map) {
        map = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(host, key, map, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return map;
}

static NSMutableDictionary<NSNumber *, NSData *> *dv_inlinePatchMap(void) {
    Class host = [NSApplication class];
    const void *key = (const void *)sel_registerName("dv_inlinePatchMap");
    NSMutableDictionary *map = objc_getAssociatedObject(host, key);
    if (!map) {
        map = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(host, key, map, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return map;
}

static void dv_swizzle(Class cls, SEL sel, IMP newImp, IMP *outOrig) {
    if (!cls || !sel || !newImp) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    NSString *key = [NSString stringWithFormat:@"-[%s %s]", class_getName(cls), sel_getName(sel)];
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

static void dv_swizzleClassMethod(Class cls, SEL sel, IMP newImp, IMP *outOrig) {
    if (!cls || !sel || !newImp) return;
    Method m = class_getClassMethod(cls, sel);
    if (!m) return;
    NSString *key = [NSString stringWithFormat:@"+[%s %s]", class_getName(cls), sel_getName(sel)];
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
}

#pragma mark - Classic menu enforcement

static IMP s_orig_boolForKey = NULL;
static BOOL swizzled_boolForKey(NSUserDefaults *self, SEL _cmd, NSString *key) {
    if (!s_hooksDisabled && ([key hasPrefix:@"NSGlassMenu"] ||
        [key isEqualToString:@"NSMenuUseGlassWindowStyle"])) {
        return NO;
    }
    return s_orig_boolForKey ? ((BOOL (*)(id, SEL, NSString *))s_orig_boolForKey)(self, _cmd, key) : NO;
}

static NSInteger swizzled_shadowOptions(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return 2;
}

static void dv_installClassicMenuEnforcement(void) {
    dv_swizzle([NSUserDefaults class], @selector(boolForKey:), (IMP)swizzled_boolForKey, &s_orig_boolForKey);

    Class popupCls = NSClassFromString(@"NSPopupMenuWindow");
    if (popupCls) {
        dv_swizzle(popupCls, @selector(shadowOptions), (IMP)swizzled_shadowOptions, NULL);
    }

    [[NSUserDefaults standardUserDefaults] registerDefaults:@{
        @"NSGlassMenusEnabled": @NO,
        @"NSGlassMenuLayoutEnabled": @NO,
        @"NSMenuUseGlassWindowStyle": @NO,
        @"NSGlassMenusUsePlainBorderView": @NO,
        @"NSGlassMenuContentAboveGlass": @NO,
    }];
}

#pragma mark - Solarium ON: glass filters -> plain Gaussian blur

static double dv_getGlassBlurRadius(void) {
    static double s_radius = 25.0;
    NSString *conf = [NSString stringWithContentsOfFile:@"/Users/Shared/.devitrify/blur-radius"
                                               encoding:NSUTF8StringEncoding
                                                  error:nil];
    if (conf && conf.length > 0) {
        double v = [conf doubleValue];
        if (v >= 0.0) return v;
    }
    const char *env = getenv("DEVITRIFY_BLUR_RADIUS");
    if (env) {
        double v = atof(env);
        if (v >= 0.0) return v;
    }
    return s_radius;
}

static inline BOOL dv_isGlassFilterType(NSString *type) {
    return [type isEqualToString:@"glassBackground"] || [type isEqualToString:@"glassForeground"];
}

static inline BOOL dv_isRefractionKey(NSString *key) {
    if (!key) return NO;
    return [key isEqualToString:@"inputInnerRefractionAmount"] ||
           [key isEqualToString:@"inputInnerRefractionHeight"] ||
           [key isEqualToString:@"inputOuterRefractionAmount"] ||
           [key isEqualToString:@"inputOuterRefractionHeight"] ||
           [key isEqualToString:@"inputRefractionOpacity"] ||
           [key isEqualToString:@"inputBleedAmount"] ||
           [key isEqualToString:@"inputBleedHeight"] ||
           [key isEqualToString:@"inputBleedOpacity"] ||
           [key isEqualToString:@"inputAberrationAmount"] ||
           [key isEqualToString:@"inputAberrationHeight"] ||
           [key isEqualToString:@"inputKeyFillHighlightAmount"] ||
           [key isEqualToString:@"inputKeyFillHighlightHeight"];
}

static IMP s_orig_sdf_setEffect = NULL;
static IMP s_orig_sdf_effect_setKeyColor = NULL;
static IMP s_orig_sdf_effect_setFillColor = NULL;

static void swizzled_sdf_effect_setKeyColor(id self, SEL _cmd, CGColorRef color) {
    if (s_orig_sdf_effect_setKeyColor) {
        CGColorRef targetColor = s_hooksDisabled ? color : CGColorGetConstantColor(kCGColorClear);
        ((void (*)(id, SEL, CGColorRef))s_orig_sdf_effect_setKeyColor)(self, _cmd, targetColor);
    }
}

static void swizzled_sdf_effect_setFillColor(id self, SEL _cmd, CGColorRef color) {
    if (s_orig_sdf_effect_setFillColor) {
        CGColorRef targetColor = s_hooksDisabled ? color : CGColorGetConstantColor(kCGColorClear);
        ((void (*)(id, SEL, CGColorRef))s_orig_sdf_effect_setFillColor)(self, _cmd, targetColor);
    }
}

static void swizzled_sdf_setEffect(CALayer *self, SEL _cmd, id effect) {
    if (!s_hooksDisabled && effect && [NSStringFromClass([effect class]) isEqualToString:@"CASDFKeyFillHighlightEffect"]) {
        @try {
            [effect setValue:(__bridge id)CGColorGetConstantColor(kCGColorClear) forKey:@"keyColor"];
            [effect setValue:(__bridge id)CGColorGetConstantColor(kCGColorClear) forKey:@"fillColor"];
        } @catch (id ex) {}
    }
    if (s_orig_sdf_setEffect) {
        ((void (*)(id, SEL, id))s_orig_sdf_setEffect)(self, _cmd, effect);
    }
}

static void dv_neutralizeGlassFilter(id filter) {
    if (s_hooksDisabled) return;
    @try {
        NSString *type = [filter valueForKey:@"type"];
        if (!dv_isGlassFilterType(type)) return;
        if ([filter respondsToSelector:@selector(inputKeys)]) {
            for (NSString *k in [filter inputKeys]) {
                if (dv_isRefractionKey(k)) [filter setValue:@0 forKey:k];
            }
        }
        if ([type isEqualToString:@"glassBackground"]) {
            [filter setValue:@(dv_getGlassBlurRadius()) forKey:@"inputBlurRadius"];
        }
    } @catch (id ex) {}
}

static IMP s_orig_filterWithType = NULL;
static id swizzled_filterWithType(id self, SEL _cmd, NSString *type) {
    id f = s_orig_filterWithType ? ((id (*)(id, SEL, NSString *))s_orig_filterWithType)(self, _cmd, type) : nil;
    if (!s_hooksDisabled && f && dv_isGlassFilterType(type)) dv_neutralizeGlassFilter(f);
    return f;
}

static IMP s_orig_cafilter_setValueForKey = NULL;
static void swizzled_cafilter_setValueForKey(id self, SEL _cmd, id value, NSString *key) {
    if (!s_hooksDisabled) {
        NSString *type = nil;
        @try { type = [self valueForKey:@"type"]; } @catch (id ex) {}
        if (dv_isGlassFilterType(type)) {
            if (dv_isRefractionKey(key)) {
                value = @0;
            } else if ([type isEqualToString:@"glassBackground"] && [key isEqualToString:@"inputBlurRadius"]) {
                value = @(dv_getGlassBlurRadius());
            }
        }
    }
    if (s_orig_cafilter_setValueForKey) {
        ((void (*)(id, SEL, id, NSString *))s_orig_cafilter_setValueForKey)(self, _cmd, value, key);
    }
}

static IMP s_orig_setFilters = NULL;
static void swizzled_setFilters(id self, SEL _cmd, NSArray *filters) {
    if (!s_hooksDisabled) {
        for (id f in filters) dv_neutralizeGlassFilter(f);
    }
    if (s_orig_setFilters) ((void (*)(id, SEL, NSArray *))s_orig_setFilters)(self, _cmd, filters);
}

static IMP s_orig_setValueForKeyPath = NULL;
static void swizzled_setValueForKeyPath(id self, SEL _cmd, id value, NSString *keyPath) {
    if (!s_hooksDisabled && [keyPath hasPrefix:@"filters.glass"]) {
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
    Class sdfCls = NSClassFromString(@"CASDFLayer");
    if (sdfCls) {
        dv_swizzle(sdfCls, NSSelectorFromString(@"setEffect:"), (IMP)swizzled_sdf_setEffect, &s_orig_sdf_setEffect);
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

static BOOL dv_returnNo(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return NO;
}

static IMP s_orig_partitionAdapter_dividerWidth = NULL;
static CGFloat swizzled_partitionAdapter_dividerWidth(id self, SEL _cmd) {
    if (!s_hooksDisabled) {
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
    if (!s_hooksDisabled && cls && [NSStringFromClass(cls) isEqualToString:@"UISplitViewControllerPanelImpl"]) {
        Class adaptiveCls = NSClassFromString(@"_UISplitViewControllerAdaptiveImpl");
        if (adaptiveCls) return adaptiveCls;
    }
    return cls;
}

static void dv_installSwiftUISolariumCompatibilityAllowedFix(void) {
    // When SwiftUI runs in level .compatibility (1) with Solarium disabled system-wide,
    // SwiftUI.Solarium.evaluate(inputs:) queries SwiftUI.Solarium.AllowedInCompatibilityKey.
    // If that key is not explicitly set, it defaults to false, causing SpotlightUIInternal's
    // StaticIf<Solarium, GlassEffect, EmptyView> to collapse into EmptyView (transparent window).
    // We patch AllowedInCompatibilityKey getter in SwiftUICore to return true (1), so
    // .compatibility apps and Spotlight render their full view tree while keeping classic metrics.
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

#pragma mark - Help menu: Keep Liquid Glass

static NSString *dv_liquidGlassAppsPath(void) {
    return @"/Users/Shared/.devitrify/liquid-glass-apps";
}

static NSString *dv_appName(void) {
    return NSBundle.mainBundle.bundleURL.lastPathComponent.stringByDeletingPathExtension;
}

static NSMutableArray<NSString *> *dv_liquidGlassAppsLines(void) {
    NSString *text = [NSString stringWithContentsOfFile:dv_liquidGlassAppsPath() encoding:NSUTF8StringEncoding error:nil] ?: @"";
    NSMutableArray<NSString *> *lines = [[text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet] mutableCopy];
    while (lines.count && lines.lastObject.length == 0) [lines removeLastObject];
    return lines;
}

static BOOL dv_isSandboxed(void) {
    return [NSHomeDirectory() containsString:@"/Library/Containers/"];
}

static NSString *dv_keepMarkerPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/devitrify-keep-liquid-glass"];
}

static BOOL s_keepsLiquidGlass = NO;
static BOOL dv_keepsLiquidGlass(void) { return s_keepsLiquidGlass; }

static BOOL s_liquidGlassOffSystemWide = NO;

static void dv_reopenApp(void) {
    NSString *script = [NSString stringWithFormat:
        @"i=0; while kill -0 %d 2>/dev/null && [ $i -lt 300 ]; do sleep 0.2; i=$((i+1)); done; "
        @"kill -0 %d 2>/dev/null || /usr/bin/open \"$0\"", getpid(), getpid()];
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/sh"];
    task.arguments = @[@"-c", script, NSBundle.mainBundle.bundlePath];
    if ([task launchAndReturnError:nil]) [NSApp terminate:nil];
}

static BOOL dv_validateMenuItemTarget(id self, SEL _cmd, NSMenuItem *item) {
    (void)self; (void)_cmd;
    item.state = dv_keepsLiquidGlass() ? NSControlStateValueOn : NSControlStateValueOff;
    return YES;
}

static void dv_toggleKeepLiquidGlassAction(id self, SEL _cmd, NSMenuItem *item) {
    (void)self; (void)_cmd; (void)item;
    NSString *name = dv_appName();
    BOOL keep = !dv_keepsLiquidGlass();
    if (dv_isSandboxed()) {
        NSString *marker = dv_keepMarkerPath();
        [NSFileManager.defaultManager createDirectoryAtPath:marker.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        if (![(keep ? @"compat\n" : @"off\n") writeToFile:marker atomically:YES encoding:NSUTF8StringEncoding error:nil]) return;
    } else {
        NSMutableArray<NSString *> *lines = dv_liquidGlassAppsLines();
        for (NSString *line in [lines copy]) {
            if ([line isEqualToString:name] || [line hasPrefix:[name stringByAppendingString:@" "]]) [lines removeObject:line];
        }
        [lines addObject:keep ? name : [name stringByAppendingString:@" off"]];
        NSString *text = [[lines componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"];
        if (![text writeToFile:dv_liquidGlassAppsPath() atomically:YES encoding:NSUTF8StringEncoding error:nil]) return;
    }
    s_keepsLiquidGlass = keep;

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [NSString stringWithFormat:keep ? @"%@ will keep Liquid Glass." : @"%@ will no longer keep Liquid Glass.", name];
    alert.informativeText = [NSString stringWithFormat:@"Reopen %@ to apply the change.", name];
    [alert addButtonWithTitle:@"Reopen Now"];
    [alert addButtonWithTitle:@"Later"];
    if ([alert runModal] == NSAlertFirstButtonReturn) dv_reopenApp();
}

static id dv_ensureKeepLiquidGlassItemTarget(void) {
    Class cls = objc_getClass("DVKeepLiquidGlassItemTarget");
    if (!cls) {
        cls = objc_allocateClassPair([NSObject class], "DVKeepLiquidGlassItemTarget", 0);
        if (cls) {
            class_addMethod(cls, @selector(validateMenuItem:), (IMP)dv_validateMenuItemTarget, "c@:@");
            class_addMethod(cls, @selector(toggleKeepLiquidGlass:), (IMP)dv_toggleKeepLiquidGlassAction, "v@:@");
            objc_registerClassPair(cls);
        } else {
            cls = [NSObject class];
        }
    } else {
        class_replaceMethod(cls, @selector(validateMenuItem:), (IMP)dv_validateMenuItemTarget, "c@:@");
        class_replaceMethod(cls, @selector(toggleKeepLiquidGlass:), (IMP)dv_toggleKeepLiquidGlassAction, "v@:@");
    }
    return [[cls alloc] init];
}

static void dv_installKeepLiquidGlassItem(void) {
    if (!s_liquidGlassOffSystemWide) return;
    if (!dv_isSandboxed()) {
        NSString *path = dv_liquidGlassAppsPath();
        if (!path || ![NSFileManager.defaultManager isWritableFileAtPath:path.stringByDeletingLastPathComponent]) return;
    }
    if (![NSBundle.mainBundle.bundlePath hasSuffix:@".app"]) return;

    id target = dv_ensureKeepLiquidGlassItemTarget();

    static __weak NSMenu *observedMenu;
    void (^addItem)(void) = ^{
        NSMenu *help = NSApp.helpMenu;
        if (!help) return;
        if ([help indexOfItemWithTarget:target andAction:@selector(toggleKeepLiquidGlass:)] < 0) {
            if (help.numberOfItems > 0) [help addItem:NSMenuItem.separatorItem];
            NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"Keep Liquid Glass" action:@selector(toggleKeepLiquidGlass:) keyEquivalent:@""];
            item.target = target;
            [help addItem:item];
        }
        if (observedMenu != help) {
            observedMenu = help;
            [NSNotificationCenter.defaultCenter addObserverForName:NSMenuDidChangeItemNotification object:help queue:nil usingBlock:^(NSNotification *note) {
                (void)note;
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSMenu *h = NSApp.helpMenu;
                    if (h && [h indexOfItemWithTarget:target andAction:@selector(toggleKeepLiquidGlass:)] < 0) {
                        if (h.numberOfItems > 0) [h addItem:NSMenuItem.separatorItem];
                        NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:@"Keep Liquid Glass" action:@selector(toggleKeepLiquidGlass:) keyEquivalent:@""];
                        it.target = target;
                        [h addItem:it];
                    }
                });
            }];
        }
    };
    for (NSNotificationName name in @[NSApplicationDidFinishLaunchingNotification, NSApplicationDidBecomeActiveNotification]) {
        [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            (void)note;
            addItem();
        }];
    }
}

#pragma mark - Compatibility mode: accessibility protection

static IMP s_orig_view_attr_value = NULL;
static id swizzled_view_attributeValue(id self, SEL _cmd, NSString *attribute) {
    @try {
        return s_orig_view_attr_value ? ((id (*)(id, SEL, NSString *))s_orig_view_attr_value)(self, _cmd, attribute) : nil;
    } @catch (NSException *ex) {
        if ([ex.name isEqualToString:@"NSAccessibilityException"]) return nil;
        @throw;
    }
}

static IMP s_orig_win_attr_value = NULL;
static id swizzled_win_attributeValue(id self, SEL _cmd, NSString *attribute) {
    @try {
        return s_orig_win_attr_value ? ((id (*)(id, SEL, NSString *))s_orig_win_attr_value)(self, _cmd, attribute) : nil;
    } @catch (NSException *ex) {
        if ([ex.name isEqualToString:@"NSAccessibilityException"]) return nil;
        @throw;
    }
}

static IMP s_orig_cell_attr_value = NULL;
static id swizzled_cell_attributeValue(id self, SEL _cmd, NSString *attribute) {
    @try {
        return s_orig_cell_attr_value ? ((id (*)(id, SEL, NSString *))s_orig_cell_attr_value)(self, _cmd, attribute) : nil;
    } @catch (NSException *ex) {
        if ([ex.name isEqualToString:@"NSAccessibilityException"]) return nil;
        @throw;
    }
}

static IMP s_orig_cell_attributeNames = NULL;
static NSArray *swizzled_cell_attributeNames(id self, SEL _cmd) {
    NSArray *names = s_orig_cell_attributeNames ? ((NSArray *(*)(id, SEL))s_orig_cell_attributeNames)(self, _cmd) : nil;
    if (!s_hooksDisabled && names && ![names containsObject:NSAccessibilitySubroleAttribute]) {
        names = [names arrayByAddingObject:NSAccessibilitySubroleAttribute];
    }
    return names;
}

static void dv_installCompatibilityAccessibilityFix(void) {
    dv_swizzle([NSView class], @selector(accessibilityAttributeValue:), (IMP)swizzled_view_attributeValue, &s_orig_view_attr_value);
    dv_swizzle([NSWindow class], @selector(accessibilityAttributeValue:), (IMP)swizzled_win_attributeValue, &s_orig_win_attr_value);
    dv_swizzle([NSCell class], @selector(accessibilityAttributeValue:), (IMP)swizzled_cell_attributeValue, &s_orig_cell_attr_value);
    Class cls = NSClassFromString(@"NSPopUpButtonCell");
    if (cls) dv_swizzle(cls, @selector(accessibilityAttributeNames), (IMP)swizzled_cell_attributeNames, &s_orig_cell_attributeNames);
}

#pragma mark - Live State Refresh on Hot-Reload

static void dv_refreshLayersRecursively(CALayer *layer) {
    if (!layer) return;
    if ([NSStringFromClass([layer class]) isEqualToString:@"CASDFLayer"]) {
        @try {
            id eff = [layer valueForKey:@"effect"];
            if (eff && !s_hooksDisabled) {
                swizzled_sdf_setEffect(layer, NSSelectorFromString(@"setEffect:"), eff);
            }
        } @catch (id ex) {}
    }
    if (layer.filters.count > 0) {
        if (!s_hooksDisabled) {
            for (id f in layer.filters) dv_neutralizeGlassFilter(f);
        }
        layer.filters = [layer.filters copy];
    }
    for (CALayer *sub in layer.sublayers) {
        dv_refreshLayersRecursively(sub);
    }
}

static void dv_refreshSubviewsRecursively(NSView *v) {
    if (!v) return;
    if (v.layer) {
        dv_refreshLayersRecursively(v.layer);
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
        dv_refreshSubviewsRecursively(sub);
    }
}

static void dv_refreshLiveWindows(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            dv_refreshLiveWindows();
        });
        return;
    }
    for (NSWindow *win in [NSApp windows]) {
        NSView *root = win.contentView.superview ?: win.contentView;
        dv_refreshSubviewsRecursively(root);
        if ([win respondsToSelector:NSSelectorFromString(@"_glassEffectChildWindow")]) {
            NSWindow *child = ((id (*)(id, SEL))objc_msgSend)(win, NSSelectorFromString(@"_glassEffectChildWindow"));
            if (child) {
                NSView *childBorder = [child valueForKey:@"_borderView"];
                dv_refreshSubviewsRecursively(childBorder);
            }
        }
    }
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
        s_hooksDisabled = YES;
        dv_setLoaderSystemDisabled(YES);
        dv_restoreAllSwizzlesAndPatches();
    }
    return ok;
}

static void dv_performHotReload(void) {
    NSString *currentPath = [NSString stringWithContentsOfFile:@"/Users/Shared/.devitrify/reload/current"
                                                      encoding:NSUTF8StringEncoding
                                                         error:nil];
    if (currentPath) {
        currentPath = [currentPath stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    if (!currentPath || currentPath.length == 0) {
        currentPath = @"/Users/Shared/.devitrify/DevitrifyCore.dylib";
    }
    dv_runFaultTolerant(^{
        dlopen(currentPath.UTF8String, RTLD_NOW | RTLD_LOCAL);
    });
}

static void dv_installHotReloadListenerIfNeeded(void) {
    Class host = [NSApplication class];
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

__attribute__((constructor))
static void DevitrifyInit(void) {
    @autoreleasepool {
        dv_installHotReloadListenerIfNeeded();

        BOOL sysDisabled = dv_isSystemDisabledOnDisk();
        BOOL procBypassed = dv_isProcessBypassedOnDisk();
        dv_setLoaderSystemDisabled(sysDisabled || procBypassed);

        if (sysDisabled || procBypassed) {
            s_hooksDisabled = YES;
            dv_restoreAllSwizzlesAndPatches();
            if (NSApp) {
                dv_refreshLiveWindows();
            }
            return;
        }

        s_hooksDisabled = NO;
        dv_runFaultTolerant(^{
            s_keepsLiquidGlass = dv_keepsLiquidGlassViaLoader();
            BOOL solariumOn = _os_feature_enabled_impl("SwiftUI", "Solarium");
            s_liquidGlassOffSystemWide = s_keepsLiquidGlass || !solariumOn;

            dv_installGlassFilterNeutralization();
            if (!s_keepsLiquidGlass) {
                dv_installSplitViewTitlebarAlignmentFix();
            }

            if (!dv_compatibilityModeViaLoader()) {
                dv_installClassicAppKit();
            } else {
                dv_installCompatibilityAccessibilityFix();
            }
            dv_installClassicMenuEnforcement();
            dv_installKeepLiquidGlassItem();

            if (NSApp) {
                dv_refreshLiveWindows();
            }
        });
    }
}
