# iOS reliability follow-up — 2026-10-26/27

This work continues the released 1.104.2 preview at
`801e291638a1cc038ced2fd34320fa4d1201fc4c`. The app remains version 1.104.2;
its build number is 13. The published core and dependency pins are unchanged.
This is a local TrollStore/ad-hoc candidate, not an App Store/TestFlight build.

## Official reference and limits

The user supplied `/Users/lei/code/tpybx/grok/tailscale-ipa`. Its new
`recovered/decrypted/decompiled/kuna/` directory contains function bodies and
assembly from official Tailscale iOS **1.104.1 (101.104.1)**, not a complete,
buildable Swift source tree. The older `REA-REPORT.md` predates this recovery.

The IPNExtension binary SHA-256 is
`917b34cf166914ed046a38dcbc5702776d8be0ec7fe38cb452fbd3f70cbe59d9`.
The supplied decryption report records `cryptid_after=0` and matching code
directory pages. This does not establish that the recovered app was run.
Kuna has incorrect function names/boundaries in portions of this export;
the comparisons below use checked addresses, selectors and assembly calls.

All reference locations below are within
`recovered/decrypted/decompiled/kuna/IPNExtension/`:

| Question | Static evidence | Consequence for AwgScale |
| --- | --- | --- |
| Which physical interface is preferred? | `IPNExtension.asm:54113`, addresses `0x100035870–0x1000358a8`, takes the first NWPath interface; lines 53962–53968 call `_goNetworkUpdate`. | Respect system preference instead of imposing Wi-Fi before cellular/Ethernet. Notify the active network monitor on every path update. |
| Can applying system settings wait forever? | `IPNExtension.c:33768–33791` calls `setTunnelNetworkSettings:completionHandler:` and waits with a 5-second deadline. | Use a 15-second deadline, explicit failure, one completion per request and protection against callbacks from old sessions. The longer deadline is our implementation choice. |
| Should an exit node replace MagicDNS? | `IPNExtension.asm:79107–79256`, actual entry `0x10004cb9c`, preserves nonempty DNS inputs; `0x100056ba8` tests empty inputs and `0x10004e148` sets servers/match domains. | Preserve the core's DNS servers, search domains and split-DNS policy. Do not invent DNS when the core supplies an empty configuration. |

Apple documents that NWPath interfaces are supplied in preference order:
[NWPath](https://developer.apple.com/documentation/network/nwpath).
Its tunnel start contract also requires completing system network settings
before reporting successful establishment:
[startTunnel](https://developer.apple.com/documentation/networkextension/nepackettunnelprovider/starttunnel(options:completionhandler:)).

No sufficiently reliable evidence was found to reconstruct the official
sleep/wake policy. This change does not invent one or claim feature parity.

## Changes

- Preserve NWPath preference, exclude virtual/loopback/unused interfaces,
  notify `netmon` on offline and same-interface updates, and replay the path
  after backend readiness. A cancelled path monitor cannot update a later run.
  The pinned core deliberately retains its last known interface while offline;
  this change does not claim to clear that core cache.
- Bound network settings application and cancel stale/superseded operations.
  System failure stops the affected tunnel and preserves the useful error.
- Keep packet reads, writes, counters and queued underlay recovery attached to
  their original session and Go application. Stop drains active packet work;
  a late read cannot create an extra loop in the next session. Backend
  readiness subscription runs off the lifecycle queue so stop remains usable
  while startup waits. These changes still need physical callback/traffic tests.
- Preserve MagicDNS and split DNS with an exit node. The old public-DNS
  workaround predates the netstack endpoint repair: the pinned core handles
  service-IP UDP/TCP DNS and returns responses through the existing TUN bridge.
  Public and private DNS still require real-device acceptance.
- Reject unsuccessful readiness responses and late LocalAPI results from a
  previous or cancelled login backend. Foreground recovery no longer stops a
  backend owned by an active connection change. Connection and mode controls
  share the same busy state as the underlying operation guards.
- Preserve file read errors instead of turning them into EOF, release consumed
  multipart streams, and serialize Swift stream reads/closes. This prevents
  silent truncation and races during cleanup. It does not promise interruption
  of an arbitrary custom InputStream blocked inside its own Read method.
- Retry Go configuration delivery after a callback failure. A successful Swift
  callback means the update was queued; actual system application is separately
  checked by the settings coordinator.
- Leave the host process's stderr intact. The real-framework simulator run
  exposed a feedback loop between filch stderr capture and OSLog echo, which
  repeatedly ingested its own output and swallowed XCTest result markers.
  Explicit Go logs still enter the persistent logtail buffer. The interrupted
  run and its system log are retained as evidence; it is not a passing run.

## Validation

- **143 XCTest cases passed, 0 failed**, using the real arm64 Go framework on
  an isolated iPhone 17 Pro simulator, iOS 27.0. The final Xcode command returned
  success (`ios-tests-pass.xcresult` and `ios-tests-pass.log`). This includes 22
  new Swift regressions. One initial file test assumed a directory could be
  opened before read failed; it was corrected to accept an I/O error at either
  stage. The earlier failed/interrupted runs remain in `evidence/`.
- `go test -race ./libtailscale/...` passed after the logging repair (both
  packages); `go vet` reported no diagnostics and all pinned modules verified.
- Device and simulator arm64 framework builds passed with Go 1.27.3.
- Release device build, IPA ZIP integrity, deep/strict ad-hoc code-signature
  verification, all three bundle versions and shared App Group/Keychain/
  NetworkExtension entitlement checks passed.
- A normal simulator launch (without XCTest) remained running after 73 seconds
  and rendered the disconnected app screen. This is a startup smoke check;
  it does not validate account login or traffic. Screenshot and process evidence
  are saved separately. Simulator RSS is not a device memory measurement.
- IPA: `AwgScale-1.104.2-build13-trollstore.ipa`, 24,761,487 bytes.
  SHA-256: `e48134d908ed4994e476fd8c6b1113efebf7efcd2bc0d58329a0b4d4d4f11f3b`.

Validation results and hashes are retained in the sibling `evidence/` and
`artifacts/` directories. Tests exercise application logic and controlled
system-callback failures, not a physical NetworkExtension data path.

## Device acceptance still required

Use a test account/device with the existing installation method and preserve
its saved state. Required checks are:

1. Upgrade without losing the profile, log in, connect, disconnect, reconnect,
   cancel during startup, and confirm errors recover on the next attempt.
2. Test Wi-Fi to cellular and back, airplane-mode recovery, switching between
   two Wi-Fi networks, and waking after lock/background suspension.
3. With an exit node, resolve a MagicDNS name, a split-DNS private name and a
   public name over UDP/TCP DNS; check IPv4/IPv6 and the LAN-access setting.
4. Send a real multi-chunk Taildrop file, compare its checksum, cancel and retry,
   and check the share extension while the app is in the background.
5. Exercise native/AWG and QUIC with compatible peers, then run sustained
   traffic while watching extension memory and unexpected disconnects.

No physical-device installation, live VPN change, real account login, external
release publication or long-running connectivity acceptance is included here.
