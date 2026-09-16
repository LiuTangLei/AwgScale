# AwgScale 1.102.4 — QUIC packet-transport work report

Branch: `feature/quic-1.102.4-20260917` (prior source `c589acb`).

This report documents the iOS implementation that adds a real QUIC packet
transport (built-in HTTP/3) alongside the retained native Amnezia-WG v2/v3 data
plane, wires the app to the published immutable shared core, and records exact
build/test results and real-device limitations.

## 1. Shared core and module pins (release)

`go.mod` now pins exactly (verified with `go list -m`):

| Module | Selected |
| --- | --- |
| `tailscale.com` | `=> github.com/LiuTangLei/tailscale v1.102.5-0.20260916181858-1f00235ed2ce` (source `1f00235ed2ceaa2231755a2d2d3677c2d42438c6`) |
| `github.com/LiuTangLei/wireguard-go` | `v0.0.32` |
| `github.com/quic-go/quic-go` | `=> github.com/LiuTangLei/quic-go v0.62.0-tailscale.4` (top-level replace) |
| `go` directive | `1.26.6` |

Notes:
- The published core requires Go >= 1.26.6. The release build pins the compiler
  with `GOTOOLCHAIN=go1.26.6` in `build_go.sh`.
- The core declares the quic-go fork mapping in *its* `go.mod`, but a
  dependency-level `replace` does not apply to this main module, so the same
  mapping is declared here at the top level. This is required for QUIC to link.
- The moved `v1.102.4` tag cache and any local/workspace replaces are **not**
  used: `build_go.sh` keeps `GOWORK=off`, `-mod=readonly`, and fails unless the
  three modules above resolve to the exact published versions.

## 2. Backend (`libtailscale/app.go`)

The managed packet-transport profile is now loaded **before**
`wgengine.NewUserspaceEngine`, mirroring the core's own `tsnet` startup path:

- `varRoot := dataDir` — the shared AppGroup container
  (`group.top.yesican.awgscale/.../awgscale`), which is the **same** absolute
  path used by both the app-login backend and the packet-tunnel extension. This
  makes the staged QUIC/native selection persist across restarts and be visible
  to whichever process activates it.
- `transportprofile.LoadForStart(varRoot)` builds the `wgtransport.Config`
  (native, or an `http3-ip` factory over the Tailscale quic-go fork) that the
  engine runs on this start.
- `wgengine.Config` now sets `Transport`, `TransportSource`,
  `TransportRevision`, and `TransportManaged: true`.
- `lb.SetVarRoot(varRoot)` persists the managed profile alongside backend state.

Together these make `LocalBackend.ConfigureTransport` **available**
(`Available = PacketTransportManaged && filepath.IsAbs(varRoot)`), which is the
precondition for the LocalAPI `packet-transport` endpoint to accept mutations.

App-only single ownership, the packet-tunnel shared state, AppGroup
`group.top.yesican.awgscale`, keychain access group, node identity, socket
protection, and the auth/ACL/replay + "no WG fallback" guarantees are unchanged;
only the engine construction gained the four transport fields plus `SetVarRoot`.

## 3. QUIC selection and coordinated AWG (semantics)

All transport mutation is driven through the core LocalAPI endpoint
`/localapi/v0/packet-transport` (`ipn.TransportControlRequest` /
`TransportControlStatus`). The core only **stages** a next-start profile; the
app restarts the backend/tunnel to activate it.

- **Select QUIC**: `action=mode, mode=quic`. The core rewrites this to
  `http3-ip` with auto-trust and clears the separately persisted AWG profile.
- **Apply/sync AWG while QUIC is active or staged**: `action=awg`. The core
  stages `native` mode and saves the AWG profile in one coordinated operation.
- **Native + AWG (not in QUIC)**: unchanged direct prefs path
  (`PATCH /localapi/v0/prefs`), preserving existing behavior.

`ExpectedRevision` is sent on every mutation; a 409 revision conflict is retried
once with the freshly read revision.

## 4. iOS app changes (Swift)

- `Shared/Models.swift`: added `TransportControlStatus` and
  `TransportControlRequest` Codable models. Only the four request fields the app
  uses are serialized (the core rejects unknown fields); the status decoder is a
  forward-compatible subset that ignores unmodeled keys.
- `Shared/LocalAPIClient.swift`: added `transportStatus()` (GET) and
  `configureTransport(_:)` (POST) against `/localapi/v0/packet-transport`.
- `Shared/AppState.swift`: added published transport state
  (`transportActiveMode`, `transportDesiredMode`, `transportPendingRestart`,
  `transportAvailable`, `isQuicTransportEnabled`), `refreshTransportStatus()`,
  `setQuicTransport(_:)` / `requestQuicTransport(_:)`, a coordinated
  `applyAwgViaCoordinatedTransport` used by `applyManualAwgConfig`, and a
  409-conflict retry helper. Activation reuses the existing serialized restart
  paths (`refreshBackendForAwgConfig` → app-backend restart or VPN
  disconnect→reconnect) with their stop/disconnected → start/active state
  verification, so changes are applied by an actual backend/tunnel restart, not
  a UI-only save.
