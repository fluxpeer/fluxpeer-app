// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../common/design/tokens.dart';
import '../state/app_controller.dart';

/// Join a network: scan a QR or paste a token. Parses an `fp://join/<base64>`
/// token and hands it to the FFI `join` (enroll + persist) via the controller.
/// (File import deferred — the file_picker plugin's gradle was incompatible.)
class JoinPage extends StatefulWidget {
  const JoinPage({super.key});

  @override
  State<JoinPage> createState() => _JoinPageState();
}

class _JoinPageState extends State<JoinPage> {
  int _tab = 1; // default to paste/import (not the camera)
  final _token = TextEditingController();
  final _device = TextEditingController();
  bool _busy = false;
  bool _handled = false;

  @override
  void dispose() {
    _token.dispose();
    _device.dispose();
    super.dispose();
  }

  void _toast(String msg) => Get.snackbar('', msg,
      colorText: Fx.fgPrimary, backgroundColor: Fx.bgElevated);

  Future<void> _join(String token) async {
    if (_busy) return;
    final t = token.trim();
    if (!t.startsWith('fp://join/')) {
      _handled = false;
      _toast("That doesn't look like a fluxpeer invite (expected fp://join/…)");
      return;
    }
    setState(() => _busy = true);
    try {
      final net =
          await Get.find<AppController>().joinToken(t, _device.text.trim());
      if (!mounted) return;
      Navigator.pop(context);
      _toast('Joined ${net.name}');
    } catch (_) {
      _handled = false;
      _toast("Couldn't join — check the invite and your connection, then retry");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('join.title'.tr)),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(FxSpace.x4),
            child: SegmentedButton<int>(
              segments: [
                ButtonSegment(value: 1, label: Text('join.paste'.tr)),
                ButtonSegment(value: 0, label: Text('join.scan'.tr)),
              ],
              selected: {_tab},
              onSelectionChanged: (s) => setState(() => _tab = s.first),
            ),
          ),
          Expanded(child: _tab == 0 ? _scanView() : _pasteView()),
        ],
      ),
    );
  }

  Widget _scanView() {
    return Stack(
      alignment: Alignment.center,
      children: [
        MobileScanner(
          onDetect: (capture) {
            if (_handled) return;
            final raw = capture.barcodes.isNotEmpty
                ? capture.barcodes.first.rawValue
                : null;
            if (raw != null && raw.startsWith('fp://join/')) {
              _handled = true;
              _join(raw);
            }
          },
        ),
        Container(
          width: 220,
          height: 220,
          decoration: BoxDecoration(
            border: Border.all(color: Fx.brandGlow, width: 2),
            borderRadius: BorderRadius.circular(FxRadius.xl),
          ),
        ),
        Positioned(
          bottom: FxSpace.x12,
          child: Text('join.scanHint'.tr, style: FxText.body),
        ),
      ],
    );
  }

  Widget _pasteView() {
    return Padding(
      padding: const EdgeInsets.all(FxSpace.x4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Explicit a11y label + stable test identifier: the bare
          // TextField exposed no accessibility name / addressable id.
          Semantics(
            identifier: 'joinTokenField',
            label: 'join.pasteHint'.tr,
            textField: true,
            child: TextField(
              controller: _token,
              maxLines: 3,
              style: FxText.mono,
              decoration: InputDecoration(
                labelText: 'join.pasteHint'.tr,
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(height: FxSpace.x4),
          Semantics(
            identifier: 'joinDeviceField',
            label: 'join.deviceName'.tr,
            textField: true,
            child: TextField(
              controller: _device,
              style: FxText.body,
              decoration: InputDecoration(
                labelText: 'join.deviceName'.tr,
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(height: FxSpace.x6),
          FilledButton(
            onPressed: _busy ? null : () => _join(_token.text),
            child: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : Text('join.confirm'.tr),
          ),
        ],
      ),
    );
  }
}
