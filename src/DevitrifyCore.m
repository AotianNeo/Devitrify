#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>

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

static BOOL dv_compatibilityModeViaLoader(void);
static BOOL dv_keepsLiquidGlassViaLoader(void) {
    int (*keeps)(void) = dlsym(RTLD_DEFAULT, "devitrify_keeps_liquid_glass");
    return keeps && keeps();
}

// ============================================================================
//  Devitrify
//
//  Turns Liquid Glass back into frosted glass. Loaded into apps by libDevitrify.dylib.
//  The branch is chosen by the process's own Solarium (Liquid Glass) state; no
//  process names are hardcoded.
//
//  1. Liquid Glass OFF (disabled through the SwiftUI/Solarium feature flag):
//     AppKit and SwiftUI draw classic controls, but NSGlassEffectView and
//     NSGlassEffectContainerView render no backdrop at all, so glass windows and
//     panels come out fully transparent. Every NSGlassEffectView in an app window
//     gets an NSVisualEffectView behind its content, clipped to the glass corner
//     radius. The class itself is left alone: AppKit's own menus use it internally
//     and rely on its real implementation.
//
//  2. Liquid Glass ON (system-wide, or per process through
//     FEATUREFLAGS_ENABLED=SwiftUI/Solarium: Control Center and Notification Center
//     under launchbad-revived, and apps named in liquid-glass-apps, see loader.c):
//     refraction, bleed, aberration and shadow are
//     stripped from the glassBackground and glassForeground filters, leaving a plain
//     Gaussian blur.
// ============================================================================

#pragma mark - Solarium OFF: NSGlassEffectView -> NSVisualEffectView

// NSGlassEffectView.Style
enum { DVGlassStyleRegular = 0, DVGlassStyleClear = 1 };

@interface NSVisualEffectView (DVPrivate)
- (void)setCornerRadius:(CGFloat)radius;
@end

static NSVisualEffectMaterial dv_materialForGlassStyle(NSInteger style) {
    return style == DVGlassStyleClear ? NSVisualEffectMaterialHUDWindow : NSVisualEffectMaterialPopover;
}

// Glass that forms the whole window background blurs the desktop behind the
// window; glass placed over window content blurs that content instead.
static NSVisualEffectBlendingMode dv_blendingModeForGlass(NSView *glass) {
    NSView *root = glass.window.contentView;
    BOOL isWindowBackground = root && (glass == root ||
        NSEqualRects([glass convertRect:glass.bounds toView:nil], [root convertRect:root.bounds toView:nil]));
    return isWindowBackground ? NSVisualEffectBlendingModeBehindWindow : NSVisualEffectBlendingModeWithinWindow;
}

static CGFloat dv_clampedCornerRadius(CGFloat radius, NSRect bounds) {
    return MAX(0.0, MIN(radius, MIN(NSWidth(bounds), NSHeight(bounds)) / 2.0));
}

static const void *kDVBackdropKey = &kDVBackdropKey;

@interface DVFrostedBackdropView : NSVisualEffectView
@end

