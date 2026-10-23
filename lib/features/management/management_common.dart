import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/tokens.dart';
import '../../core/widgets/common.dart';
import '../../core/widgets/word_safe_text.dart';
import '../../data/models/booking.dart';
import '../../data/models/staff.dart';
import '../../data/providers.dart';

final myStaffAccessProvider = FutureProvider<StaffAccess>((ref) {
  ref.watch(accountProvider.select((a) => (a.value?.id, a.value?.managementRole)));
  return ref.watch(backendProvider).myStaffAccess();
});

final opsDashboardProvider = FutureProvider<OpsDashboard>((ref) => ref.watch(backendProvider).opsDashboard());

final opsCasesProvider = FutureProvider.family<List<OpsCase>, (String, bool)>(
  (ref, a) => ref.watch(backendProvider).opsCases(scope: a.$1, includeResolved: a.$2),
);

final opsCaseDetailProvider = FutureProvider.family<OpsCaseDetail, int>(
  (ref, id) => ref.watch(backendProvider).opsCaseDetail(id),
);

final staffOverviewProvider = FutureProvider<List<StaffMember>>((ref) => ref.watch(backendProvider).staffOverview());

final myStaffActivityProvider = FutureProvider<List<StaffActivity>>(
  (ref) => ref.watch(backendProvider).myStaffActivity(),
);

/// Probar la app como cliente sin dejar de ser del equipo. Dura la sesión.
final managementCustomerModeProvider = NotifierProvider<_CustomerMode, bool>(_CustomerMode.new);

class _CustomerMode extends Notifier<bool> {
  @override
  bool build() {
    // Al cambiar de cuenta se vuelve al panel.
    ref.watch(authUserProvider.select((u) => u.value?.id));
    return false;
  }

  void set(bool value) => state = value;
}

/// Color de acento de cada panel, dentro de la marca (azul marino, blanco y
/// naranja): el propietario en naranja, el gerente en verde y el empleado en
/// azul, para que nunca se confundan.
Color panelAccent(StaffRole role) => switch (role) {
  StaffRole.owner => HyColors.primary,
  StaffRole.manager => HyColors.green,
  StaffRole.employee => const Color(0xFF4F8FE0),
};

/// Encabezado de los paneles: azul marino con el nombre del panel.
class PanelAppBar extends StatelessWidget implements PreferredSizeWidget {
  const PanelAppBar({super.key, required this.role, required this.title, this.actions = const []});

  final StaffRole role;
  final String title;
  final List<Widget> actions;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight + 22);

  @override
  Widget build(BuildContext context) {
    // La letra del encabezado sigue a la del teléfono hasta 1,2x: así entra
    // siempre en su alto fijo y nada queda tapado ni cortado.
    final media = MediaQuery.of(context);
    final scaler = TextScaler.linear(media.textScaler.scale(1).clamp(1.0, 1.2));
    return AppBar(
      backgroundColor: HyColors.navy,
      foregroundColor: Colors.white,
      toolbarHeight: kToolbarHeight + 22,
      titleSpacing: HySpacing.page,
      title: MediaQuery(
        data: media.copyWith(textScaler: scaler),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(color: panelAccent(role), shape: BoxShape.circle),
                ),
                const SizedBox(width: 6),
                Flexible(
                  // El nombre del panel entra entero: se achica en pantallas chicas.
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: AlignmentDirectional.centerStart,
                    child: Text(
                      role.panelTitle.toUpperCase(),
                      key: Key('panel-title-${role.key}'),
                      maxLines: 1,
                      style: TextStyle(
                        fontSize: 12,
                        letterSpacing: 0.8,
                        fontWeight: FontWeight.w800,
                        color: panelAccent(role),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: AlignmentDirectional.centerStart,
              child: Text(
                title,
                maxLines: 1,
                style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800, color: Colors.white),
              ),
            ),
          ],
        ),
      ),
      actions: actions,
    );
  }
}

/// Un número del panel, con su etiqueta. Sin datos, lo dice.
class PanelStat extends StatelessWidget {
  const PanelStat(this.label, this.value, {super.key, this.tone, this.onTap, this.display, this.detail});

