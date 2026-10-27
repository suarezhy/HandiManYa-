import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handimanya/app.dart';
import 'package:handimanya/core/services/location_service.dart';
import 'package:handimanya/core/theme/tokens.dart';
import 'package:handimanya/core/utils/category_order.dart';
import 'package:handimanya/data/demo/demo_backend.dart';
import 'package:handimanya/data/demo/demo_data.dart';
import 'package:handimanya/data/models/booking.dart';
import 'package:handimanya/data/models/geo.dart';
import 'package:handimanya/data/providers.dart';
import 'package:handimanya/features/booking/request_flow_page.dart';
import 'package:handimanya/features/common/professional_card.dart';
import 'package:handimanya/features/professional/professional_profile_page.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/demo_login.dart';

/// Tamaños lógicos de pantalla: teléfonos Android chicos y comunes, iPhones
/// (SE, 8, 14) y una tableta.
const _sizes = <String, Size>{
  '320x568 (Android chico / iPhone SE 1ra)': Size(320, 568),
  '360x640 (Android chico)': Size(360, 640),
  '360x800 (Samsung Galaxy A)': Size(360, 800),
  '384x832 (Samsung Galaxy S)': Size(384, 832),
  '375x667 (iPhone SE / 8)': Size(375, 667),
  '390x844 (iPhone 14)': Size(390, 844),
  '412x915 (Android grande)': Size(412, 915),
  '800x1280 (tableta)': Size(800, 1280),
};
const _scales = [1.0, 1.3, 2.0];
const _bottomInset = 24.0; // barra de gestos de Android / zona segura del iPhone
const _navLabels = ['Inicio', 'Buscar', 'Solicitudes', 'Mensajes', 'Perfil'];

/// Las pruebas de Flutter dibujan con una letra de cuadritos; cargamos Nunito
/// (la letra real de la app) para medir los textos como en el teléfono.
Future<void> _loadFonts() async {
  final loader = FontLoader('Nunito');
  for (final w in [400, 600, 700, 800, 900]) {
    loader.addFont(rootBundle.load('assets/fonts/Nunito-$w.ttf'));
  }
  await loader.load();
}

class _FakeLocation implements LocationService {
  GeoPoint point = const GeoPoint(-17.7800, -63.1800);

  @override
  Future<GeoPoint> current() async => point;
}

class _SpyBackend extends DemoAppBackend {
  _SpyBackend() : super(simulateDelays: false, codeCooldown: Duration.zero);

  final drafts = <BookingDraft>[];

  @override
  Future<String> create(BookingDraft input) {
    drafts.add(input);
    return super.create(input);
  }
}

Future<_SpyBackend> _pumpHome(
  WidgetTester tester, {
  required Size size,
  double textScale = 1,
  int? cityId,
  _FakeLocation? location,
}) async {
  await initializeDateFormatting('es');
  SharedPreferences.setMockInitialValues({'onboarding_seen_v1': true, 'selected_city_v1': ?cityId});
  final prefs = await SharedPreferences.getInstance();
  final backend = _SpyBackend();
  addTearDown(backend.dispose);
  // La sesión del cliente de demostración, sin pasar por la pantalla de acceso.
  await backend.signInAs(DemoBackend.customerPhone);
  tester.view.physicalSize = size * 3;
  tester.view.devicePixelRatio = 3;
  tester.view.padding = const FakeViewPadding(bottom: _bottomInset * 3);
  tester.view.viewPadding = const FakeViewPadding(bottom: _bottomInset * 3);
  addTearDown(tester.view.reset);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        backendProvider.overrideWithValue(backend),
        locationServiceProvider.overrideWithValue(location ?? _FakeLocation()),
        // Las pruebas no piden mosaicos del mapa a internet.
        mapTileUrlProvider.overrideWithValue(null),
      ],
      child: const HandiManYaApp(),
    ),
  );
  await tester.pumpAndSettle();
  expect(find.byKey(const Key('home-ya-fab')), findsOneWidget, reason: 'debería estar en el inicio del cliente');
  return backend;
}

