#!/usr/bin/env bash
# Generate AFK.xcodeproj on a Mac (requires XcodeGen: brew install xcodegen).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "Install XcodeGen: brew install xcodegen" >&2
  exit 1
fi
xcodegen generate
echo "Opened path: $ROOT/AFK.xcodeproj"
