// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../common/design/tokens.dart';
import '../state/app_controller.dart';
import '../tab_connect/view.dart';
import '../tab_me/view.dart';
import '../tab_networks/view.dart';

/// Root shell: optional demo banner + 3-tab bottom nav (Connect / Networks / Me).
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  final AppController _c = Get.find<AppController>();
  late int _i = _c.lastTab.clamp(0, 2);

  static const _pages = [ConnectTab(), NetworksTab(), MeTab()];

  void _select(int v) {
    setState(() => _i = v);
    _c.saveTab(v);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          Obx(() => _c.isMock.value
              ? const _DemoBanner()
              : const SizedBox.shrink()),
          Expanded(child: IndexedStack(index: _i, children: _pages)),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _i,
        onTap: _select,
        items: [
          BottomNavigationBarItem(
              icon: Icon(Icons.electrical_services),
              label: 'tab.connect'.tr),
          BottomNavigationBarItem(
              icon: Icon(Icons.hub_outlined), label: 'tab.networks'.tr),
          BottomNavigationBarItem(
              icon: Icon(Icons.person_outline), label: 'tab.me'.tr),
        ],
      ),
    );
  }
}

class _DemoBanner extends StatelessWidget {
  const _DemoBanner();

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Fx.warning.withValues(alpha: 0.14),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: FxSpace.x4, vertical: FxSpace.x2),
          child: Row(
            children: [
              Icon(Icons.science_outlined, size: 16, color: Fx.warning),
              const SizedBox(width: FxSpace.x2),
              Expanded(
                child: Text(
                  'Demo mode — no native tunnel; status is simulated',
                  style: FxText.caption.copyWith(color: Fx.warning),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
