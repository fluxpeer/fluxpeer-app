// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../common/design/tokens.dart';
import '../common/format.dart';
import '../models/models.dart';
import '../state/app_controller.dart';

/// Status / monitor: interface card + peers list (wg-show style, mobile-friendly).
class StatusPage extends StatelessWidget {
  const StatusPage({super.key});

  @override
  Widget build(BuildContext context) {
    final c = Get.find<AppController>();
    return Scaffold(
      appBar: AppBar(title: Text('status.title'.tr)),
      body: Obx(() {
        final net = c.active;
        final totalRx = c.peers.fold<int>(0, (a, p) => a + p.rxBytes);
        final totalTx = c.peers.fold<int>(0, (a, p) => a + p.txBytes);
        return RefreshIndicator(
          onRefresh: c.refreshStatus,
          color: Fx.brandGlow,
          backgroundColor: Fx.bgSurface,
          child: ListView(
            padding: const EdgeInsets.all(FxSpace.x4),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(FxSpace.x4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('status.interface'.tr, style: FxText.label),
                      const SizedBox(height: FxSpace.x3),
                      _row('status.overlay'.tr, c.overlay.value ?? '—',
                          mono: true),
                      if (net?.pubkey != null)
                        _row('pubkey', shortKey(net!.pubkey!), mono: true),
                      _row('status.uptime'.tr, _uptime(c.connectedAtMs.value)),
                      _row('status.transfer'.tr,
                          '↓${fmtBytes(totalRx)}  ↑${fmtBytes(totalTx)}'),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: FxSpace.x4),
              Text('${c.peers.length} ${'connect.peers'.tr}',
                  style: FxText.label),
              const SizedBox(height: FxSpace.x2),
              if (c.peers.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(FxSpace.x6),
                  child: Center(child: Text('—', style: FxText.caption)),
                ),
              ...c.peers.map(_peerTile),
            ],
          ),
        );
      }),
    );
  }

  String _uptime(int? ms) {
    if (ms == null) return '—';
    final s = (DateTime.now().millisecondsSinceEpoch - ms) ~/ 1000;
    final h = s ~/ 3600, m = (s % 3600) ~/ 60;
    return h > 0 ? '${h}h ${m}m' : '${m}m ${s % 60}s';
  }

  Widget _row(String k, String v, {bool mono = false}) => Padding(
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

  Widget _peerTile(FxPeer p) {
    final direct = p.transport == FxTransport.udpDirect;
    return Card(
      margin: const EdgeInsets.only(bottom: FxSpace.x2),
      child: Padding(
        padding: const EdgeInsets.all(FxSpace.x3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Tooltip(
                  message: direct
                      ? 'status.transport.udpDirect'.tr
                      : 'status.transport.relay'.tr,
                  child: Icon(direct ? Icons.bolt : Icons.swap_horiz,
                      size: 18, color: direct ? Fx.accent : Fx.warning),
                ),
                const SizedBox(width: FxSpace.x2),
                Expanded(
                  child: Text(p.name,
                      style: FxText.body.copyWith(fontWeight: FontWeight.w600)),
                ),
                Text(p.rttMs != null ? '${p.rttMs}ms' : '—',
                    style: FxText.caption),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Text(p.endpoint ?? '—', style: FxText.monoMuted),
                const Spacer(),
                Text(agoMs(p.lastHandshakeMs), style: FxText.caption),
              ],
            ),
            const SizedBox(height: 2),
            Text('↓${fmtBytes(p.rxBytes)}  ↑${fmtBytes(p.txBytes)}',
                style: FxText.caption),
          ],
        ),
      ),
    );
  }
}
