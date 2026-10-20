import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:handimanya/app.dart';
import 'package:handimanya/core/services/location_service.dart';
import 'package:handimanya/core/utils/app_error.dart';
import 'package:handimanya/data/demo/demo_backend.dart';
import 'package:handimanya/data/demo/demo_data.dart';
import 'package:handimanya/data/models/booking.dart';
import 'package:handimanya/data/models/catalog.dart';
import 'package:handimanya/data/models/geo.dart';
import 'package:handimanya/data/models/professional.dart';
import 'package:handimanya/data/providers.dart';
import 'package:handimanya/features/booking/booking_detail_page.dart';
import 'package:handimanya/features/booking/choose_professional_page.dart';
import 'package:handimanya/features/common/professional_card.dart';
import 'package:handimanya/features/search/search_page.dart';
import 'package:handimanya/router.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Las listas pedidas para cada categoría, en orden (fuente: el dueño del proyecto).
const expectedProblems = {
  'plomeria': [
    'Fuga de agua',
    'Destapar cañería',
    'Reparar inodoro',
    'Reparar o instalar grifo',
    'Problema con la ducha',
    'Sin agua',
    'Instalar tuberías',
    'Otro problema',
  ],
  'electricidad': [
    'No tengo luz',
    'Cortocircuito',
    'Instalar tomacorrientes',
    'Reparar interruptores',
    'Instalar lámparas',
    'Problema con el tablero eléctrico',
    'Revisar instalación eléctrica',
    'Otro problema',
  ],
  'limpieza': [
    'Limpieza de casa',
    'Limpieza profunda',
    'Limpieza de departamento',
    'Limpieza después de construcción',
    'Limpieza de cocina',
    'Limpieza de baños',
    'Limpieza de oficinas',
    'Otro servicio',
  ],
  'pintura': [
    'Pintar paredes interiores',
    'Pintar exteriores',
    'Pintar techo',
    'Reparar y pintar paredes',
    'Pintar puertas',
    'Pintar rejas',
    'Pintar habitación',
    'Otro servicio',
  ],
  'albanileria': [
    'Reparar paredes',
    'Construir muro',
    'Colocar cerámica',
    'Reparar pisos',
    'Reparar techo',
    'Trabajos de cemento',
    'Remodelación',
    'Otro trabajo',
  ],
  'carpinteria': [
    'Reparar muebles',
    'Fabricar muebles',
    'Instalar puertas',
    'Reparar puertas',
    'Instalar cerraduras',
    'Reparar armarios',
    'Trabajos en madera',
    'Otro servicio',
  ],
  'jardineria': [
    'Cortar césped',
    'Podar árboles',
    'Podar plantas',
    'Limpiar jardín',
    'Instalar plantas',
    'Mantenimiento de jardín',
    'Retirar maleza',
    'Otro servicio',
  ],
  'reparaciones-hogar': [
    'Reparar puertas',
    'Reparar ventanas',
    'Colgar televisores',
    'Instalar repisas',
    'Armar muebles',
    'Reparaciones generales',
    'Instalaciones pequeñas',
    'Otro problema',
  ],
  'mecanica': [
    'El auto no arranca',
    'Batería descargada',
    'Cambio de aceite',
    'Problema con los frenos',
    'Problema con el motor',
    'Cambio de llanta',
    'Diagnóstico mecánico',
    'Otro problema',
  ],
  'aire-acondicionado': [
    'No enfría',
    'No enciende',
    'Instalación de aire acondicionado',
    'Limpieza y mantenimiento',
    'Recarga de refrigerante',
    'Fuga de agua',
    'Reparación general',
    'Otro problema',
  ],
  'cerrajeria': [
    'Me quedé fuera de casa',
    'Perdí mis llaves',
    'Cambiar cerradura',
    'Reparar chapa',
    'Duplicar llaves',
    'Abrir vehículo',
    'Instalar cerradura nueva',
    'Otro problema',
  ],
  'belleza': [
    'Corte de cabello',
    'Peinado',
    'Tinte de cabello',
    'Maquillaje',
    'Tratamiento capilar',
    'Peinado para evento',
    'Barbería',
    'Otro servicio',
  ],
  'manicure': [
    'Manicure',
    'Pedicure',
    'Uñas acrílicas',
    'Uñas en gel',
    'Esmaltado semipermanente',
    'Retiro de uñas',
    'Decoración de uñas',
    'Otro servicio',
  ],
  'ninera': [
    'Cuidado por horas',
    'Cuidado durante el día',
    'Cuidado por la noche',
    'Cuidado ocasional',
    'Acompañamiento después del colegio',
    'Cuidado durante eventos',
    'Otro servicio',
  ],
  'mascotas': [
    'Pasear perros',
    'Baño de mascotas',
    'Peluquería canina',
    'Cuidado por horas',
    'Cuidado durante el día',
    'Cuidado durante viajes',
    'Visitas a domicilio',
    'Otro servicio',
  ],
  'clases': [
    'Matemáticas',
    'Lenguaje y lectura',
    'Inglés',
    'Apoyo escolar',
    'Preparación para exámenes',
    'Música',
    'Computación',
    'Otra materia',
  ],
  'eventos': [
    'Meseros',
    'Decoración',
    'Ayudantes para eventos',
    'Organización de fiestas',
    'Limpieza después del evento',
    'Montaje de mesas y sillas',
    'Atención de invitados',
    'Otro servicio',
  ],
  'asesoria-legal': [
    'Consulta legal',
    'Contratos',
    'Trámites',
    'Derecho familiar',
    'Asuntos laborales',
    'Asuntos comerciales',
    'Documentos legales',
    'Otra consulta',
  ],
};

