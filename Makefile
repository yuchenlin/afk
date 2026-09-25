APP_NAME := AFK
APP_BUNDLE := $(APP_NAME).app
BUILD_DIR := $(shell swift build -c release --show-bin-path 2>/dev/null || echo .build/release)
DEV_CERT := AFK Local Dev
# Prefer the stable dev identity (see scripts/make-dev-cert.sh) so Accessibility
# survives rebuilds; fall back to ad-hoc signing.
CODESIGN_IDENTITY ?= $(shell security find-certificate -c "$(DEV_CERT)" >/dev/null 2>&1 && echo "$(DEV_CERT)" || echo -)

.PHONY: build clean run install dev-cert api-key icons

build:
	swift build -c release
	$(eval BUILD_DIR := $(shell swift build -c release --show-bin-path))
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS
	mkdir -p $(APP_BUNDLE)/Contents/Resources
	cp $(BUILD_DIR)/$(APP_NAME) $(APP_BUNDLE)/Contents/MacOS/
	cp Supporting/Info.plist $(APP_BUNDLE)/Contents/
	cp Resources/lexicon.example.txt $(APP_BUNDLE)/Contents/Resources/lexicon.txt
	cp Resources/AppIcon.icns $(APP_BUNDLE)/Contents/Resources/AppIcon.icns
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

dev-cert:
	./scripts/make-dev-cert.sh "$(DEV_CERT)"

# Writes XAI_API_KEY_VOICE to a user-only key file for AFK. Local dev only.
KEY_DIR := $(HOME)/Library/Application Support/AFK
api-key:
	@KEY="$$XAI_API_KEY_VOICE"; \
	test -n "$$KEY" || { echo "Set XAI_API_KEY_VOICE first"; exit 1; }; \
	mkdir -p "$(KEY_DIR)" && chmod 700 "$(KEY_DIR)" && \
	(umask 077; printf '%s' "$$KEY" > "$(KEY_DIR)/xai-api-key") && \
	echo "✅ Wrote $(KEY_DIR)/xai-api-key"

# Regenerates the app icons from Sources/AFKCore/LogoMark.swift (see design/logo/).
icons:
	mkdir -p .build design/icons
	swiftc -O -parse-as-library Sources/AFKCore/LogoMark.swift scripts/make-icons.swift -o .build/make-icons
	.build/make-icons design/icons
	iconutil -c icns design/icons/AppIcon.iconset -o Resources/AppIcon.icns
	@echo "✅ Resources/AppIcon.icns and design/icons/"
