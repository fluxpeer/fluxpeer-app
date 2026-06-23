// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../common/design/tokens.dart';
import '../common/format.dart';
import '../models/models.dart';
import '../state/app_controller.dart';

/// Per-network detail: identity (read-only — assigned at enrollment) + editable
/// settings (MTU / DNS / exit-node / excluded subnets).
class SettingsPage extends StatefulWidget {
  const SettingsPage(this.net, {super.key});
  final FxNetwork net;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _mtu;
  late final TextEditingController _dns;
  late final TextEditingController _exclude;
  late bool _exit;

  @override
  void initState() {
    super.initState();
    _mtu = TextEditingController(text: '${widget.net.mtu}');
    _dns = TextEditingController(text: widget.net.dns.join(', '));
    _exclude = TextEditingController(text: widget.net.excludeRoutes.join(', '));
    _exit = widget.net.exitNode;
  }

  @override
  void dispose() {
    _mtu.dispose();
    _dns.dispose();
    _exclude.dispose();
    super.dispose();
  }

  List<String> _csv(String s) =>
      s.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

  void _save() {
    final updated = widget.net.copyWith(
      mtu: int.tryParse(_mtu.text.trim()) ?? widget.net.mtu,
      dns: _csv(_dns.text),
      exitNode: _exit,
      excludeRoutes: _csv(_exclude.text),
    );
    Get.find<AppController>().updateNetwork(updated);
    Navigator.pop(context);
    Get.snackbar('', 'settings.applyHint'.tr,
        colorText: Fx.fgPrimary, backgroundColor: Fx.bgElevated);
  }

  void _identityQr() {
    final pk = widget.net.pubkey;
    if (pk == null) return;
    showDialog<void>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: Fx.bgElevated,
        title: Text('settings.identity'.tr, style: FxText.heading),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(FxSpace.x3),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(FxRadius.md),
              ),
              child: QrImageView(data: pk, version: QrVersions.auto, size: 220),
            ),
            const SizedBox(height: FxSpace.x3),
            TextButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: pk));
                Get.snackbar('', 'Copied',
                    colorText: Fx.fgPrimary, backgroundColor: Fx.bgElevated);
              },
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('Copy'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _idRow(String k, String v, {bool mono = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(k, style: FxText.caption),
            Flexible(
              child: Text(v,
                  textAlign: TextAlign.end,
                  style: mono ? FxText.mono : FxText.body),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final n = widget.net;
    return Scaffold(
      appBar: AppBar(
        title: Text(n.name),
        actions: [
          if (n.pubkey != null)
            IconButton(
              icon: const Icon(Icons.qr_code),
              tooltip: 'settings.identity'.tr,
              onPressed: _identityQr,
            ),
          IconButton(icon: const Icon(Icons.check), onPressed: _save),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(FxSpace.x4),
        children: [
          // identity — read-only, assigned per enrollment
          Card(
            child: Padding(
              padding: const EdgeInsets.all(FxSpace.x4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('settings.identity'.tr, style: FxText.label),
                  const SizedBox(height: FxSpace.x2),
                  _idRow('device', n.deviceId ?? '—'),
                  _idRow('me.pubkey'.tr,
                      n.pubkey != null ? shortKey(n.pubkey!) : '—',
                      mono: true),
                  _idRow('status.overlay'.tr, n.overlayV4 ?? '—', mono: true),
                  _idRow('control', n.controlUrl, mono: true),
                ],
              ),
            ),
          ),
          const SizedBox(height: FxSpace.x4),
          TextField(
            controller: _mtu,
            keyboardType: TextInputType.number,
            style: FxText.body,
            decoration: InputDecoration(
                labelText: 'settings.mtu'.tr,
                border: const OutlineInputBorder()),
          ),
          const SizedBox(height: FxSpace.x4),
          TextField(
            controller: _dns,
            style: FxText.body,
            decoration: InputDecoration(
                labelText: 'settings.dns'.tr,
                hintText: '1.1.1.1, 9.9.9.9',
                border: const OutlineInputBorder()),
          ),
          const SizedBox(height: FxSpace.x4),
          SwitchListTile(
            value: _exit,
            onChanged: (v) => setState(() => _exit = v),
            title: Text('settings.exitNode'.tr, style: FxText.body),
            contentPadding: EdgeInsets.zero,
          ),
          const SizedBox(height: FxSpace.x4),
          TextField(
            controller: _exclude,
            maxLines: 3,
            style: FxText.body,
            decoration: InputDecoration(
                labelText: 'settings.exclude'.tr,
                hintText: '192.168.0.0/16, 10.0.0.0/8',
                border: const OutlineInputBorder()),
          ),
          const SizedBox(height: FxSpace.x4),
          Text('settings.applyHint'.tr, style: FxText.caption),
        ],
      ),
    );
  }
}
