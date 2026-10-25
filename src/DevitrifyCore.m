#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

@interface CAFilter : NSObject
+ (instancetype)filterWithType:(NSString *)type;
- (NSString *)type;
- (NSArray *)inputKeys;
@end

extern bool _os_feature_enabled_impl(const char *domain, const char *feature);

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

#pragma mark - Master Constructor

__attribute__((constructor))
static void DevitrifyInit(void) {
    @autoreleasepool {
        if (_os_feature_enabled_impl("SwiftUI", "Solarium")) {
            dv_installGlassFilterNeutralization();
            if (getenv("DEVITRIFY_LIQUID_GLASS_APP")) dv_installClassicAppKit();
        } else {
            dv_installFrostedGlassFallback();
        }
    }
}
