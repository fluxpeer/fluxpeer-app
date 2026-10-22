// SPDX-License-Identifier: AGPL-3.0-or-later
// Debug-only backend; all callers are guarded by a compile-time debug flag.
import 'dart:async';
import '../models/models.dart';

/// In-memory mock of the tunnel host so the UI runs without native code.
class DebugMockBackend {
  final StreamController<FxStateSnapshot> _ctrl =
      StreamController<FxStateSnapshot>.broadcast();
  FxStateSnapshot current = const FxStateSnapshot();
  bool _authorized = false;

  Stream<FxStateSnapshot> get stream => _ctrl.stream;

  Future<FxNetwork> join(String token, String device) async {
    await Future<void>.delayed(const Duration(milliseconds: 600));
    final ts = DateTime.now().millisecondsSinceEpoch;
    return FxNetwork(
      id: 'mock-$ts',
      name: 'home-net',
      controlUrl: 'https://demo.invalid',
      overlayV4: '100.72.16.5',
      deviceId: 'dev-${device.isEmpty ? 'mock' : device}',
      pubkey: 'mock+pubkey+${ts.toRadixString(36)}',
    );
  }

  Future<void> start(FxNetwork net) async {
    // First connect ever simulates the OS VPN-permission grant.
    if (!_authorized) {
      current = FxStateSnapshot(
        state: FxConnState.authorizing,
        networkId: net.key,
      );
      _ctrl.add(current);
      await Future<void>.delayed(const Duration(milliseconds: 900));
      _authorized = true;
    }
    current = FxStateSnapshot(state: FxConnState.connecting, networkId: net.key);
    _ctrl.add(current);
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    current = FxStateSnapshot(
      state: FxConnState.connected,
      networkId: net.key,
      overlayV4: net.overlayV4,
      connectedAtMs: DateTime.now().millisecondsSinceEpoch,
      peers: _mockPeers(),
    );
    _ctrl.add(current);
  }

  Future<void> stop() async {
    current = const FxStateSnapshot(state: FxConnState.disconnected);
    _ctrl.add(current);
  }

  List<FxPeer> _mockPeers() {
    final now = DateTime.now().millisecondsSinceEpoch;
    return [
      FxPeer(
        name: 'laptop',
        pubkey: 'pk-laptop',
        endpoint: '203.0.113.7:41820',
        transport: FxTransport.udpDirect,
        rttMs: 12,
        rxBytes: 2300000,
        txBytes: 1100000,
        lastHandshakeMs: now - 23000,
      ),
      FxPeer(
        name: 'phone',
        pubkey: 'pk-phone',
        endpoint: 'relay',
        transport: FxTransport.relay,
        rttMs: 38,
        rxBytes: 420000,
        txBytes: 510000,
        lastHandshakeMs: now - 95000,
      ),
      FxPeer(
        name: 'nas',
        pubkey: 'pk-nas',
        endpoint: '198.51.100.4:41820',
        transport: FxTransport.udpDirect,
        rttMs: 4,
        rxBytes: 9800000,
        txBytes: 230000,
        lastHandshakeMs: now - 4000,
      ),
    ];
  }
}
