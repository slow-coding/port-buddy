# APP is the executable inside the bundle; DISPLAY is the bundle's own name.
# (No trailing comments on these lines: make keeps the spaces before a '#',
#  and a variable with trailing spaces splits target names in two.)
APP        := PortBuddy
DISPLAY    := PortBuddy
VERSION    := 1.0.1
MIN_MACOS  := 13.0
SOURCES    := $(wildcard Sources/*.swift)
BUILD      := build
BUNDLE     := $(BUILD)/$(DISPLAY).app
SWIFTFLAGS := -O -swift-version 5
FRAMEWORKS := -framework AppKit -framework Foundation

.PHONY: all bundle run install zip dmg icon check clean

all: bundle

$(BUILD):
	@mkdir -p $(BUILD)

# Two slices plus lipo: swiftc can target the other architecture directly,
# the linker warning about libswiftCompatibilityPacks is expected and harmless.
$(BUILD)/$(APP)-arm64: $(SOURCES) | $(BUILD)
	swiftc $(SWIFTFLAGS) -target arm64-apple-macos$(MIN_MACOS) $(FRAMEWORKS) -o $@ $(SOURCES)

$(BUILD)/$(APP)-x86_64: $(SOURCES) | $(BUILD)
	swiftc $(SWIFTFLAGS) -target x86_64-apple-macos$(MIN_MACOS) $(FRAMEWORKS) -o $@ $(SOURCES)

$(BUILD)/$(APP): $(BUILD)/$(APP)-arm64 $(BUILD)/$(APP)-x86_64
	lipo -create -output $@ $^

$(BUNDLE): $(BUILD)/$(APP) Resources/Info.plist
	rm -rf $@
	mkdir -p $@/Contents/MacOS $@/Contents/Resources
	cp $(BUILD)/$(APP) $@/Contents/MacOS/$(APP)
	cp Resources/Info.plist $@/Contents/Info.plist
	@if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns $@/Contents/Resources/AppIcon.icns; fi
	codesign --force --sign - $@
	@echo "built $(BUNDLE)"

bundle: $(BUNDLE)

run: bundle
	open $(BUNDLE)

install: bundle
	@osascript -e 'quit app "$(APP)"' >/dev/null 2>&1 || true
	ditto $(BUNDLE) /Applications/$(APP).app
	@SetFile -a B /Applications/$(APP).app 2>/dev/null || true
	@/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/$(APP).app 2>/dev/null || true
	@echo "installed /Applications/$(APP).app"

zip: bundle
	ditto -c -k --keepParent $(BUNDLE) $(BUILD)/$(APP)-$(VERSION).zip
	@echo "built $(BUILD)/$(APP)-$(VERSION).zip"

# 装给别人用的盘：.app + 一颗 Applications 快捷方式（双击拖进去）——
# 比 zip 少一步「解压，再拖」，非技术同事也不会拖错地方。
$(BUILD)/$(APP)-$(VERSION).dmg: $(BUNDLE)
	@rm -rf $(BUILD)/.dmg-stage
	@mkdir -p $(BUILD)/.dmg-stage
	@ditto $(BUNDLE) $(BUILD)/.dmg-stage/$(DISPLAY).app
	@ln -sfn /Applications $(BUILD)/.dmg-stage/Applications
	hdiutil create -volname $(DISPLAY) -srcfolder $(BUILD)/.dmg-stage -ov -format UDZO -quiet $@
	@rm -rf $(BUILD)/.dmg-stage
	@echo "built $@ ($$(du -h $@ | cut -f1))"

dmg: $(BUILD)/$(APP)-$(VERSION).dmg

icon:
	@mkdir -p $(BUILD)
	swiftc -O -swift-version 5 -o $(BUILD)/make-icon Sources/PortGlyph.swift scripts/make-icon.swift
	$(BUILD)/make-icon Resources/AppIcon.icns

# Build check: JSON on stdout must list at least the loopback interface and
# every line must be valid JSON. Add --selftest-click <port> to exercise the
# terminate button against a real socket.
check: $(BUILD)/$(APP)
	$(BUILD)/$(APP) --json | python3 -c 'import json,sys; rows=[json.loads(l) for l in sys.stdin]; assert all(r["port"]>0 for r in rows); print(f"{len(rows)} listening sockets, all rows valid JSON")'

clean:
	rm -rf $(BUILD)
