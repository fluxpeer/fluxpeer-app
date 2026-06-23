// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import '../models/models.dart';

/// Bridge to the native tunnel host — iOS NetworkExtension (PacketTunnelProvider)
/// / Android VpnService — which runs the fluxpeer node IN-PROCESS over FFI.
///
/// Until the native side lands, a built-in MOCK backend (auto-enabled the first
/// time a platform method is missing) drives the whole UI so the Flutter app is
/// runnable standalone.
class FluxpeerChannel {
  FluxpeerChannel._();

  static const MethodChannel _m = MethodChannel('dev.fluxpeer.app/flux');
  static const EventChannel _e = EventChannel('dev.fluxpeer.app/fluxStatus');

  static final _MockBackend _mock = _MockBackend();
  static bool _useMock = false;

  static bool get usingMock => _useMock;

  /// Enroll a join token (scan / paste / import) → returns the joined network.
  /// Wraps the FFI `join`: keygen + enroll-once + persist config natively.
  static Future<FxNetwork> join(String token, String deviceName) async {
    try {
      final r = await _m.invokeMethod('join', {
        'token': token,
        'device': deviceName,
      });
      return FxNetwork.fromJson(Map<String, dynamic>.from(r as Map));
    } on MissingPluginException {
      _useMock = true;
      return _mock.join(token, deviceName);
    }
  }

  static Future<void> startTunnel(FxNetwork net) async {
    try {
      await _m.invokeMethod('start', {'network': jsonEncode(net.toJson())});
    } on MissingPluginException {
      _useMock = true;
      await _mock.start(net);
    }
  }

  static Future<void> stopTunnel() async {
    try {
      await _m.invokeMethod('stop');
    } on MissingPluginException {
      _useMock = true;
      await _mock.stop();
    }
  }

  /// Cold-start / foreground sync: read LIVE state from the running tunnel.
  static Future<FxStateSnapshot> getCurrentState() async {
    try {
      final r = await _m.invokeMethod('getCurrentState');
      return FxStateSnapshot.fromJson(Map<String, dynamic>.from(r as Map));
    } catch (_) {
      // any failure to reach the native host → fall back to the mock backend
      _useMock = true;
      return _mock.current;
    }
  }

  /// Keep-alive / system-permission status for the Me tab. Keys: `vpn`,
  /// `battery`, `notifications`, `autostart` — value `true`/`false`, or `null`
  /// when not applicable on the platform (e.g. battery/autostart on iOS).
  static Future<Map<String, dynamic>> permissionStatus() async {
    try {
      final r = await _m.invokeMethod('permissionStatus');
      return Map<String, dynamic>.from(r as Map);
    } catch (_) {
      _useMock = true;
      // Mock: pretend nothing granted so the UI is exercisable standalone.
      return {'vpn': false, 'battery': false, 'notifications': false, 'autostart': null};
    }
  }

  static Future<void> requestVpn() => _grant('requestVpn');
  static Future<void> requestBatteryExemption() => _grant('requestBatteryExemption');
  static Future<void> requestNotifications() => _grant('requestNotifications');
  static Future<void> openAutoStart() => _grant('openAutoStart');

  static Future<void> _grant(String method) async {
    try {
      await _m.invokeMethod(method);
    } catch (_) {/* mock / unsupported — no-op */}
  }

  /// Real-time status stream from the tunnel host.
  static Stream<FxStateSnapshot> statusStream() {
    if (_useMock) return _mock.stream;
    try {
      return _e.receiveBroadcastStream().map(
            (e) => FxStateSnapshot.fromJson(Map<String, dynamic>.from(e as Map)),
          );
    } catch (_) {
      _useMock = true;
      return _mock.stream;
    }
  }
}

/// In-memory mock of the tunnel host so the UI runs without native code.
class _MockBackend {
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
      controlUrl: 'https://demo.fluxpeer.dev',
      overlayV4: '100.72.16.5',
      deviceId: 'dev-${device.isEmpty ? 'mock' : device}',
      pubkey: 'mock+pubkey+${ts.toRadixString(36)}',
    );
  }

  Future<void> start(FxNetwork net) async {
    // First connect ever simulates the OS VPN-permission grant.
    if (!_authorized) {
      current = FxStateSnapshot(state: FxConnState.authorizing, networkId: net.id);
      _ctrl.add(current);
      await Future<void>.delayed(const Duration(milliseconds: 900));
      _authorized = true;
    }
    current = FxStateSnapshot(state: FxConnState.connecting, networkId: net.id);
    _ctrl.add(current);
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    current = FxStateSnapshot(
      state: FxConnState.connected,
      networkId: net.id,
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
