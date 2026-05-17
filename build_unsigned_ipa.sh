#!/bin/bash
# Build a TrollStore/ldid-ready IPA for the iOS app and packet tunnel extension.
#
# Usage:
#   ./build_unsigned_ipa.sh
#
# Output:
#   build/unsigned-ipa/AwgScale-trollstore.ipa
#
# Note:
#   TrollStore still needs device-side ldid or a pre-applied CoreTrust bypass
#   to finish installation. TrollStore error 173 means ldid is missing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

SCHEME="AwgScale"
PROJECT="AwgScale.xcodeproj"
CONFIGURATION="Release"
SDK="iphoneos"
OUTPUT_IPA_REL="build/unsigned-ipa/AwgScale-trollstore.ipa"
DERIVED_DATA_REL="build/unsigned-ipa/DerivedData"
SIGN_MODE="trollstore"
TEAM_ID="TROLLSTORE"

usage() {
    cat <<'EOF'
Build an IPA for TrollStore or later re-signing.

Default mode builds without Xcode provisioning, then ad-hoc signs the app and
extension with the entitlements TrollStore needs to read. TrollStore will still
need device-side ldid or a pre-applied CoreTrust bypass to finish installation.
TrollStore error 173 means ldid is missing in TrollStore Settings.

Options:
    --scheme NAME           Xcode scheme to build (default: AwgScale)
    --project PATH          Xcode project path relative to project root (default: AwgScale.xcodeproj)
    --configuration NAME    Build configuration (default: Release)
    --out PATH              Output IPA path relative to project root or absolute path
    --derived-data PATH     DerivedData path relative to project root or absolute path
  --team-id ID            Fake team ID for ad-hoc entitlements (default: TROLLSTORE)
  --pure-unsigned         Strip signatures and do not embed entitlements
  -h, --help              Show this help
EOF
}

plist_value() {
    /usr/bin/plutil -extract "$2" raw -o - "$1"
}

write_entitlements() {
    local output_path="$1"
    local bundle_id="$2"

    cat >"$output_path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>application-identifier</key>
    <string>${TEAM_ID}.${bundle_id}</string>
    <key>com.apple.developer.team-identifier</key>
    <string>${TEAM_ID}</string>
    <key>com.apple.security.application-groups</key>
    <array>
        <string>group.top.yesican.awgscale</string>
    </array>
    <key>keychain-access-groups</key>
    <array>
        <string>${TEAM_ID}.top.yesican.awgscale.shared</string>
    </array>
    <key>com.apple.developer.networking.networkextension</key>
    <array>
        <string>packet-tunnel-provider</string>
    </array>
    <key>get-task-allow</key>
    <true/>
</dict>
</plist>
EOF
}

codesign_common_args() {
    local args=(--force --sign - --timestamp=none)
    if /usr/bin/codesign --help 2>&1 | grep -q -- '--generate-entitlement-der'; then
        args+=(--generate-entitlement-der)
    fi
    printf '%s\0' "${args[@]}"
}

ad_hoc_sign_bundle() {
    local bundle_path="$1"
    local entitlements_path="${2:-}"
    local args=()

    while IFS= read -r -d '' arg; do
        args+=("$arg")
    done < <(codesign_common_args)

    if [[ -n "$entitlements_path" ]]; then
        args+=(--entitlements "$entitlements_path")
    fi

    /usr/bin/codesign "${args[@]}" "$bundle_path"
}

strip_signatures() {
    local app_path="$1"

    find "$app_path" -depth \( \
        -name '*.app' -o \
        -name '*.appex' -o \
        -name '*.framework' -o \
        -name '*.dylib' \
    \) -print0 | while IFS= read -r -d '' path; do
        /usr/bin/codesign --remove-signature "$path" >/dev/null 2>&1 || true
    done

    find "$app_path" \( \
        -name '_CodeSignature' -o \
        -name 'CodeResources' -o \
        -name '*.xcent' \
    \) -print0 | while IFS= read -r -d '' path; do
        rm -rf "$path"
    done
}

sign_for_trollstore() {
    local app_path="$1"
    local entitlements_dir="$2"
    local app_bundle_id

    app_bundle_id="$(plist_value "$app_path/Info.plist" CFBundleIdentifier)"
    write_entitlements "$entitlements_dir/app.entitlements" "$app_bundle_id"

    echo "==> Ad-hoc signing embedded frameworks"
    find "$app_path" -type d -name '*.framework' -print0 | while IFS= read -r -d '' framework_path; do
        ad_hoc_sign_bundle "$framework_path"
    done

    echo "==> Ad-hoc signing app extensions with entitlements"
    find "$app_path/PlugIns" -maxdepth 1 -type d -name '*.appex' -print0 2>/dev/null | while IFS= read -r -d '' extension_path; do
        local extension_bundle_id
        local extension_entitlements
        extension_bundle_id="$(plist_value "$extension_path/Info.plist" CFBundleIdentifier)"
        extension_entitlements="$entitlements_dir/$(basename "$extension_path").entitlements"
        write_entitlements "$extension_entitlements" "$extension_bundle_id"
        ad_hoc_sign_bundle "$extension_path" "$extension_entitlements"
    done

    echo "==> Ad-hoc signing app with entitlements"
    ad_hoc_sign_bundle "$app_path" "$entitlements_dir/app.entitlements"
}

