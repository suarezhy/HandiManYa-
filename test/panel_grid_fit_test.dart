import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handimanya/core/theme/app_theme.dart';
import 'package:handimanya/features/management/management_common.dart';

import 'support/layout_checks.dart';

/// Issue #12 en el Samsung (Dev-17): "Profesional / es", "Postulacion / es",
/// "Documento / s" en Propietario → Resumen, aunque las pruebas de pantallas
/// fijas pasaban. Aquí se barren anchos, tamaños de letra, la negrita del
/// sistema y la letra grande de Android 14 (que no crece en proporción).
const _labels = [
  'Pedidos de hoy',
  'Activos ahora',
  'Completados hoy',
  'Cancelados hoy',
  'Casos urgentes',
  'Escalados a ti',
  'Incidentes de seguridad',
  'Alertas de fraude',
  'Disputas abiertas',
  'Clientes',
  'Profesionales',
  'Disponibles ahora',
  'Solicitudes pendientes',
  'Postulaciones pendientes',
  'Revisar documentos',
  'Documentos por revisar',
  'Identidad en revisión',
  'Casos sin asignar',
  'Pendientes del Centro IA',
  'Alertas IA altas o críticas',
  'Costos del mes',
];

/// Como Android 14: la letra chica crece todo el factor, la grande menos
/// (tabla de Android para 2,0: 14 → 28, 18 → 32, 24 → 40, 30 → 45).
class _AndroidNonLinear extends TextScaler {
  const _AndroidNonLinear();
  static const _from = [0.0, 8, 10, 12, 14, 18, 20, 24, 30, 100];
  static const _to = [0.0, 16, 20, 24, 28, 32, 35, 40, 45, 100];

  @override
  double scale(double fontSize) {
    for (var i = 1; i < _from.length; i++) {
      if (fontSize <= _from[i]) {
        final t = (fontSize - _from[i - 1]) / (_from[i] - _from[i - 1]);
        return _to[i - 1] + t * (_to[i] - _to[i - 1]);
      }
    }
    return fontSize;
  }

  @override
  // ignore: deprecated_member_use
  double get textScaleFactor => 2;

  @override
  bool operator ==(Object other) => other is _AndroidNonLinear;

  @override
  int get hashCode => 7;
}

void main() {
  Future<List<String>> check(WidgetTester tester, double width, TextScaler scaler, bool bold) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(size: Size(width, 2000), textScaler: scaler, boldText: bold),
            child: Scaffold(
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: PanelGrid(children: [for (final l in _labels) PanelStat(l, 3, onTap: () {})]),
              ),
            ),
          ),
        ),
      ),
    );
    final where =
        '${width.toInt()}px ${scaler == const _AndroidNonLinear() ? 'Android 14 x2' : 'x${scaler.scale(1)}'}'
        '${bold ? ' negrita' : ''}';
    final problems = <String>[];
    for (final p in tester.allRenderObjects.whereType<RenderParagraph>()) {
      for (final w in brokenWords(p)) {
        problems.add('$where: "$w"');
      }
      // Legible: los nombres no se achican (la tarjeta se ensancha).
      final size = (p.text as TextSpan).style?.fontSize ?? 14;
      final text = p.text.toPlainText();
      if (_labels.contains(text) && size < 14) problems.add('$where: "$text" achicado a $size');
    }
    final e = tester.takeException();
    if (e != null) problems.add('$where: $e');
    return problems;
  }

  testWidgets('Resumen: ningún nombre se parte ni se achica, en ningún ancho ni letra', (tester) async {
    await loadAppFonts(tester);
    tester.view.physicalSize = const Size(480, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final all = <String>[];
    for (var w = 300.0; w <= 440; w += 4) {
      for (final bold in [false, true]) {
        for (final s in [1.0, 1.1, 1.15, 1.2, 1.25, 1.3, 1.4, 1.5, 1.6]) {
          all.addAll(await check(tester, w, TextScaler.linear(s), bold));
        }
        all.addAll(await check(tester, w, const _AndroidNonLinear(), bold));
      }
    }
    expect(all, isEmpty, reason: all.take(20).join('\n'));
  });
}
