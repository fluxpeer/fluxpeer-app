// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../common/design/tokens.dart';
import '../join/join_page.dart';
import '../settings/settings_page.dart';
import '../state/app_controller.dart';

class NetworksTab extends StatelessWidget {
  const NetworksTab({super.key});

  @override
  Widget build(BuildContext context) {
    final c = Get.find<AppController>();
    return Scaffold(
      appBar: AppBar(
        title: Text('net.title'.tr),
        actions: [
          IconButton(
            icon: Icon(Icons.add),
            tooltip: 'net.join'.tr,
            onPressed: () => Get.to(() => const JoinPage()),
          ),
        ],
      ),
      body: Obx(() {
        if (c.networks.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(FxSpace.x8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.qr_code_scanner, size: 56, color: Fx.fgMuted),
                  const SizedBox(height: FxSpace.x4),
                  Text('net.empty'.tr,
                      textAlign: TextAlign.center, style: FxText.label),
                ],
              ),
            ),
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.all(FxSpace.x4),
          itemCount: c.networks.length,
          separatorBuilder: (_, _) => const SizedBox(height: FxSpace.x2),
          itemBuilder: (_, i) {
            final n = c.networks[i];
            final active = n.id == c.activeId.value;
            return Card(
              child: ListTile(
                leading: Icon(Icons.hub_outlined,
                    color: active ? Fx.brandGlow : Fx.fgMuted),
                title: Text(n.name, style: FxText.body),
                subtitle: Text(n.overlayV4 ?? n.controlUrl,
                    style: FxText.monoMuted),
                trailing: PopupMenuButton<String>(
                  color: Fx.bgElevated,
                  tooltip: 'settings.title'.tr,
                  onSelected: (v) {
                    if (v == 'settings') {
                      Get.to(() => SettingsPage(n));
                    } else if (v == 'rename') {
                      _renameDialog(context, c, n.id, n.name);
                    } else if (v == 'leave') {
                      c.leave(n.id);
                    }
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                        value: 'settings',
                        child: Text('settings.title'.tr,
                            style: TextStyle(color: Fx.fgPrimary))),
                    PopupMenuItem(
                        value: 'rename',
                        child: Text('net.rename'.tr,
                            style: TextStyle(color: Fx.fgPrimary))),
                    PopupMenuItem(
                        value: 'leave',
                        child: Text('net.leave'.tr,
                            style: TextStyle(color: Fx.danger))),
                  ],
                ),
                onTap: () => c.switchTo(n.id),
              ),
            );
          },
        );
      }),
    );
  }

  void _renameDialog(
      BuildContext context, AppController c, String id, String current) {
    final ctrl = TextEditingController(text: current);
    showDialog<void>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: Fx.bgElevated,
        title: Text('net.rename'.tr, style: FxText.heading),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: FxText.body,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              c.rename(id, ctrl.text);
              Navigator.pop(dctx);
            },
            child: Text('net.rename'.tr),
          ),
        ],
      ),
    );
  }
}
