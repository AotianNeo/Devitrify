CC = clang
ARCHS = -arch arm64 -arch arm64e
CFLAGS = -O2 -Wall -Wextra $(ARCHS)
INSTALL_DIR = /Users/Shared/.devitrify

# codesign must not run with a previous Devitrify build injected into it.
SIGN = env -u DYLD_INSERT_LIBRARIES codesign -s - -f
SIGN_DEBUG = env -u DYLD_INSERT_LIBRARIES codesign -s - -f --entitlements assets/debugger.entitlements

all: build/libDevitrify.dylib build/DevitrifyCore.dylib build/devitrify-menubar build/devitrify-reload

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

install: all
	mkdir -p $(INSTALL_DIR)
	mkdir -p $(INSTALL_DIR)/reload
	cp build/libDevitrify.dylib $(INSTALL_DIR)/libDevitrify.dylib.new && mv -f $(INSTALL_DIR)/libDevitrify.dylib.new $(INSTALL_DIR)/libDevitrify.dylib
	cp build/DevitrifyCore.dylib $(INSTALL_DIR)/DevitrifyCore.dylib.new && mv -f $(INSTALL_DIR)/DevitrifyCore.dylib.new $(INSTALL_DIR)/DevitrifyCore.dylib
	cp build/devitrify-reload $(INSTALL_DIR)/devitrify-reload.new && mv -f $(INSTALL_DIR)/devitrify-reload.new $(INSTALL_DIR)/devitrify-reload
	chmod +x $(INSTALL_DIR)/devitrify-reload
	cp assets/devitrify-agent $(INSTALL_DIR)/devitrify-agent && chmod +x $(INSTALL_DIR)/devitrify-agent
	cp assets/devitrify-refresh $(INSTALL_DIR)/devitrify-refresh && chmod +x $(INSTALL_DIR)/devitrify-refresh
	mv -f $(INSTALL_DIR)/reload/current ~/.Trash/ 2>/dev/null || true

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

.PHONY: all install reload disable enable status clean