class _FakeLocation implements LocationService {
  const _FakeLocation();

  @override
  Future<GeoPoint> current() async => const GeoPoint(-17.7800, -63.1800);
}

Future<DemoAppBackend> _pumpApp(WidgetTester tester, {double textScale = 1}) async {
  await initializeDateFormatting('es');
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final backend = DemoAppBackend(simulateDelays: false);
  addTearDown(backend.dispose);
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        backendProvider.overrideWithValue(backend),
        locationServiceProvider.overrideWithValue(const _FakeLocation()),
      ],
      child: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
        child: const HandiManYaApp(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return backend;
}

Future<void> _login(WidgetTester tester, {String email = DemoBackend.customerEmail}) async {
  await tester.tap(find.text('Omitir'));
  await tester.pumpAndSettle();
  final door = find.text('Necesito un servicio');
  await tester.ensureVisible(door);
  await tester.pumpAndSettle();
  await tester.tap(door);
  await tester.pumpAndSettle();
  final fields = find.byType(TextFormField);
  await tester.enterText(fields.at(0), email);
  await tester.enterText(fields.at(1), DemoBackend.demoPassword);
  final submit = find.widgetWithText(FilledButton, 'Ingresar');
  await tester.ensureVisible(submit);
  await tester.pumpAndSettle();
  await tester.tap(submit);
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

Future<void> _tapText(WidgetTester tester, String label) => _tap(tester, find.text(label).last);

Future<void> _go(WidgetTester tester, String route) async {
  GoRouter.of(tester.element(find.byType(Scaffold).first)).push(route);
  await tester.pumpAndSettle();
}

Finder _problem(int id) => find.byKey(ValueKey('problem-$id'));

int _problemId(int categoryId, String name) =>
    DemoData.problems.firstWhere((p) => p.categoryId == categoryId && p.name == name).id;

void main() {
  group('catálogo de problemas', () {
    test('las 18 categorías tienen exactamente las opciones pedidas, en orden', () {
      expect(DemoData.categories, hasLength(18));
      for (final c in DemoData.categories) {
        final names = [
          for (final p
              in DemoData.problems.where((p) => p.categoryId == c.id).toList()
                ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder)))
            p.name,
        ];
        expect(names, expectedProblems[c.slug], reason: c.name);
        final others = DemoData.problems.where((p) => p.categoryId == c.id && p.isOther).toList();
        expect(others, hasLength(1), reason: '${c.name}: una sola opción "Otro"');
        expect(others.single.name, names.last, reason: '${c.name}: "Otro" va al final');
      }
    });

    test('la migración 0010 siembra las mismas opciones que la app de demostración', () {
      final sql = File('supabase/migrations/20261020001000_service_problems.sql').readAsStringSync();
      for (final c in DemoData.categories) {
        for (final p in DemoData.problems.where((p) => p.categoryId == c.id)) {
          final other = p.isOther ? 'true' : 'false';
          expect(
            sql.contains("('${c.slug}', '${p.name}', '${p.icon}', $other, ${p.sortOrder})"),
            isTrue,
            reason: '${c.name}: ${p.name}',
          );
        }
      }
    });

    test('las categorías sensibles piden documento y niñera y asesoría legal no van por ¡Ya!', () {
      final bySlug = {for (final c in DemoData.categories) c.slug: c};
      expect(bySlug['ninera']!.requiredDoc, 'antecedentes');
      expect(bySlug['cerrajeria']!.requiredDoc, 'antecedentes');
      expect(bySlug['mecanica']!.requiredDoc, 'antecedentes');
      expect(bySlug['asesoria-legal']!.requiredDoc, 'certificado');
      expect(bySlug['ninera']!.allowsYa, isFalse);
      expect(bySlug['asesoria-legal']!.allowsYa, isFalse);
      expect(bySlug['cerrajeria']!.allowsYa, isTrue);
      for (final slug in ['ninera', 'cerrajeria', 'mecanica', 'asesoria-legal']) {
        expect(bySlug[slug]!.safetyNote, isNotEmpty, reason: slug);
        expect(bySlug[slug]!.proNote, isNotEmpty, reason: slug);
      }
      expect(DemoData.categories.where((c) => c.isSensitive), hasLength(4));
    });
  });

  group('solicitudes con problemas (demostración)', () {
    late DemoBackend backend;
    setUp(() => backend = DemoBackend(simulateDelays: false));
    tearDown(() => backend.dispose());
    Future<void> asCustomer() => backend.signIn(email: DemoBackend.customerEmail, password: DemoBackend.demoPassword);
    Future<void> asAdmin() => backend.signIn(email: DemoBackend.adminEmail, password: DemoBackend.demoPassword);

    BookingDraft ya(int category, List<int> ids, {String description = '', String? other}) => BookingDraft(
      categoryId: category,
      cityId: 1,
      mode: BookingMode.now,
      description: description,
      address: 'Calle Junín 12',
      problemIds: ids,
      otherText: other,
    );

    test('guarda varios problemas y el texto de "Otro"', () async {
      await asCustomer();
      final id = await backend.create(
        ya(1, [_problemId(1, 'Otro problema'), _problemId(1, 'Fuga de agua')], other: 'el tanque hace ruido'),
      );
      final d = await backend.detail(id);
      expect(d.categoryId, 1);
      expect(d.problems, ['Fuga de agua', 'Otro problema: el tanque hace ruido']);
      expect(d.description, 'Fuga de agua. Otro problema: el tanque hace ruido');
      final list = await backend.myBookings(asProfessional: false);
      expect(list.firstWhere((b) => b.id == id).problems, d.problems);
    });

    test('valida la selección', () async {
      await asCustomer();
      Future<void> fails(BookingDraft d, String code) =>
          expectLater(backend.create(d), throwsA(isA<AppError>().having((e) => e.code, 'code', code)));
      await fails(ya(2, [_problemId(2, 'Otro problema')]), 'HMY_OTHER_REQUIRED');
      await fails(ya(2, [_problemId(1, 'Fuga de agua')]), 'HMY_INVALID_PROBLEM');
      await fails(ya(2, [_problemId(2, 'Cortocircuito')], other: 'suelto'), 'HMY_INVALID_PROBLEM');
      final nanny = DemoData.categories.firstWhere((c) => c.slug == 'ninera').id;
      await fails(ya(nanny, [_problemId(nanny, 'Cuidado por horas')]), 'HMY_YA_NOT_ALLOWED');
    });

    test('el admin agrega, edita, ordena y apaga opciones sin cambiar la app', () async {
      await asAdmin();
      await backend.saveProblem(const ServiceProblem(id: 0, categoryId: 1, name: 'Calefón a gas', sortOrder: 75));
      var list = await backend.adminProblems(1);
      final added = list.firstWhere((p) => p.name == 'Calefón a gas');
      await backend.saveProblem(added.copyWith(name: 'Revisar calefón'));
      await backend.reorderProblems([
        added.id,
        for (final p in list)
          if (p.id != added.id) p.id,
      ]);
      expect((await backend.problems(1)).first.name, 'Revisar calefón');
      await backend.saveProblem(added.copyWith(name: 'Revisar calefón', isActive: false));
      expect((await backend.problems(1)).map((p) => p.name), isNot(contains('Revisar calefón')));
      expect((await backend.adminProblems(1)).map((p) => p.name), contains('Revisar calefón'));

      await backend.saveCategory(const ServiceCategory(id: 0, slug: 'fumigacion', name: 'Fumigación', icon: 'build'));
      final cat = (await backend.adminServiceCategories()).firstWhere((c) => c.slug == 'fumigacion');
      expect((await backend.problems(cat.id)).map((p) => p.name), ['Otro servicio']);
      expect((await backend.categories()).map((c) => c.name), contains('Fumigación'));
      final audit = await backend.auditLog();
      expect(audit.where((e) => e.action.startsWith('service_problems.')), isNotEmpty);
    });

    test('programar para después lleva los mismos problemas al profesional elegido', () async {
      await asCustomer();
      final draft = ya(1, [_problemId(1, 'Fuga de agua')], description: 'Mejor en la mañana');
      final pros = await backend.search(const SearchFilters(cityId: 1, categoryId: 1));
      final start = DateTime.now().add(const Duration(days: 2));
      final id = await backend.create(
        draft.scheduledWith(
          professionalId: pros.first.id,
          start: DateTime(start.year, start.month, start.day, 10),
          durationMinutes: 60,
        ),
      );
      final d = await backend.detail(id);
      expect(d.mode, BookingMode.scheduled);
      expect(d.problems, ['Fuga de agua']);
      expect(d.description, 'Mejor en la mañana');
      expect(d.professional?.id, pros.first.id);
    });
  });

  group('pantallas', () {
    testWidgets('al tocar una categoría del inicio se pregunta qué necesitas, no se listan profesionales', (
      tester,
    ) async {
      await _pumpApp(tester);
      await _login(tester);
      await _tap(tester, find.bySemanticsLabel('Plomería').first);
      expect(find.text('¿Qué necesitas solucionar?'), findsOneWidget);
      expect(find.byType(SearchPage), findsNothing);
      expect(find.text('Fuga de agua'), findsOneWidget);
    });

    testWidgets('"Todos los servicios" también abre la pantalla de problemas', (tester) async {
      await _pumpApp(tester);
      await _login(tester);
      await _go(tester, Routes.categories);
      await tester.scrollUntilVisible(find.text('Asesoría legal'), 300, scrollable: find.byType(Scrollable).last);
      await _tapText(tester, 'Asesoría legal');
      expect(find.text('¿Qué necesitas solucionar?'), findsOneWidget);
      expect(find.text('Consulta legal'), findsOneWidget);
      expect(find.byType(SearchPage), findsNothing);
    });

    for (final scale in [1.0, 1.6]) {
      testWidgets('cada categoría muestra sus propias opciones (letra x$scale)', (tester) async {
        await _pumpApp(tester, textScale: scale);
        await _login(tester);
        for (final c in DemoData.categories) {
          await _go(tester, Routes.service(c.id));
          expect(tester.takeException(), isNull, reason: c.name);
          expect(find.text('¿Qué necesitas solucionar?'), findsOneWidget, reason: c.name);
          for (final name in expectedProblems[c.slug]!) {
            expect(find.text(name, skipOffstage: false), findsOneWidget, reason: '${c.name}: $name');
          }
          if (c.safetyNote != null) expect(find.text(c.safetyNote!, skipOffstage: false), findsOneWidget);
          // Elegir la primera opción habilita "Continuar" y lleva a "Cuéntanos más".
          final first = DemoData.problems.firstWhere((p) => p.categoryId == c.id);
          await _tap(tester, _problem(first.id));
          await _tapText(tester, 'Continuar');
          expect(find.text('Cuéntanos más'), findsOneWidget, reason: c.name);
          expect(find.text(first.name), findsOneWidget, reason: '${c.name}: resumen de lo elegido');
          await _tapText(tester, 'Continuar');
          expect(find.text('¿Dónde es?'), findsOneWidget, reason: c.name);
          if (c.allowsYa) {
            expect(find.text('Lo necesito ¡Ya!'), findsOneWidget, reason: c.name);
            expect(find.text('Programar para después'), findsOneWidget, reason: c.name);
          } else {
            expect(find.text('Lo necesito ¡Ya!'), findsNothing, reason: c.name);
            expect(find.text('Elegir profesional y horario'), findsOneWidget, reason: c.name);
          }
          GoRouter.of(tester.element(find.byType(Scaffold).first)).pop();
          await tester.pumpAndSettle();
        }
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('"Otro problema" pide escribir lo que necesitas', (tester) async {
      await _pumpApp(tester);
      await _login(tester);
      await _go(tester, Routes.service(1));
      expect(find.byKey(const ValueKey('other-text')), findsNothing);
      await _tap(tester, _problem(_problemId(1, 'Otro problema')));
      expect(find.byKey(const ValueKey('other-text')), findsOneWidget);
      await _tapText(tester, 'Continuar');
      expect(find.text('Cuéntanos qué necesitas'), findsOneWidget); // no avanza sin texto
      await tester.enterText(find.byKey(const ValueKey('other-text')), 'Se rompió el calefón');
      await _tapText(tester, 'Continuar');
      expect(find.text('Otro problema: Se rompió el calefón'), findsOneWidget);
    });

    testWidgets('pedido ¡Ya! completo con varios problemas', (tester) async {
      final backend = await _pumpApp(tester);
      await _login(tester);
      await _go(tester, Routes.service(1)); // Plomería
      await _tap(tester, _problem(_problemId(1, 'Fuga de agua')));
      await _tap(tester, _problem(_problemId(1, 'Destapar cañería')));
      await _tap(tester, _problem(_problemId(1, 'Destapar cañería'))); // tocar de nuevo la quita
      await _tap(tester, _problem(_problemId(1, 'Sin agua')));
      await _tapText(tester, 'Continuar');
      await tester.enterText(find.byType(TextFormField).first, 'Gotea debajo del lavaplatos');
      await _tapText(tester, 'Continuar');
      await tester.enterText(find.widgetWithText(TextFormField, 'Dirección'), 'Calle Los Pinos 123');
      // El detalle tiene una animación continua: se avanza cuadro a cuadro.
      final ya = find.text('Lo necesito ¡Ya!');
      await tester.ensureVisible(ya);
      await tester.pumpAndSettle();
      await tester.tap(ya);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(tester.takeException(), isNull);
      expect(find.byType(BookingDetailPage), findsOneWidget);
      expect(find.text('Fuga de agua'), findsOneWidget);
      expect(find.text('Sin agua'), findsOneWidget);
      expect(find.text('Destapar cañería'), findsNothing);
      expect(find.text('Gotea debajo del lavaplatos'), findsOneWidget);
      final mine = await backend.myBookings(asProfessional: false);
      expect(mine.first.problems, ['Fuga de agua', 'Sin agua']);
      expect(mine.first.categoryId, 1);
    });

    testWidgets('"Programar para después" lleva a elegir profesional y horario', (tester) async {
      await _pumpApp(tester);
      await _login(tester);
      await _go(tester, Routes.service(1));
      await _tap(tester, _problem(_problemId(1, 'Fuga de agua')));
      await _tapText(tester, 'Continuar');
      await _tapText(tester, 'Continuar');
      await tester.enterText(find.widgetWithText(TextFormField, 'Dirección'), 'Calle Los Pinos 123');
      await _tapText(tester, 'Programar para después');
      expect(find.byType(ChooseProfessionalPage), findsOneWidget);
      expect(find.text('Elige quién lo hará'), findsOneWidget);
      expect(find.text('Fuga de agua'), findsOneWidget);
      final card = find.textContaining('Ver perfil de');
      expect(card, findsWidgets);
      // Tocar a un profesional pide el día y la hora.
      await _tap(tester, find.byType(ProfessionalCard).first);
      expect(find.text('Elegir día'), findsOneWidget);
      await _tapText(tester, 'Enviar solicitud');
      expect(find.text('Elige el día y la hora'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('el administrador agrega una opción y el cliente la ve', (tester) async {
      await _pumpApp(tester);
      await _login(tester, email: DemoBackend.adminEmail);
      await _tapText(tester, 'Catálogo');
      expect(find.text('Plomería'), findsOneWidget);
      await _tap(
        tester,
        find.descendant(of: find.byKey(const ValueKey('admin-cat-1')), matching: find.text('Opciones')),
      );
      expect(find.text('Opciones de Plomería'), findsOneWidget);
      expect(find.text('Fuga de agua'), findsOneWidget);
      await _tapText(tester, 'Nueva opción');
      await tester.enterText(find.widgetWithText(TextFormField, 'Nombre'), 'Revisar calefón');
      await _tapText(tester, 'Guardar');
      expect(find.text('Revisar calefón'), findsOneWidget);
      // Subirla al primer lugar.
      for (var i = 0; i < 8; i++) {
        final up = find.ancestor(of: find.byTooltip('Subir Revisar calefón'), matching: find.byType(IconButton));
        if (tester.widget<IconButton>(up).onPressed == null) break;
        await _tap(tester, up);
      }
      await _go(tester, Routes.service(1));
      expect(find.text('Revisar calefón'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
