// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';

import '../common/design/tokens.dart';
import '../models/models.dart';

/// The main connect control: a clean circular power button with a status ring.
/// Tapping toggles the tunnel. Appearance follows [state]:
/// grey outline when disconnected, amber pulse when connecting, a filled
/// indigo→cyan disc with a glow when connected, red on error.
class ConnectRing extends StatefulWidget {
  const ConnectRing({
    super.key,
    required this.state,
    required this.onTap,
    this.size = 220,
  });

  final FxConnState state;
  final VoidCallback onTap;
  final double size;

  @override
  State<ConnectRing> createState() => _ConnectRingState();
}

class _ConnectRingState extends State<ConnectRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  bool get _busy =>
      widget.state == FxConnState.connecting ||
      widget.state == FxConnState.authorizing ||
      widget.state == FxConnState.disconnecting;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );
    if (_busy) _pulse.repeat();
  }

  @override
  void didUpdateWidget(ConnectRing old) {
    super.didUpdateWidget(old);
    if (old.state != widget.state) {
      if (_busy) {
        _pulse.repeat();
      } else {
        _pulse.stop();
        _pulse.value = 0;
      }
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final connected = widget.state == FxConnState.connected;
    return GestureDetector(
      onTap: widget.onTap,
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: AnimatedBuilder(
          animation: _pulse,
          builder: (_, child) => CustomPaint(
            painter: _PowerRingPainter(state: widget.state, pulse: _pulse.value),
            child: child,
          ),
          child: Center(
            child: Icon(
              Icons.power_settings_new_rounded,
              size: widget.size * 0.30,
              color: connected ? Fx.fgOnBrand : _accent(widget.state),
            ),
          ),
        ),
      ),
    );
  }
}

Color _accent(FxConnState s) => switch (s) {
      FxConnState.disconnected => Fx.fgSecondary,
      FxConnState.authorizing ||
      FxConnState.connecting ||
      FxConnState.disconnecting =>
        Fx.warning,
      FxConnState.connected => Fx.brand,
      FxConnState.error => Fx.danger,
    };

class _PowerRingPainter extends CustomPainter {
  _PowerRingPainter({required this.state, required this.pulse});

  final FxConnState state;
  final double pulse;

  bool get _busy =>
      state == FxConnState.connecting ||
      state == FxConnState.authorizing ||
      state == FxConnState.disconnecting;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final ringR = size.width * 0.40;
    final accent = _accent(state);
    final connected = state == FxConnState.connected;

    // expanding pulse halos while connecting
    if (_busy) {
      for (final delay in const [0.0, 0.4, 0.8]) {
        final t = (pulse + (1 - delay)) % 1.0;
        final r = ringR * (1.0 + 0.45 * t);
        final op = (0.40 * (1 - t)).clamp(0.0, 0.40);
        canvas.drawCircle(
          center,
          r,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3
            ..color = accent.withValues(alpha: op),
        );
      }
    }

    // soft glow + filled disc when connected
    if (connected) {
      canvas.drawCircle(
        center,
        ringR,
        Paint()
          ..color = Fx.brand.withValues(alpha: 0.28)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 22),
      );
      canvas.drawCircle(
        center,
        ringR,
        Paint()
          ..shader = RadialGradient(
            colors: [Fx.brandGlow, Fx.brand],
          ).createShader(Rect.fromCircle(center: center, radius: ringR)),
      );
    } else {
      // subtle inner fill so the button reads as tappable
      canvas.drawCircle(
        center,
        ringR,
        Paint()..color = Fx.bgElevated,
      );
    }

    // status ring
    canvas.drawCircle(
      center,
      ringR,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = connected ? 0 : 4
        ..color = connected ? Colors.transparent : accent.withValues(alpha: 0.9),
    );
  }

  @override
  bool shouldRepaint(_PowerRingPainter old) =>
      old.state != state || old.pulse != pulse;
}
