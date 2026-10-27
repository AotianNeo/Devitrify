#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <notify.h>

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

#pragma mark - Idempotent Swizzle Registry

// Process-wide map of original IMPs stored on [NSApplication class] so hot-reloads
// never chain swizzles or lose the original implementation.
static NSMutableDictionary<NSString *, NSValue *> *dv_originalIMPMap(void) {
    Class host = [NSApplication class];
    NSMutableDictionary *map = objc_getAssociatedObject(host, @selector(dv_originalIMPMap));
    if (!map) {
        map = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(host, @selector(dv_originalIMPMap), map, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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

#pragma mark - Classic menu enforcement

static IMP s_orig_boolForKey = NULL;
static BOOL swizzled_boolForKey(NSUserDefaults *self, SEL _cmd, NSString *key) {
    if ([key hasPrefix:@"NSGlassMenu"] ||
        [key isEqualToString:@"NSMenuUseGlassWindowStyle"]) {
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
    // Check dynamic override file or environment on hot-reload
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

static void swizzled_sdf_setEffect(CALayer *self, SEL _cmd, id effect) {
    if (effect && [NSStringFromClass([effect class]) isEqualToString:@"CASDFKeyFillHighlightEffect"]) {
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

static void dv_installClassicAppKit(void) {
    Class cls = NSClassFromString(@"_NSSwiftUICoreFeatureFlags");
    if (cls) {
        dv_swizzleClassMethod(cls, @selector(isSolariumEnabled), (IMP)dv_returnNo, NULL);
        dv_swizzleClassMethod(cls, NSSelectorFromString(@"isSolariumEnabledIgnoringCompatibility"), (IMP)dv_returnNo, NULL);
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
    if (names && ![names containsObject:NSAccessibilitySubroleAttribute]) names = [names arrayByAddingObject:NSAccessibilitySubroleAttribute];
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
            if (eff) swizzled_sdf_setEffect(layer, NSSelectorFromString(@"setEffect:"), eff);
        } @catch (id ex) {}
    }
    if (layer.filters.count > 0) {
        for (id f in layer.filters) dv_neutralizeGlassFilter(f);
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

#pragma mark - Hot-Reload Listener

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
    dlopen(currentPath.UTF8String, RTLD_NOW | RTLD_LOCAL);
}

static void dv_installHotReloadListenerIfNeeded(void) {
    Class host = [NSApplication class];
    if (objc_getAssociatedObject(host, @selector(dv_installHotReloadListenerIfNeeded))) return;
    objc_setAssociatedObject(host, @selector(dv_installHotReloadListenerIfNeeded), @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

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
        s_keepsLiquidGlass = dv_keepsLiquidGlassViaLoader();
        BOOL solariumOn = _os_feature_enabled_impl("SwiftUI", "Solarium");
        s_liquidGlassOffSystemWide = s_keepsLiquidGlass || !solariumOn;

        dv_installGlassFilterNeutralization();

        if (!dv_compatibilityModeViaLoader()) {
            dv_installClassicAppKit();
        } else {
            dv_installCompatibilityAccessibilityFix();
        }
        dv_installClassicMenuEnforcement();
        dv_installKeepLiquidGlassItem();
        dv_installHotReloadListenerIfNeeded();

        if (NSApp) {
            dv_refreshLiveWindows();
        }
    }
}
