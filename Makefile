CC = clang
ARCHS = -arch arm64 -arch arm64e
CFLAGS = -O2 -Wall -Wextra $(ARCHS)
INSTALL_DIR = /Users/Shared/.devitrify

# codesign must not run with a previous Devitrify build injected into it.
SIGN = env -u DYLD_INSERT_LIBRARIES codesign -s - -f

all: build/libDevitrify.dylib build/DevitrifyCore.dylib build/devitrify-menubar

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

clean:
	rm -rf build

.PHONY: all clean