@implementation DVFrostedBackdropView
- (NSView *)hitTest:(NSPoint)point { (void)point; return nil; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { (void)event; return NO; }
@end

// AppKit and other system frameworks build menus and similar chrome out of
// NSGlassEffectView too and draw them correctly by themselves. Only glass in windows
// of an app's own classes (system apps included) or plain NSWindow / NSPanel gets a
// backdrop.
static BOOL dv_isAppWindow(NSWindow *window) {
    if (!window) return NO;
    for (Class cls = object_getClass(window); cls && cls != [NSPanel class] && cls != [NSWindow class]; cls = class_getSuperclass(cls)) {
        const char *image = class_getImageName(cls);
        if (image && strstr(image, "/System/Library/") && strstr(image, ".framework/")) return NO;
    }
    return YES;
}

static void dv_updateFrostedBackdrop(NSView *glass) {
    if (!dv_isAppWindow(glass.window)) return;
    DVFrostedBackdropView *fx = objc_getAssociatedObject(glass, kDVBackdropKey);
    if (!fx) {
        fx = [[DVFrostedBackdropView alloc] initWithFrame:glass.bounds];
        fx.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        fx.state = NSVisualEffectStateActive;
        objc_setAssociatedObject(glass, kDVBackdropKey, fx, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    // Keep the backdrop as the bottom-most subview, below the glass content.
    if (fx.superview != glass || glass.subviews.firstObject != fx) {
        [glass addSubview:fx positioned:NSWindowBelow relativeTo:nil];
    }
    fx.frame = glass.bounds;
    fx.material = dv_materialForGlassStyle([[glass valueForKey:@"style"] integerValue]);
    fx.blendingMode = dv_blendingModeForGlass(glass);
    [fx setCornerRadius:dv_clampedCornerRadius([[glass valueForKey:@"cornerRadius"] doubleValue], glass.bounds)];
}

static IMP s_orig_glass_layout = NULL;
static void swizzled_glass_layout(NSView *self, SEL _cmd) {
    ((void (*)(id, SEL))s_orig_glass_layout)(self, _cmd);
    dv_updateFrostedBackdrop(self);
}

static IMP s_orig_glass_viewDidMoveToWindow = NULL;
static void swizzled_glass_viewDidMoveToWindow(NSView *self, SEL _cmd) {
    ((void (*)(id, SEL))s_orig_glass_viewDidMoveToWindow)(self, _cmd);
    self.needsLayout = YES;
}

static IMP s_orig_glass_setCornerRadius = NULL;
static void swizzled_glass_setCornerRadius(NSView *self, SEL _cmd, CGFloat radius) {
    ((void (*)(id, SEL, CGFloat))s_orig_glass_setCornerRadius)(self, _cmd, radius);
    self.needsLayout = YES;
}

static IMP s_orig_glass_setStyle = NULL;
static void swizzled_glass_setStyle(NSView *self, SEL _cmd, NSInteger style) {
    ((void (*)(id, SEL, NSInteger))s_orig_glass_setStyle)(self, _cmd, style);
    self.needsLayout = YES;
}

static void dv_swizzle(Class cls, SEL sel, IMP newImp, IMP *outOrig) {
    Method m = class_getInstanceMethod(cls, sel);
    if (m) *outOrig = method_setImplementation(m, newImp);
}

static void dv_installFrostedGlassFallback(void) {
    Class glassCls = NSClassFromString(@"NSGlassEffectView");
    if (!glassCls) return;
    dv_swizzle(glassCls, @selector(layout), (IMP)swizzled_glass_layout, &s_orig_glass_layout);
    dv_swizzle(glassCls, @selector(viewDidMoveToWindow), (IMP)swizzled_glass_viewDidMoveToWindow, &s_orig_glass_viewDidMoveToWindow);
    dv_swizzle(glassCls, @selector(setCornerRadius:), (IMP)swizzled_glass_setCornerRadius, &s_orig_glass_setCornerRadius);
    dv_swizzle(glassCls, @selector(setStyle:), (IMP)swizzled_glass_setStyle, &s_orig_glass_setStyle);
}

#pragma mark - Always-on modern Solarium menus

@interface NSWindow (DVPopupMenuWindowPrivate)
- (void)_setCornerRadius:(CGFloat)radius;
@end

@interface NSObject (DVRevealMenuItemPrivate)
- (NSInteger)tagForType;
@end

static IMP s_orig_popup_initWithContextMenuImpl = NULL;
static id swizzled_popup_initWithContextMenuImpl(NSWindow *self, SEL _cmd, id impl) {
    self = ((id (*)(id, SEL, id))s_orig_popup_initWithContextMenuImpl)(self, _cmd, impl);
    if (self) {
        if ([self respondsToSelector:@selector(_setCornerRadius:)]) {
            [self _setCornerRadius:12.0];
        }
        [self setBackgroundColor:[NSColor clearColor]];
        [self setOpaque:NO];
    }
    return self;
}

static IMP s_orig_rvMenuItem_image = NULL;
static NSImage *swizzled_rvMenuItem_image(id self, SEL _cmd) {
    if ([self respondsToSelector:@selector(tagForType)] && [self tagForType] == 1) {
        NSImage *img = [NSImage imageWithSystemSymbolName:@"text.magnifyingglass" accessibilityDescription:nil];
        if (img) return img;
    }
    return s_orig_rvMenuItem_image ? ((NSImage *(*)(id, SEL))s_orig_rvMenuItem_image)(self, _cmd) : nil;
}

static IMP s_orig_rvTranslateMenuItem_image = NULL;
static NSImage *swizzled_rvTranslateMenuItem_image(id self, SEL _cmd) {
    NSImage *img = [NSImage imageWithSystemSymbolName:@"translate" accessibilityDescription:nil];
    if (img) return img;
    return s_orig_rvTranslateMenuItem_image ? ((NSImage *(*)(id, SEL))s_orig_rvTranslateMenuItem_image)(self, _cmd) : nil;
}

static void dv_onRevealImageAdded(const struct mach_header *mh, intptr_t vmaddr_slide) {
    (void)vmaddr_slide;
    Dl_info info;
    if (!dladdr(mh, &info) || !info.dli_fname || !strstr(info.dli_fname, "/Reveal.framework/")) return;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class rvCls = NSClassFromString(@"RVMenuItem");
        if (rvCls) dv_swizzle(rvCls, @selector(image), (IMP)swizzled_rvMenuItem_image, &s_orig_rvMenuItem_image);
        Class rvtCls = NSClassFromString(@"RVTranslateMenuItem");
        if (rvtCls) dv_swizzle(rvtCls, @selector(image), (IMP)swizzled_rvTranslateMenuItem_image, &s_orig_rvTranslateMenuItem_image);
    });
}

static void dv_installModernMenus(BOOL solariumEnabled) {
    if (!solariumEnabled) {
        [[NSUserDefaults standardUserDefaults] registerDefaults:@{
            @"NSGlassMenuLayoutEnabled": @YES,
            @"NSMenuUseGlassWindowStyle": @NO,
        }];
        Class popupCls = NSClassFromString(@"NSPopupMenuWindow");
        if (popupCls) {
            dv_swizzle(popupCls, NSSelectorFromString(@"initWithContextMenuImpl:"),
                       (IMP)swizzled_popup_initWithContextMenuImpl, &s_orig_popup_initWithContextMenuImpl);
        }
    }
    _dyld_register_func_for_add_image(dv_onRevealImageAdded);
}

#pragma mark - Solarium ON: glass filters -> plain Gaussian blur

static double dv_getGlassBlurRadius(void) {
    static double s_radius = 25.0;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        const char *env = getenv("DEVITRIFY_BLUR_RADIUS");
        if (env) {
            double v = atof(env);
            if (v >= 0.0) s_radius = v;
        }
    });
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
    id f = ((id (*)(id, SEL, NSString *))s_orig_filterWithType)(self, _cmd, type);
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
    ((void (*)(id, SEL, id, NSString *))s_orig_cafilter_setValueForKey)(self, _cmd, value, key);
}

