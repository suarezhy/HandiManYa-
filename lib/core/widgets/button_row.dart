import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Botones lado a lado solo si cada uno entra con su texto en una línea; si
/// no (pantalla chica, negrita o letra grande del teléfono), uno debajo del
/// otro y a todo el ancho. Así un botón nunca queda apretado ni con una
/// palabra partida ("Progra / mar").
///
/// Lado a lado, cada botón recibe al menos lo que necesita y el espacio que
/// sobra se reparte según [flex] (por defecto, por igual). Apilados, el
/// primero queda arriba.
class ButtonRow extends MultiChildRenderObjectWidget {
  const ButtonRow({super.key, required super.children, this.spacing = 12, this.flex});

  final double spacing;

  /// Peso de cada botón al repartir el espacio que sobra (uno por hijo).
  final List<int>? flex;

  @override
  RenderObject createRenderObject(BuildContext context) => RenderButtonRow(spacing, flex);

  @override
  void updateRenderObject(BuildContext context, covariant RenderButtonRow renderObject) {
    renderObject
      ..spacing = spacing
      ..flex = flex;
  }
}

class _ParentData extends ContainerBoxParentData<RenderBox> {}

class RenderButtonRow extends RenderBox
    with ContainerRenderObjectMixin<RenderBox, _ParentData>, RenderBoxContainerDefaultsMixin<RenderBox, _ParentData> {
  RenderButtonRow(this._spacing, this._flex);

  double _spacing;
  set spacing(double v) {
    if (v == _spacing) return;
    _spacing = v;
    markNeedsLayout();
  }

  List<int>? _flex;
  set flex(List<int>? v) {
    if (v == _flex) return;
    _flex = v;
    markNeedsLayout();
  }

  /// Quedaron uno debajo del otro en el último armado.
  bool stacked = false;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _ParentData) child.parentData = _ParentData();
  }

  List<RenderBox> get _children {
    final list = <RenderBox>[];
    var c = firstChild;
    while (c != null) {
      list.add(c);
      c = childAfter(c);
    }
    return list;
  }

  @override
  double computeMinIntrinsicWidth(double height) =>
      _children.fold(0.0, (w, c) => math.max(w, c.getMinIntrinsicWidth(height)));

  @override
  double computeMaxIntrinsicWidth(double height) {
    final kids = _children;
    if (kids.isEmpty) return 0;
    return kids.fold(0.0, (w, c) => w + c.getMaxIntrinsicWidth(height)) + _spacing * (kids.length - 1);
  }

  @override
  double computeMinIntrinsicHeight(double width) => _heightFor(width);

  @override
  double computeMaxIntrinsicHeight(double width) => _heightFor(width);

  double _heightFor(double width) {
    final kids = _children;
    if (kids.isEmpty) return 0;
    final needs = [for (final c in kids) c.getMaxIntrinsicWidth(double.infinity)];
    final side = needs.fold(0.0, (a, b) => a + b) + _spacing * (kids.length - 1) <= width;
    if (side) return kids.fold(0.0, (h, c) => math.max(h, c.getMaxIntrinsicHeight(width / kids.length)));
    return kids.fold(0.0, (h, c) => h + c.getMaxIntrinsicHeight(width)) + _spacing * (kids.length - 1);
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      constraints.constrain(Size(constraints.maxWidth, _heightFor(constraints.maxWidth)));

  @override
  void performLayout() {
    final kids = _children;
    final width = constraints.maxWidth;
    if (kids.isEmpty) {
      size = constraints.smallest;
      return;
    }
    // Lo que cada botón necesita para su texto en una línea (con el ícono y el relleno).
    final needs = [for (final c in kids) c.getMaxIntrinsicWidth(double.infinity)];
    final gaps = _spacing * (kids.length - 1);
    final total = needs.fold(0.0, (a, b) => a + b) + gaps;
    stacked = !width.isFinite || total > width;
    if (!stacked) {
      final weights = [for (var i = 0; i < kids.length; i++) (_flex != null && i < _flex!.length) ? _flex![i] : 1];
      final sum = weights.fold(0, (a, b) => a + b);
      final extra = width - total;
      var x = 0.0;
      var height = 0.0;
      final widths = [for (var i = 0; i < kids.length; i++) needs[i] + extra * weights[i] / sum];
      for (var i = 0; i < kids.length; i++) {
        kids[i].layout(BoxConstraints.tightFor(width: widths[i]), parentUsesSize: true);
        height = math.max(height, kids[i].size.height);
      }
      for (var i = 0; i < kids.length; i++) {
        kids[i].layout(BoxConstraints.tightFor(width: widths[i], height: height), parentUsesSize: true);
        (kids[i].parentData! as _ParentData).offset = Offset(x, 0);
        x += widths[i] + _spacing;
      }
      size = constraints.constrain(Size(width, height));
      return;
    }
    var y = 0.0;
    for (final c in kids) {
      c.layout(BoxConstraints(minWidth: width, maxWidth: width), parentUsesSize: true);
      (c.parentData! as _ParentData).offset = Offset(0, y);
      y += c.size.height + _spacing;
    }
    size = constraints.constrain(Size(width, y - _spacing));
  }

  @override
  void paint(PaintingContext context, Offset offset) => defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}