  final String label;
  final int? value;
  final StatusTone? tone;
  final VoidCallback? onTap;

  /// Texto en lugar del número (por ejemplo un monto en Bs). Null y sin
  /// [value]: "—", sin datos.
  final String? display;

  /// Una línea chica debajo del nombre (por ejemplo "3 billeteras"), para que
  /// el nombre no se corte.
  final String? detail;

  static const labelStyle = TextStyle(color: HyColors.textSecondary, height: 1.25);
  static const detailStyle = TextStyle(color: HyColors.textMuted, fontSize: 13);

  @override
  Widget build(BuildContext context) => AppCard(
    onTap: onTap,
    padding: const EdgeInsets.symmetric(horizontal: HySpacing.md, vertical: HySpacing.sm),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // El número y la flecha en la misma línea; el nombre usa todo el ancho
        // de la tarjeta debajo, así las palabras largas entran enteras.
        Row(
          children: [
            Expanded(
              // Un monto nunca se corta: se achica para entrar entero.
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: AlignmentDirectional.centerStart,
                child: Text(
                  display ?? (value == null ? '—' : '$value'),
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: display != null ? 21 : 26,
                    fontWeight: FontWeight.w900,
                    color: tone != null && (value ?? 0) > 0 ? tone!.foreground : HyColors.navy,
                  ),
                ),
              ),
            ),
            // Se ve que se puede tocar (en Build 13 las tarjetas parecían fijas).
            if (onTap != null) const Icon(Icons.chevron_right, size: 20, color: HyColors.textMuted),
          ],
        ),
        // Sin "…" ni palabras partidas: la tarjeta crece y la fila se empareja.
        // Texto común, sin LayoutBuilder: así PanelGrid puede preguntarle su
        // ancho mínimo (la palabra más larga) y darle siempre ese ancho.
        Text(label, style: labelStyle),
        if (detail != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(detail!, style: detailStyle),
          ),
      ],
    ),
  );
}

/// Cuadrícula que se adapta al ancho: 2 columnas en el teléfono, más en la
/// tableta, y una sola en pantallas chicas o con letra grande. Las tarjetas de
/// una fila tienen la misma altura.
///
/// Issue #12 (Samsung, Dev-17 y Dev-18): las columnas se eligen preguntándole
/// a cada [PanelStat] qué ancho mínimo necesita para que su palabra más larga
/// entre entera, medido por el mismo motor que la dibuja (con la negrita y la
/// letra del teléfono). Si no entra, hay menos columnas y tarjetas más anchas:
/// la letra no se achica y ninguna palabra se parte.
class PanelGrid extends StatelessWidget {
  const PanelGrid({super.key, required this.children, this.minTileWidth = 150});

  final List<Widget> children;
  final double minTileWidth;

  @override
  Widget build(BuildContext context) {
    // Con la letra del teléfono en 1,3x o más, cada tarjeta necesita más ancho.
    final scale = MediaQuery.textScalerOf(context).scale(1);
    return _PanelGridLayout(
      minTileWidth: minTileWidth * (scale >= 1.3 ? scale : 1.0),
      spacing: HySpacing.sm,
      children: [for (final c in children) _GridCell(measured: c is PanelStat, child: c)],
    );
  }
}

class _GridCellData extends ContainerBoxParentData<RenderBox> {
  bool measured = false;
}

/// Marca qué tarjetas se miden (las de [PanelStat] no usan LayoutBuilder).
class _GridCell extends ParentDataWidget<_GridCellData> {
  const _GridCell({required this.measured, required super.child});

  final bool measured;

  @override
  void applyParentData(RenderObject renderObject) {
    final data = renderObject.parentData! as _GridCellData;
    if (data.measured != measured) {
      data.measured = measured;
      renderObject.parent?.markNeedsLayout();
    }
  }

  @override
  Type get debugTypicalAncestorWidgetClass => _PanelGridLayout;
}

class _PanelGridLayout extends MultiChildRenderObjectWidget {
  const _PanelGridLayout({required this.minTileWidth, required this.spacing, required super.children});

  final double minTileWidth;
  final double spacing;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderPanelGrid(minTileWidth, spacing);