static IMP s_orig_setFilters = NULL;
static void swizzled_setFilters(id self, SEL _cmd, NSArray *filters) {
    for (id f in filters) dv_neutralizeGlassFilter(f);
    ((void (*)(id, SEL, NSArray *))s_orig_setFilters)(self, _cmd, filters);
}

// Animations address filter inputs through key paths such as
// "filters.glassBackground.inputRefractionAmount".
static IMP s_orig_setValueForKeyPath = NULL;
static void swizzled_setValueForKeyPath(id self, SEL _cmd, id value, NSString *keyPath) {
    if ([keyPath hasPrefix:@"filters.glass"]) {
        if (dv_isRefractionKey(keyPath)) {
            value = @0;
        } else if ([keyPath hasSuffix:@"inputBlurRadius"]) {
            value = @(dv_getGlassBlurRadius());
        }
    }
    ((void (*)(id, SEL, id, NSString *))s_orig_setValueForKeyPath)(self, _cmd, value, keyPath);
}

static void dv_installGlassFilterNeutralization(void) {
    Class filterCls = NSClassFromString(@"CAFilter");
    if (filterCls) {
        Method m = class_getClassMethod(filterCls, @selector(filterWithType:));
        if (m) s_orig_filterWithType = method_setImplementation(m, (IMP)swizzled_filterWithType);
        dv_swizzle(filterCls, @selector(setValue:forKey:), (IMP)swizzled_cafilter_setValueForKey, &s_orig_cafilter_setValueForKey);
    }
    dv_swizzle([CALayer class], @selector(setFilters:), (IMP)swizzled_setFilters, &s_orig_setFilters);
    dv_swizzle([CALayer class], @selector(setValue:forKeyPath:), (IMP)swizzled_setValueForKeyPath, &s_orig_setValueForKeyPath);
}

#pragma mark - Liquid Glass apps: classic AppKit controls

