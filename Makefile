CC = clang
ARCHS = -arch arm64 -arch arm64e
CFLAGS = -O2 -Wall -Wextra $(ARCHS)
INSTALL_DIR = /Users/Shared/.devitrify
MACOS_MAJOR = $(shell sw_vers -productVersion | cut -d. -f1)
WM_CANONICAL = /System/Library/PrivateFrameworks/WindowManager.framework/Versions/A/WindowManager
DD_CANONICAL = /System/Library/PrivateFrameworks/DynamicDesktop.framework/Versions/A/DynamicDesktop

# codesign and swiftc must not run with a previous Devitrify build injected into them.
SIGN = env -u DYLD_INSERT_LIBRARIES codesign -s - -f
SIGN_DEBUG = env -u DYLD_INSERT_LIBRARIES codesign -s - -f --entitlements assets/debugger.entitlements

all: build/libDevitrify.dylib build/DevitrifyCore.dylib build/devitrify-menubar build/devitrify-reload \
     build/DynamicDesktop.framework/Versions/A/DynamicDesktop build/WindowManagerShim.dylib

build/libDevitrify.dylib: src/loader.c
	mkdir -p build
	$(CC) $(CFLAGS) -dynamiclib -install_name $(INSTALL_DIR)/libDevitrify.dylib $< -o $@
	$(SIGN) $@

build/DevitrifyCore.dylib: src/DevitrifyCore.m
	mkdir -p build
	$(CC) $(CFLAGS) -fobjc-arc -dynamiclib -framework Cocoa -framework QuartzCore \
		-install_name $(INSTALL_DIR)/DevitrifyCore.dylib $< -o $@
	$(SIGN) $@

build/devitrify-menubar: src/menubar.c
	mkdir -p build
	$(CC) -O2 -Wall -Wextra -arch arm64e -F/System/Library/PrivateFrameworks \
		-framework SkyLight -framework CoreGraphics $< -o $@
	$(SIGN) $@

build/devitrify-reload: src/reload.c assets/debugger.entitlements
	mkdir -p build
	$(CC) $(CFLAGS) $< -o $@
	$(SIGN_DEBUG) $@

build/DynamicDesktop.framework/Versions/A/DynamicDesktop: src/DynamicDesktop-shim.c
	mkdir -p build/DynamicDesktop.framework/Versions/A/Resources
	$(CC) -arch x86_64 -arch arm64e -dynamiclib \
		-install_name $(DD_CANONICAL) \
		-compatibility_version 1.0.0 -current_version 2419.0.0 \
		-o $@ $<
	printf '%s\n' \
		'<?xml version="1.0" encoding="UTF-8"?>' \
		'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
		'<plist version="1.0"><dict>' \
		'<key>CFBundleIdentifier</key><string>com.apple.DynamicDesktop</string>' \
		'<key>CFBundleName</key><string>DynamicDesktop</string>' \
		'<key>CFBundleVersion</key><string>2419.0.0</string>' \
		'<key>CFBundleShortVersionString</key><string>1.0</string>' \
		'</dict></plist>' > build/DynamicDesktop.framework/Versions/A/Resources/Info.plist
	ln -sfh A build/DynamicDesktop.framework/Versions/Current
	ln -sfh Versions/Current/DynamicDesktop build/DynamicDesktop.framework/DynamicDesktop
	ln -sfh Versions/Current/Resources build/DynamicDesktop.framework/Resources
	$(SIGN) $@

build/WindowManagerShim.dylib: src/WindowManager.swift src/WindowManager-thunk.s
	mkdir -p build
	@set -e; \
	NEEDS=build/wm-needs.txt; HAVE=build/wm-have.txt; REEXPORT=build/wm-reexport.txt; \
	REALSTUB=build/wm-realstub.s; REALSTUB_DYLIB=build/wm-realstub.dylib; THUNK_O=build/wm-thunk.o; \
	dyld_info -imports assets/Dock.app/Contents/MacOS/Dock 2>/dev/null \
		| grep -i windowmanager | awk '{print $$2}' | grep -E '^_?\$$s' | sed 's/^_//' | sort -u > "$$NEEDS"; \
	dyld_info -exports "$(WM_CANONICAL)" 2>/dev/null \
		| awk '{print $$NF}' | grep -E '^_?\$$s' | sed 's/^_//' | sort -u > "$$HAVE"; \
	comm -12 "$$NEEDS" "$$HAVE" > "$$REEXPORT"; \
	{ echo '.data'; echo '.p2align 3'; \
	  while IFS= read -r s; do printf '.globl "_%s"\n"_%s":\n    .quad 0\n' "$$s" "$$s"; done < "$$REEXPORT"; \
	} > "$$REALSTUB"; \
	$(CC) -arch arm64e -mmacosx-version-min=$(MACOS_MAJOR).0 -c src/WindowManager-thunk.s -o "$$THUNK_O"; \
	$(CC) -arch arm64e -mmacosx-version-min=$(MACOS_MAJOR).0 -dynamiclib -install_name "$(WM_CANONICAL)" \
		-Wl,-not_for_dyld_shared_cache -o "$$REALSTUB_DYLIB" "$$REALSTUB"; \
	env -u DYLD_INSERT_LIBRARIES swiftc -target "arm64e-apple-macos$(MACOS_MAJOR).0" -emit-library -O \
		-module-name WindowManager src/WindowManager.swift "$$THUNK_O" -o $@ \
		-Xlinker -install_name -Xlinker "$(INSTALL_DIR)/Frameworks/WindowManagerShim.dylib" \
		-Xlinker -reexport_library -Xlinker "$$REALSTUB_DYLIB"; \
	mv -f "$$NEEDS" "$$HAVE" "$$REEXPORT" "$$REALSTUB" "$$REALSTUB_DYLIB" "$$THUNK_O" ~/.Trash/ 2>/dev/null || true
	$(SIGN) $@

