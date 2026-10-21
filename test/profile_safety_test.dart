import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:handimanya/app.dart';
import 'package:handimanya/core/services/location_service.dart';
import 'package:handimanya/core/theme/app_theme.dart';
import 'package:handimanya/data/demo/demo_backend.dart';
import 'package:handimanya/data/models/booking.dart';
import 'package:handimanya/data/models/geo.dart';
import 'package:handimanya/data/providers.dart';
import 'package:handimanya/features/auth/phone_auth_page.dart';
import 'package:handimanya/features/booking/booking_detail_page.dart';
import 'package:handimanya/features/booking/live_trip.dart';
import 'package:handimanya/features/legal/legal_texts.dart';
import 'package:handimanya/features/pro_mode/wallet_page.dart';
import 'package:handimanya/features/profile/profile_page.dart';
import 'package:handimanya/features/safety/emergency_numbers.dart';
import 'package:handimanya/router.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/demo_login.dart';

class _FakeLocation implements LocationService {
  const _FakeLocation();

  @override
  Future<GeoPoint> current() async => const GeoPoint(-17.7800, -63.1800);
}

const _small = Size(320, 568);

const _phone = Size(390, 844);

void _setSize(WidgetTester tester, Size logical) {
  tester.view.physicalSize = logical * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

/// Portapapeles de prueba: guarda lo que la app copia.
String? _clipboard;
void _mockClipboard(WidgetTester tester) {
  _clipboard = null;
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') _clipboard = (call.arguments as Map)['text'] as String?;
    return null;
  });
  addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
}

