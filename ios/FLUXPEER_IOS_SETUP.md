# fluxpeer iOS — Network Extension setup

The Rust engine, the Swift sources, and the entitlements are all in the repo.
What remains is **Xcode project wiring** that can't be safely scripted into
`Runner.xcodeproj/project.pbxproj` (a new target + signing). One-time steps:

## 1. Build the engine xcframework

```sh
scripts/build-ios.sh            # release; --debug for a faster local build
```

Produces `ios/Frameworks/Fluxpeer.xcframework` (device + simulator slices,
`import FluxpeerFFI` exposes all `fp_*` symbols; gitignored — regenerate on
demand).

## 2. Add the PacketTunnel extension target

In Xcode (`Runner.xcworkspace`):

1. **File ▸ New ▸ Target… ▸ Network Extension** (or *Packet Tunnel Provider*).
   - Product name: **PacketTunnel**
   - Bundle id: **dev.fluxpeer.fluxpeer.PacketTunnel** (must match
     `FluxpeerPlugin.extensionBundleId`).
2. Delete the auto-generated `PacketTunnelProvider.swift`; instead add the repo
   files to the **PacketTunnel** target:
   - `ios/PacketTunnel/PacketTunnelProvider.swift`
   - `ios/PacketTunnel/FluxpeerNative.swift`   *(also add to the Runner target)*
   - Set the target's **Info.plist** to `ios/PacketTunnel/Info.plist` and its
     **Code Signing Entitlements** to `ios/PacketTunnel/PacketTunnel.entitlements`.
3. Add `ios/Runner/FluxpeerPlugin.swift` to the **Runner** target (already
   referenced from `AppDelegate.swift`).

## 3. Link the xcframework

For **both** targets (Runner needs keygen/enroll/gateway; PacketTunnel runs the
tunnel): General ▸ *Frameworks, Libraries, and Embedded Content* ▸ **+** ▸ Add
Other ▸ `ios/Frameworks/Fluxpeer.xcframework`.
- Runner: *Embed & Sign*. PacketTunnel: *Do Not Embed* (it links the same lib).

## 4. Capabilities (both targets)

- **App Groups**: enable `group.dev.fluxpeer.fluxpeer` on Runner *and*
  PacketTunnel (already in the `.entitlements` files — just turn on the
  capability so provisioning includes it).
- **Network Extensions**: Runner gets *Personal VPN* (`allow-vpn`); PacketTunnel
  gets *Packet Tunnel*. Both entitlement files are pre-written; point each
  target's *Code Signing Entitlements* build setting at them.
- Set `Runner` entitlements to `ios/Runner/Runner.entitlements`.

## 5. Signing

A paid Apple Developer account is required (the Network Extension +
packet-tunnel-provider entitlement is not available to free teams). Set the same
team on both targets.

## Data flow (matches Android)

```
Dart  ──MethodChannel dev.fluxpeer.app/flux──►  FluxpeerPlugin (Runner)
  join   → fp_generate_keypair + fp_enroll → persist record (App Group)
  start  → fp_gateway (fill node_*) → NETunnelProviderManager.save + start
                                              │
                              providerConfiguration["flux_config"]
                                              ▼
                        PacketTunnelProvider (extension)
  fp_connect_handshake_only → setTunnelNetworkSettings (split-tunnel)
    → utun fd → fp_attach_tun → data plane live
status ◄──EventChannel dev.fluxpeer.app/fluxStatus── NEVPNStatusDidChange
```

The Dart side (`lib/channel/fluxpeer_channel.dart`) is unchanged — its mock
auto-disables once these native handlers respond.
