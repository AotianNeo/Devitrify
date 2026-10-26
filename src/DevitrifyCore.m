#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
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

#pragma mark - Solarium OFF: NSGlassEffectView -> NSVisualEffectView

enum { DVGlassStyleRegular = 0, DVGlassStyleClear = 1 };

@interface NSVisualEffectView (DVPrivate)
- (void)setCornerRadius:(CGFloat)radius;
@end

static NSVisualEffectMaterial dv_materialForGlassStyle(NSInteger style) {
    return style == DVGlassStyleClear ? NSVisualEffectMaterialHUDWindow : NSVisualEffectMaterialPopover;
}

static NSVisualEffectBlendingMode dv_blendingModeForGlass(NSView *glass) {
    NSView *root = glass.window.contentView;
    BOOL isWindowBackground = root && (glass == root ||
        NSEqualRects([glass convertRect:glass.bounds toView:nil], [root convertRect:root.bounds toView:nil]));
    return isWindowBackground ? NSVisualEffectBlendingModeBehindWindow : NSVisualEffectBlendingModeWithinWindow;
}

static CGFloat dv_clampedCornerRadius(CGFloat radius, NSRect bounds) {
    return MAX(0.0, MIN(radius, MIN(NSWidth(bounds), NSHeight(bounds)) / 2.0));
}

static NSView *dv_frostedBackdropForGlass(NSView *glass) {
    return objc_getAssociatedObject(glass, @selector(dv_frostedBackdropForGlass:));
}