Future<DemoAppBackend> _pumpApp(WidgetTester tester, {Size size = _phone, double textScale = 1}) async {
  await initializeDateFormatting('es');
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final backend = DemoAppBackend(simulateDelays: false, codeCooldown: Duration.zero);
  addTearDown(backend.dispose);
  _setSize(tester, size);
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

GoRouter _router(WidgetTester tester) => GoRouter.of(tester.element(find.byType(Scaffold).first));

/// Entra y abre Perfil por la ruta (la barra de abajo la cambia otra tarea).
Future<DemoAppBackend> _openProfile(
  WidgetTester tester, {
  String phone = DemoBackend.customerPhone,
  Size size = _phone,
  double textScale = 1,
}) async {
  final backend = await _pumpApp(tester, size: size, textScale: textScale);
  await loginWithPhone(tester, phone);
  _router(tester).go(phone == DemoBackend.professionalPhone ? Routes.proProfile : Routes.profile);
  await tester.pumpAndSettle();
  expect(find.byType(ProfilePage), findsOneWidget);
  return backend;
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

/// Desplaza la hoja abierta hasta que se ve [f] y lo toca (si [tap]).
Future<void> _inSheet(WidgetTester tester, Finder f, {bool tap = true}) async {
  final scrollable = find
      .descendant(of: find.byType(DraggableScrollableSheet).last, matching: find.byType(Scrollable))
      .first;
  if (f.evaluate().isEmpty) {
    await tester.scrollUntilVisible(f, 150, scrollable: scrollable);
  } else {
    await tester.ensureVisible(f);
  }
  await tester.pumpAndSettle();
  if (tap) {
    await tester.tap(f);
    await tester.pumpAndSettle();
  }
}

Future<void> _closeSheet(WidgetTester tester) async {
  // Toque fuera de la hoja (arriba de la app de demostración hay un aviso).
  await tester.tapAt(tester.getTopLeft(find.byType(ModalBarrier).last) + const Offset(10, 10));
  await tester.pumpAndSettle();
}

/// Un servicio confirmado entre el cliente y Juan Carlos (profesional demo).
Future<String> _confirmedBooking(DemoBackend backend) async {
  await backend.signInAs(DemoBackend.professionalPhone);
  await backend.setAvailability(true);
  await backend.signInAs(DemoBackend.customerPhone);
  final id = await backend.create(
    const BookingDraft(
      categoryId: 2,
      cityId: 1,
      zoneId: 12,
      mode: BookingMode.now,
      description: 'Se cortó la luz en la cocina',
      address: 'Calle Los Pinos 123',
      latitude: -17.7833,
      longitude: -63.1821,
    ),
  );
  await backend.signInAs(DemoBackend.professionalPhone);
  await backend.accept(id, isOffer: true);
  return id;
}

Future<void> _pumpDetail(
  WidgetTester tester,
  DemoAppBackend app,
  String id, {
  Size size = _phone,
  double textScale = 1,
  bool settle = true,
}) async {
  await initializeDateFormatting('es');
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  _setSize(tester, size);
  await tester.pumpWidget(
    ProviderScope(
      key: UniqueKey(),
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        backendProvider.overrideWithValue(app),
        locationServiceProvider.overrideWithValue(const _FakeLocation()),
        tripShareBaseUrlProvider.overrideWithValue('https://ejemplo.bo'),
      ],
      child: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
        child: MaterialApp(
          builder: (c, child) => MediaQuery(
            data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          theme: AppTheme.light(),
          locale: const Locale('es', 'BO'),
          supportedLocales: const [Locale('es', 'BO')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: BookingDetailPage(id: id),
        ),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

void main() {
  group('Perfil: Seguridad y confianza', () {
    for (final (size, scale) in const [(_phone, 1.0), (_small, 1.3)]) {
      testWidgets(
        'la sección se ve completa y sin desbordes (${size.width.toInt()}x${size.height.toInt()}, letra x$scale)',
        (tester) async {
          await _openProfile(tester, size: size, textScale: scale);
          for (final key in const [
            'safety-section',
            'safety-emergency-guide',
            'safety-trusted-contact',
            'safety-report',
            'safety-blocked',
          ]) {
            final f = find.byKey(Key(key));
            await tester.ensureVisible(f);
            await tester.pumpAndSettle();
            expect(f, findsOneWidget, reason: key);
          }
          expect(find.text('Seguridad y confianza'), findsOneWidget);
          // Cuenta unificada: la postulación sigue en Perfil.
          await tester.ensureVisible(find.text('Quiero ser profesional'));
          expect(find.text('Quiero ser profesional'), findsOneWidget);
          await tester.ensureVisible(find.text('Eliminar mi cuenta'));
          await tester.pumpAndSettle();
          expect(find.textContaining('SOS'), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }

    for (final (size, scale) in const [(_phone, 1.0), (_small, 1.3)]) {
      testWidgets('Guía de emergencia: números, aviso y sin desbordes (${size.width.toInt()}, x$scale)', (
        tester,
      ) async {
        _mockClipboard(tester);
        await _openProfile(tester, size: size, textScale: scale);
        await _tap(tester, find.byKey(const Key('safety-emergency-guide')));
        expect(find.text('Guía de emergencia'), findsOneWidget);
        expect(find.byKey(const Key('not-emergency-service')), findsOneWidget);
        expect(find.text(notEmergencyServiceText), findsOneWidget);
        for (final n in boliviaEmergencyNumbers) {
          await tester.ensureVisible(find.byKey(Key('emergency-call-${n.number}')));
          await tester.pumpAndSettle();
          expect(find.text('Llamar al ${n.number}'), findsOneWidget);
          expect(find.byKey(Key('emergency-copy-${n.number}')), findsOneWidget);
        }
        expect(boliviaEmergencyNumbers.map((n) => n.number), containsAll(['110', '118', '119']));
        await tester.ensureVisible(find.text('Consejos para recibir a un profesional en casa'));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(find.text('Si algo no está bien'), 200);
        await tester.pumpAndSettle();
        expect(find.textContaining('SOS'), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('Copiar y Llamar: sin teléfono disponible se copia el número', (tester) async {
      _mockClipboard(tester);
      await _openProfile(tester);
      await _tap(tester, find.byKey(const Key('safety-emergency-guide')));
      await _tap(tester, find.byKey(const Key('emergency-copy-110')));
      expect(_clipboard, '110');
      expect(find.text('Copiamos el 110 (Policía).'), findsOneWidget);
      // En las pruebas no hay app de teléfono: el botón copia el número y lo dice.
      _clipboard = null;
      await _tap(tester, find.byKey(const Key('emergency-call-118')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();
      expect(_clipboard, '118');
      expect(find.text('No pudimos abrir el teléfono. Marca el 118 (lo copiamos).'), findsOneWidget);
    });

    testWidgets('Contacto de confianza explica "Compartir mi viaje" y lleva a las solicitudes', (tester) async {
      await _openProfile(tester);
      await _tap(tester, find.byKey(const Key('safety-trusted-contact')));
      expect(find.byKey(const Key('trusted-contact-sheet')), findsOneWidget);
      expect(find.textContaining('no guarda una lista de contactos'), findsOneWidget);
      await _tap(tester, find.text('Ver mis solicitudes'));
      expect(_router(tester).state.matchedLocation, Routes.requests);
    });

    testWidgets('Personas bloqueadas muestra cuántas y cómo desbloquear', (tester) async {
      await _openProfile(tester);
      await _tap(tester, find.byKey(const Key('safety-blocked')));
      expect(find.byKey(const Key('blocked-sheet')), findsOneWidget);
      expect(find.text('No bloqueaste a nadie.'), findsOneWidget);
    });

    testWidgets('Reportar un problema de seguridad: sobre un servicio llega a los reportes del equipo', (tester) async {
      final backend = await _pumpApp(tester);
      await tester.runAsync(() async {
        await _confirmedBooking(backend);
        await backend.signOut();
      });
      await tester.pumpAndSettle();
      await loginWithPhone(tester, DemoBackend.customerPhone);
      _router(tester).go(Routes.profile);
      await tester.pumpAndSettle();
      await _tap(tester, find.byKey(const Key('safety-report')));
      expect(find.byKey(const Key('safety-report-sheet')), findsOneWidget);
      final booking = find.byWidgetPredicate(
        (w) =>
            w is ListTile &&
            (w.key is ValueKey<String>) &&
            (w.key! as ValueKey<String>).value.startsWith('safety-report-booking-'),
      );
      expect(booking, findsWidgets);
      await _tap(tester, booking.first);
      await _tap(tester, find.text('Acoso, insultos o amenazas'));
      await _tap(tester, find.text('Enviar reporte'));
      expect(find.text('Gracias. Nuestro equipo revisará tu reporte.'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.runAsync(() => backend.signInAs(DemoBackend.adminPhone));
      final reports = (await tester.runAsync(() => backend.adminReports()))!;
      expect(reports.any((r) => r.reason.key == 'acoso' && r.bookingId != null), isTrue);
    });

    testWidgets('Reportar un problema de seguridad sin servicio: llega a soporte', (tester) async {
      final backend = await _openProfile(tester);
      await _tap(tester, find.byKey(const Key('safety-report')));
      await _tap(tester, find.byKey(const Key('safety-report-write')));
      await tester.enterText(find.byKey(const Key('safety-report-body')), 'Alguien me escribió amenazas por WhatsApp');
      await _tap(tester, find.text('Enviar al equipo'));
      expect(find.textContaining('Recibimos tu mensaje'), findsOneWidget);
      await tester.runAsync(() => backend.signInAs(DemoBackend.adminPhone));
      final tickets = (await tester.runAsync(() => backend.adminTickets()))!;
      expect(tickets.any((t) => t.subject == 'Problema de seguridad'), isTrue);
    });
  });

  group('Cerrar sesión', () {
    testWidgets('pide confirmar, cierra la sesión y las pantallas privadas ya no abren', (tester) async {
      final backend = await _openProfile(tester);
      await _tap(tester, find.text('Cerrar sesión'));
      expect(find.text('¿Cerrar sesión?'), findsOneWidget);
      // "Volver" no cierra nada.
      await _tap(tester, find.text('Volver'));
      expect(backend.currentUser, isNotNull);
      expect(find.byType(ProfilePage), findsOneWidget);

      await _tap(tester, find.text('Cerrar sesión'));
      await _tap(tester, find.widgetWithText(FilledButton, 'Cerrar sesión'));
      expect(backend.currentUser, isNull);
      expect(find.byType(PhoneAuthPage), findsOneWidget);

      for (final route in [Routes.profile, Routes.requests, Routes.emergencyGuide, Routes.wallet, Routes.admin]) {
        _router(tester).go(route);
        await tester.pumpAndSettle();
        expect(find.byType(PhoneAuthPage), findsOneWidget, reason: route);
        expect(find.byType(ProfilePage), findsNothing, reason: route);
      }
      expect(tester.takeException(), isNull);
    });
  });

  group('Eliminar mi cuenta', () {
    testWidgets('pide confirmación; Volver no pide nada y confirmar deja el pedido registrado', (tester) async {
      final backend = await _openProfile(tester);
      await _tap(tester, find.text('Eliminar mi cuenta'));
      expect(find.text('¿Eliminar tu cuenta?'), findsOneWidget);
      expect(find.textContaining('no se borra al instante'), findsOneWidget);
      await _tap(tester, find.text('Volver'));
      expect((await tester.runAsync(() => backend.myAccount()))!.deletionRequested, isFalse);

      await _tap(tester, find.text('Eliminar mi cuenta'));
      await _tap(tester, find.text('Pedir eliminación'));
      expect((await tester.runAsync(() => backend.myAccount()))!.deletionRequested, isTrue);
      await tester.ensureVisible(find.text('Eliminación de cuenta solicitada'));
      final button = tester.widget<TextButton>(find.widgetWithText(TextButton, 'Eliminación de cuenta solicitada'));
      expect(button.onPressed, isNull, reason: 'no se puede pedir dos veces');
    });
  });

  group('Billetera solo para profesionales', () {
    testWidgets('el cliente no ve billetera y no puede abrirla por la dirección', (tester) async {
      await _openProfile(tester);
      expect(find.text('Mi billetera'), findsNothing);
      _router(tester).go(Routes.wallet);
      await tester.pumpAndSettle();
      expect(find.byType(WalletPage), findsNothing, reason: 'vuelve al inicio');
    });

    testWidgets('el profesional ve Mi billetera con saldo, recarga e historial', (tester) async {
      await _openProfile(tester, phone: DemoBackend.professionalPhone);
      await _tap(tester, find.text('Mi billetera'));
      expect(find.byType(WalletPage), findsOneWidget);
      expect(find.text('Saldo disponible (Bs)'), findsOneWidget);
      expect(find.text('Recargar saldo'), findsWidgets);
      await tester.scrollUntilVisible(
        find.text('Historial de movimientos'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Historial de movimientos'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('Documentos legales', () {
    Future<void> checkDoc(WidgetTester tester, LegalDoc doc) async {
      final tile = find.widgetWithText(ListTile, doc.title);
      await _tap(tester, tile);
      final page = find.byType(LegalDocPage);
      expect(page, findsOneWidget, reason: doc.key);
      expect(
        find.descendant(of: page, matching: find.text(doc.title)),
        findsOneWidget,
        reason: doc.key,
      );
      expect(
        find.descendant(of: page, matching: find.text(doc.body)),
        findsOneWidget,
        reason: doc.key,
      );
      expect(find.descendant(of: page, matching: find.textContaining('BORRADOR')), findsOneWidget);
      // La flecha de volver funciona y deja el perfil donde estaba.
      await tester.tap(find.byKey(const Key('legal-back')));
      await tester.pumpAndSettle();
      expect(page, findsNothing);
      expect(tile, findsOneWidget);
    }

    testWidgets('cliente: cada documento abre el texto correcto', (tester) async {
      await _openProfile(tester);
      final shown = [LegalDoc.terms, LegalDoc.privacy, LegalDoc.cancellations, LegalDoc.acceptableUse];
      for (final doc in shown) {
        await checkDoc(tester, doc);
      }
      // Los de profesionales no se muestran a quien no postuló.
      expect(find.widgetWithText(ListTile, LegalDoc.commissions.title), findsNothing);
      expect(find.widgetWithText(ListTile, LegalDoc.proRules.title), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('profesional: también comisiones y reglas', (tester) async {
      await _openProfile(tester, phone: DemoBackend.professionalPhone);
      for (final doc in LegalDoc.values) {
        await checkDoc(tester, doc);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('al crear la cuenta, los enlaces abren su documento y al volver se conserva lo escrito', (
      tester,
    ) async {
      await _pumpApp(tester);
      await loginWithPhone(tester, '+59167770001');
      await tester.enterText(find.byKey(const Key('profile-name')), 'Ana Quispe');
      await tester.ensureVisible(find.byKey(const Key('profile-terms')));
      await tester.pumpAndSettle();
      final scrollable = find.byType(Scrollable).first;
      final before = tester.state<ScrollableState>(scrollable).position.pixels;
      for (final (label, doc, systemBack) in const [
        ('Términos de uso', LegalDoc.terms, false),
        ('Política de privacidad', LegalDoc.privacy, true),
      ]) {
        await tester.tapOnText(find.textRange.ofSubstring(label));
        await tester.pumpAndSettle();
        final page = find.byType(LegalDocPage);
        expect(
          find.descendant(of: page, matching: find.text(doc.title)),
          findsOneWidget,
          reason: label,
        );
        expect(
          find.descendant(of: page, matching: find.text(doc.body)),
          findsOneWidget,
          reason: label,
        );
        if (systemBack) {
          // Botón atrás de Android.
          await tester.binding.handlePopRoute();
        } else {
          await tester.tap(find.byKey(const Key('legal-back')));
        }
        await tester.pumpAndSettle();
        expect(page, findsNothing, reason: label);
        expect(find.text('Ana Quispe'), findsOneWidget, reason: 'se conserva el nombre escrito');
        expect(tester.state<ScrollableState>(scrollable).position.pixels, before, reason: 'misma posición');
      }
    });

    test('los textos legales describen el ingreso sin contraseña y los pagos directos', () {
      final all = LegalDoc.values.map((d) => d.body).join('\n');
      expect(all, isNot(matches(RegExp('tu contraseña|correo y contraseña'))), reason: 'el ingreso es con celular');
      expect(LegalDoc.terms.body, contains('No hay contraseña'));
      expect(LegalDoc.terms.body, contains('no recibe, no retiene y no garantiza ese pago'));
      expect(LegalDoc.terms.body, contains('Los clientes no tienen billetera'));
      expect(LegalDoc.privacy.body, contains('Didit'));
      expect(LegalDoc.terms.body, contains('no es un servicio de emergencias'));
      expect(LegalDoc.commissions.body, contains('Los clientes no tienen billetera ni pagan comisión'));
    });

    test('la política de privacidad nombra el botón real y la ubicación en vivo', () {
      expect(LegalDoc.privacy.body, contains('Perfil > Eliminar mi cuenta'));
      expect(LegalDoc.privacy.body, contains('Compartir mi viaje'));
    });
  });

  group('Emergencia en una solicitud activa', () {
    testWidgets('no aparece antes de que un profesional acepte', (tester) async {
      final app = DemoAppBackend(simulateDelays: false, codeCooldown: Duration.zero);
      addTearDown(app.dispose);
      final id = (await tester.runAsync(() async {
        await app.signInAs(DemoBackend.customerPhone);
        return app.create(
          const BookingDraft(
            categoryId: 1,
            cityId: 1,
            mode: BookingMode.now,
            description: 'Gotea el caño de la cocina',
            address: 'Calle Los Pinos 123',
          ),
        );
      }))!;
      await _pumpDetail(tester, app, id, settle: false);
      // "Buscando profesional" anima sin parar: se avanza el reloj a mano.
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('Cancelar solicitud'), findsOneWidget, reason: 'el detalle cargó');
      expect(find.byKey(const Key('emergency-link')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('no aparece en una solicitud cancelada', (tester) async {
      final app = DemoAppBackend(simulateDelays: false, codeCooldown: Duration.zero);
      addTearDown(app.dispose);
      final id = (await tester.runAsync(() async {
        final id = await _confirmedBooking(app);
        await app.signInAs(DemoBackend.customerPhone);
        await app.cancel(id, 'Ya no lo necesito');
        return id;
      }))!;
      await _pumpDetail(tester, app, id);
      expect(find.text('Cancelado'), findsWidgets, reason: 'el detalle cargó');
      expect(find.byKey(const Key('emergency-link')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    for (final (size, scale) in const [(_phone, 1.0), (_small, 1.3)]) {
      testWidgets('cliente: números, aviso, compartir viaje y reporte (${size.width.toInt()}, x$scale)', (
        tester,
      ) async {
        final app = DemoAppBackend(simulateDelays: false, codeCooldown: Duration.zero);
        addTearDown(app.dispose);
        final id = (await tester.runAsync(() async {
          final id = await _confirmedBooking(app);
          await app.signInAs(DemoBackend.customerPhone);
          return id;
        }))!;
        await _pumpDetail(tester, app, id, size: size, textScale: scale);
        expect((await tester.runAsync(() => app.detail(id)))!.status.isActive, isTrue);
        await _tap(tester, find.byKey(const Key('emergency-link')));
        expect(find.text('Emergencia'), findsWidgets);
        expect(find.text(notEmergencyServiceText), findsOneWidget);
        for (final n in boliviaEmergencyNumbers) {
          await _inSheet(tester, find.byKey(Key('emergency-call-${n.number}')), tap: false);
          expect(find.text('Llamar al ${n.number}'), findsOneWidget);
        }
        await _inSheet(tester, find.byKey(const Key('emergency-share-trip')), tap: false);
        await _inSheet(tester, find.byKey(const Key('emergency-report')), tap: false);
        expect(find.textContaining('SOS'), findsNothing);
        expect(tester.takeException(), isNull);

        await _closeSheet(tester);

        // Compartir mi viaje: abre la hoja que ya existe (live_trip.dart). Solo
        // en tamaño normal: esa hoja no se desplaza y en 320 px con letra x1.3
        // se desborda (avisado; está fuera de esta tarea).
        if (size == _phone) {
          await _tap(tester, find.byKey(const Key('emergency-link')));
          await _inSheet(tester, find.byKey(const Key('emergency-share-trip')));
          expect(find.byKey(const Key('share-contact-name')), findsOneWidget);
          expect(tester.takeException(), isNull);
          await _closeSheet(tester);
        }

        // Reporte: llega a los reportes del equipo con la solicitud.
        await _tap(tester, find.byKey(const Key('emergency-link')));
        await _inSheet(tester, find.byKey(const Key('emergency-report')));
        await _tap(tester, find.text('Acoso, insultos o amenazas'));
        await _tap(tester, find.text('Enviar reporte'));
        expect(tester.takeException(), isNull);
        await tester.runAsync(() => app.signInAs(DemoBackend.adminPhone));
        final reports = (await tester.runAsync(() => app.adminReports()))!;
        expect(reports.any((r) => r.bookingId == id && r.reason.key == 'acoso'), isTrue);
        await tester.pumpWidget(const SizedBox());
      });
    }

    testWidgets('profesional: ve los números y reporta al cliente; no comparte viaje', (tester) async {
      final app = DemoAppBackend(simulateDelays: false, codeCooldown: Duration.zero);
      addTearDown(app.dispose);
      final id = (await tester.runAsync(() => _confirmedBooking(app)))!;
      await _pumpDetail(tester, app, id);
      await _tap(tester, find.byKey(const Key('emergency-link')));
      expect(find.text(notEmergencyServiceText), findsOneWidget);
      expect(find.byKey(const Key('emergency-share-trip')), findsNothing);
      await _inSheet(tester, find.byKey(const Key('emergency-report')));
      await _tap(tester, find.text('Otro motivo'));
      await _tap(tester, find.text('Enviar reporte'));
      await tester.runAsync(() => app.signInAs(DemoBackend.adminPhone));
      final reports = (await tester.runAsync(() => app.adminReports()))!;
      expect(reports.any((r) => r.bookingId == id && r.reason.key == 'otro'), isTrue);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
