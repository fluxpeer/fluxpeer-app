// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:get_storage/get_storage.dart';

import '../channel/fluxpeer_channel.dart';
import '../common/app_theme.dart';
import '../common/design/tokens.dart';
import '../models/models.dart';

/// Central app state: joined networks (persisted locally), the active network,
/// live tunnel connection state + peers. Bridges the platform channel and the
/// UI. Cold-start restores from storage AND syncs live state from the running
/// tunnel (the tunnel lives in the OS NE/VpnService process, not this one).
class AppController extends GetxController with WidgetsBindingObserver {
  final RxList<FxNetwork> networks = <FxNetwork>[].obs;
  final RxnString activeId = RxnString();
  final Rx<FxConnState> conn = FxConnState.disconnected.obs;
  final RxList<FxPeer> peers = <FxPeer>[].obs;
  final RxnString overlay = RxnString();
  final RxnInt connectedAtMs = RxnInt();
  final RxBool isMock = false.obs;

  final GetStorage _box = GetStorage();
  StreamSubscription<FxStateSnapshot>? _sub;

  static const _kNetworks = 'networks';
  static const _kActive = 'activeId';
  static const _kTab = 'tab';
  static const _kTheme = 'themeMode';

  FxNetwork? get active {
    for (final n in networks) {
      if (n.id == activeId.value) return n;
    }
    return null;
  }

  bool get isBusy =>
      conn.value == FxConnState.connecting ||
      conn.value == FxConnState.authorizing;

  bool get isOn => conn.value == FxConnState.connected || isBusy;

  @override
  void onInit() {
    super.onInit();
    WidgetsBinding.instance.addObserver(this); // resume → re-sync from the tunnel host
    _load();
    _init();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The tunnel runs in the VpnService/NE process independent of the UI; on
    // foreground, pull the live state so the UI reflects reality (it may have
    // connected/dropped while we were backgrounded).
    if (state == AppLifecycleState.resumed) refreshStatus();
  }

  Future<void> _init() async {
    // Cold-start sync first — primes mock detection if the native tunnel host is
    // absent — then subscribe to the live status stream.
    await _coldSync();
    isMock.value = FluxpeerChannel.usingMock;
    if (isMock.value && networks.isEmpty) _seedDemo();
    _sub = FluxpeerChannel.statusStream().listen(_apply);
  }

  /// Demo networks so the full flow is explorable without enrolling (mock only).
  void _seedDemo() {
    networks.assignAll(const [
      FxNetwork(
        id: 'demo-home',
        name: 'home-net',
        controlUrl: 'https://demo.fluxpeer.dev',
        overlayV4: '100.72.16.5',
        deviceId: 'phone-01',
        pubkey: 'mock-pk-home-9f2a7c1b',
        dns: ['1.1.1.1'],
      ),
      FxNetwork(
        id: 'demo-lab',
        name: 'lab-mesh',
        controlUrl: 'https://lab.fluxpeer.dev',
        overlayV4: '100.72.40.2',
        deviceId: 'phone-01',
        pubkey: 'mock-pk-lab-3b81de07',
        exitNode: true,
        excludeRoutes: ['192.168.0.0/16'],
      ),
    ]);
    activeId.value = 'demo-home';
    _persist();
  }

  void _load() {
    final raw = _box.read<List>(_kNetworks) ?? const [];
    networks.assignAll(
      raw.map((e) => FxNetwork.fromJson(Map<String, dynamic>.from(e as Map))),
    );
    activeId.value =
        _box.read<String>(_kActive) ?? (networks.isEmpty ? null : networks.first.id);
  }

  void _persist() {
    _box.write(_kNetworks, networks.map((n) => n.toJson()).toList());
    final id = activeId.value;
    if (id != null) _box.write(_kActive, id);
  }

  Future<void> _coldSync() async {
    _apply(await FluxpeerChannel.getCurrentState());
  }

  void _apply(FxStateSnapshot s) {
    conn.value = s.state;
    peers.assignAll(s.peers);
    overlay.value = s.overlayV4 ?? active?.overlayV4;
    connectedAtMs.value = s.connectedAtMs;
    if (s.networkId != null && s.state != FxConnState.disconnected) {
      activeId.value = s.networkId;
    }
  }

