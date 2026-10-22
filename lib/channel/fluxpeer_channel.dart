// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'debug_mock.dart';

import '../models/models.dart';

/// Bridge to the native tunnel host — iOS NetworkExtension (PacketTunnelProvider)
/// / Android VpnService — which runs the fluxpeer node IN-PROCESS over FFI.
///
/// A built-in MOCK backend exists for UI-only development, but debug
/// builds must opt in explicitly with `--dart-define=FLUXPEER_ALLOW_MOCK=true`.
class FluxpeerChannel {
  FluxpeerChannel._();

  static const MethodChannel _m = MethodChannel('dev.fluxpeer.app/flux');
  static const EventChannel _e = EventChannel('dev.fluxpeer.app/fluxStatus');
  static const bool _allowMock = kDebugMode && bool.fromEnvironment(
    'FLUXPEER_ALLOW_MOCK',
    defaultValue: false,
  );

  static final DebugMockBackend _mock = DebugMockBackend();
  static bool _useMock = false;

  static bool get usingMock => _allowMock && _useMock;

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
      if (!_allowMock) rethrow;
      _useMock = true;
      return _mock.join(token, deviceName);
    }
  }

  static Future<void> startTunnel(FxNetwork net) async {
    if (net.needsRejoin) throw StateError('Rejoin this network before connecting');
    try {
      await _m.invokeMethod('start', {'network': jsonEncode(net.toJson())});
    } on MissingPluginException {
      if (!_allowMock) rethrow;
      _useMock = true;
      await _mock.start(net);
    }
  }

  static Future<void> stopTunnel() async {
    try {
      await _m.invokeMethod('stop');
    } on MissingPluginException {
      if (!_allowMock) rethrow;
      _useMock = true;
      await _mock.stop();
    }
  }

  static Future<void> leave(FxNetwork net) async {
    try {
      await _m.invokeMethod('leave', {'network': jsonEncode(net.toJson())});
    } on MissingPluginException {
      if (!_allowMock) rethrow;
      _useMock = true;
      if (_mock.current.networkId == net.key) await _mock.stop();
    }
  }

  /// Cold-start / foreground sync: read LIVE state from the running tunnel.
  static Future<FxStateSnapshot> getCurrentState() async {
    try {
      final r = await _m.invokeMethod('getCurrentState');
      return FxStateSnapshot.fromJson(Map<String, dynamic>.from(r as Map));
    } on MissingPluginException {
      if (!_allowMock) rethrow;
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
    } on MissingPluginException {
      if (!_allowMock) rethrow;
      _useMock = true;
      // Mock: pretend nothing granted so the UI is exercisable standalone.
      return {
        'vpn': false,
        'battery': false,
        'notifications': false,
        'autostart': null,
      };
    }
  }

  static Future<void> requestVpn() => _grant('requestVpn');
  static Future<void> requestBatteryExemption() =>
      _grant('requestBatteryExemption');
  static Future<void> requestNotifications() => _grant('requestNotifications');
  static Future<void> openAutoStart() => _grant('openAutoStart');

  static Future<void> _grant(String method) async {
    try {
      await _m.invokeMethod(method);
    } on MissingPluginException {
      if (!_allowMock) rethrow;
      _useMock = true;
    }
  }

  /// Real-time status stream from the tunnel host.
  static Stream<FxStateSnapshot> statusStream() {
    if (_allowMock && _useMock) return _mock.stream;
    try {
      return _e.receiveBroadcastStream().map(
        (e) => FxStateSnapshot.fromJson(Map<String, dynamic>.from(e as Map)),
      );
    } on MissingPluginException {
      if (!_allowMock) rethrow;
      _useMock = true;
      return _mock.stream;
    }
  }
}