// Apps listed in liquid-glass-apps run with Liquid Glass so that their SwiftUI glass keeps
// its shape, while every other app is classic. AppKit asks _NSSwiftUICoreFeatureFlags
// whether Liquid Glass is on; answering NO gives the app the same classic windows, menus
// and controls as the rest of the system. SwiftUI glass, and NSGlassEffectView built on
// it, check SwiftUI's own flag and keep working. Controls drawn by SwiftUI itself, such as
// its buttons, still follow Liquid Glass.
static BOOL dv_returnNo(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return NO;
}

static void dv_installClassicAppKit(void) {
    Method m = class_getClassMethod(NSClassFromString(@"_NSSwiftUICoreFeatureFlags"), @selector(isSolariumEnabled));
    if (m) method_setImplementation(m, (IMP)dv_returnNo);
}

#pragma mark - Help menu: Keep Liquid Glass

// With Liquid Glass disabled system-wide, the Help menu of every app gets a "Keep Liquid
// Glass" item that adds the app to liquid-glass-apps (or removes it) and offers to reopen
// the app so the change takes effect.

static NSString *dv_liquidGlassAppsPath(void) {
    Dl_info info;
    if (!dladdr((const void *)dv_liquidGlassAppsPath, &info) || !info.dli_fname) return nil;
    return [[@(info.dli_fname) stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"liquid-glass-apps"];
}

// The name liquid-glass-apps matches against: the app's file name without ".app".
static NSString *dv_appName(void) {
    return NSBundle.mainBundle.bundleURL.lastPathComponent.stringByDeletingPathExtension;
}

static NSMutableArray<NSString *> *dv_liquidGlassAppsLines(void) {
    NSString *text = [NSString stringWithContentsOfFile:dv_liquidGlassAppsPath() encoding:NSUTF8StringEncoding error:nil] ?: @"";
    NSMutableArray<NSString *> *lines = [[text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet] mutableCopy];
    while (lines.count && lines.lastObject.length == 0) [lines removeLastObject];
    return lines;
}

// Sandboxed apps can't read liquid-glass-apps. They keep a marker file in their own
// container instead, which the app can read and write itself.
static BOOL dv_isSandboxed(void) {
    return [NSHomeDirectory() containsString:@"/Library/Containers/"];
}

static NSString *dv_keepMarkerPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/devitrify-keep-liquid-glass"];
}

// Whether this app runs with Liquid Glass kept, as the loader decided, whether by the
// list, the marker or because the app uses SwiftUI's glass effect. Updated in-process if
// the user toggles the menu item and chooses "Later".
static BOOL s_keepsLiquidGlass = NO;

static BOOL dv_keepsLiquidGlass(void) {
    return s_keepsLiquidGlass;
}

// Whether Liquid Glass is turned off for this app because it is disabled system-wide.
// Evaluated before Devitrify enables it for apps that keep it.
static BOOL s_liquidGlassOffSystemWide = NO;

// Reopens the app once it has quit. If quitting is cancelled, for example to keep unsaved
// changes, it gives up after a minute instead of reopening the app later by surprise.
static void dv_reopenApp(void) {
    NSString *script = [NSString stringWithFormat:
        @"i=0; while kill -0 %d 2>/dev/null && [ $i -lt 300 ]; do sleep 0.2; i=$((i+1)); done; "
        @"kill -0 %d 2>/dev/null || /usr/bin/open \"$0\"", getpid(), getpid()];
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/sh"];
    task.arguments = @[@"-c", script, NSBundle.mainBundle.bundlePath];
    if ([task launchAndReturnError:nil]) [NSApp terminate:nil];
}

@interface DVKeepLiquidGlassItemTarget : NSObject
@end

@implementation DVKeepLiquidGlassItemTarget

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    item.state = dv_keepsLiquidGlass() ? NSControlStateValueOn : NSControlStateValueOff;
    return YES;
}