  @override
  void updateRenderObject(BuildContext context, covariant RenderObject renderObject) {
    (renderObject as _RenderPanelGrid)
      ..minTileWidth = minTileWidth
      ..spacing = spacing;
  }
}

class _RenderPanelGrid extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _GridCellData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _GridCellData> {
  _RenderPanelGrid(this._minTileWidth, this._spacing);

  double _minTileWidth;
  set minTileWidth(double v) {
    if (v == _minTileWidth) return;
    _minTileWidth = v;
    markNeedsLayout();
  }

  double _spacing;
  set spacing(double v) {
    if (v == _spacing) return;
    _spacing = v;
    markNeedsLayout();
  }

  /// Columnas que se usaron en la última medida (para las pruebas).
  int columns = 1;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _GridCellData) child.parentData = _GridCellData();
  }

  double _cell(double width, int columns) => math.max(0, (width - _spacing * (columns - 1)) / columns);

  int _columnsFor(double width) {
    var c = (width / _minTileWidth).floor().clamp(1, 5);
    var need = 0.0;
    for (var child = firstChild; child != null; child = childAfter(child)) {
      if ((child.parentData! as _GridCellData).measured) {
        need = math.max(need, child.getMinIntrinsicWidth(double.infinity));
      }
    }
    while (c > 1 && _cell(width, c) < need) {
      c--;
    }
    return c;
  }

  @override
  void performLayout() {
    final width = constraints.maxWidth;
    columns = _columnsFor(width);
    final cell = _cell(width, columns);
    final all = <RenderBox>[];
    for (var child = firstChild; child != null; child = childAfter(child)) {
      all.add(child);
    }
    var y = 0.0;
    for (var i = 0; i < all.length; i += columns) {
      final row = all.sublist(i, math.min(i + columns, all.length));
      if (i > 0) y += _spacing;
      // Igual que EqualHeightRow: cada una con su altura, después todas con la
      // de la más alta (mínimo, no fijo, para que vuelvan a medirse).
      var tallest = 0.0;
      for (final c in row) {
        c.layout(BoxConstraints(minWidth: cell, maxWidth: cell), parentUsesSize: true);
        tallest = math.max(tallest, c.size.height);
      }
      var x = 0.0;
      var height = tallest;
      for (final c in row) {
        c.layout(BoxConstraints(minWidth: cell, maxWidth: cell, minHeight: tallest), parentUsesSize: true);
        height = math.max(height, c.size.height);
        (c.parentData! as _GridCellData).offset = Offset(x, y);
        x += cell + _spacing;
      }
      y += height;
    }
    size = constraints.constrain(Size(width, y));
  }

  @override
  double computeMinIntrinsicWidth(double height) {
    var w = 0.0;
    for (var child = firstChild; child != null; child = childAfter(child)) {
      if ((child.parentData! as _GridCellData).measured) w = math.max(w, child.getMinIntrinsicWidth(height));
    }
    return w;
  }

  @override
  double computeMaxIntrinsicWidth(double height) => computeMinIntrinsicWidth(height);

  @override
  void paint(PaintingContext context, Offset offset) => defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}

/// Una tarea del panel: ícono, título, explicación y pendientes.
class PanelTile extends StatelessWidget {
  const PanelTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.count,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final int? count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: HySpacing.xs),
    child: AppCard(
      onTap: onTap,
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(color: HyColors.primarySoft, borderRadius: BorderRadius.circular(HyRadii.md)),
            child: Icon(icon, color: HyColors.primaryDark),
          ),
          const SizedBox(width: HySpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                WordSafeText(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                WordSafeText(subtitle, style: const TextStyle(color: HyColors.textSecondary)),
              ],
            ),
          ),
          if (count != null && count! > 0)
            Semantics(
              label: '$count pendientes',
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(color: HyColors.primary, borderRadius: BorderRadius.circular(HyRadii.pill)),
                child: Text(
                  '$count',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16),
                ),
              ),
            ),
          const Icon(Icons.chevron_right, color: HyColors.textMuted),
        ],
      ),
    ),
  );
}

