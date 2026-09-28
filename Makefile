APP_NAME := AFK
APP_BUNDLE := $(APP_NAME).app
BUILD_DIR := $(shell swift build -c release --show-bin-path 2>/dev/null || echo .build/release)
DEV_CERT := AFK Local Dev

# Stable signing keeps Accessibility/Microphone TCC grants across rebuilds.
# Prefer a trusted "AFK Local Dev" identity (make dev-cert); else any Apple
# Development identity; ad-hoc ("-") only for local ./AFK.app smoke tests —
# `make install` refuses ad-hoc because it resets permissions every build.
# With the Developer ID profile present (iCloud), sign with Developer ID: that profile only
# accepts Developer ID certificates, and it gives local builds the same identity as releases.
CODESIGN_IDENTITY ?= $(shell \
	if [ -f "Supporting/AFK.provisionprofile" ] && id=$$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1) && [ -n "$$id" ]; then \
		echo "$$id"; \
	elif security find-identity -v -p codesigning 2>/dev/null | grep -F '"$(DEV_CERT)"' >/dev/null; then \
		echo "$(DEV_CERT)"; \
	elif id=$$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -1); then \
		test -n "$$id" && echo "$$id" || echo -; \
	else echo -; fi)

# iCloud vocabulary sync (Supporting/AFK.entitlements) needs a provisioning profile with
# iCloud key-value storage. Put it at $(PROVISIONING_PROFILE) to embed it; without one,
# builds use AFK.local.entitlements (no iCloud) so macOS still launches the app.
PROVISIONING_PROFILE ?= Supporting/AFK.provisionprofile
ENTITLEMENTS ?= $(if $(wildcard $(PROVISIONING_PROFILE)),Supporting/AFK.entitlements,Supporting/AFK.local.entitlements)

.PHONY: build clean run install dmg dev-cert api-key icons check-sign signing-status

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

# Read-only report: Apple Development vs Developer ID vs notary profile.
# Does not create certs or store credentials. See docs/DISTRIBUTION.md.
signing-status:
	./scripts/check-signing.sh


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
	@if [ -f "$(PROVISIONING_PROFILE)" ]; then \
		cp "$(PROVISIONING_PROFILE)" $(APP_BUNDLE)/Contents/embedded.provisionprofile; \
		echo "✅ Embedded $(PROVISIONING_PROFILE) (iCloud vocabulary sync on)"; \
	else \
		echo "ℹ️  No $(PROVISIONING_PROFILE): signing without iCloud (vocabulary stays local)"; \
	fi
	@id="$(CODESIGN_IDENTITY)"; \
	if [ "$$id" = "-" ] || [ -z "$$id" ]; then \
		echo "⚠️  Signing ad-hoc — Accessibility/Mic will reset on every rebuild."; \
		echo "   Run \`make dev-cert\` (or use an Apple Development identity), then \`make install\`."; \
		codesign --force --sign - --entitlements $(ENTITLEMENTS) $(APP_BUNDLE); \
	else \
		codesign --force --sign "$$id" --entitlements $(ENTITLEMENTS) $(APP_BUNDLE); \
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

# Package AFK.app into dist/AFK-VERSION.dmg (drag-to-Applications).
# Uses the signature from `make build`. Not notarized — see docs/DISTRIBUTION.md.
dmg: build
	./scripts/make-dmg.sh

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