/// El párrafo del primer texto (widget Text) dentro de [f]; no el de un ícono.
RenderParagraph _paragraph(WidgetTester tester, Finder f) {
  final text = find.descendant(of: f, matching: find.byType(Text), matchRoot: true).first;
  return tester.renderObject<RenderParagraph>(find.descendant(of: text, matching: find.byType(RichText)).first);
}

/// Cantidad de líneas que ocupa el texto.
int _lines(RenderParagraph p) {
  final len = p.text.toPlainText().length;
  final boxes = p.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: len));
  return boxes.map((b) => b.top.round()).toSet().length;
}

/// Palabras partidas entre dos líneas ("Electricida / d"). Vacío si ninguna.
List<String> _brokenWords(RenderParagraph p) {
  final text = p.text.toPlainText();
  final broken = <String>[];
  double? lastTop;
  for (var i = 0; i < text.length; i++) {
    final boxes = p.getBoxesForSelection(TextSelection(baseOffset: i, extentOffset: i + 1));
    if (boxes.isEmpty) continue;
    final top = boxes.first.top;
    if (lastTop != null && (top - lastTop).abs() > 1 && i > 0) {
      final prev = text[i - 1];
      final cur = text[i];
      if (prev.trim().isNotEmpty && cur.trim().isNotEmpty && prev != '-') broken.add('${text.substring(0, i)}|');
    }
    lastTop = top;
  }
  return broken;
}

bool _inside(Rect outer, Rect inner, {double tol = 0.5}) =>
    inner.left >= outer.left - tol &&
    inner.top >= outer.top - tol &&
    inner.right <= outer.right + tol &&
    inner.bottom <= outer.bottom + tol;

void _checkBottomNav(WidgetTester tester, Size size, String why) {
  final nav = find.byKey(const Key('app-bottom-nav'));
  expect(nav, findsOneWidget, reason: why);
  final rects = <Rect>[];
  for (final label in _navLabels) {
    final dest = find.byKey(Key('nav-$label'));
    expect(dest, findsOneWidget, reason: '$why: falta $label');
    final r = tester.getRect(dest);
    rects.add(r);
    // Toque cómodo: al menos 48 x 48 dp.
    expect(r.width, greaterThanOrEqualTo(48), reason: '$why: $label ancho');
    expect(r.height, greaterThanOrEqualTo(48), reason: '$why: $label alto');

    final text = find.descendant(of: dest, matching: find.text(label));
    expect(text, findsOneWidget, reason: '$why: $label');
    final p = _paragraph(tester, text);
    expect(_lines(p), 1, reason: '$why: "$label" en una sola línea');
    expect(p.didExceedMaxLines, isFalse);
    final textRect = tester.getRect(text);
    expect(_inside(r, textRect), isTrue, reason: '$why: "$label" dentro de su espacio');
    // Fuente responsiva: ≈ 10–11 sp a escala 1, nunca menos de 9.5 ni más de 1,3x.
    final fontSize = p.textScaler.scale((p.text.style?.fontSize ?? 11));
    expect(fontSize, inInclusiveRange(9.5, 11 * 1.3 + 0.01), reason: '$why: tamaño de "$label"');

    // Ícono centrado sobre su etiqueta, de 22–24 dp.
    final icon = find.descendant(of: dest, matching: find.byType(Icon)).first;
    final iconRect = tester.getRect(icon);
    expect((iconRect.center.dx - textRect.center.dx).abs(), lessThan(1.0), reason: '$why: ícono de $label');
    expect(iconRect.bottom, lessThanOrEqualTo(textRect.top + 0.5), reason: '$why: ícono arriba de $label');
    expect(iconRect.width, inInclusiveRange(21.99, 24.01));
  }
  // Cinco espacios del mismo ancho, en una fila, a lo ancho de la pantalla.
  for (final r in rects) {
    expect((r.width - rects.first.width).abs(), lessThan(0.5), reason: '$why: anchos iguales');
    expect((r.top - rects.first.top).abs(), lessThan(0.5), reason: '$why: misma fila');
  }
  expect(rects.first.left, closeTo(0, 0.5));
  expect(rects.last.right, closeTo(size.width, 0.5));
  // Encima de la zona segura de abajo.
  for (final label in _navLabels) {
    final t = tester.getRect(find.descendant(of: find.byKey(Key('nav-$label')), matching: find.text(label)));
    expect(t.bottom, lessThanOrEqualTo(size.height - _bottomInset), reason: '$why: $label sobre la zona segura');
  }
  // Pestaña elegida (Inicio) en naranja; las demás neutras.
  final selectedIcon = find.descendant(of: find.byKey(const Key('nav-Inicio')), matching: find.byType(Icon)).first;
  expect(IconTheme.of(tester.element(selectedIcon)).color, HyColors.primary, reason: why);
  final otherIcon = find.descendant(of: find.byKey(const Key('nav-Buscar')), matching: find.byType(Icon)).first;
  expect(IconTheme.of(tester.element(otherIcon)).color, HyColors.textSecondary, reason: why);
}

