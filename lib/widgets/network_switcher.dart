// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../common/design/tokens.dart';
import '../join/join_page.dart';
import '../state/app_controller.dart';

/// Bottom-sheet network switcher.
Future<void> showNetworkSwitcher(BuildContext context) {
  final c = Get.find<AppController>();
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Fx.bgSurface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(FxRadius.xl2)),
    ),
    builder: (sheetCtx) => SafeArea(
      child: Obx(
        () => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              margin: const EdgeInsets.symmetric(vertical: FxSpace.x3),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Fx.border,
                borderRadius: BorderRadius.circular(FxRadius.pill),
              ),
            ),
            ...c.networks.map(
              (n) => ListTile(
                leading: Icon(
                  Icons.hub_outlined,
                  color: n.id == c.activeId.value ? Fx.brandGlow : Fx.fgMuted,
                ),
                title: Text(n.name,
                    style: TextStyle(color: Fx.fgPrimary)),
                subtitle: n.overlayV4 != null
                    ? Text(n.overlayV4!,
                        style: TextStyle(color: Fx.fgMuted, fontSize: 12))
                    : null,
                trailing: n.id == c.activeId.value
                    ? Icon(Icons.check, color: Fx.brandGlow)
                    : null,
                onTap: () {
                  c.switchTo(n.id);
                  Navigator.pop(sheetCtx);
                },
              ),
            ),
            Divider(height: 1, color: Fx.border),
            ListTile(
              leading: Icon(Icons.add, color: Fx.brandGlow),
              title: Text('net.join'.tr,
                  style: TextStyle(color: Fx.brandGlow)),
              onTap: () {
                Navigator.pop(sheetCtx);
                Get.to(() => const JoinPage());
              },
            ),
            const SizedBox(height: FxSpace.x4),
          ],
        ),
      ),
    ),
  );
}
