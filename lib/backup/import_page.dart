// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../common/design/tokens.dart';
import '../state/app_controller.dart';

/// Second-level page to import a config backup (JSON exported from another
/// device). Replaces the old dialog.
class ImportPage extends StatefulWidget {
  const ImportPage({super.key});

  @override
  State<ImportPage> createState() => _ImportPageState();
}

class _ImportPageState extends State<ImportPage> {
  final _ctrl = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _toast(String msg) => Get.snackbar('', msg,
      colorText: Fx.fgPrimary, backgroundColor: Fx.bgElevated);

  void _import() {
    if (_busy) return;
    final raw = _ctrl.text.trim();
    if (raw.isEmpty) return;
    setState(() => _busy = true);
    try {
      final n = Get.find<AppController>().importBackup(raw);
      if (!mounted) return;
      Navigator.pop(context);
      _toast('Imported $n network(s)');
    } catch (_) {
      if (mounted) _toast("That backup couldn't be read");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('me.import'.tr)),
      body: Padding(
        padding: const EdgeInsets.all(FxSpace.x4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('me.importHint'.tr, style: FxText.caption),
            const SizedBox(height: FxSpace.x4),
            TextField(
              controller: _ctrl,
              maxLines: 8,
              style: FxText.monoMuted,
              decoration: const InputDecoration(
                hintText: 'Paste backup JSON',
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: FxSpace.x6),
            FilledButton(
              onPressed: _busy ? null : _import,
              child: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : Text('me.import'.tr),
            ),
          ],
        ),
      ),
    );
  }
}
