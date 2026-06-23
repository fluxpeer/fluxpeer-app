// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../channel/fluxpeer_channel.dart';
import '../common/design/tokens.dart';

/// Second-level page that gathers every system-permission / keep-alive knob
/// (VPN authorization, notifications, battery optimization, auto-start) in one
/// place. Each row shows on/off and taps to grant. Reloads on app resume (the
/// grant flows leave the app for OS settings).
class PermissionsPage extends StatefulWidget {
  const PermissionsPage({super.key});

  @override
  State<PermissionsPage> createState() => _PermissionsPageState();
}

class _PermissionsPageState extends State<PermissionsPage>
    with WidgetsBindingObserver {
  Map<String, dynamic> _status = const {};

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
    if (mounted) setState(() => _status = s);
  }

  Future<void> _act(Future<void> Function() f) async {
    await f();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[
      _row(Icons.vpn_key, 'perm.vpn', _status['vpn'],
          () => _act(FluxpeerChannel.requestVpn)),
      _row(Icons.notifications_active_outlined, 'perm.notifications',
          _status['notifications'],
          () => _act(FluxpeerChannel.requestNotifications)),
    ];
    // Battery + auto-start are Android-only knobs (the engine handles iOS keepalive).
    if (Platform.isAndroid) {
      rows.add(_row(Icons.battery_saver, 'perm.battery', _status['battery'],
          () => _act(FluxpeerChannel.requestBatteryExemption)));
      rows.add(_row(Icons.restart_alt, 'perm.autostart', _status['autostart'],
          () => _act(FluxpeerChannel.openAutoStart)));
    }

    return Scaffold(
      appBar: AppBar(title: Text('me.permissions'.tr)),
      body: ListView(
        padding: const EdgeInsets.all(FxSpace.x4),
        children: [
          Text('perm.cardBody'.tr, style: FxText.caption),
          const SizedBox(height: FxSpace.x4),
          Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                      FxSpace.x4, FxSpace.x3, FxSpace.x4, 0),
                  child: Text('me.keepalive'.tr, style: FxText.caption),
                ),
                for (int i = 0; i < rows.length; i++) ...[
                  if (i > 0) Divider(height: 1, color: Fx.border),
                  rows[i],
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(IconData icon, String titleKey, Object? state, VoidCallback onTap) {
    // state: true = on, false = off, null = can't query (e.g. auto-start) → action only.
    final Widget trailing;
    if (state == true) {
      trailing = _chip('perm.on'.tr, Fx.success);
    } else if (state == false) {
      trailing = _chip('perm.off'.tr, Fx.danger);
    } else {
      trailing = _chip('perm.goSettings'.tr, Fx.fgSecondary);
    }
    return ListTile(
      leading: Icon(icon, color: Fx.fgSecondary),
      title: Text(titleKey.tr, style: FxText.body),
      trailing: trailing,
      onTap: onTap,
    );
  }

  Widget _chip(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(
            horizontal: FxSpace.x3, vertical: FxSpace.x1),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(FxRadius.pill),
        ),
        child: Text(text, style: FxText.caption.copyWith(color: color)),
      );
}