List<String> _homeCategoryOrder(WidgetTester tester) {
  final tiles = find.byWidgetPredicate((w) {
    final k = w.key;
    return k is ValueKey<String> && k.value.startsWith('home-category-');
  });
  final entries = [
    for (final e in tiles.evaluate())
      (
        (e.widget.key! as ValueKey<String>).value.substring('home-category-'.length),
        tester.getRect(find.byWidget(e.widget)),
      ),
  ];
  entries.sort((a, b) {
    final dy = a.$2.top.round().compareTo(b.$2.top.round());
    return dy != 0 ? dy : a.$2.left.compareTo(b.$2.left);
  });
  return [for (final e in entries) e.$1];
}

void main() {
  setUpAll(_loadFonts);

  final expectedOrder = orderCategories(
    DemoData.categories,
    slug: (c) => c.slug,
    name: (c) => c.name,
  ).map((c) => c.slug).toList();

  test('orden único de servicios: los nueve del hogar a pedido primero', () {
    expect(expectedOrder.take(9), [
      'plomeria',
      'electricidad',
      'limpieza',
      'albanileria',
      'pintura',
      'reparaciones-hogar',
      'cerrajeria',
      'jardineria',
      'aire-acondicionado',
    ]);
    // Todas siguen disponibles.
    expect(expectedOrder.toSet(), DemoData.categories.map((c) => c.slug).toSet());
    // Funciona también por nombre (sin tildes ni mayúsculas) si el slug fuera otro.
    expect(categoryRank(slug: 'x', name: 'ALBAÑILERÍA'), 3);
    expect(categoryRank(slug: 'x', name: 'Reparaciones del hogar'), 5);
    expect(categoryMatchesQuery('plomeria', ['Plomería']), isTrue);
    expect(categoryMatchesQuery('ELÉCTRI', ['Electricidad']), isTrue);
  });

  test('plomería: lo urgente primero y "Otro problema" siempre al final', () {
    final plumbing = DemoData.problems.where((p) => p.categoryId == 1).toList();
    final ordered = orderProblems(plumbing, categorySlug: 'plomeria', name: (p) => p.name, isOther: (p) => p.isOther);
    expect(ordered.map((p) => p.name), [
      'Fuga de agua',
      'Destapar cañería',
      'Sin agua',
      'Problema con la ducha',
      'Reparar inodoro',
      'Reparar o instalar grifo',
      'Instalar tuberías',
      'Otro problema',
    ]);
    for (final c in DemoData.categories) {
      final list = DemoData.problems.where((p) => p.categoryId == c.id).toList();
      final o = orderProblems(list, categorySlug: c.slug, name: (p) => p.name, isOther: (p) => p.isOther);
      expect(o.toSet(), list.toSet(), reason: c.name);
      if (list.any((p) => p.isOther)) expect(o.last.isOther, isTrue, reason: c.name);
    }
  });

  test('GPS: fuera de Bolivia no se usa el punto; en Uyuni sugiere Uyuni', () {
    final cities = DemoData.cities;
    final lima = resolveGpsFix(const GeoPoint(-12.0464, -77.0428), cities);
    expect(lima.outsideBolivia, isTrue);
    expect(lima.point, isNull);
    expect(lima.city, isNull);
    final uyuni = resolveGpsFix(const GeoPoint(-20.4600, -66.8250), cities);
    expect(uyuni.outsideBolivia, isFalse);
    expect(uyuni.point, isNotNull);
    expect(uyuni.city?.name, 'Uyuni');
  });

  for (final entry in _sizes.entries) {
    for (final scale in _scales) {
      testWidgets('inicio del cliente ${entry.key}, letra x$scale', (tester) async {
        final size = entry.value;
        await _pumpHome(tester, size: size, textScale: scale);
        final why = '${entry.key} x$scale';
        expect(tester.takeException(), isNull, reason: why);

        // "Pedir ¡Ya!": píldora flotante, entera a la vista, sobre la barra de
        // abajo y en una línea. Es la única forma de pedir ya en el inicio.
        final fab = find.byKey(const Key('home-ya-fab'));
        final navTop = tester.getRect(find.byKey(const Key('app-bottom-nav'))).top;
        void checkFab(String when) {
          final r = tester.getRect(fab);
          expect(r.left, greaterThanOrEqualTo(0), reason: '$why $when');
          expect(r.right, lessThanOrEqualTo(size.width), reason: '$why $when');
          expect(r.bottom, lessThanOrEqualTo(navTop), reason: '$why $when: sobre la barra de abajo');
          expect(r.bottom, greaterThan(navTop - 40), reason: '$why $when: pegado a la barra');
          expect((r.center.dx - size.width / 2).abs(), lessThan(1), reason: '$why $when: centrado');
        }

        checkFab('al abrir');
        expect(
          _lines(_paragraph(tester, find.descendant(of: fab, matching: find.text('Pedir ¡Ya!')))),
          1,
          reason: why,
        );
        expect(find.text('Pedir ¡Ya!'), findsOneWidget, reason: '$why: sin botones repetidos');
        expect(find.textContaining('Encuéntral'), findsNothing, reason: '$why: sin banner de promoción');
        expect(find.byKey(const Key('home-promo')), findsNothing, reason: why);

        // Mapa (o aviso) antes de los servicios, del ancho de la página.
        final map = find.byKey(const Key('home-map'));
        expect(map, findsOneWidget, reason: '$why: en Santa Cruz hay profesionales disponibles');
        final mapRect = tester.getRect(map);
        expect(mapRect.height, inInclusiveRange(200, 240), reason: why);
        expect(mapRect.left, greaterThanOrEqualTo(0), reason: why);
        expect(mapRect.right, lessThanOrEqualTo(size.width), reason: why);
        expect(mapRect.top, greaterThan(tester.getRect(find.byType(TextField).first).bottom), reason: why);
        expect(find.text('Buscar profesionales'), findsOneWidget, reason: '$why: acción secundaria');

        // Al final de la lista, el botón sigue a la vista y no tapa lo último.
        final list = tester.state<ScrollableState>(
          find.descendant(of: find.byKey(const Key('home-list')), matching: find.byType(Scrollable)).first,
        );
        list.position.jumpTo(list.position.maxScrollExtent);
        await tester.pumpAndSettle();
        checkFab('al final');
        final cards = find.byType(ProfessionalCard);
        final last = cards.evaluate().isEmpty
            ? find.byKey(Key('home-category-${_homeCategoryOrder(tester).last}'))
            : cards.last;
        expect(
          tester.getRect(last).bottom,
          lessThanOrEqualTo(tester.getRect(fab).top),
          reason: '$why: lo último no queda tapado',
        );
        list.position.jumpTo(0);
        await tester.pumpAndSettle();

        _checkBottomNav(tester, size, why);

        // Servicios: los prioritarios primero, sin palabras partidas ni cortadas.
        final order = _homeCategoryOrder(tester);
        expect(order.take(6), expectedOrder.take(6), reason: why);
        final shown = order.where((s) => s != 'more').toList();
        expect(shown, expectedOrder.take(shown.length), reason: why);
        for (final slug in order) {
          final tile = find.byKey(Key('home-category-$slug'));
          final p = _paragraph(tester, tile);
          expect(_brokenWords(p), isEmpty, reason: '$why: $slug');
          expect(p.didExceedMaxLines, isFalse, reason: '$why: $slug cortado');
        }
        expect(find.text('Reparaciones'), findsOneWidget, reason: 'etiqueta corta');
        expect(find.bySemanticsLabel('Reparaciones del hogar'), findsOneWidget, reason: 'nombre completo accesible');

        expect(tester.takeException(), isNull, reason: why);
      });
    }
  }

  for (final scale in [1.0, 1.3, 2.0]) {
    testWidgets('sin profesionales cerca: aviso útil y sin espacio vacío (x$scale)', (tester) async {
      // Uyuni (Potosí): en la demostración no hay profesionales ahí.
      await _pumpHome(tester, size: const Size(360, 640), textScale: scale, cityId: 239);
      expect(find.byKey(const Key('home-map')), findsNothing, reason: 'sin mapa vacío');
      final card = find.byKey(const Key('home-map-empty'));
      expect(card, findsOneWidget);
      expect(
        find.text(
          'Aún no hay profesionales disponibles en tu zona. Puedes solicitar un servicio ahora o '
          'programarlo para después.',
        ),
        findsOneWidget,
      );
      expect(
        tester.getRect(card).height,
        lessThan(switch (scale) {
          1.0 => 130,
          1.3 => 200,
          _ => 320,
        }),
        reason: 'aviso corto, menos que el mapa',
      );
      expect(find.text('Buscar profesionales'), findsOneWidget);
      expect(find.text('Pedir ¡Ya!'), findsOneWidget, reason: 'solo el botón flotante');
      expect(find.text('Profesionales cerca de ti'), findsNothing, reason: 'no repite el aviso');
      expect(tester.takeException(), isNull);
    });
  }

  for (final size in [const Size(360, 640), const Size(360, 800)]) {
    testWidgets('mapa ${size.width.toInt()}x${size.height.toInt()}: un punto abre la vista previa y el perfil', (
      tester,
    ) async {
      await _pumpHome(tester, size: size);
      final pins = find.byWidgetPredicate(
        (w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('home-map-pin-'),
      );
      expect(pins, findsWidgets, reason: 'Santa Cruz tiene profesionales disponibles en la demostración');
      expect(find.text('${pins.evaluate().length} disponibles ahora'), findsOneWidget);
      // Sin mosaicos en las pruebas, pero la atribución va siempre que haya mosaicos.
      expect(find.byKey(const Key('home-map-attribution')), findsNothing);
      final map = tester.getRect(find.byKey(const Key('home-map')));
      for (final e in pins.evaluate()) {
        final r = tester.getRect(find.byWidget(e.widget));
        expect(map.contains(r.center), isTrue, reason: 'el punto queda dentro del mapa');
      }
      await tester.tap(pins.first);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('home-map-preview')), findsOneWidget);
      expect(find.text('Disponible ahora. La ubicación del mapa es aproximada.'), findsOneWidget);
      await tester.tap(find.byKey(const Key('home-map-preview-profile')));
      await tester.pumpAndSettle();
      expect(find.byType(ProfessionalProfilePage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('el botón flotante abre el pedido ¡Ya!', (tester) async {
    await _pumpHome(tester, size: const Size(360, 800));
    await tester.tap(find.byKey(const Key('home-ya-fab')));
    await tester.pumpAndSettle();
    expect(find.byType(RequestFlowPage), findsOneWidget);
    expect(find.text('Paso 1 de 4'), findsOneWidget);
  });

  testWidgets('la barra de abajo es la misma en todas las pestañas del cliente', (tester) async {
    const size = Size(320, 568);
    await _pumpHome(tester, size: size, textScale: 1.3);
    for (final tab in _navLabels) {
      await tester.tap(find.byKey(Key('nav-$tab')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: tab);
      expect(find.byKey(const Key('app-bottom-nav')), findsOneWidget, reason: tab);
      final selected = find.descendant(of: find.byKey(Key('nav-$tab')), matching: find.byType(Icon)).first;
      expect(IconTheme.of(tester.element(selected)).color, HyColors.primary, reason: tab);
      for (final label in _navLabels) {
        final t = find.descendant(of: find.byKey(Key('nav-$label')), matching: find.text(label));
        expect(_lines(_paragraph(tester, t)), 1, reason: '$tab: $label');
      }
    }
  });

  Future<void> openYa(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('home-ya-fab')));
    await tester.pumpAndSettle();
    expect(find.text('Paso 1 de 4'), findsOneWidget);
  }

  Future<void> tapVisible(WidgetTester tester, Finder f) async {
    await tester.ensureVisible(f);
    await tester.pumpAndSettle();
    await tester.tap(f);
    await tester.pumpAndSettle();
  }

  for (final scale in [1.0, 1.3]) {
    testWidgets('Pedir ¡Ya! paso 1: mismo orden que el inicio y buscador (320x568, x$scale)', (tester) async {
      await _pumpHome(tester, size: const Size(320, 568), textScale: scale);
      final homeOrder = _homeCategoryOrder(tester).where((s) => s != 'more').toList();
      await openYa(tester);
      expect(tester.takeException(), isNull);
      // El orden del paso 1 es el mismo (y empieza con los mismos) que el inicio.
      final names = {for (final c in DemoData.categories) c.name: c.slug};
      final texts = find.descendant(
        of: find.byType(RequestFlowPage),
        matching: find.byWidgetPredicate((w) => w is Text && names.containsKey(w.data)),
        skipOffstage: false,
      );
      final step1 = [
        for (final e in texts.evaluate())
          (names[(e.widget as Text).data]!, (e.renderObject! as RenderBox).localToGlobal(Offset.zero).dy),
      ]..sort((a, b) => a.$2.compareTo(b.$2));
      expect(step1.map((e) => e.$1).toList(), expectedOrder);
      expect(step1.map((e) => e.$1).take(homeOrder.length).toList(), homeOrder);

      // Buscador sin tildes ni mayúsculas.
      await tester.enterText(find.byKey(const Key('category-search')), 'PLOMERIA');
      await tester.pumpAndSettle();
      expect(find.text('Plomería'), findsOneWidget);
      expect(find.text('Electricidad'), findsNothing);
      await tester.enterText(find.byKey(const Key('category-search')), 'zzz');
      await tester.pumpAndSettle();
      expect(find.text('Ver todos los servicios'), findsOneWidget);
      await tapVisible(tester, find.text('Ver todos los servicios'));
      expect(find.text('Electricidad'), findsOneWidget);

      // "Continuar" siempre a la vista, sobre la zona segura.
      final cont = tester.getRect(find.text('Continuar'));
      expect(cont.bottom, lessThanOrEqualTo(568 - _bottomInset));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('paso 2 (plomería): orden, varias opciones, check naranja y Continuar fijo (320x568, x1.3)', (
    tester,
  ) async {
    await _pumpHome(tester, size: const Size(320, 568), textScale: 1.3);
    await openYa(tester);
    await tapVisible(tester, find.text('Plomería'));
    expect(find.text('Paso 2 de 4'), findsOneWidget);
    expect(tester.takeException(), isNull);

    final plumbing = DemoData.problems.where((p) => p.categoryId == 1).toList();
    final ys = <String, double>{
      for (final p in plumbing)
        p.name:
            tester.getTopLeft(find.byKey(ValueKey('problem-${p.id}'), skipOffstage: false)).dy * 10000 +
            tester.getTopLeft(find.byKey(ValueKey('problem-${p.id}'), skipOffstage: false)).dx,
    };
    final shownOrder = ys.keys.toList()..sort((a, b) => ys[a]!.compareTo(ys[b]!));
    expect(shownOrder, [
      'Fuga de agua',
      'Destapar cañería',
      'Sin agua',
      'Problema con la ducha',
      'Reparar inodoro',
      'Reparar o instalar grifo',
      'Instalar tuberías',
      'Otro problema',
    ]);

    // Tarjetas compactas pero cómodas de tocar.
    for (final p in plumbing) {
      final r = tester.getRect(find.byKey(ValueKey('problem-${p.id}'), skipOffstage: false));
      expect(r.height, greaterThanOrEqualTo(48), reason: p.name);
      expect(r.height, lessThan(140), reason: '${p.name}: no tan alta');
    }

    // Se eligen varias; cada elegida queda en naranja con ✓.
    final fuga = plumbing.firstWhere((p) => p.name == 'Fuga de agua');
    final ducha = plumbing.firstWhere((p) => p.name == 'Problema con la ducha');
    await tapVisible(tester, find.byKey(ValueKey('problem-${fuga.id}')));
    await tapVisible(tester, find.byKey(ValueKey('problem-${ducha.id}')));
    for (final p in [fuga, ducha]) {
      final check = tester.widget<Icon>(find.byKey(ValueKey('problem-check-${p.id}')));
      expect(check.icon, Icons.check_circle_rounded);
      expect(check.color, HyColors.primary);
    }
    final notChosen = plumbing.firstWhere((p) => p.name == 'Sin agua');
    expect(
      tester.widget<Icon>(find.byKey(ValueKey('problem-check-${notChosen.id}'))).icon,
      isNot(Icons.check_circle_rounded),
    );
    // Inodoro ya no usa el letrero de baño público.
    final inodoro = plumbing.firstWhere((p) => p.name == 'Reparar inodoro');
    expect(
      find.descendant(
        of: find.byKey(ValueKey('problem-${inodoro.id}'), skipOffstage: false),
        matching: find.byIcon(Icons.wc),
      ),
      findsNothing,
    );

    // "Continuar" fijo sobre la zona segura mientras la lista se desplaza.
    final before = tester.getRect(find.text('Continuar'));
    expect(before.bottom, lessThanOrEqualTo(568 - _bottomInset));
    await tester.drag(find.byType(SingleChildScrollView).first, const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(tester.getRect(find.text('Continuar')), before);

    await tester.tap(find.text('Continuar'));
    await tester.pumpAndSettle();
    expect(find.text('Cuéntanos más'), findsOneWidget);
    expect(find.text('Fuga de agua'), findsOneWidget);
    expect(find.text('Problema con la ducha'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  Future<void> toStep4(WidgetTester tester) async {
    await openYa(tester);
    await tapVisible(tester, find.text('Plomería'));
    final fuga = DemoData.problems.firstWhere((p) => p.categoryId == 1 && p.name == 'Fuga de agua');
    await tapVisible(tester, find.byKey(ValueKey('problem-${fuga.id}')));
    await tester.tap(find.text('Continuar'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continuar'));
    await tester.pumpAndSettle();
    expect(find.text('Paso 4 de 4'), findsOneWidget);
  }

  Future<void> useGps(WidgetTester tester) async {
    await tapVisible(tester, find.text('Usar mi ubicación'));
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Continuar')));
    await tester.pumpAndSettle();
  }

  Future<void> fillAddressAndSend(WidgetTester tester) async {
    final address = find.widgetWithText(TextFormField, 'Dirección');
    await tester.ensureVisible(address);
    await tester.enterText(address, 'Calle Potosí 123, barrio Central');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lo necesito ¡Ya!'));
    // El detalle del pedido tiene animaciones que no terminan: solo avanzamos.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('paso 4: GPS fuera de Bolivia avisa y no manda coordenadas', (tester) async {
    final gps = _FakeLocation()..point = const GeoPoint(-12.0464, -77.0428); // Lima
    final backend = await _pumpHome(tester, size: const Size(360, 640), location: gps);
    await toStep4(tester);
    await useGps(tester);
    expect(find.byKey(const Key('gps-outside-bolivia')), findsOneWidget);
    expect(find.text(outsideBoliviaMessage), findsOneWidget);
    expect(find.byKey(const Key('gps-taken')), findsNothing);
    await fillAddressAndSend(tester);
    expect(backend.drafts, hasLength(1));
    expect(backend.drafts.single.latitude, isNull);
    expect(backend.drafts.single.longitude, isNull);
    expect(backend.drafts.single.cityId, 1, reason: 'se queda en la ciudad del cliente');
    expect(tester.takeException(), isNull);
  });

  testWidgets('paso 4: GPS en Uyuni elige Uyuni (sin cambiar la ciudad del cliente)', (tester) async {
    final gps = _FakeLocation()..point = const GeoPoint(-20.4600, -66.8250);
    final backend = await _pumpHome(tester, size: const Size(360, 640), location: gps);
    await toStep4(tester);
    await useGps(tester);
    expect(find.byKey(const Key('gps-taken')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('service-city')), matching: find.text('Uyuni')), findsOneWidget);
    await fillAddressAndSend(tester);
    final d = backend.drafts.single;
    expect(d.cityId, 239);
    expect(d.latitude, closeTo(-20.46, 0.001));
    expect(d.longitude, closeTo(-66.825, 0.001));
    final container = ProviderScope.containerOf(tester.element(find.byType(MaterialApp).first));
    expect(container.read(selectedCityProvider), isNot(239), reason: 'la ciudad guardada no cambia');
    expect(tester.takeException(), isNull);
  });

  testWidgets('paso 4: cambiar el municipio a mano', (tester) async {
    final backend = await _pumpHome(tester, size: const Size(360, 640));
    await toStep4(tester);
    await tapVisible(tester, find.byKey(const Key('service-city')));
    await tester.enterText(find.byKey(const Key('city-search')), 'uyuni');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('city-uyuni-pt')));
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byKey(const Key('service-city')), matching: find.text('Uyuni')), findsOneWidget);
    await fillAddressAndSend(tester);
    expect(backend.drafts.single.cityId, 239);
    expect(backend.drafts.single.latitude, isNull);
  });

  testWidgets('paso 4: la dirección es obligatoria y el aviso de privacidad no queda tapado (320x568, x1.3)', (
    tester,
  ) async {
    final backend = await _pumpHome(tester, size: const Size(320, 568), textScale: 1.3);
    await toStep4(tester);
    expect(tester.takeException(), isNull);
    final privacy = find.byKey(const Key('address-privacy'));
    await tester.ensureVisible(privacy);
    await tester.pumpAndSettle();
    final bar = tester.getRect(find.text('Lo necesito ¡Ya!'));
    final note = tester.getRect(privacy);
    // El aviso entero queda encima del botón naranja (no debajo de la barra).
    final barTop = tester
        .getRect(find.ancestor(of: find.text('Lo necesito ¡Ya!'), matching: find.byType(SafeArea)).first)
        .top;
    expect(note.bottom, lessThanOrEqualTo(barTop + 0.5));
    expect(bar.bottom, lessThanOrEqualTo(568 - _bottomInset));
    expect(find.text('Programar'), findsOneWidget);
    // Sin dirección no se envía.
    await tester.tap(find.text('Lo necesito ¡Ya!'));
    await tester.pumpAndSettle();
    expect(find.text('Escribe la dirección'), findsOneWidget);
    expect(backend.drafts, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
