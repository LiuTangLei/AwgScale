# AwgScale

**AwgScale is an open source Tailscale-compatible iOS client with Amnezia-WG / AWG support.**

AwgScale provides a system-wide Packet Tunnel VPN when the app is signed with the required Network Extension entitlement. It also includes app-only tailnet tools that keep useful private-network workflows inside the app when a full-device VPN tunnel is not desired or not available.

AwgScale is independent software. It is not affiliated with, sponsored by, endorsed by, or approved by Tailscale Inc.

## Features

- Tailscale-compatible login, profiles, custom control server URLs, and machine authorization.
- System-wide iOS Packet Tunnel VPN with exit nodes, DNS controls, subnet routes, Tailnet Lock, health status, and diagnostics.
- App-only built-in apps for tailnet workflows:
  - Browser tabs, history, bookmarks, compact mobile chrome, tailnet HTTP access, and optional exit-node routing for public browsing.
  - SSH terminal with saved hosts, password or private-key authentication, a phone keyboard path, and a compact preset terminal keyboard.
- Amnezia-WG configuration status, manual parameter editing, JSON paste/copy, and peer-to-device AWG config sync.
- Taildrop receive and send flows, including the Share Extension.
- Peer details, SSH entry from peers, ping diagnostics, notification settings, MDM policy display, and bug report export.

## Connection Modes

### System-wide VPN

VPN Permission enables the full Packet Tunnel extension and system-wide tailnet routing. This requires Apple signing with the Network Extension entitlement, such as a TrollStore build or an appropriately provisioned signed binary.

### App-only tools

Without VPN Permission, AwgScale keeps tailnet access inside the app only. You still get the built-in terminal and, on iOS 17 or later, the internal browser with tailnet/http access and optional exit-node routing for public browsing.

External apps cannot use the tailscale network or a peer exit node when VPN Permission is disabled.

## Build

Build the Go framework:

```sh
./build_go.sh --all
```

Build a TrollStore-ready IPA:

```sh
./build_unsigned_ipa.sh
```

The IPA is written to `build/unsigned-ipa/AwgScale-trollstore.ipa`.

Quick validation:

```sh
go test ./libtailscale/...
xcodebuild build -project AwgScale.xcodeproj -scheme AwgScale -configuration Debug -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
```

For local Xcode runs, use a signing configuration that matches the features being exercised. App-only screens can be developed in the simulator; the system VPN tunnel still depends on Network Extension support from the running environment.

## Open Source Projects

AwgScale is built on open source projects and keeps those acknowledgements visible in the app under **Settings > About AwgScale > Open Source Projects**.

### Libraries and upstreams

| Project | Use in AwgScale |
| --- | --- |
| [Tailscale](https://github.com/tailscale/tailscale) | Tailnet runtime, LocalAPI behavior, networking stack, Taildrop, and the main Go client foundation. The `tailscale.com` module is resolved to the AWG fork at [LiuTangLei/tailscale](https://github.com/LiuTangLei/tailscale). |
| [wireguard-go](https://git.zx2c4.com/wireguard-go/) | WireGuard userspace foundation used through the AWG fork at [LiuTangLei/wireguard-go](https://github.com/LiuTangLei/wireguard-go). |
| [Amnezia-WG](https://github.com/amnezia-vpn/amneziawg-go) | AWG protocol ideas and configuration model exposed by the forked networking stack. |
| [golang.org/x/crypto/ssh](https://pkg.go.dev/golang.org/x/crypto/ssh) | SSH client implementation for the built-in terminal. |
| [Go](https://go.dev/) | Go toolchain used to build the embedded networking runtime. |
| [gomobile](https://pkg.go.dev/golang.org/x/mobile) | Go-to-iOS binding toolchain used for `Libtailscale.xcframework`. |
| [XcodeGen](https://github.com/yonaskolb/XcodeGen) | Xcode project generation from `project.yml`. |

## Legal

AwgScale includes open source code from `tailscale.com` and related repositories under the BSD 3-Clause license and accompanying PATENTS grant. Keep [LICENSE](LICENSE) and [PATENTS](PATENTS) with source and binary redistributions, and preserve the licenses and notices required by each bundled open source project listed above.

WireGuard is a registered trademark of Jason A. Donenfeld. Amnezia-WG belongs to its respective upstream project. Other names may be trademarks of their owners.