static void dv_setFrostedBackdropForGlass(NSView *glass, NSView *fx) {
    objc_setAssociatedObject(glass, @selector(dv_frostedBackdropForGlass:), fx, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// AppKit and other system frameworks build menus and similar chrome out of
// NSGlassEffectView too and draw them correctly by themselves. Only glass in windows
// of an app's own classes (system apps included) or plain NSWindow / NSPanel gets a
// backdrop.
static BOOL dv_isAppWindow(NSWindow *window) {
    if (!window) return NO;
    NSString *name = NSStringFromClass([window class]);
    // Menus already draw their classic background via NSRootMenuWindowBackgroundView
    if ([name containsString:@"Menu"]) return NO;
    // Status bar items in menubar are handled separately
    if ([name containsString:@"StatusBar"]) return NO;
    return YES;
}

static NSView *dv_hitTestPassThrough(id self, SEL _cmd, NSPoint pt) {
    (void)self; (void)_cmd; (void)pt;
    return nil;
}

static BOOL dv_acceptsFirstMouseNo(id self, SEL _cmd, NSEvent *event) {
    (void)self; (void)_cmd; (void)event;
    return NO;
}

static Class dv_ensureFrostedBackdropViewClass(void) {
    Class cls = objc_getClass("DVFrostedBackdropView");
    if (!cls) {
        cls = objc_allocateClassPair([NSVisualEffectView class], "DVFrostedBackdropView", 0);
        if (cls) {
            class_addMethod(cls, @selector(hitTest:), (IMP)dv_hitTestPassThrough, "@@:{CGPoint=dd}");
            class_addMethod(cls, @selector(acceptsFirstMouse:), (IMP)dv_acceptsFirstMouseNo, "c@:@");
            objc_registerClassPair(cls);
        } else {
            cls = [NSVisualEffectView class];
        }
    } else {
        class_replaceMethod(cls, @selector(hitTest:), (IMP)dv_hitTestPassThrough, "@@:{CGPoint=dd}");
        class_replaceMethod(cls, @selector(acceptsFirstMouse:), (IMP)dv_acceptsFirstMouseNo, "c@:@");
    }
    return cls;
}

static void dv_updateFrostedBackdrop(NSView *glass) {
    if (!dv_isAppWindow(glass.window)) return;
    NSVisualEffectView *fx = (NSVisualEffectView *)dv_frostedBackdropForGlass(glass);
    if (!fx) {
        // Look for existing backdrop subview if reloaded from an earlier version
        for (NSView *sub in glass.subviews) {
            if ([NSStringFromClass([sub class]) isEqualToString:@"DVFrostedBackdropView"]) {
                fx = (NSVisualEffectView *)sub;
                break;
            }
        }
        if (!fx) {
            Class cls = dv_ensureFrostedBackdropViewClass();
            fx = [[cls alloc] initWithFrame:glass.bounds];
            fx.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            fx.state = NSVisualEffectStateActive;
        }
        dv_setFrostedBackdropForGlass(glass, fx);
    }
    if (fx.superview != glass || glass.subviews.firstObject != fx) {
        [glass addSubview:fx positioned:NSWindowBelow relativeTo:nil];
    }
    fx.frame = glass.bounds;
    fx.material = dv_materialForGlassStyle([[glass valueForKey:@"style"] integerValue]);
    fx.blendingMode = dv_blendingModeForGlass(glass);
    [fx setCornerRadius:dv_clampedCornerRadius([[glass valueForKey:@"cornerRadius"] doubleValue], glass.bounds)];
}

// System alert panels, sheets, and dialogs use NSGlassContentFrameView as their root themeFrame,
// which becomes completely transparent when Solarium is disabled. We add a frosted backdrop
// behind the frame content, matching the window's alert shape and corner radius.
static void dv_updateFrameBackdrop(NSView *frameView) {
    if (!frameView) return;
    NSWindow *win = frameView.window;
    if (!win) return;

    BOOL isTarget = [NSStringFromClass([frameView class]) containsString:@"GlassContentFrame"] ||
                    [NSStringFromClass([win class]) containsString:@"Alert"];
    if (!isTarget) return;

    NSVisualEffectView *fx = (NSVisualEffectView *)dv_frostedBackdropForGlass(frameView);
    if (!fx) {
        Class cls = dv_ensureFrostedBackdropViewClass();
        for (NSView *sub in frameView.subviews) {
            if ([sub isKindOfClass:cls]) {
                fx = (NSVisualEffectView *)sub;
                break;
            }
        }
        if (!fx) {
            fx = [[cls alloc] initWithFrame:frameView.bounds];
            fx.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            fx.state = NSVisualEffectStateActive;
            fx.material = NSVisualEffectMaterialPopover;
            fx.blendingMode = NSVisualEffectBlendingModeBehindWindow;

            CGFloat rad = 16.0;
            @try {
                double r = [[frameView valueForKey:@"cornerRadius"] doubleValue];
                if (r > 0) rad = r;
                else if (win) {
                    double wr = [[win valueForKey:@"cornerRadius"] doubleValue];
                    if (wr > 0) rad = wr;
                }
            } @catch (id ex) {}
            [fx setCornerRadius:MAX(12.0, rad)];
            objc_setAssociatedObject(frameView, @selector(dv_updateFrameBackdrop:), fx, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        dv_setFrostedBackdropForGlass(frameView, fx);
    }

    if (fx.superview != frameView || frameView.subviews.firstObject != fx) {
        [frameView addSubview:fx positioned:NSWindowBelow relativeTo:nil];
    }
    fx.frame = frameView.bounds;
}

static IMP s_orig_glass_layout = NULL;
static void swizzled_glass_layout(NSView *self, SEL _cmd) {
    if (s_orig_glass_layout) ((void (*)(id, SEL))s_orig_glass_layout)(self, _cmd);
    dv_updateFrostedBackdrop(self);
}

static IMP s_orig_theme_layout = NULL;
static void swizzled_theme_layout(NSView *self, SEL _cmd) {
    static __thread BOOL s_guard = NO;
    if (s_guard) {
        if (s_orig_theme_layout) ((void (*)(id, SEL))s_orig_theme_layout)(self, _cmd);
        return;
    }
    s_guard = YES;
    if (s_orig_theme_layout) ((void (*)(id, SEL))s_orig_theme_layout)(self, _cmd);
    dv_updateFrameBackdrop(self);
    s_guard = NO;
}

static IMP s_orig_container_layout = NULL;
static void swizzled_container_layout(NSView *self, SEL _cmd) {
    if (s_orig_container_layout) ((void (*)(id, SEL))s_orig_container_layout)(self, _cmd);
    dv_updateFrostedBackdrop(self);
}

static IMP s_orig_alert_doOrderWindow = NULL;
static void swizzled_alert_doOrderWindow(NSWindow *self, SEL _cmd, NSInteger order) {
    if (self.contentView.superview) {
        dv_updateFrameBackdrop(self.contentView.superview);
    }
    if (s_orig_alert_doOrderWindow) {
        ((void (*)(id, SEL, NSInteger))s_orig_alert_doOrderWindow)(self, _cmd, order);
    }
}

static IMP s_orig_glass_viewDidMoveToWindow = NULL;
static void swizzled_glass_viewDidMoveToWindow(NSView *self, SEL _cmd) {
    if (s_orig_glass_viewDidMoveToWindow) ((void (*)(id, SEL))s_orig_glass_viewDidMoveToWindow)(self, _cmd);
    self.needsLayout = YES;
}

static IMP s_orig_glass_setCornerRadius = NULL;
static void swizzled_glass_setCornerRadius(NSView *self, SEL _cmd, CGFloat radius) {
    if (s_orig_glass_setCornerRadius) ((void (*)(id, SEL, CGFloat))s_orig_glass_setCornerRadius)(self, _cmd, radius);
    self.needsLayout = YES;
}

static IMP s_orig_glass_setStyle = NULL;
static void swizzled_glass_setStyle(NSView *self, SEL _cmd, NSInteger style) {
    if (s_orig_glass_setStyle) ((void (*)(id, SEL, NSInteger))s_orig_glass_setStyle)(self, _cmd, style);
    self.needsLayout = YES;
}

static void dv_installFrostedGlassFallback(void) {
    Class glassCls = NSClassFromString(@"NSGlassEffectView");
    if (glassCls) {
        dv_swizzle(glassCls, @selector(layout), (IMP)swizzled_glass_layout, &s_orig_glass_layout);
        dv_swizzle(glassCls, @selector(viewDidMoveToWindow), (IMP)swizzled_glass_viewDidMoveToWindow, &s_orig_glass_viewDidMoveToWindow);
        dv_swizzle(glassCls, @selector(setCornerRadius:), (IMP)swizzled_glass_setCornerRadius, &s_orig_glass_setCornerRadius);
        dv_swizzle(glassCls, @selector(setStyle:), (IMP)swizzled_glass_setStyle, &s_orig_glass_setStyle);
    }
    Class containerCls = NSClassFromString(@"NSGlassEffectContainerView");
    if (containerCls) {
        dv_swizzle(containerCls, @selector(layout), (IMP)swizzled_container_layout, &s_orig_container_layout);
    }
}

// System alert panels, sheets, and dialogs must always have frosted glass backdrops
// across all Solarium modes (even when Solarium is enabled, NSAlertGlassSolariumEnabled is off
// and NSGlassView renders no layer).
static void dv_installAlertAndFrameBackdropFallback(void) {
    Class themeFrameCls = NSClassFromString(@"NSThemeFrame");
    if (themeFrameCls) {
        dv_swizzle(themeFrameCls, @selector(layout), (IMP)swizzled_theme_layout, &s_orig_theme_layout);
    }
    Class alertPanelCls = NSClassFromString(@"_NSAlertPanel");
    if (alertPanelCls) {
        dv_swizzle(alertPanelCls, NSSelectorFromString(@"_doOrderWindow:"), (IMP)swizzled_alert_doOrderWindow, &s_orig_alert_doOrderWindow);
    }
}

#pragma mark - Classic menu & alert enforcement

static IMP s_orig_boolForKey = NULL;
static BOOL swizzled_boolForKey(NSUserDefaults *self, SEL _cmd, NSString *key) {
    if ([key hasPrefix:@"NSGlassMenu"] ||
        [key isEqualToString:@"NSMenuUseGlassWindowStyle"] ||
        [key isEqualToString:@"NSAlertGlassSolariumEnabled"] ||
        [key isEqualToString:@"NSAlertUseGlassWindowStyle"]) {
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
        @"NSAlertGlassSolariumEnabled": @NO,
        @"NSAlertUseGlassWindowStyle": @NO,
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
    return [key containsString:@"Refraction"] ||
           [key containsString:@"Bleed"] ||
           [key containsString:@"Aberration"] ||
           [key containsString:@"Shadow"];
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
        if (dv_isRefractionKey(keyPath)) {
            value = @0;
        } else if ([keyPath hasSuffix:@"inputBlurRadius"]) {
            value = @(dv_getGlassBlurRadius());
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
    if (cls) dv_swizzleClassMethod(cls, @selector(isSolariumEnabled), (IMP)dv_returnNo, NULL);
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

static void dv_refreshSubviewsRecursively(NSView *v, BOOL solariumOn) {
    if (!v) return;
    if (!solariumOn) {
        if ([v isKindOfClass:NSClassFromString(@"NSGlassEffectView")]) {
            dv_updateFrostedBackdrop(v);
            v.needsLayout = YES;
        }
    }
    CALayer *layer = v.layer;
    if (layer && layer.filters.count > 0) {
        for (id f in layer.filters) dv_neutralizeGlassFilter(f);
        layer.filters = [layer.filters copy];
    }
    for (NSView *sub in v.subviews) {
        dv_refreshSubviewsRecursively(sub, solariumOn);
    }
}

static void dv_refreshLiveWindows(BOOL solariumOn) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            dv_refreshLiveWindows(solariumOn);
        });
        return;
    }
    for (NSWindow *win in [NSApp windows]) {
        if (!dv_isAppWindow(win)) continue;
        NSView *tf = win.contentView.superview;
        if (tf && ([NSStringFromClass([tf class]) containsString:@"GlassContentFrame"] || [NSStringFromClass([win class]) containsString:@"Alert"])) {
            dv_updateFrameBackdrop(tf);
        }
        dv_refreshSubviewsRecursively(win.contentView, solariumOn);
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

        if (solariumOn) {
            dv_installGlassFilterNeutralization();
            if (dv_keepsLiquidGlassViaLoader() && !dv_compatibilityModeViaLoader()) dv_installClassicAppKit();
            if (dv_compatibilityModeViaLoader()) dv_installCompatibilityAccessibilityFix();
        } else {
            dv_installFrostedGlassFallback();
        }
        dv_installAlertAndFrameBackdropFallback();
        dv_installClassicMenuEnforcement();
        dv_installKeepLiquidGlassItem();
        dv_installHotReloadListenerIfNeeded();

        if (NSApp) {
            dv_refreshLiveWindows(solariumOn);
        }
    }
}
