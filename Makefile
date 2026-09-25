APP_NAME := AFK
APP_BUNDLE := $(APP_NAME).app
BUILD_DIR := $(shell swift build -c release --show-bin-path 2>/dev/null || echo .build/release)
CODESIGN_IDENTITY ?= -

.PHONY: build clean run install

build:
	swift build -c release
	$(eval BUILD_DIR := $(shell swift build -c release --show-bin-path))
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS
	mkdir -p $(APP_BUNDLE)/Contents/Resources
	cp $(BUILD_DIR)/$(APP_NAME) $(APP_BUNDLE)/Contents/MacOS/
	cp Info.plist $(APP_BUNDLE)/Contents/
	codesign --force --sign "$(CODESIGN_IDENTITY)" $(APP_BUNDLE)
	@echo "✅ Built $(APP_BUNDLE)"

run: build
	open $(APP_BUNDLE)

clean:
	swift package clean
	rm -rf $(APP_BUNDLE) .build

install: build
	rm -rf /Applications/$(APP_BUNDLE)
	cp -R $(APP_BUNDLE) /Applications/
	@echo "✅ Installed /Applications/$(APP_BUNDLE)"
