APP_NAME := AFK
APP_BUNDLE := $(APP_NAME).app
BUILD_DIR := $(shell swift build -c release --show-bin-path 2>/dev/null || echo .build/release)
DEV_CERT := AFK Local Dev

# Stable signing keeps Accessibility/Microphone TCC grants across rebuilds.
# Prefer a trusted "AFK Local Dev" identity (make dev-cert); else any Apple
# Development identity; ad-hoc ("-") only for local ./AFK.app smoke tests —
# `make install` refuses ad-hoc because it resets permissions every build.
CODESIGN_IDENTITY ?= $(shell \
	if security find-identity -v -p codesigning 2>/dev/null | grep -F '"$(DEV_CERT)"' >/dev/null; then \
		echo "$(DEV_CERT)"; \
	elif id=$$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -1); then \
		test -n "$$id" && echo "$$id" || echo -; \
	else echo -; fi)

.PHONY: build clean run install dev-cert api-key icons check-sign

check-sign:
	@id="$(CODESIGN_IDENTITY)"; \
	if [ "$$id" = "-" ] || [ -z "$$id" ]; then \
		echo "❌ No stable code-signing identity."; \
		echo "   Ad-hoc signing changes the CDHash on every build, so macOS"; \
		echo "   forgets Accessibility / Microphone grants."; \
		echo ""; \
		echo "   Fix (pick one):"; \
		echo "     make dev-cert    # once: self-signed '$(DEV_CERT)' (then trust it for Code Signing in Keychain Access)"; \
		echo "     # or install Xcode and sign in so an Apple Development identity appears"; \
		echo "   Then: make install"; \
		exit 1; \
	fi; \
	echo "✅ Signing as $$id"

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
	@id="$(CODESIGN_IDENTITY)"; \
	if [ "$$id" = "-" ] || [ -z "$$id" ]; then \
		echo "⚠️  Signing ad-hoc — Accessibility/Mic will reset on every rebuild."; \
		echo "   Run \`make dev-cert\` (or use an Apple Development identity), then \`make install\`."; \
		codesign --force --sign - $(APP_BUNDLE); \
	else \
		codesign --force --sign "$$id" $(APP_BUNDLE); \
		echo "✅ Signed with $$id"; \
	fi
	@echo "✅ Built $(APP_BUNDLE)"

run: build
	open $(APP_BUNDLE)

clean:
	swift package clean
	rm -rf $(APP_BUNDLE) .build

install: check-sign build
	# Replace in place so the path stays /Applications/AFK.app (stable for TCC).
	rm -rf /Applications/$(APP_BUNDLE)
	cp -R $(APP_BUNDLE) /Applications/
	@codesign -dv --verbose=4 /Applications/$(APP_BUNDLE) 2>&1 | grep -E '^(Identifier|Signature|TeamIdentifier|Authority)=' || true
	@echo "✅ Installed /Applications/$(APP_BUNDLE)"
	@echo "   If this is the first stable-signed install, grant Accessibility + Microphone once in"
	@echo "   System Settings → Privacy & Security (remove any old ad-hoc 'AFK' ghosts first)."

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
