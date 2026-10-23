import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handimanya/core/theme/app_theme.dart';
import 'package:handimanya/core/utils/category_order.dart';
import 'package:handimanya/data/demo/demo_data.dart';
import 'package:handimanya/features/pro_mode/service_selector.dart';

List<String> _search(String q) => [
  for (final c in DemoData.categories)
    if (categoryMatchesQuery(q, [c.name, c.description, c.slug])) c.slug,
];

void main() {
  group('Churrasquero y Notario', () {
    test('se agregan sin cambiar identificadores', () {
      final bySlug = {for (final c in DemoData.categories) c.slug: c};
      expect(bySlug['eventos']!.id, 17);
      expect(bySlug['asesoria-legal']!.id, 18);
      expect(DemoData.categories.map((c) => c.id).toSet(), hasLength(DemoData.categories.length));
      expect(DemoData.problems.map((p) => p.id).toSet(), hasLength(DemoData.problems.length));
      expect(
        DemoData.problems.where((p) => p.categoryId == 17).map((p) => p.name),
        contains('Churrasquero (parrillero)'),
      );
      final notario = bySlug['notario']!;
      expect(notario.requiredDoc, 'nombramiento_notarial', reason: 'la matrícula de abogado no alcanza');
      expect(notario.allowsYa, isFalse);
      expect(DemoData.problems.where((p) => p.categoryId == notario.id && p.isOther), hasLength(1));
    });

    test('el cliente los encuentra al buscar', () {
      expect(_search('churrasquero'), ['eventos']);
      expect(_search('CHURRASQUEROS'), ['eventos']);
      expect(_search('notario'), ['notario']);
      expect(_search('notaria'), isEmpty, reason: 'sin coincidencias parciales raras');
    });

    testWidgets('el profesional de Asesoría legal ve Notario como recomendado, con su requisito', (tester) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: ServiceSelectorSheet(categories: DemoData.categories, primaryId: 18, selected: const {}),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final first = tester.widget<CheckboxListTile>(find.byType(CheckboxListTile).first).key! as ValueKey<String>;
      expect(first.value, 'service-notario');
      expect(find.text('Pide la resolución de nombramiento (DIRNOPLU) y revisión del equipo'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('service-search')), 'churrasquero');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('service-eventos')), findsOneWidget);
      expect(find.byKey(const Key('service-notario')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
