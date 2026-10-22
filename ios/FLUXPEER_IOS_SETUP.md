# fluxpeer iOS — full node Network Extension

The Xcode project contains the Runner native bridge and the PacketTunnel extension,
its dependency/embed phase, App Group entitlements and static xcframework links.
Both targets use `fp-node-mobile-sys`. The old dispatcher handshake/attach ABI and
cached gateway selection are no longer used by iOS.

## Build

From the sibling core repository:

```sh
scripts/build-ios.sh --debug     # omit --debug for release
```

This produces the gitignored `ios/Frameworks/Fluxpeer.xcframework` with device
arm64 and simulator arm64 static libraries, a checked C ABI header and module map.
Rebuild it after Rust changes. Intel simulator slices are not included.

From this app repository, for an unsigned arm64 simulator build:

```sh
xcodebuild -project ios/Runner.xcodeproj -scheme Runner -configuration Debug \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build
```

The repository retains its existing iOS 13 deployment settings. Xcode 27's simulator
SDK rejects deployment targets below 15; for validation with that SDK add
`IPHONEOS_DEPLOYMENT_TARGET=15.0` to the command. This build override does not establish
iOS 13 runtime compatibility. Provisioning and on-device testing remain separate.

## Signing and installation

Use the same paid Apple Developer team for Runner and PacketTunnel. Provision
`group.dev.fluxpeer.fluxpeer` for both targets and the packet-tunnel-provider
Network Extension capability. Runner's Personal VPN entitlement is also retained.
Select matching provisioning profiles in Xcode; no team or signing credentials
are committed. The extension bundle id is `dev.fluxpeer.fluxpeer.PacketTunnel`.

## Engine and settings contract

Runner enrolls through the node SDK, persists the membership and merges typed
local `use_exit`/`exitNode`, DNS, MTU, exclusions and transport settings. Private
credentials come only from the saved membership. The engine fetches fresh control
configuration on every start and uses the same raw WireGuard data plane as Android.

PacketTunnel exchanges packets through the public `NEPacketTunnelFlow` API and a
private datagram socket pair. It does not inspect private KVC properties or scan
unrelated descriptors. The engine owns a duplicate of its socket endpoint and
uses iOS's four-byte address-family framing; stopping joins the engine before the
extension acknowledges teardown. No callback joins its own engine thread.

Only engine-applied overlay/subnet routes, addresses, selected exit and DNS can
produce OS settings. Split mode rejects both default prefixes. A selected exit
plus explicit local opt-in installs IPv4 default and captures IPv6 default for
discard in both directions; IPv6 exclusions cannot bypass that guard. The local
`fd00::1` placeholder is used only when NE needs an IPv6 interface address but the
control server assigned none. It is not a service endpoint.

Ready follows successful network-settings completion. Generation checks reject
late events, and a new start waits until the previous engine and outstanding NE
settings operation finish. Engine exit, bridge error or settings failure cancels
the tunnel with an error. Desktop-style host route/firewall commands are not used
inside the extension. Client kill-switch is not implemented by this migration.

## Host tests and remaining device checks

```sh
swiftc ios/PacketTunnel/TunnelPolicy.swift ios/PacketTunnel/TunnelLifecycle.swift \
  ios/tests/TunnelPolicyTests.swift -o /tmp/fluxpeer-ios-policy-tests
/tmp/fluxpeer-ios-policy-tests
```

The tests cover typed settings, family-aware routes, split/default filtering,
IPv6 packet capture/discard, framing and stale generation rejection. Core Rust
unit tests cover FFI fd ownership and generation-aware stop. Build success is not
proof of a working Network Extension session. A signed physical device is still
needed for iOS-to-node traffic, control/relay socket bypass, IPv6 leakage, network
handoffs, reconnect/route changes and lifecycle failure checks.