- (void)toggleKeepLiquidGlass:(NSMenuItem *)item {
    (void)item;
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

@end

static void dv_installKeepLiquidGlassItem(void) {
    if (!s_liquidGlassOffSystemWide) return;
    if (!dv_isSandboxed()) {
        NSString *path = dv_liquidGlassAppsPath();
        if (!path || ![NSFileManager.defaultManager isWritableFileAtPath:path.stringByDeletingLastPathComponent]) return;
    }
    if (![NSBundle.mainBundle.bundlePath hasSuffix:@".app"]) return;

    static DVKeepLiquidGlassItemTarget *target;
    target = [[DVKeepLiquidGlassItemTarget alloc] init];

    // SwiftUI apps rebuild their menus whenever their state changes, which removes the item,
    // so it is added again after every change to the Help menu.
    static __weak NSMenu *observedMenu;
    static void (^addItem)(void);
    addItem = ^{
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
                dispatch_async(dispatch_get_main_queue(), addItem);
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

// In compatibility mode (and older SDK emulation), SwiftUI asks legacy AppKit controls
// for attributes like AXSubrole, AXIsElement, etc. that older AppKit implementations
// don't declare. AppKit throws NSAccessibilityException for undeclared attributes,
// crashing the app as soon as an accessibility client (window manager, screen capture,
// System Events) inspects the window hierarchy.
//
// We catch and suppress NSAccessibilityException on accessibilityAttributeValue: for
// NSView, NSWindow, and NSCell (returning nil instead of uncaught exception),
// as well as interposing the C entry point NSAccessibilityAttributeValue.
#define DYLD_INTERPOSE(replacement, replacee) \
    __attribute__((used)) static struct { const void *replacement; const void *replacee; } _interpose_##replacee \
    __attribute__((section("__DATA,__interpose"))) = { (const void *)(unsigned long)&replacement, (const void *)(unsigned long)&replacee }

extern id NSAccessibilityAttributeValue(id element, NSString *attribute);

static id devitrify_NSAccessibilityAttributeValue(id element, NSString *attribute) {
    @try {
        return NSAccessibilityAttributeValue(element, attribute);
    } @catch (NSException *ex) {
        if ([ex.name isEqualToString:@"NSAccessibilityException"]) return nil;
        @throw;
    }
}

DYLD_INTERPOSE(devitrify_NSAccessibilityAttributeValue, NSAccessibilityAttributeValue);

static IMP s_orig_view_attr_value = NULL;
static id swizzled_view_attributeValue(id self, SEL _cmd, NSString *attribute) {
    @try {
        return ((id (*)(id, SEL, NSString *))s_orig_view_attr_value)(self, _cmd, attribute);
    } @catch (NSException *ex) {
        if ([ex.name isEqualToString:@"NSAccessibilityException"]) return nil;
        @throw;
    }
}

static IMP s_orig_win_attr_value = NULL;
static id swizzled_win_attributeValue(id self, SEL _cmd, NSString *attribute) {
    @try {
        return ((id (*)(id, SEL, NSString *))s_orig_win_attr_value)(self, _cmd, attribute);
    } @catch (NSException *ex) {
        if ([ex.name isEqualToString:@"NSAccessibilityException"]) return nil;
        @throw;
    }
}

static IMP s_orig_cell_attr_value = NULL;
static id swizzled_cell_attributeValue(id self, SEL _cmd, NSString *attribute) {
    @try {
        return ((id (*)(id, SEL, NSString *))s_orig_cell_attr_value)(self, _cmd, attribute);
    } @catch (NSException *ex) {
        if ([ex.name isEqualToString:@"NSAccessibilityException"]) return nil;
        @throw;
    }
}

static IMP s_orig_cell_attributeNames = NULL;
static NSArray *swizzled_cell_attributeNames(id self, SEL _cmd) {
    NSArray *names = ((NSArray *(*)(id, SEL))s_orig_cell_attributeNames)(self, _cmd);
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

__attribute__((constructor))
static void DevitrifyInit(void) {
    @autoreleasepool {
        s_keepsLiquidGlass = dv_keepsLiquidGlassViaLoader();
        s_liquidGlassOffSystemWide = s_keepsLiquidGlass || !_os_feature_enabled_impl("SwiftUI", "Solarium");
        BOOL solariumOn = _os_feature_enabled_impl("SwiftUI", "Solarium");
        if (solariumOn) {
            dv_installGlassFilterNeutralization();
            if (dv_keepsLiquidGlassViaLoader() && !dv_compatibilityModeViaLoader()) dv_installClassicAppKit();
            if (dv_compatibilityModeViaLoader()) dv_installCompatibilityAccessibilityFix();
        } else {
            dv_installFrostedGlassFallback();
        }
        dv_installModernMenus(solariumOn);
        dv_installKeepLiquidGlassItem();
    }
}
