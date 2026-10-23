import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Una fila de lista: [leading] (foto o ícono), [body] (nombre y datos) y
/// [trailing] (un estado o un botón). Si con la letra grande del teléfono o
/// en una pantalla chica el texto quedaría con menos de [minBodyWidth], el
/// [trailing] baja debajo del texto en vez de apretarlo y partir las palabras.
class TrailingRow extends StatelessWidget {
  const TrailingRow({
    super.key,
    required this.leading,
    required this.body,
    required this.trailing,
    this.gap = 12,
    this.minBodyWidth = 150,
  });

  final Widget leading;
  final Widget body;
  final Widget trailing;
  final double gap;

  /// Con letra normal; crece con la escala de letra del teléfono.
  final double minBodyWidth;

  @override
  Widget build(BuildContext context) => _TrailingRow(
    gap: gap,
    minBodyWidth: minBodyWidth * MediaQuery.textScalerOf(context).scale(1),
    children: [leading, body, trailing],
  );
}

class _TrailingRow extends MultiChildRenderObjectWidget {
  const _TrailingRow({required this.gap, required this.minBodyWidth, required super.children});

  final double gap;
  final double minBodyWidth;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderTrailingRow(gap, minBodyWidth);

  @override
  void updateRenderObject(BuildContext context, covariant RenderObject renderObject) {
    (renderObject as _RenderTrailingRow)
      ..gap = gap
      ..minBodyWidth = minBodyWidth;
  }
}

class _ParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderTrailingRow extends RenderBox
    with ContainerRenderObjectMixin<RenderBox, _ParentData>, RenderBoxContainerDefaultsMixin<RenderBox, _ParentData> {
  _RenderTrailingRow(this._gap, this._minBodyWidth);

  double _gap;
  set gap(double v) {
    if (v == _gap) return;
    _gap = v;
    markNeedsLayout();
  }

  double _minBodyWidth;
  set minBodyWidth(double v) {
    if (v == _minBodyWidth) return;
    _minBodyWidth = v;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _ParentData) child.parentData = _ParentData();
  }

  @override
  void performLayout() {
    final width = constraints.maxWidth;
    final leading = firstChild!;
    final body = childAfter(leading)!;
    final trailing = childAfter(body)!;
    leading.layout(BoxConstraints(maxWidth: width / 3), parentUsesSize: true);
    trailing.layout(BoxConstraints(maxWidth: width), parentUsesSize: true);
    final lw = leading.size.width;
    final lGap = lw > 0 ? _gap : 0.0;
    final tGap = trailing.size.width > 0 ? _gap : 0.0;
    final inRow = width - lw - lGap - trailing.size.width - tGap;
    final side = inRow >= _minBodyWidth;
    final bodyWidth = math.max(0.0, side ? inRow : width - lw - lGap);
    body.layout(BoxConstraints(minWidth: bodyWidth, maxWidth: bodyWidth), parentUsesSize: true);
    double height;
    if (side) {
      height = [leading.size.height, body.size.height, trailing.size.height].reduce(math.max);
      _place(leading, 0, (height - leading.size.height) / 2);
      _place(body, lw + lGap, (height - body.size.height) / 2);
      _place(trailing, width - trailing.size.width, (height - trailing.size.height) / 2);
    } else {
      // Al lado de la foto: el texto; debajo del texto, el estado.
      final textHeight = body.size.height + (trailing.size.height > 0 ? 6 + trailing.size.height : 0);
      height = math.max(leading.size.height, textHeight);
      _place(leading, 0, 0);
      _place(body, lw + lGap, 0);
      _place(trailing, lw + lGap, body.size.height + 6);
    }
    size = constraints.constrain(Size(width, height));
  }

  void _place(RenderBox child, double x, double y) => (child.parentData! as _ParentData).offset = Offset(x, y);

  @override
  void paint(PaintingContext context, Offset offset) => defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}
