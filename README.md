# AwgScale

**AwgScale is an open source Tailscale iOS client with Amnezia-WG / AWG support.**

It is a third-party iPhone/iPad Packet Tunnel app for Tailscale-compatible control planes. The goal is simple: provide a transparent, open source iOS client for users who need Tailscale-style networking plus AWG transport support.

Keywords: tailscale ios open source, open source Tailscale iOS client, Tailscale iOS AWG, Amnezia-WG iOS VPN client.

AwgScale is not affiliated with, sponsored by, endorsed by, or approved by Tailscale Inc.

## Status

- Not available on the App Store.
- Experimental and self-managed. Review the source and built IPA before using it for sensitive traffic.
- Built around a gomobile `Libtailscale.xcframework` using `github.com/LiuTangLei/tailscale v1.98.2` and `github.com/LiuTangLei/wireguard-go`.

## Installation

The current IPA is intended for **TrollStore / 巨魔** installation only.

SideStore, AltStore, and ordinary developer-account sideloading are not enough for the VPN feature. They cannot provide the Packet Tunnel Network Extension entitlement this app needs, so the app may install but the VPN tunnel will not work.

To use a normal Apple signing path, you need a provisioning profile with the required Packet Tunnel entitlement granted by Apple.

## Main Features

- Tailscale-compatible login, profiles, custom control server URLs, and machine authorization.
- iOS Packet Tunnel VPN with exit node, DNS, subnet route, and Tailnet Lock views.
- Amnezia-WG settings, AWG JSON paste/apply, current JSON copy, and peer AWG config sync.
- Taildrop receive/send, including Share Extension send.
- Ping diagnostics, health view, notifications settings, MDM policy display, and bug report export.

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

## Legal

AwgScale includes open source code from `tailscale.com` and related repositories under the BSD 3-Clause license and accompanying PATENTS grant. Keep [LICENSE](LICENSE) and [PATENTS](PATENTS) with source and binary redistributions.

WireGuard is a registered trademark of Jason A. Donenfeld. Amnezia-WG belongs to its respective upstream project. Other names may be trademarks of their owners.