  Future<FxNetwork> joinToken(String token, String device) async {
    final net = await FluxpeerChannel.join(token, device);
    networks.add(net);
    activeId.value = net.id;
    _persist();
    return net;
  }

  Future<void> toggle() async {
    final net = active;
    if (net == null) return;
    if (isOn) {
      conn.value = FxConnState.disconnecting;
      await FluxpeerChannel.stopTunnel();
    } else {
      conn.value = FxConnState.connecting;
      await FluxpeerChannel.startTunnel(net);
    }
  }

  Future<void> switchTo(String id) async {
    if (id == activeId.value) return;
    if (isOn) await FluxpeerChannel.stopTunnel();
    activeId.value = id;
    _persist();
  }

  void leave(String id) {
    networks.removeWhere((n) => n.id == id);
    if (activeId.value == id) {
      activeId.value = networks.isEmpty ? null : networks.first.id;
    }
    _persist();
  }

  void updateNetwork(FxNetwork net) {
    final i = networks.indexWhere((n) => n.id == net.id);
    if (i >= 0) networks[i] = net;
    _persist();
  }

  /// Set the active network's connection mode ('auto' | 'anytls' | 'tcp-bond').
  /// Takes effect on the next (re)connect.
  void setTransport(String proto) {
    final n = active;
    if (n != null) updateNetwork(n.copyWith(transportProtocol: proto));
  }

  void rename(String id, String name) {
    final i = networks.indexWhere((n) => n.id == id);
    if (i >= 0 && name.trim().isNotEmpty) {
      networks[i] = networks[i].copyWith(name: name.trim());
      _persist();
    }
  }

  Future<void> refreshStatus() async =>
      _apply(await FluxpeerChannel.getCurrentState());

  bool get usingMock => FluxpeerChannel.usingMock;

  int get lastTab => _box.read<int>(_kTab) ?? 0;
  void saveTab(int i) => _box.write(_kTab, i);

  // theme: 'system' | 'dark' | 'light'
  String get themeMode => _box.read<String>(_kTheme) ?? 'system';

  void applyThemeAtStartup() => _applyMode(themeMode);

  void setThemeMode(String m) {
    _box.write(_kTheme, m);
    _applyMode(m);
    Get.changeTheme(buildFluxpeerTheme());
  }

  // language: 'en' | 'zh_Hans' (persisted). Absent = follow the system locale.
  static const _kLang = 'lang';

  String? get savedLang => _box.read<String>(_kLang);

  /// Startup locale: an explicit saved choice wins; otherwise follow the device
  /// locale (zh → Simplified Chinese), falling back to English. Fixes the app
  /// defaulting to English on a zh-locale device (QA F3).
  Locale get startupLocale {
    switch (savedLang) {
      case 'zh_Hans':
        return const Locale('zh', 'Hans');
      case 'en':
        return const Locale('en');
    }
    final sys = WidgetsBinding.instance.platformDispatcher.locale;
    return sys.languageCode == 'zh' ? const Locale('zh', 'Hans') : const Locale('en');
  }

  /// Persist + apply a language choice from the Language picker.
  void setLanguage(String code) {
    _box.write(_kLang, code);
    Get.updateLocale(code == 'zh_Hans' ? const Locale('zh', 'Hans') : const Locale('en'));
  }

  void _applyMode(String m) {
    final dark = switch (m) {
      'dark' => true,
      'light' => false,
      _ => WidgetsBinding.instance.platformDispatcher.platformBrightness ==
          Brightness.dark,
    };
    Fx.applyDark(dark);
  }

  /// Export all joined networks as a JSON backup (for reinstall recovery).
  String exportBackup() =>
      jsonEncode(networks.map((n) => n.toJson()).toList());

  /// Import a JSON backup; returns the number of new networks added.
  int importBackup(String raw) {
    final list = jsonDecode(raw) as List;
    var added = 0;
    for (final e in list) {
      final n = FxNetwork.fromJson(Map<String, dynamic>.from(e as Map));
      if (!networks.any((x) => x.id == n.id)) {
        networks.add(n);
        added++;
      }
    }
    if (activeId.value == null && networks.isNotEmpty) {
      activeId.value = networks.first.id;
    }
    _persist();
    return added;
  }

  @override
  void onClose() {
    WidgetsBinding.instance.removeObserver(this);
    _sub?.cancel();
    super.onClose();
  }
}
