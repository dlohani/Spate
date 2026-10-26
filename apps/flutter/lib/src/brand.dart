import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Brand colour: the chosen accent is the primary, pinned rather than
/// derived, so the Download button and the running bar are recognisably
/// Spate in both themes. Dark mode lifts it so it reads on near-black.
Color brandPrimary(Color accent, Brightness b) =>
    b == Brightness.dark ? Color.lerp(accent, Colors.white, 0.28)! : accent;

/// The Spate mark: three streams merging into one arrow. Same geometry as
/// assets/brand/glyph.svg, drawn as strokes so it scales and takes any colour.
class SpateGlyph extends CustomPainter {
  final Color color;
  const SpateGlyph(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide / 1024;
    final thin = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = 88 * s;
    final thick = Paint.from(thin)..strokeWidth = 120 * s;
    Path p(String d) {
      final path = Path();
      final parts = d.split(' ');
      var i = 0;
      while (i < parts.length) {
        switch (parts[i]) {
          case 'M':
            path.moveTo(double.parse(parts[i + 1]) * s, double.parse(parts[i + 2]) * s);
            i += 3;
          case 'L':
            path.lineTo(double.parse(parts[i + 1]) * s, double.parse(parts[i + 2]) * s);
            i += 3;
          case 'C':
            path.cubicTo(
              double.parse(parts[i + 1]) * s, double.parse(parts[i + 2]) * s,
              double.parse(parts[i + 3]) * s, double.parse(parts[i + 4]) * s,
              double.parse(parts[i + 5]) * s, double.parse(parts[i + 6]) * s,
            );
            i += 7;
          default:
            i++;
        }
      }
      return path;
    }
    canvas.drawPath(p('M 212 230 C 212 400 470 410 500 520'), thin);
    canvas.drawPath(p('M 812 230 C 812 400 554 410 524 520'), thin);
    canvas.drawPath(p('M 512 200 L 512 520'), thin);
    canvas.drawPath(p('M 512 500 L 512 800'), thick);
    canvas.drawPath(p('M 312 630 L 512 830 L 712 630'), thick);
  }

  @override
  bool shouldRepaint(SpateGlyph old) => old.color != color;
}

/// A tiny line chart of recent aggregate speed; the last point is emphasised.
class Sparkline extends CustomPainter {
  final List<double> values;
  final Color color;
  const Sparkline(this.values, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    final max = values.fold<double>(0, math.max);
    if (max <= 0) return;
    final dx = size.width / (values.length - 1);
    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final x = i * dx;
      final y = size.height - (values[i] / max) * (size.height - 2) - 1;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    final fill = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(fill, Paint()..color = color.withValues(alpha: 0.18));
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeJoin = StrokeJoin.round,
    );
    final lx = size.width;
    final ly = size.height - (values.last / max) * (size.height - 2) - 1;
    canvas.drawCircle(Offset(lx, ly), 2.2, Paint()..color = color);
  }

  @override
  bool shouldRepaint(Sparkline old) => old.values != values || old.color != color;
}
