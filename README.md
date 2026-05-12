# Tailscale iOS Client

An unofficial iOS client experiment for Tailscale-compatible tailnets, including Headscale deployments. The app embeds a Go Tailscale backend through gomobile and runs the data plane inside an iOS Packet Tunnel Network Extension.

## Status

This repository is split from the previous mixed mobile workspace and intentionally contains only the iOS app, PacketTunnel extension, shared Swift code, iOS Go bridge, tests, and build scripts.

Working areas include:

- Login before VPN activation through an app-process backend.
- Packet Tunnel based VPN data plane.
- Headscale custom control server login.
- Peer list, health, DNS, Taildrop, AWG-related UI, and exit-node selection.
- TrollStore-oriented unsigned IPA packaging for local testing.

## Disclaimer

This project is unofficial and is not affiliated with, endorsed by, sponsored by, or approved by Tailscale Inc. Tailscale is a trademark of Tailscale Inc.

This client was developed from publicly available source code, public protocol/API behavior, and independent implementation work. It does not use reverse engineering of Tailscale's proprietary iOS application.

Use at your own risk. This software is experimental and may break connectivity, leak diagnostics, or behave differently from official Tailscale clients. Review the code and build artifacts before installing on any device that carries sensitive traffic.

## Repository Layout

```text
App/                 SwiftUI app target
PacketTunnel/        NEPacketTunnelProvider extension
Shared/              Swift models, state, LocalAPI IPC, Go bridge, VPN manager
Tests/               Swift unit tests
libtailscale/        Go gomobile package wrapping Tailscale backend pieces
docs/                Architecture and maintenance notes
build_go.sh          Builds Libtailscale.xcframework with gomobile
build_unsigned_ipa.sh Builds a TrollStore/ldid-ready IPA
project.yml          XcodeGen project definition
Tailscale.xcodeproj/ Generated Xcode project kept for convenience
```

Generated output is intentionally ignored by Git, including `build/`, `DerivedData/`, `*.ipa`, and `Libtailscale.xcframework/`.

## Build

Requirements:

- macOS with Xcode.
- Go matching `go.mod`.
- `gomobile` and `gobind` installable from the pinned `golang.org/x/mobile` module.
- XcodeGen if regenerating `Tailscale.xcodeproj` from `project.yml`.

Build the Go framework:

```sh
./build_go.sh --all
```

Run Go tests:

```sh
go test ./libtailscale
```

Run the focused Swift tunnel config tests:

```sh
xcodebuild test \
  -project Tailscale.xcodeproj \
  -scheme Tailscale \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.4' \
  -only-testing:TailscaleTests/TunnelConfigBridgeTests
```

Build a TrollStore-oriented IPA for local device testing:

```sh
./build_unsigned_ipa.sh
```

The IPA is written to `build/unsigned-ipa/Tailscale-trollstore.ipa`.

## Maintenance Direction

The current code works, but long-term maintainability depends on reducing scattered LocalAPI calls in Swift. See [docs/LOCALAPI_CLIENT_PLAN.md](docs/LOCALAPI_CLIENT_PLAN.md) for the proposed typed LocalAPI layer inspired by `swift-tailscale-client` and public client patterns.

## License

This repository currently retains the upstream Tailscale license files present in the source tree. Review licensing before publishing binary artifacts or redistributing modified code.
