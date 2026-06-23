// SPDX-License-Identifier: AGPL-3.0-or-later
// Small formatting helpers shared across views.

String fmtBytes(int b) {
  if (b < 1024) return '${b}B';
  final kb = b / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(0)}K';
  final mb = kb / 1024;
  if (mb < 1024) return '${mb.toStringAsFixed(1)}M';
  return '${(mb / 1024).toStringAsFixed(1)}G';
}

String shortKey(String k) => k.length <= 12 ? k : '${k.substring(0, 10)}…';

String agoMs(int? ms) {
  if (ms == null) return '—';
  final secs = (DateTime.now().millisecondsSinceEpoch - ms) ~/ 1000;
  if (secs < 60) return '${secs}s';
  if (secs < 3600) return '${secs ~/ 60}m';
  return '${secs ~/ 3600}h';
}
