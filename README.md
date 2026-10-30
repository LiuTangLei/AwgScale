# AwgScale

**An open source Tailscale-compatible iOS client with Amnezia-WG and QUIC support.**

AwgScale is independent software — not affiliated with, sponsored by, or approved by Tailscale Inc.

---

## 1.104.4

[Download AwgScale 1.104.4](https://github.com/LiuTangLei/AwgScale/releases/tag/v1.104.4).

- Updated Tailscale core to 1.104.4 with native WireGuard, AWG v2/v3 and QUIC.
- Improved network switching, MagicDNS, connection recovery and login storage.
- Fixed Share Sheet cancellation and cleaned up request and logging resources.

Install the IPA with TrollStore, or re-sign it using your Apple developer profile.
QUIC uses HTTP/3 automatically; select QUIC on every communicating peer.

## Which install method are you using?

The Network Extension entitlement controls whether AwgScale can create a system-wide VPN tunnel.

### TrollStore — full features, no Apple account needed

TrollStore installs the app persistently with all entitlements intact. No Apple Developer account is required, and no re-signing is ever needed.

**All features available:**
- System-wide Packet Tunnel VPN — exit nodes, DNS, subnet routes, Tailnet Lock
- Built-in SSH terminal and browser (tailnet + public via exit node)
- Taildrop, AWG config sync, peer diagnostics

### Paid Apple Developer account (Sideloadly, Xcode, etc.)

A paid Apple Developer Program account ($99/year) can request the Network Extension capability for an App ID in the Developer Portal. Signing with that provisioning profile — via Sideloadly, Xcode, or any other tool — produces a fully functional build with system-wide VPN. The certificate is valid for one year.

**All features available** (same as TrollStore), with annual re-signing required.

> In Sideloadly: choose your paid team, import the provisioning profile that includes the Network Extension capability, then sign.

### Free Apple ID signing (Sideloadly default, AltStore personal team, etc.)

Free accounts cannot request the Network Extension entitlement. The app runs in **app-only mode**: tailnet access works inside the app only, no system-wide VPN is created, and certificates expire after 7 days.

**Available in app-only mode:**
- Built-in SSH terminal (connects to tailnet hosts directly)
- Built-in browser with tailnet HTTP access and exit-node public browsing (iOS 17+)

---

## Build

```sh
# Build the Go framework
./build_go.sh --all

# Build the ad-hoc signed IPA for TrollStore or later re-signing
./build_unsigned_ipa.sh
# Output: build/unsigned-ipa/AwgScale-trollstore.ipa
```

Quick validation:

```sh
go test ./libtailscale/...
xcodebuild build -project AwgScale.xcodeproj -scheme AwgScale \
  -configuration Debug -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO
```

`build_go.sh` verifies the published dependencies before compiling:
`github.com/LiuTangLei/tailscale v1.104.4`,
`github.com/LiuTangLei/wireguard-go v0.0.34`, and
`github.com/LiuTangLei/quic-go v0.63.0-tailscale.1.0.20261021083103-10dfe69b6d4c`,
and `github.com/LiuTangLei/utls v1.8.3-0.20261021023852-7effde6a93dc`.
It uses Go 1.27.3 and matching gomobile/gobind tools. `GOWORK=off` prevents
ambient local source replacements. Native AWG v2/v3 and QUIC remain supported.

App-only UI can be developed in the Simulator. The system VPN tunnel requires a device with a valid Network Extension entitlement.

---

## Open Source Projects

Acknowledgements are also visible in the app under **Settings → About AwgScale → Open Source Projects**.

| Project | Role |
| --- | --- |
| [Tailscale](https://github.com/tailscale/tailscale) | Tailnet runtime, LocalAPI, networking stack, Taildrop. Module resolved to the AWG fork at [LiuTangLei/tailscale](https://github.com/LiuTangLei/tailscale). |
| [wireguard-go](https://git.zx2c4.com/wireguard-go/) | WireGuard userspace, via the AWG fork at [LiuTangLei/wireguard-go](https://github.com/LiuTangLei/wireguard-go). |
| [Amnezia-WG](https://github.com/amnezia-vpn/amneziawg-go) | AWG protocol and configuration model. |
| [golang.org/x/crypto/ssh](https://pkg.go.dev/golang.org/x/crypto/ssh) | SSH client for the built-in terminal. |
| [Go](https://go.dev/) | Toolchain for the embedded networking runtime. |
| [gomobile](https://pkg.go.dev/golang.org/x/mobile) | Go-to-iOS binding for `Libtailscale.xcframework`. |
| [XcodeGen](https://github.com/yonaskolb/XcodeGen) | Xcode project generation from `project.yml`. |

---

## Legal

AwgScale includes code from `tailscale.com` and related repositories under the BSD 3-Clause license. Keep [LICENSE](LICENSE) and [PATENTS](PATENTS) with any source or binary redistribution, and preserve the upstream licenses listed above.

WireGuard is a registered trademark of Jason A. Donenfeld. Other names may be trademarks of their respective owners.
