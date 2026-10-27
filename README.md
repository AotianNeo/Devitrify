# Devitrify

Devitrify turns Liquid Glass back into frosted glass on macOS Tahoe and macOS Golden Gate.

With Liquid Glass disabled, apps that still use glass views such as `NSGlassEffectView` draw them fully transparent, leaving text floating over whatever is behind the window. Devitrify replaces every one of them with classic frosted glass, without any per-app configuration. Where Liquid Glass stays on, it strips the refraction and keeps a plain blur.

## Usage
1. [Turn off System Integrity Protection](https://developer.apple.com/documentation/security/disabling-and-enabling-system-integrity-protection) by running `csrutil disable` in recoveryOS
2. Install the Xcode Command Line Tools by running `xcode-select --install`
3. Download [Devitrify](https://codeload.github.com/AotianNeo/Devitrify/zip/refs/heads/main) and unzip it
4. Open Terminal and run `~/Downloads/Devitrify-main/devitrify`
5. When the script lists apps that were already running, let it quit and reopen them so they load Devitrify

This has been tested on macOS Golden Gate 27.2. The script checks that the `amfi_get_out_of_my_way=0x1` and `-arm64e_preview_abi` boot arguments are set, offers to add them if they are missing (run the script again after the reboot), builds Devitrify from source, copies it to `/Users/Shared/.devitrify` and installs a login agent that loads it into every app you open.

To uninstall, run `~/Downloads/Devitrify-main/devitrify` again, then log out and back in. To clear the boot argument change, run `sudo nvram -d boot-args`.

## Screenshot
<img width="1920" alt="Devitrify frosted glass showcase across Calculator, System Alert, Spotlight, and Control Center with Solarium disabled" src="assets/showcase.png" />

<img width="1920" alt="The same glass panel with Liquid Glass, with Liquid Glass disabled, and with Liquid Glass disabled plus Devitrify" src="assets/screenshot.png" />

## Tip: Disable Liquid Glass
Devitrify is meant to be used with Liquid Glass (`SwiftUI/Solarium`) disabled system-wide. To disable Liquid Glass, open Terminal and run the following command. You won't see your password as you type. Changes take effect after restart.

```bash
sudo mkdir -p /Library/Preferences/FeatureFlags/Domain
sudo defaults write /Library/Preferences/FeatureFlags/Domain/SwiftUI.plist Solarium -dict Enabled -bool false
```

With `Solarium` disabled system-wide, Devitrify automatically keeps all system components (`ControlCenter`, `NotificationCenter`, `Spotlight` / `Siri AI`, `NSAlert` dialogs, SwiftUI `.glassEffect()` apps like `Calculator`, and Mac Catalyst apps like `FindMy`) working out of the box with classic window chrome, native drop shadows, and uniform Gaussian frosted blur—without requiring per-process `FEATUREFLAGS_ENABLED=SwiftUI/Solarium` overrides.

To re-enable Liquid Glass, open Terminal and run the following command. Changes take effect after restart.

```bash
sudo defaults delete /Library/Preferences/FeatureFlags/Domain/SwiftUI.plist
```

## Tip: Zero-restart Hot Reload
You can modify `DevitrifyCore.m` or adjust blur settings and re-apply changes live across all running apps in real-time without restarting them:

```bash
make reload
# Or directly run:
/Users/Shared/.devitrify/devitrify-reload
```

This compiles a new generation core dylib, broadcasts the `com.aotianneo.devitrify.reload` Darwin IPC notification to all active Cocoa applications, and updates active window layers and menu caches in-place in <50ms.

## Tip: Customize the blur radius
Where Liquid Glass stays on, Devitrify blurs with a radius of 25 points. You can change it globally by writing to `/Users/Shared/.devitrify/blur-radius` and running `make reload`, or setting `DEVITRIFY_BLUR_RADIUS`:

```bash
echo 30 > /Users/Shared/.devitrify/blur-radius
make reload
```

## Tip: Reload apps that are already running
Apps and services only load Devitrify when they launch. To reload the ones that were started before Devitrify was loaded, for example windows restored at login, open Terminal and run the following command. It lists them first and asks before quitting and reopening the apps and before letting launchd restart the services, such as Finder and SystemUIServer. With Liquid Glass disabled, it only picks apps that use `NSGlassEffectView`, because nothing changes for the others. Services under `/System/Library` are always listed, because they use glass from system frameworks that can't be checked.

```
/Users/Shared/.devitrify/devitrify-refresh
```

Add `-n` to only list them. Add bundle identifiers such as `com.apple.Music` to reload only those apps, even if they already have Devitrify loaded.

## Apps that use SwiftUI glass
Apps built with SwiftUI's `.glassEffect()` lose their glass shapes and can render transparent when Liquid Glass is disabled globally. Devitrify handles this completely automatically across all apps: native glass rendering is active by default with all liquid refraction neutralized into crisp frosted blur, while AppKit controls and menus always remain 100% classic (22pt height, full dark shadows). You never need to manually whitelist apps.

If you ever wish to explicitly disable glass for a specific app (opt-out blacklist), you can configure `/Users/Shared/.devitrify/liquid-glass-apps`, named by the app name without `.app`:

```
Calculator off
```

A line with only a name turns the compatibility mode on, `off` turns it off and `stable` keeps Liquid Glass with SwiftUI's own controls in the new style. Reload the app afterwards:

```
/Users/Shared/.devitrify/devitrify-refresh com.apphousekitchen.aldente-pro
```

Sandboxed apps, which include most apps that come with macOS, can't read that file. They keep a marker file in their own container instead, whose content is `compat`, `stable` or `off`:

```
echo off > ~/Library/Containers/com.apple.calculator/Data/Library/Application\ Support/devitrify-keep-liquid-glass
```

## How it works
- `libDevitrify.dylib` is injected into every process through `DYLD_INSERT_LIBRARIES`. It links nothing beyond `libSystem` and loads `DevitrifyCore.dylib` only into GUI processes that link `AppKit`, so command-line tools are unaffected.
- At image load time, `libDevitrify.dylib` hooks `SwiftUICore`'s `Solarium.computeValues()` (the single source of truth for SwiftUI glass enablement) to upgrade `.off (0)` to `.compatibility (1)` across all desktop apps, `ControlCenter`, and `NotificationCenter`. In `.compatibility (1)` mode, SwiftUI's `Solarium.isCompatibilityEnabled(.mac)` returns `true` so `.glassEffect()`, `.buttonStyle(.glass)`, and `ControlCenter` / `NotificationCenter` `CABackdropLayer` trees remain intact, while `Solarium.isEnabled(.mac)` returns `false` so window toolbars and navigation chrome stay classic.
- For processes that require full `Solarium` semantics to construct their view hierarchy (`SpotlightUIInternal` / `Siri AI` and Mac Catalyst `UIKitCore` apps such as `FindMy`), the loader resolves `_os_feature_enabled_impl("SwiftUI", "Solarium")` to `true` while `DevitrifyCore.dylib` swizzles `AppKit`'s `_NSSolariumEnabled` to `false` (except inside `NSAlert` / `_NSAlertPanel` init frames, preserving native alert glass and drop shadows).
- Inside `QuartzCore`, `DevitrifyCore.dylib` intercepts `CAFilter` and `CASDFKeyFillHighlightEffect`:
  - `glassBackground` and `glassForeground` have their refraction (`inputLensingPower`, `inputRefractionHeight`), edge bleed (`inputBleedAmount`), and chromatic aberration (`inputAbberation` / `inputChromaticAberration`) zeroed out, with `inputBlurRadius` set to a uniform Gaussian frosted blur (`25pt` by default) while preserving native `inputShadow*` parameters.
  - `CASDFKeyFillHighlightEffect` has its `keyColor` and `fillColor` neutralized to `kCGColorClear` (`rgba(0,0,0,0)`), eliminating the 3D specular Liquid Glass rim across SwiftUI and `ControlCenter` tiles without breaking `CA::Render::SDFLayer` validation.
- For AppKit `NSGlassEffectView` instances when `_NSSolariumEnabled` is `false`, `DevitrifyCore.dylib` inserts an `NSVisualEffectView` clipped to the glass corner radius (`BehindWindow` for root glass views, `WithinWindow` for nested controls).
- `devitrify-menubar` keeps the compact 33-point notched menu bar height in `WindowServer` while `SwiftUI/Solarium` is disabled system-wide, dynamically resolving `SkyLight.framework` instructions without hardcoded offsets so it remains effective across macOS updates.

## Limitations
- The custom tint color of `NSGlassEffectView` is approximated using standard `NSVisualEffectView` materials when `_NSSolariumEnabled` is `false`.
- Apps restored at login before the login agent runs start without Devitrify until they are reopened, for example with `devitrify-refresh`.
- Sandboxed app extensions, such as the panes of System Settings, don't load Devitrify. They don't need it: with Liquid Glass disabled they already draw classic controls.
