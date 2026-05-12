#!/bin/bash
# Build Libtailscale.xcframework for iOS using gomobile bind.
#
# Prerequisites:
#   - Go toolchain (matching go.mod's go directive)
#   - gomobile: go install golang.org/x/mobile/cmd/gomobile@latest
#   - gobind:   go install golang.org/x/mobile/cmd/gobind@latest
#
# Usage:
#   cd ios/ && ./build_go.sh
#
# Output:
#   ios/Libtailscale.xcframework  — import this in Xcode

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

OUTPUT="Libtailscale.xcframework"

# Parse arguments
# Usage: ./build_go.sh [--sim | --device | --all]
#   --device  : Build for real device only (ios/arm64) — default
#   --sim     : Build for simulator only (iossimulator/arm64)
#   --all     : Build for both device and simulator
TARGET_FLAG="ios/arm64"
case "${1:-}" in
    --sim)
        TARGET_FLAG="iossimulator/arm64"
        ;;
    --all)
        TARGET_FLAG="ios/arm64,iossimulator/arm64"
        ;;
    --device|"")
        TARGET_FLAG="ios/arm64"
        ;;
    *)
        echo "Usage: $0 [--device | --sim | --all]"
        exit 1
        ;;
esac

MOBILE_VERSION="$(go list -m -f '{{.Version}}' golang.org/x/mobile)"
GOBIN_DIR="$(go env GOBIN)"
if [[ -z "$GOBIN_DIR" ]]; then
    GOBIN_DIR="$(go env GOPATH)/bin"
fi
export PATH="$GOBIN_DIR:$PATH"

# Ensure gomobile and gobind are available, pinned to the x/mobile version in go.mod.
if ! command -v gomobile &>/dev/null || ! command -v gobind &>/dev/null; then
    echo "gomobile or gobind not found. Installing golang.org/x/mobile ${MOBILE_VERSION}..."
    go install "golang.org/x/mobile/cmd/gomobile@${MOBILE_VERSION}"
    go install "golang.org/x/mobile/cmd/gobind@${MOBILE_VERSION}"
fi

# Initialize gomobile for iOS/Xcode paths.
gomobile init

# Clean previous build
rm -rf "$OUTPUT"

echo "Building $OUTPUT (target: $TARGET_FLAG) from ./libtailscale ..."

gomobile bind \
    -target "$TARGET_FLAG" \
    -o "$OUTPUT" \
    -iosversion 15.0 \
    -ldflags="-s -w" \
    ./libtailscale

# Some gomobile/Xcode combinations emit framework Info.plist files with
# MinimumOSVersion=100.0 even when -iosversion is set. Normalize the embedded
# framework plists so Xcode can select both device and simulator slices.
find "$OUTPUT" -path "*/Libtailscale.framework/Info.plist" -print0 | while IFS= read -r -d '' plist; do
    plutil -replace MinimumOSVersion -string 15.0 "$plist"
done

echo ""
echo "Success: $OUTPUT"
ls -lh "$OUTPUT"
echo ""
echo "Next: add $OUTPUT to the Xcode project's PacketTunnel target (Frameworks, Libraries, and Embedded Content)."
echo "For TrollStore or real-device testing, build with --device or --all so the xcframework contains ios/arm64."
