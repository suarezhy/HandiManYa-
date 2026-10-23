import 'package:flutter/material.dart';

/// Android: el atrás predictivo del sistema y, además, deslizar desde el borde
/// izquierdo dentro de la app para volver a la pantalla anterior.
///
/// Muchos Samsung vienen con la barra de tres botones: ahí el sistema no tiene
/// gesto atrás y deslizar desde el borde no hacía nada. Con la navegación por
/// gestos el sistema toma el borde antes que la app y hace su propio atrás, que
/// llega al mismo lugar.
///
/// - Solo cuenta un toque que empieza en el borde ([EdgeSwipeBack.edgeWidth]):
///   las listas, pestañas y carruseles del resto de la pantalla no cambian.
/// - Nunca en la primera pantalla de una pestaña ni en una ventana completa
///   (fullscreenDialog): ahí atrás es del sistema.
/// - Pasa por [Navigator.maybePop], así que respeta "¿Salir sin guardar?" y
///   los pasos de un formulario ([PopScope]).
class SwipeBackPageTransitionsBuilder extends PageTransitionsBuilder {
  const SwipeBackPageTransitionsBuilder();

  static const _predictive = PredictiveBackPageTransitionsBuilder();

  @override
  Duration get transitionDuration => _predictive.transitionDuration;

  @override
  DelegatedTransitionBuilder? get delegatedTransition => _predictive.delegatedTransition;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final inner = _predictive.buildTransitions(route, context, animation, secondaryAnimation, child);
    if (route.isFirst || route.fullscreenDialog) return inner;
    return EdgeSwipeBack(route: route, child: inner);
  }
}

class EdgeSwipeBack extends StatefulWidget {
  const EdgeSwipeBack({super.key, required this.route, required this.child});

  /// Ancho del borde donde empieza el gesto (igual que en iOS).
  static const edgeWidth = 20.0;

  /// Distancia (fracción del ancho) o velocidad para que cuente como atrás.
  static const commitFraction = 0.3;
  static const commitVelocity = 700.0;

  final PageRoute<dynamic> route;
  final Widget child;

  @override
  State<EdgeSwipeBack> createState() => _EdgeSwipeBackState();
}

class _EdgeSwipeBackState extends State<EdgeSwipeBack> with SingleTickerProviderStateMixin {
  late final _offset = AnimationController(vsync: this, duration: const Duration(milliseconds: 200));
  double _width = 1;
  bool _dragging = false;
  // Cuánto se arrastró, aunque la pantalla no siga al dedo.
  double _travel = 0;

  @override
  void dispose() {
    _offset.dispose();
    super.dispose();
  }

  // Con cambios sin guardar la pantalla no se mueve; al soltar, pregunta.
  bool get _canFollow => widget.route.popGestureEnabled;

  void _start(DragStartDetails _) {
    if (!widget.route.isCurrent) return;
    _offset.stop();
    _dragging = true;
  }

  void _update(DragUpdateDetails d) {
    if (!_dragging || !_canFollow) return;
    _offset.value = (_offset.value + (d.primaryDelta ?? 0) / _width).clamp(0.0, 1.0);
  }

  Future<void> _end(DragEndDetails d) async {
    if (!_dragging) return;
    _dragging = false;
    final enough =
        (d.primaryVelocity ?? 0) >= EdgeSwipeBack.commitVelocity || _travel >= _width * EdgeSwipeBack.commitFraction;
    _travel = 0;
    if (!enough || !widget.route.isCurrent) {
      _offset.animateBack(0);
      return;
    }
    final popped = await widget.route.navigator?.maybePop() ?? false;
    if (!mounted) return;
    // Si no salió (preguntó y la persona se quedó), la pantalla vuelve a su
    // lugar sin perder nada.
    if (!popped || widget.route.isCurrent) _offset.animateBack(0);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      _width = constraints.maxWidth.isFinite && constraints.maxWidth > 0 ? constraints.maxWidth : 1;
      return Stack(
        children: [
          AnimatedBuilder(
            animation: _offset,
            builder: (context, child) => _offset.value == 0
                ? child!
                : Transform.translate(offset: Offset(_offset.value * _width, 0), child: child),
            child: widget.child,
          ),
          PositionedDirectional(
            start: 0,
            top: 0,
            bottom: 0,
            width: EdgeSwipeBack.edgeWidth,
            child: GestureDetector(
              key: const Key('edge-swipe-back'),
              behavior: HitTestBehavior.translucent,
              onHorizontalDragStart: _start,
              onHorizontalDragUpdate: (d) {
                _travel += d.primaryDelta ?? 0;
                _update(d);
              },
              onHorizontalDragEnd: _end,
              onHorizontalDragCancel: () {
                _dragging = false;
                _travel = 0;
                _offset.animateBack(0);
              },
            ),
          ),
        ],
      );
    },
  );
}
