import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handimanya/core/utils/bolivia_geo.dart';
import 'package:handimanya/data/demo/demo_data.dart';
import 'package:handimanya/data/models/catalog.dart';
import 'package:handimanya/data/providers.dart';
import 'package:handimanya/features/common/city_picker.dart';

const _all = DemoData.cities;

City _bySlug(String slug) => _all.firstWhere((c) => c.slug == slug);

void main() {
  group('catálogo de Bolivia', () {
    test('339 municipios en los 9 departamentos, como el INE', () {
      expect(_all, hasLength(339));
      final perDept = <int, int>{};
      for (final c in _all) {
        perDept[c.departmentId!] = (perDept[c.departmentId!] ?? 0) + 1;
      }
      expect(perDept, {1: 29, 2: 87, 3: 47, 4: 35, 5: 40, 6: 11, 7: 56, 8: 19, 9: 15});
      expect(_all.map((c) => c.slug).toSet(), hasLength(339), reason: 'slugs únicos');
      expect(_all.where((c) => c.province == null), isEmpty);
    });

    test('las tres ciudades de antes conservan su id', () {
      expect(_all.take(3).map((c) => (c.id, c.slug)), [(1, 'santa-cruz'), (2, 'cochabamba'), (3, 'la-paz')]);
    });

    test('pueblos y municipios rurales, en su departamento', () {
      expect(_bySlug('uyuni-pt').department, 'Potosí');
      expect(_bySlug('riberalta-be').department, 'Beni');
      expect(_bySlug('copacabana-lp').province, 'Manco Kapac');
      expect(_bySlug('cobija').department, 'Pando');
      expect(_bySlug('camiri-sc').place, 'Prov. Cordillera · Santa Cruz');
    });
  });

  group('GPS', () {
    test('dentro y fuera de Bolivia', () {
      for (final (lat, lng) in [
        (-17.7833, -63.1821), // Santa Cruz de la Sierra
        (-16.5000, -68.1500), // La Paz
        (-20.4600, -66.8200), // Uyuni
        (-11.0267, -68.7692), // Cobija
        (-11.0100, -66.0700), // Riberalta
        (-21.5355, -64.7296), // Tarija
      ]) {
        expect(isInBolivia(lat, lng), isTrue, reason: '$lat, $lng');
      }
      for (final (lat, lng) in [
        (-15.8402, -70.0219), // Puno, Perú
        (-10.7800, -65.3400), // Guajará-Mirim, Brasil
        (-22.0900, -63.7000), // Tartagal, Argentina
        (-18.4783, -70.3126), // Arica, Chile
        (-16.5000, -55.0000), // Brasil
        (40.4168, -3.7038), // Madrid
      ]) {
        expect(isInBolivia(lat, lng), isFalse, reason: '$lat, $lng');
      }
    });

    test('sugiere el municipio más cercano', () {
      expect(nearestCity(_all, -17.79, -63.18)?.slug, 'santa-cruz');
      expect(nearestCity(_all, -19.58, -65.75)?.name, 'Potosí');
      expect(nearestCity(_all, -16.16, -69.08)?.name, 'Copacabana');
    });
  });

  group('búsqueda', () {
    test('sin tildes ni mayúsculas', () {
      expect(filterCities(_all, query: 'POTOSI').first.name, 'Potosí');
      expect(filterCities(_all, query: 'villazon').first.name, 'Villazón');
      expect(filterCities(_all, query: '  uyuni ').first.slug, 'uyuni-pt');
    });

    test('primero los que empiezan con lo escrito', () {
      final r = filterCities(_all, query: 'san');
      expect(r.first.name.toLowerCase().startsWith('san'), isTrue);
      expect(r.length, greaterThan(20));
    });

    test('por provincia y por departamento', () {
      expect(filterCities(_all, query: 'vaca diez').map((c) => c.name), contains('Riberalta'));
      expect(filterCities(_all, departmentId: 9), hasLength(15));
      expect(filterCities(_all, departmentId: 8, query: 'san').every((c) => c.department == 'Beni'), isTrue);
    });

    test('nombres repetidos se distinguen por provincia y departamento', () {
      final sanPedro = filterCities(_all, query: 'san pedro').where((c) => c.name == 'San Pedro').toList();
      expect(sanPedro.length, greaterThan(1));
      expect(sanPedro.map((c) => c.place).toSet(), hasLength(sanPedro.length));
    });

    test('sin resultados', () {
      expect(filterCities(_all, query: 'madrid'), isEmpty);
    });
  });

  group('buscador en pantalla', () {
    Future<City?> open(WidgetTester tester, Size size, double scale) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      City? picked;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [citiesProvider.overrideWith((ref) async => _all)],
          child: MaterialApp(
            builder: (c, child) => MediaQuery(
              data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Scaffold(
              body: Builder(
                builder: (c) =>
                    TextButton(onPressed: () async => picked = await pickCity(c), child: const Text('abrir')),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('abrir'));
      await tester.pumpAndSettle();
      return picked;
    }

    for (final (size, scale) in [
      (const Size(320, 568), 1.0),
      (const Size(320, 568), 1.3),
      (const Size(360, 640), 2.0),
      (const Size(412, 915), 1.0),
      (const Size(1024, 1366), 1.0),
    ]) {
      testWidgets('busca y elige Riberalta en ${size.width.toInt()}x${size.height.toInt()} texto x$scale', (
        tester,
      ) async {
        await open(tester, size, scale);
        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('city-dept-0')), findsOneWidget);
        await tester.enterText(find.byKey(const Key('city-search')), 'riberal');
        await tester.pumpAndSettle();
        final tile = find.byKey(const Key('city-riberalta-be'));
        expect(tile, findsOneWidget);
        final rect = tester.getRect(tile);
        expect(rect.left >= 0 && rect.right <= size.width, isTrue);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('filtrar por departamento y elegir devuelve el municipio', (tester) async {
      City? picked;
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [citiesProvider.overrideWith((ref) async => _all)],
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (c) =>
                    TextButton(onPressed: () async => picked = await pickCity(c), child: const Text('abrir')),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('abrir'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('city-dept-9')));
      await tester.tap(find.byKey(const Key('city-dept-9')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('city-cobija')), findsOneWidget);
      expect(find.byKey(const Key('city-santa-cruz')), findsNothing);
      await tester.tap(find.byKey(const Key('city-cobija')));
      await tester.pumpAndSettle();
      expect(picked?.name, 'Cobija');
      expect(find.byType(CityPickerSheet), findsNothing);
    });

    testWidgets('sin resultados muestra una ayuda', (tester) async {
      await open(tester, const Size(360, 640), 1.0);
      await tester.enterText(find.byKey(const Key('city-search')), 'madrid');
      await tester.pumpAndSettle();
      expect(find.textContaining('No encontramos "madrid"'), findsOneWidget);
    });
  });
}
