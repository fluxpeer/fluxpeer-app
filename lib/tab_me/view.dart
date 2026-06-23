// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../backup/import_page.dart';
import '../common/design/tokens.dart';
import '../state/app_controller.dart';
import 'permissions_page.dart';

/// Me tab — DEVICE/APP-global scope only. Per-network identity (pubkey / overlay
/// / device_id) lives in each network's detail page, NOT here, because identity
/// is assigned per enrollment (one per joined network).
class MeTab extends StatelessWidget {
  const MeTab({super.key});

  @override
  Widget build(BuildContext context) {
    final c = Get.find<AppController>();
    return Scaffold(
      appBar: AppBar(title: Text('tab.me'.tr)),
      body: ListView(
        padding: const EdgeInsets.all(FxSpace.x4),
        children: [
          Obx(() => Card(
                child: ListTile(
                  leading: Icon(Icons.hub_outlined, color: Fx.fgSecondary),
                  title: Text('me.networksJoined'.trArgs(['${c.networks.length}']),
                      style: FxText.body),
                  subtitle: Text('me.identityHint'.tr, style: FxText.caption),
                ),
              )),
          const SizedBox(height: FxSpace.x4),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: Icon(Icons.ios_share, color: Fx.brandGlow),
                  title: Text('me.export'.tr, style: FxText.body),
                  subtitle: Text('me.backup'.tr, style: FxText.caption),
                  onTap: () => _exportSheet(context, c),
                ),
                Divider(height: 1, color: Fx.border),
                ListTile(
                  leading: Icon(Icons.download, color: Fx.brandGlow),
                  title: Text('me.import'.tr, style: FxText.body),
                  onTap: () => Get.to(() => const ImportPage()),
                ),
              ],
            ),
          ),
          const SizedBox(height: FxSpace.x4),
          Card(
            child: ListTile(
              leading: Icon(Icons.shield_outlined, color: Fx.fgSecondary),
              title: Text('me.permissions'.tr, style: FxText.body),
              subtitle: Text('perm.cardBody'.tr, style: FxText.caption),
              trailing: Icon(Icons.chevron_right, color: Fx.fgSecondary),
              onTap: () => Get.to(() => const PermissionsPage()),
            ),
          ),
          const SizedBox(height: FxSpace.x4),
          Obx(() {
            final net = c.active;
            if (net == null) return const SizedBox.shrink();
            return Card(
              child: ListTile(
                leading: Icon(Icons.swap_horiz, color: Fx.fgSecondary),
                title: Text('me.conn'.tr, style: FxText.body),
                subtitle:
                    Text('me.conn.${net.transportProtocol}'.tr, style: FxText.caption),
                onTap: () => _pickConnMode(context),
              ),
            );
          }),
          const SizedBox(height: FxSpace.x4),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: Icon(Icons.brightness_6, color: Fx.fgSecondary),
                  title: Text('me.theme'.tr, style: FxText.body),
                  onTap: () => _pickTheme(context),
                ),
                Divider(height: 1, color: Fx.border),
                ListTile(
                  leading: Icon(Icons.translate, color: Fx.fgSecondary),
                  title: Text('me.language'.tr, style: FxText.body),
                  onTap: () => _pickLanguage(context),
                ),
                Divider(height: 1, color: Fx.border),
                ListTile(
                  leading: Icon(Icons.info_outline, color: Fx.fgSecondary),
                  title: Text('me.about'.tr, style: FxText.body),
                  subtitle: Text('fluxpeer 1.0.0', style: FxText.caption),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _exportSheet(BuildContext context, AppController c) {
    if (c.networks.isEmpty) {
      Get.snackbar('', 'Nothing to export yet',
          colorText: Fx.fgPrimary, backgroundColor: Fx.bgElevated);
      return;
    }
    showDialog<void>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: Fx.bgElevated,
        title: Text('me.backup'.tr, style: FxText.heading),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(FxSpace.x3),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(FxRadius.md),
              ),
              child: QrImageView(
                  data: c.exportBackup(), version: QrVersions.auto, size: 220),
            ),
            const SizedBox(height: FxSpace.x3),
            TextButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: c.exportBackup()));
                Get.snackbar('', 'Copied',
                    colorText: Fx.fgPrimary, backgroundColor: Fx.bgElevated);
              },
              icon: Icon(Icons.copy, size: 16),
              label: const Text('Copy'),
            ),
          ],
        ),
      ),
    );
  }

  void _pickConnMode(BuildContext context) {
    final c = Get.find<AppController>();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Fx.bgSurface,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final m in const ['auto', 'anytls', 'tcp-bond'])
              ListTile(
                title: Text('me.conn.$m'.tr, style: FxText.body),
                subtitle: Text('me.conn.$m.desc'.tr, style: FxText.caption),
                trailing: (c.active?.transportProtocol ?? 'auto') == m
                    ? Icon(Icons.check, color: Fx.brandGlow)
                    : null,
                onTap: () {
                  c.setTransport(m);
                  Navigator.pop(ctx);
                },
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  FxSpace.x4, FxSpace.x2, FxSpace.x4, FxSpace.x4),
              child: Text('me.conn.note'.tr, style: FxText.caption),
            ),
          ],
        ),
      ),
    );
  }

  void _pickTheme(BuildContext context) {
    final c = Get.find<AppController>();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Fx.bgSurface,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final m in const ['system', 'dark', 'light'])
              ListTile(
                title: Text('me.theme.$m'.tr, style: FxText.body),
                trailing: c.themeMode == m
                    ? Icon(Icons.check, color: Fx.brandGlow)
                    : null,
                onTap: () {
                  c.setThemeMode(m);
                  Navigator.pop(ctx);
                },
              ),
          ],
        ),
      ),
    );
  }

  void _pickLanguage(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Fx.bgSurface,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text('English', style: FxText.body),
              onTap: () {
                Get.find<AppController>().setLanguage('en');
                Navigator.pop(ctx);
              },
            ),
            ListTile(
              title: Text('简体中文', style: FxText.body),
              onTap: () {
                Get.find<AppController>().setLanguage('zh_Hans');
                Navigator.pop(ctx);
              },
            ),
          ],
        ),
      ),
    );
  }
}