resolve_path() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *) printf '%s/%s\n' "$SCRIPT_DIR" "$1" ;;
    esac
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --scheme)
            SCHEME="$2"
            shift 2
            ;;
        --project)
            PROJECT="$2"
            shift 2
            ;;
        --configuration)
            CONFIGURATION="$2"
            shift 2
            ;;
        --out)
            OUTPUT_IPA_REL="$2"
            shift 2
            ;;
        --derived-data)
            DERIVED_DATA_REL="$2"
            shift 2
            ;;
        --team-id)
            TEAM_ID="$2"
            shift 2
            ;;
        --pure-unsigned)
            SIGN_MODE="unsigned"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

PROJECT_PATH="$(resolve_path "$PROJECT")"
OUTPUT_IPA="$(resolve_path "$OUTPUT_IPA_REL")"
DERIVED_DATA_PATH="$(resolve_path "$DERIVED_DATA_REL")"
OUTPUT_DIR="$(dirname "$OUTPUT_IPA")"
STAGING_DIR="$OUTPUT_DIR/staging"
PAYLOAD_DIR="$STAGING_DIR/Payload"
ENTITLEMENTS_DIR="$STAGING_DIR/entitlements"

if [[ ! -d "$PROJECT_PATH" ]]; then
    echo "Xcode project not found: $PROJECT_PATH" >&2
    exit 1
fi

if [[ ! -d "$SCRIPT_DIR/Libtailscale.xcframework" ]]; then
    echo "Missing Libtailscale.xcframework. Run ./build_go.sh --device or ./build_go.sh --all first." >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
rm -rf "$STAGING_DIR"
mkdir -p "$PAYLOAD_DIR"
mkdir -p "$ENTITLEMENTS_DIR"

PRODUCTS_DIR="$DERIVED_DATA_PATH/Build/Products/${CONFIGURATION}-${SDK}"
EXPECTED_APP_PATH="$PRODUCTS_DIR/${SCHEME}.app"

echo "==> Building ${SCHEME} (${CONFIGURATION}, ${SDK}) without code signing"
xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -sdk "$SDK" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    build

APP_PATH="$EXPECTED_APP_PATH"
if [[ ! -d "$APP_PATH" ]]; then
    APP_PATH="$(find "$PRODUCTS_DIR" -maxdepth 1 -type d -name '*.app' | head -n 1)"
fi

if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
    echo "Built app bundle not found under: $PRODUCTS_DIR" >&2
    exit 1
fi

APP_BASENAME="$(basename "$APP_PATH")"
STAGED_APP_PATH="$PAYLOAD_DIR/$APP_BASENAME"

echo "==> Copying app bundle into Payload/"
ditto "$APP_PATH" "$STAGED_APP_PATH"

echo "==> Removing stale signatures from staged bundle"
strip_signatures "$STAGED_APP_PATH"

if [[ "$SIGN_MODE" == "trollstore" ]]; then
    sign_for_trollstore "$STAGED_APP_PATH" "$ENTITLEMENTS_DIR"
else
    echo "==> Leaving staged bundle unsigned"
fi

rm -f "$OUTPUT_IPA"

echo "==> Packaging IPA"
(
    cd "$STAGING_DIR"
    /usr/bin/zip -qry "$OUTPUT_IPA" Payload
)

IPA_SIZE="$(du -h "$OUTPUT_IPA" | awk '{print $1}')"

echo ""
if [[ "$SIGN_MODE" == "trollstore" ]]; then
    echo "TrollStore/ldid-ready IPA created: $OUTPUT_IPA"
else
    echo "Unsigned IPA created: $OUTPUT_IPA"
fi
echo "Size: $IPA_SIZE"
echo ""
if [[ "$SIGN_MODE" == "trollstore" ]]; then
    echo "Entitlements embedded for TrollStore. Inspect with: codesign -d --entitlements :- Payload/AwgScale.app"
    echo "If TrollStore returns 173, install ldid from TrollStore Settings and retry this same IPA."
else
    echo "Pure unsigned mode has no embedded entitlements and may fail TrollStore dumpEntitlements."
fi