StatusTone caseStatusTone(OpsCaseStatus s) => switch (s) {
  OpsCaseStatus.open => StatusTone.brand,
  OpsCaseStatus.inProgress => StatusTone.info,
  OpsCaseStatus.waiting => StatusTone.neutral,
  OpsCaseStatus.escalated => StatusTone.danger,
  OpsCaseStatus.resolved => StatusTone.success,
};

IconData caseKindIcon(OpsCaseKind k) => switch (k) {
  OpsCaseKind.support => Icons.support_agent_outlined,
  OpsCaseKind.application => Icons.badge_outlined,
  OpsCaseKind.dispute => Icons.gavel_outlined,
  OpsCaseKind.report => Icons.flag_outlined,
  OpsCaseKind.booking => Icons.receipt_long_outlined,
};

/// Recarga todo lo del equipo después de una acción.
void refreshOps(WidgetRef ref) {
  ref
    ..invalidate(opsDashboardProvider)
    ..invalidate(opsCasesProvider)
    ..invalidate(opsCaseDetailProvider)
    ..invalidate(staffOverviewProvider)
    ..invalidate(myStaffActivityProvider);
}

/// Pantalla de panel en secciones: el título de la sección que se está
/// leyendo queda fijo arriba, entero y debajo del encabezado, mientras se
/// recorre. Lo último queda por encima de la barra de abajo y de la barra de
/// gestos. [children] es la misma lista que iría en una columna: un
/// SectionHeader empieza cada sección. Todo se arma de una vez (un panel es
/// corto), como antes la columna.
class PanelSections extends StatefulWidget {
  const PanelSections({super.key, required this.children});

  final List<Widget> children;

  @override
  State<PanelSections> createState() => _PanelSectionsState();
}

class _PanelSectionsState extends State<PanelSections> {
  final _viewport = GlobalKey();
  var _keys = <GlobalKey>[];

  /// Título fijo: cuál y cuánto lo empuja hacia arriba el siguiente.
  int? _pinned;
  double _push = 0;

  List<int> get _headerIndexes => [
    for (var i = 0; i < widget.children.length; i++)
      if (widget.children[i] is SectionHeader) i,
  ];

  void _update() {
    final viewport = _viewport.currentContext?.findRenderObject() as RenderBox?;
    if (viewport == null || !viewport.hasSize) return;
    final top = viewport.localToGlobal(Offset.zero).dy;
    int? pinned;
    double pinnedHeight = 0;
    double push = 0;
    for (var k = 0; k < _keys.length; k++) {
      final box = _keys[k].currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) continue;
      final y = box.localToGlobal(Offset.zero).dy - top;
      if (y < 0) {
        pinned = k;
        pinnedHeight = box.size.height;
        push = 0;
      } else if (pinned != null && y < pinnedHeight) {
        // El título siguiente llega arriba y empuja al fijo.
        push = pinnedHeight - y;
        break;
      } else {
        break;
      }
    }
    if (pinned != _pinned || push != _push) {
      setState(() {
        _pinned = pinned;
        _push = push;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final headers = _headerIndexes;
    if (_keys.length != headers.length) _keys = [for (final _ in headers) GlobalKey()];
    final children = [
      for (var i = 0; i < widget.children.length; i++)
        if (widget.children[i] is SectionHeader)
          KeyedSubtree(key: _keys[headers.indexOf(i)], child: widget.children[i])
        else
          widget.children[i],
    ];
    final pinned = _pinned;
    return NotificationListener<ScrollNotification>(
      onNotification: (_) {
        _update();
        return false;
      },
      child: Stack(
        key: _viewport,
        children: [
          ListView(
            padding: bottomSafePadding(context),
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              PageBody(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
              ),
            ],
          ),
          if (pinned != null)
            Positioned(
              top: -_push,
              left: 0,
              right: 0,
              // Solo se ve: los toques pasan a la pantalla (el título real está en la lista).
              child: IgnorePointer(
                child: ExcludeSemantics(
                  child: DecoratedBox(
                    key: const Key('panel-pinned-heading'),
                    decoration: const BoxDecoration(
                      color: HyColors.background,
                      border: Border(bottom: BorderSide(color: HyColors.border)),
                    ),
                    child: PageBody(child: widget.children[headers[pinned]]),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