- `App/Views/SettingsView.swift`: a single **"QUIC (built-in H3)"** toggle in a
  new "Packet Transport" section. Enabling it selects QUIC (clearing AWG) and
  restarts; disabling returns to native. The Amnezia-WG v2/v3 configuration UI
  is retained for native mode. The toggle reflects the backend's actual staged
  mode and is disabled when no managed transport is available or an operation is
  in progress.

## 5. Build tooling and versioning

- `build_go.sh`: `GOTOOLCHAIN=go1.26.6`; release version guards updated to the
  three pins in §1 (tailscale, wireguard-go, and the quic-go fork), with
  `GOWORK=off` and `-mod=readonly` retained.
- App/core version bumped to **1.102.4** with a monotonic build number **11**
  across `App/Info.plist`, `PacketTunnel/Info.plist`, `ShareExtension/Info.plist`
  (`CFBundleShortVersionString`, `CFBundleVersion`); `TailscaleAWGVersion` set to
  `1.102.4`.

## 6. Exact test and build results

Environment: macOS, Xcode 27.0 (27A5194q); Go toolchain `go1.26.6`.

- `go vet ./libtailscale/` — pass.
- `go test ./libtailscale/` — `ok ... 0.056s` (pass).
- `./build_go.sh --all` — success. `Libtailscale.xcframework` produced with both
  `ios-arm64` (device) and `ios-arm64-simulator` slices; guard output confirmed
  the exact tailscale / wireguard-go / quic-go pins. (~58 s.)
- Swift tests via `xcodebuild test` on simulator `codex-quic4-20260908`
  (`47869869-ECCE-4AA5-869D-700E056BA0C9`): **`** TEST SUCCEEDED **`**.
  - `ModelsTests`: **24 tests, 0 failures**, including 4 new transport tests:
    `testTransportControlStatusDecodesSnakeCaseAndIgnoresUnknownKeys`,
    `testTransportControlStatusQuicModeMapping`,
    `testTransportRequestSelectQuicEncodesOnlyKnownFields`,
    `testTransportRequestApplyAWGEmbedsCanonicalConfigAndStagesNative`.
  - Full suite targets present and building/passing: `AppStateTests` (36),
    `LocalAPITests` (17), `ModelsTests` (24), `TunnelConfigBridgeTests` (15).
- `./build_unsigned_ipa.sh` — `** BUILD SUCCEEDED **`.

### Artifacts
- xcframework: `Libtailscale.xcframework/` (slices `ios-arm64`,
  `ios-arm64-simulator`; main + framework binaries verified `arm64`).
- IPA: `build/unsigned-ipa/AwgScale-trollstore.ipa` — **24 MB**, app
  `CFBundleShortVersionString 1.102.4`, `CFBundleVersion 11`.

Both artifacts are git-ignored (`Libtailscale.xcframework/`, `build/`, `*.ipa`)
and are not committed.

## 7. Signing (accurate description — not App Store)

The IPA is produced by `build_unsigned_ipa.sh` with
`CODE_SIGNING_ALLOWED=NO`, then **ad-hoc signed** (`codesign --sign -`) with the
TrollStore entitlements template (`application-groups`
`group.top.yesican.awgscale`, keychain access group, `packet-tunnel-provider`,
`get-task-allow`). This is a **TrollStore / ad-hoc** artifact for sideloading or
later re-signing. It is **not** an App Store-approved or App Store-distributed
build, and no claim of Apple distribution signing is made. TrollStore may still
require device-side `ldid` / a CoreTrust bypass to complete installation.

## 8. Real-device limitations

- **No physical iOS device was online**, so the app was **not installed or run
  on real hardware**, and the host VPN was not modified. Per task scope, no
  installation on real phones was attempted.
- Consequently, the **QUIC (HTTP/3) data-plane runtime** — a live tunnel that
  actually carries traffic over the built-in H3 carrier to a peer — was **not
  validated end-to-end on device**. Validation covered: the backend compiling
  and linking the quic-go fork against the published core, the managed-transport
  wiring that exposes `ConfigureTransport`, the request/response contracts
  (unit-tested), and full app compilation + test suite on the simulator.
- Simulator runs cannot exercise a real `NEPacketTunnelProvider` data plane, so
  packet-tunnel activation and the QUIC handshake against a real peer remain to
  be confirmed on a device with a TrollStore/ad-hoc install.

## 9. Scope boundaries honored

Only this repository (`tailscale-ios`) was modified. No other repositories were
changed; nothing was published, pushed, or tagged; no other agents were stopped.
Core publication / shared-core / Android remain owned by the parent. No secrets
or key material appear in this report or in source.
