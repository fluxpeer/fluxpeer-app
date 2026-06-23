# fluxpeer (mobile)

The **fluxpeer** mobile mesh-VPN client: a Flutter UI driving the fluxpeer mesh
engine through a Rust FFI. The device joins a fluxpeer mesh and runs as a
WireGuard-compatible mesh node — split-tunnel by default, never a public-exit VPN.

- **UI**: Flutter (`lib/`) — onboarding/join, connect ring, network switcher,
  status, settings, and config import.
- **Engine**: the Rust mesh client engine (`fp-node-client-sys` in the core repo),
  cross-built into native libraries and called over a platform channel
  (Android `VpnService`, iOS `NEPacketTunnelProvider`).

## Build prerequisites

The native engine is **not** built by Flutter. Build it first from the core
repository (https://github.com/fluxpeer/fluxpeer):

```bash
# in the fluxpeer core repo
scripts/build-android.sh   # produces android/app/src/main/jniLibs/<abi>/*.so
scripts/build-ios.sh       # produces the iOS PacketTunnel framework
```

Then build the app:

```bash
flutter pub get
flutter run                # debug
flutter build apk          # Android release
flutter build ios          # iOS release (set your own signing team)
```

> iOS signing: `DEVELOPMENT_TEAM` is intentionally empty in
> `ios/Runner.xcodeproj/project.pbxproj`. Set your own Apple Developer team before
> building for a device.

## License

AGPL-3.0-or-later. See [`LICENSE`](LICENSE) and the full text in
[`LICENSE-AGPL-3.0.txt`](LICENSE-AGPL-3.0.txt). A commercial license (to use this
client without AGPL obligations) is available: licensing@fluxpeer.org. See
[LICENSING.md](https://github.com/fluxpeer/fluxpeer/blob/main/LICENSING.md) and
[TRADEMARKS.md](https://github.com/fluxpeer/fluxpeer/blob/main/TRADEMARKS.md).

**App Store / marketplaces:** an additional permission lets this AGPL app be
distributed via the Apple App Store / Google Play despite their terms of service —
see [`LICENSE-APP-STORE-EXCEPTION.md`](LICENSE-APP-STORE-EXCEPTION.md).

## Contributing

Contributions are welcome. fluxpeer uses a **Contributor License Agreement** so the
project can ship to app stores and offer a commercial edition — see [`CLA.md`](CLA.md).
Sign off commits with `git commit -s` (DCO) and confirm CLA agreement in your PR.
