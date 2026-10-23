import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Una fila de tarjetas del mismo ancho y la misma altura: la de la más alta.
/// A diferencia de IntrinsicHeight, funciona con hijos que usan LayoutBuilder
/// (mide cada hijo con su ancho real y después los estira).
class EqualHeightRow extends MultiChildRenderObjectWidget {
  const EqualHeightRow({super.key, required this.columns, required this.spacing, required super.children});

  /// Lugares de la fila; si hay menos hijos, quedan huecos a la derecha.
  final int columns;
  final double spacing;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderEqualHeightRow(columns, spacing);

  @override
  void updateRenderObject(BuildContext context, covariant RenderObject renderObject) {
    (renderObject as _RenderEqualHeightRow)
      ..columns = columns
      ..spacing = spacing;
  }
}

class _RowParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderEqualHeightRow extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _RowParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _RowParentData> {
  _RenderEqualHeightRow(this._columns, this._spacing);

  int _columns;
  set columns(int v) {
    if (v == _columns) return;
    _columns = v;
    markNeedsLayout();
  }

  double _spacing;
  set spacing(double v) {
    if (v == _spacing) return;
    _spacing = v;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _RowParentData) child.parentData = _RowParentData();
  }

  double _cellWidth(double width) => math.max(0, (width - _spacing * (_columns - 1)) / _columns);

  @override
  void performLayout() {
    final width = constraints.maxWidth;
    final cell = _cellWidth(width);
    // 1) Cada tarjeta con su ancho y la altura que necesita.
    var tallest = 0.0;
    var child = firstChild;
    while (child != null) {
      child.layout(BoxConstraints(minWidth: cell, maxWidth: cell), parentUsesSize: true);
      tallest = math.max(tallest, child.size.height);
      child = childAfter(child);
    }
    // 2) Todas con la altura de la más alta. Sin altura fija: con una fija el
    // hijo se vuelve independiente y, si su texto cambia después (llegan los
    // datos), crece sin que la fila lo vuelva a medir.
    var x = 0.0;
    var height = tallest;
    child = firstChild;
    while (child != null) {
      child.layout(BoxConstraints(minWidth: cell, maxWidth: cell, minHeight: tallest), parentUsesSize: true);
      height = math.max(height, child.size.height);
      (child.parentData! as _RowParentData).offset = Offset(x, 0);
      x += cell + _spacing;
      child = childAfter(child);
    }
    size = constraints.constrain(Size(width, height));
  }

  @override
  double computeMinIntrinsicHeight(double width) => _maxChildHeight(width, (c, w) => c.getMinIntrinsicHeight(w));

  @override
  double computeMaxIntrinsicHeight(double width) => _maxChildHeight(width, (c, w) => c.getMaxIntrinsicHeight(w));

  double _maxChildHeight(double width, double Function(RenderBox, double) measure) {
    final cell = _cellWidth(width);
    var tallest = 0.0;
    var child = firstChild;
    while (child != null) {
      tallest = math.max(tallest, measure(child, cell));
      child = childAfter(child);
    }
    return tallest;
  }

  @override
  void paint(PaintingContext context, Offset offset) => defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}
