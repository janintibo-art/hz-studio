import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

class StudioSignalPanel extends StatefulWidget {
  const StudioSignalPanel({
    super.key,
    required this.frequency,
    required this.playing,
    this.samples,
    this.title = 'OSCILLOSCOPE',
  });

  final double frequency;
  final bool playing;
  final Float32List? samples;
  final String title;

  @override
  State<StudioSignalPanel> createState() => _StudioSignalPanelState();
}

class _StudioSignalPanelState extends State<StudioSignalPanel>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: const LinearGradient(
          colors: [Color(0xff071523), Color(0xff0a2435)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: const Color(0xff1e6371)),
        boxShadow: const [
          BoxShadow(color: Color(0x2200ffd9), blurRadius: 26),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.multiline_chart,
                    color: Color(0xff70fff0), size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.title,
                    style: const TextStyle(
                      color: Color(0xff70fff0),
                      letterSpacing: 2,
                      fontWeight: FontWeight.w800,
                      fontSize: 11,
                    ),
                  ),
                ),
                const _LiveBadge(),
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 160,
              width: double.infinity,
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, child) => CustomPaint(
                  painter: _SignalPainter(
                    frequency: widget.frequency,
                    phase: widget.playing ? _controller.value : 0,
                    active: widget.playing,
                    samples: widget.samples,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              widget.samples == null
                  ? 'APERÇU VISUEL DU GÉNÉRATEUR'
                  : 'APERÇU DE LA FORME D’ONDE IMPORTÉE',
              style: const TextStyle(
                color: Color(0xff7ea6af),
                fontSize: 10,
                letterSpacing: 1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LiveBadge extends StatelessWidget {
  const _LiveBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xff0e3444),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xff1c6070)),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle, size: 8, color: Color(0xff70fff0)),
          SizedBox(width: 6),
          Text(
            'LIVE',
            style: TextStyle(
              color: Color(0xffd0fdf9),
              fontSize: 10,
              letterSpacing: 1.2,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _SignalPainter extends CustomPainter {
  _SignalPainter({
    required this.frequency,
    required this.phase,
    required this.active,
    required this.samples,
  });

  final double frequency;
  final double phase;
  final bool active;
  final Float32List? samples;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Offset.zero & size,
        const Radius.circular(14),
      ),
      Paint()..color = const Color(0xff05111d),
    );

    final gridPaint = Paint()
      ..color = const Color(0xff173847)
      ..strokeWidth = 0.8;
    for (var i = 0; i <= 10; i++) {
      final x = i * size.width / 10;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }
    for (var i = 0; i <= 5; i++) {
      final y = i * size.height / 5;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    final midPaint = Paint()
      ..color = const Color(0xff33687b)
      ..strokeWidth = 1.1;
    canvas.drawLine(
      Offset(0, size.height / 2),
      Offset(size.width, size.height / 2),
      midPaint,
    );

    final path = Path();
    final count = math.max(120, size.width.floor());
    for (var i = 0; i < count; i++) {
      final t = i / (count - 1);
      double value;
      if (samples != null && samples!.isNotEmpty) {
        final start = (samples!.length * t).floor();
        final next = (((i + 1) / count) * samples!.length).ceil();
        final end = math.min(samples!.length, math.max(start + 1, next));
        var peak = 0.0;
        for (var j = start; j < end; j++) {
          final a = samples![j].abs();
          if (a > peak) peak = a;
        }
        value = peak * (i.isEven ? 1 : -1);
      } else {
        final cycles = (frequency / 100).clamp(2.0, 12.0);
        value = math.sin((t * cycles + phase) * math.pi * 2) *
            (active ? 0.85 : 0.5);
      }
      final x = t * size.width;
      final y = size.height / 2 - value * size.height * 0.38;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 7
        ..color = const Color(0x3300ffe8)
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = const Color(0xff70fff0)
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(covariant _SignalPainter oldDelegate) {
    return oldDelegate.frequency != frequency ||
        oldDelegate.phase != phase ||
        oldDelegate.active != active ||
        oldDelegate.samples != samples;
  }
}
