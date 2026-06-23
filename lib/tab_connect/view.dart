// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../channel/fluxpeer_channel.dart';
import '../common/design/tokens.dart';
import '../join/join_page.dart';
import '../models/models.dart';
import '../state/app_controller.dart';
import '../status/status_page.dart';
import '../widgets/connect_ring.dart';
import '../widgets/network_switcher.dart';

String statusLabel(FxConnState s) => switch (s) {
      FxConnState.disconnected => 'connect.tapToConnect'.tr,
      FxConnState.authorizing => 'connect.authorizing'.tr,
      FxConnState.connecting => 'connect.connecting'.tr,
      FxConnState.connected => 'connect.connected'.tr,
      FxConnState.disconnecting => 'connect.disconnecting'.tr,
      FxConnState.error => 'connect.error'.tr,
    };

String _duration(int? ms) {
  if (ms == null) return '';
  final s = (DateTime.now().millisecondsSinceEpoch - ms) ~/ 1000;
  if (s < 0) return '';
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
  return h > 0
      ? '${h}h ${m}m ${sec}s'
      : '${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
}

class ConnectTab extends StatefulWidget {
  const ConnectTab({super.key});

  @override
  State<ConnectTab> createState() => _ConnectTabState();
}

class _ConnectTabState extends State<ConnectTab> {
  final AppController c = Get.find<AppController>();
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // tick the connected-duration label once a second
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && c.conn.value == FxConnState.connected) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final net = c.active;
      if (net == null) return _empty(context);
      final s = c.conn.value;
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(FxSpace.x6),
          child: Column(
            children: [
              InkWell(
                borderRadius: BorderRadius.circular(FxRadius.pill),
                onTap: () => showNetworkSwitcher(context),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: FxSpace.x4, vertical: FxSpace.x2),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(net.name, style: FxText.title),
                      Icon(Icons.expand_more, color: Fx.fgSecondary),
                    ],
                  ),
                ),
              ),
              const _KeepAliveHint(),
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ConnectRing(state: s, onTap: c.toggle),
                      const SizedBox(height: FxSpace.x6),
                      Text(statusLabel(s), style: FxText.heading),
                      if (s == FxConnState.connected) ...[
                        const SizedBox(height: FxSpace.x2),
                        if (c.overlay.value != null)
                          Text(c.overlay.value!, style: FxText.monoMuted),
                        const SizedBox(height: 2),
                        Text(_duration(c.connectedAtMs.value),
                            style: FxText.caption),
                      ],
                    ],
                  ),
                ),
              ),
              if (s == FxConnState.connected) _peerStrip(context),
              const SizedBox(height: FxSpace.x2),
            ],
          ),
        ),
      );
    });
  }

  Widget _peerStrip(BuildContext context) {
    final direct =
        c.peers.where((p) => p.transport == FxTransport.udpDirect).length;
    final relay =
        c.peers.where((p) => p.transport == FxTransport.relay).length;
    return InkWell(
      borderRadius: BorderRadius.circular(FxRadius.lg),
      onTap: () => Get.to(() => const StatusPage()),
      child: Container(
        padding: const EdgeInsets.all(FxSpace.x4),
        decoration: BoxDecoration(
          color: Fx.bgSurface,
          borderRadius: BorderRadius.circular(FxRadius.lg),
          border: Border.all(color: Fx.border),
        ),
        child: Row(
          children: [
            Icon(Icons.hub_outlined, color: Fx.brandGlow, size: 20),
            const SizedBox(width: FxSpace.x3),
            Text('${c.peers.length} ${'connect.peers'.tr}', style: FxText.body),
            const SizedBox(width: FxSpace.x3),
            if (direct > 0) ...[
              Icon(Icons.bolt, size: 15, color: Fx.accent),
              Text('$direct', style: FxText.caption),
              const SizedBox(width: FxSpace.x2),
            ],
            if (relay > 0) ...[
              Icon(Icons.swap_horiz, size: 15, color: Fx.warning),
              Text('$relay', style: FxText.caption),
            ],
            const Spacer(),
            Icon(Icons.chevron_right, color: Fx.fgMuted),
          ],
        ),
      ),
    );
  }

  Widget _empty(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(FxSpace.x8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.hub_outlined, size: 64, color: Fx.fgMuted),
            const SizedBox(height: FxSpace.x4),
            Text('connect.noNetwork'.tr, style: FxText.label),
            const SizedBox(height: FxSpace.x6),
            FilledButton.icon(
              onPressed: () => Get.to(() => const JoinPage()),
              icon: Icon(Icons.add),
              label: Text('connect.scanToJoin'.tr),
            ),
          ],
        ),
      ),
    );
  }
}

/// First-connect guidance banner: nudges the user to grant the keep-alive
/// permissions so the tunnel survives screen-off / background. Shows only when a
/// permission that matters is missing; dismissible for the session. Reloads on
/// resume (the grant flow leaves the app).
class _KeepAliveHint extends StatefulWidget {
  const _KeepAliveHint();

  @override
  State<_KeepAliveHint> createState() => _KeepAliveHintState();
}

class _KeepAliveHintState extends State<_KeepAliveHint> with WidgetsBindingObserver {
  static bool _dismissed = false;
  bool _needed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _reload();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _reload();
  }

  Future<void> _reload() async {
    final s = await FluxpeerChannel.permissionStatus();
    // On Android the battery-optimization exemption is the one that actually
    // prevents idle kills; VPN must be authorized everywhere.
    final missing = s['vpn'] == false || (Platform.isAndroid && s['battery'] == false);
    if (mounted) setState(() => _needed = missing);
  }

  @override
  Widget build(BuildContext context) {
    if (_dismissed || !_needed) return const SizedBox.shrink();
    return Card(
      color: Fx.brandGlow.withValues(alpha: 0.10),
      margin: const EdgeInsets.only(top: FxSpace.x2),
      child: Padding(
        padding: const EdgeInsets.all(FxSpace.x4),
        child: Row(
          children: [
            Icon(Icons.shield_moon_outlined, color: Fx.brandGlow),
            const SizedBox(width: FxSpace.x3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('perm.cardTitle'.tr, style: FxText.body),
                  const SizedBox(height: 2),
                  Text('perm.cardBody'.tr, style: FxText.caption),
                ],
              ),
            ),
            const SizedBox(width: FxSpace.x2),
            Column(
              children: [
                TextButton(
                  onPressed: () async {
                    if (Platform.isAndroid) await FluxpeerChannel.requestBatteryExemption();
                    await FluxpeerChannel.requestVpn();
                    _reload();
                  },
                  child: Text('perm.cardCta'.tr),
                ),
                GestureDetector(
                  onTap: () => setState(() => _dismissed = true),
                  child: Text('perm.later'.tr, style: FxText.caption),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