install: all
	mkdir -p $(INSTALL_DIR) $(INSTALL_DIR)/reload $(INSTALL_DIR)/Frameworks
	cp build/libDevitrify.dylib $(INSTALL_DIR)/libDevitrify.dylib.new && mv -f $(INSTALL_DIR)/libDevitrify.dylib.new $(INSTALL_DIR)/libDevitrify.dylib
	cp build/DevitrifyCore.dylib $(INSTALL_DIR)/DevitrifyCore.dylib.new && mv -f $(INSTALL_DIR)/DevitrifyCore.dylib.new $(INSTALL_DIR)/DevitrifyCore.dylib
	cp build/devitrify-reload $(INSTALL_DIR)/devitrify-reload.new && mv -f $(INSTALL_DIR)/devitrify-reload.new $(INSTALL_DIR)/devitrify-reload
	chmod +x $(INSTALL_DIR)/devitrify-reload
	mv -f $(INSTALL_DIR)/Frameworks/DynamicDesktop.framework ~/.Trash/DynamicDesktop.framework.$$(date +%s) 2>/dev/null || true
	cp -R build/DynamicDesktop.framework $(INSTALL_DIR)/Frameworks/
	cp build/WindowManagerShim.dylib $(INSTALL_DIR)/Frameworks/WindowManagerShim.dylib.new && mv -f $(INSTALL_DIR)/Frameworks/WindowManagerShim.dylib.new $(INSTALL_DIR)/Frameworks/WindowManagerShim.dylib
	cp assets/devitrify-agent $(INSTALL_DIR)/devitrify-agent && chmod +x $(INSTALL_DIR)/devitrify-agent
	cp assets/devitrify-refresh $(INSTALL_DIR)/devitrify-refresh && chmod +x $(INSTALL_DIR)/devitrify-refresh
	mv -f $(INSTALL_DIR)/reload/current ~/.Trash/ 2>/dev/null || true

install-launchpad: install
	@printf "[Devitrify Launchpad] Installing patched Dock.app and Launchpad.app into $(INSTALL_DIR)...\n"
	xattr -cr assets/Dock.app assets/Launchpad.app
	mv -f $(INSTALL_DIR)/Dock.app ~/.Trash/Dock.app.$$(date +%s) 2>/dev/null || true
	cp -R assets/Dock.app $(INSTALL_DIR)/Dock.app
	@if [ "$(MACOS_MAJOR)" -ge 27 ]; then \
		install_name_tool -change "$(WM_CANONICAL)" "$(INSTALL_DIR)/Frameworks/WindowManagerShim.dylib" "$(INSTALL_DIR)/Dock.app/Contents/MacOS/Dock"; \
		DOCK_ENTS=build/dock-ents.plist; \
		env -u DYLD_INSERT_LIBRARIES codesign -d --entitlements "$$DOCK_ENTS" --xml assets/Dock.app 2>/dev/null; \
		env -u DYLD_INSERT_LIBRARIES codesign --force --sign - --entitlements "$$DOCK_ENTS" "$(INSTALL_DIR)/Dock.app/Contents/MacOS/Dock"; \
		mv -f "$$DOCK_ENTS" ~/.Trash/ 2>/dev/null || true; \
	fi
	mv -f /Applications/Launchpad.app ~/.Trash/Launchpad.app.$$(date +%s) 2>/dev/null || true
	cp -R assets/Launchpad.app /Applications/Launchpad.app
	plutil -remove LSRequiredFeatureFlags /Applications/Launchpad.app/Contents/Info.plist 2>/dev/null || true
	mv -f $(INSTALL_DIR)/Launchpad.app ~/.Trash/Launchpad.app.backup.$$(date +%s) 2>/dev/null || true
	cp -R /Applications/Launchpad.app $(INSTALL_DIR)/Launchpad.app

reload: install
	$(INSTALL_DIR)/devitrify-reload

disable: install
	$(INSTALL_DIR)/devitrify-reload --disable

enable: install
	$(INSTALL_DIR)/devitrify-reload --enable

status:
	$(INSTALL_DIR)/devitrify-reload --status

clean:
	mv -f build ~/.Trash/devitrify-build.$$(date +%s) 2>/dev/null || true

.PHONY: all install install-launchpad reload disable enable status clean
