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
# Release builds must use the versioned forks in go.mod, never an ambient
# parent workspace that happens to contain unreleased protocol changes.
export GOWORK=off
# The published core requires Go >= 1.26.6 and is validated against 1.26.6.
# Pin the toolchain so gomobile/gobind and every `go` invocation below build
# with the same compiler used to qualify the release.
export GOTOOLCHAIN=go1.26.6
# Keep caller-provided build flags, but make dependency resolution immutable.
# Appending makes this the effective -mod value if GOFLAGS already contains one.
export GOFLAGS="${GOFLAGS:+$GOFLAGS }-mod=readonly"

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

# Refuse to produce an AwgScale framework from upstream Tailscale or a
# different WireGuard module by accident. These are the AWG v2/v3-compatible
# forks selected by this app's go.mod. The Tailscale pseudo-version carries the
# published packet-transport engine (native/AWG plus built-in QUIC HTTP/3) used
# by this release; QUIC is pinned to the Tailscale-maintained quic-go fork.
TAILSCALE_SOURCE="$(go list -m -f '{{if .Replace}}{{.Replace.Path}}{{else}}{{.Path}}{{end}}' tailscale.com)"
TAILSCALE_VERSION="$(go list -m -f '{{if .Replace}}{{.Replace.Version}}{{else}}{{.Version}}{{end}}' tailscale.com)"
WIREGUARD_SOURCE="$(go list -m -f '{{if .Replace}}{{.Replace.Path}}{{else}}{{.Path}}{{end}}' github.com/LiuTangLei/wireguard-go)"
WIREGUARD_VERSION="$(go list -m -f '{{if .Replace}}{{.Replace.Version}}{{else}}{{.Version}}{{end}}' github.com/LiuTangLei/wireguard-go)"
QUICGO_SOURCE="$(go list -m -f '{{if .Replace}}{{.Replace.Path}}{{else}}{{.Path}}{{end}}' github.com/quic-go/quic-go)"
QUICGO_VERSION="$(go list -m -f '{{if .Replace}}{{.Replace.Version}}{{else}}{{.Version}}{{end}}' github.com/quic-go/quic-go)"

if [[ "$TAILSCALE_SOURCE" != "github.com/LiuTangLei/tailscale" ||
      "$TAILSCALE_VERSION" != "v1.102.5-0.20260916181858-1f00235ed2ce" ]]; then
    echo "error: expected github.com/LiuTangLei/tailscale v1.102.5-0.20260916181858-1f00235ed2ce, got $TAILSCALE_SOURCE $TAILSCALE_VERSION" >&2
    exit 1
fi
if [[ "$WIREGUARD_SOURCE" != "github.com/LiuTangLei/wireguard-go" ||
      "$WIREGUARD_VERSION" != "v0.0.32" ]]; then
    echo "error: expected github.com/LiuTangLei/wireguard-go v0.0.32, got $WIREGUARD_SOURCE $WIREGUARD_VERSION" >&2
    exit 1
fi
if [[ "$QUICGO_SOURCE" != "github.com/LiuTangLei/quic-go" ||
      "$QUICGO_VERSION" != "v0.62.0-tailscale.4" ]]; then
    echo "error: expected github.com/quic-go/quic-go => github.com/LiuTangLei/quic-go v0.62.0-tailscale.4, got $QUICGO_SOURCE $QUICGO_VERSION" >&2
    exit 1
fi
echo "Using $TAILSCALE_SOURCE $TAILSCALE_VERSION"
echo "Using $WIREGUARD_SOURCE $WIREGUARD_VERSION"
echo "Using $QUICGO_SOURCE $QUICGO_VERSION (github.com/quic-go/quic-go)"

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
