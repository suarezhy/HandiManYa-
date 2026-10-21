import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handimanya/core/theme/app_theme.dart';
import 'package:handimanya/core/utils/app_error.dart';
import 'package:handimanya/data/demo/demo_backend.dart';
import 'package:handimanya/data/models/admin.dart';
import 'package:handimanya/data/models/costs.dart';
import 'package:handimanya/data/models/user.dart';
import 'package:handimanya/data/providers.dart';
import 'package:handimanya/features/admin/admin_applications_page.dart';
import 'package:handimanya/features/admin/admin_costs_page.dart';
import 'package:handimanya/features/pro_mode/identity_check_card.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/demo_login.dart';

Matcher _code(String code) => throwsA(isA<AppError>().having((e) => e.code, 'code', code));

const _applicant = 'demo-post-1';
const _applicantPhone = '+59170012345';

void main() {
  test('la app muestra los mismos proveedores y precios que siembra la migración 0016', () async {
    final sql = File('supabase/migrations/20261020001600_operating_costs.sql').readAsStringSync();
    final backend = DemoBackend(simulateDelays: false, codeCooldown: Duration.zero);
    addTearDown(backend.dispose);
    await backend.signInAs(DemoBackend.adminPhone);
    final d = await backend.costDashboard();
    expect(d.vendors, hasLength(11));
    for (final v in d.vendors) {
      expect(sql.contains("('${v.key}', '${v.name}'"), isTrue, reason: v.key);
    }
    final didit = d.vendors.firstWhere((v) => v.key == 'didit_kyc');
    expect(didit.freeUnits, 30, reason: 'desde el 1/11/2026, USD 10 de crédito ≈ 30 verificaciones');
    expect(didit.status, VendorStatus.sandbox);
    expect(d.vendors.where((v) => v.status == VendorStatus.paid), isEmpty, reason: 'nada pagado sin autorización');
  });

  group('costos (demostración, igual que la base)', () {
    late DemoBackend backend;
    setUp(() async {
      backend = DemoBackend(simulateDelays: false, codeCooldown: Duration.zero);
      await backend.signInAs(DemoBackend.adminPhone);
    });
    tearDown(() => backend.dispose());

    test('autorizar un gasto pide confirmación y un tope; frenar no', () async {
      await expectLater(
        backend.setVendor('whatsapp_otp', VendorStatus.paid, monthlyCapUsd: 5),
        _code('HMY_CONFIRMATION_REQUIRED'),
      );
      await expectLater(
        backend.setVendor('whatsapp_otp', VendorStatus.paid, authMethod: 'otp'),
        _code('HMY_CAP_REQUIRED'),
      );
      await expectLater(backend.setVendor('apple_dev', VendorStatus.sandbox), _code('HMY_NO_SANDBOX'));
      await backend.confirmWithCode();
      await backend.setVendor('whatsapp_otp', VendorStatus.paid, monthlyCapUsd: 5, authMethod: 'otp');
      var w = (await backend.costDashboard()).vendors.firstWhere((v) => v.key == 'whatsapp_otp');
      expect(w.status, VendorStatus.paid);
      expect(w.monthlyCapUsd, 5);
      await backend.setVendor('whatsapp_otp', VendorStatus.off);
      w = (await backend.costDashboard()).vendors.firstWhere((v) => v.key == 'whatsapp_otp');
      expect(w.status, VendorStatus.off);
      expect(w.monthlyCapUsd, 0);
      expect((await backend.auditLog()).where((e) => e.action == 'costs.vendor'), hasLength(2));
    });

    test('solo el equipo ve los costos', () async {
      await backend.signInAs(DemoBackend.customerPhone);
      await expectLater(backend.costDashboard(), throwsA(isA<AppError>()));
    });
  });

  group('verificación de identidad (demostración)', () {
    late DemoBackend backend;
    setUp(() => backend = DemoBackend(simulateDelays: false, codeCooldown: Duration.zero));
    tearDown(() => backend.dispose());

    test('el sandbox crea una prueba que no aprueba a nadie ni cuenta como real', () async {
      await backend.signInAs(_applicantPhone);
      expect((await backend.identityCheck()).status, IdentityStatus.none);
      final s = await backend.startIdentityCheck();
      expect(s.sandbox, isTrue);
      expect((await backend.identityCheck()).status, IdentityStatus.created);
      backend.debugIdentityResult(_applicant, IdentityStatus.approved, faceMatch: 96);

      await backend.signInAs(DemoBackend.adminPhone);
      final d = await backend.adminApplicationDetail(_applicant);
      expect(d.summary.status, VerificationStatus.submitted, reason: 'el resultado de Didit no aprueba');
      expect(d.identityChecks.single.sandbox, isTrue);

      for (final doc in d.documents) {
        await backend.reviewDocument(doc.id, DocumentStatus.accepted);
      }
      await backend.setIdentityCheckRequired(true);
      await expectLater(
        backend.reviewApplication(_applicant, VerificationStatus.approved),
        _code('HMY_IDENTITY_CHECK_REQUIRED'),
        reason: 'una prueba del sandbox nunca alcanza',
      );
      await expectLater(backend.setIdentityCheckRequired(false), _code('HMY_CONFIRMATION_REQUIRED'));
      backend.debugIdentityResult(_applicant, IdentityStatus.approved, faceMatch: 96, sandbox: false);
      await backend.reviewApplication(_applicant, VerificationStatus.approved);
    });

    test('con Didit apagado, la verificación queda en pausa (no se cobra)', () async {
      await backend.signInAs(DemoBackend.adminPhone);
      await backend.setVendor('didit_kyc', VendorStatus.off);
      await backend.signInAs(_applicantPhone);
      await expectLater(backend.startIdentityCheck(), _code('HMY_IDENTITY_PAUSED'));
    });
  });

  group('pantallas', () {
    Future<void> pump(WidgetTester tester, DemoAppBackend app, Widget page) async {
      await initializeDateFormatting('es');
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          key: UniqueKey(),
          overrides: [prefsProvider.overrideWithValue(prefs), backendProvider.overrideWithValue(app)],
          child: MaterialApp(
            theme: AppTheme.light(),
            locale: const Locale('es', 'BO'),
            supportedLocales: const [Locale('es', 'BO')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: page,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('costos del mes: resumen, plan gratis y apagar un proveedor', (tester) async {
      final app = DemoAppBackend(simulateDelays: false, codeCooldown: Duration.zero);
      addTearDown(app.dispose);
      await tester.runAsync(() => app.signInAs(DemoBackend.adminPhone));
      await pump(tester, app, const AdminCostsPage());
      expect(find.byKey(const Key('cost-summary')), findsOneWidget);
      expect(find.text('Gastado: US\$ 0'), findsOneWidget);
      expect(find.textContaining('Nada pagado se activa ni cobra sin tu autorización'), findsOneWidget);
      expect(find.byKey(const Key('vendor-didit_kyc')), findsOneWidget);
      expect(find.textContaining('Gratis este mes: 0 de 30 verificaciones'), findsOneWidget);

      final stop = find.byKey(const Key('vendor-stop-didit_kyc'));
      await tester.ensureVisible(stop);
      await tester.pumpAndSettle();
      await tester.tap(stop);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('vendor-stop-didit_kyc')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('autorizar un pago pide un tope antes de guardar', (tester) async {
      final app = DemoAppBackend(simulateDelays: false, codeCooldown: Duration.zero);
      addTearDown(app.dispose);
      await tester.runAsync(() => app.signInAs(DemoBackend.adminPhone));
      await pump(tester, app, const AdminCostsPage());
      final change = find.byKey(const Key('vendor-change-sms_otp'));
      await tester.ensureVisible(change);
      await tester.pumpAndSettle();
      await tester.tap(change);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('vendor-option-paid')));
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(find.byKey(const Key('vendor-save'))).onPressed, isNull);
      await tester.enterText(find.byKey(const Key('vendor-cap')), '3');
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(find.byKey(const Key('vendor-save'))).onPressed, isNotNull);
    });

    testWidgets('el profesional ve el aviso de modo de prueba', (tester) async {
      final app = DemoAppBackend(simulateDelays: false, codeCooldown: Duration.zero);
      addTearDown(app.dispose);
      await tester.runAsync(() async {
        await app.signInAs(_applicantPhone);
        await app.startIdentityCheck();
      });
      await pump(tester, app, const Scaffold(body: IdentityCheckCard()));
      expect(find.byKey(const Key('identity-sandbox')), findsOneWidget);
      expect(find.textContaining('no uses tu carnet real'), findsOneWidget);
      expect(find.text('Continuar la verificación'), findsOneWidget);
    });

    testWidgets('la postulación muestra la verificación y que es una prueba', (tester) async {
      final app = DemoAppBackend(simulateDelays: false, codeCooldown: Duration.zero);
      addTearDown(app.dispose);
      await tester.runAsync(() async {
        await app.signInAs(_applicantPhone);
        await app.startIdentityCheck();
        app.debugIdentityResult(_applicant, IdentityStatus.approved, faceMatch: 96);
        await app.signInAs(DemoBackend.adminPhone);
      });
      await pump(tester, app, const AdminApplicationDetailPage(professionalId: _applicant));
      expect(find.byKey(const Key('identity-section')), findsOneWidget);
      expect(find.text('Prueba (no cuenta)'), findsOneWidget);
      expect(find.textContaining('Parecido con el carnet: 96%'), findsOneWidget);
      expect(find.byKey(const Key('identity-required')), findsOneWidget);
    });
  });
}
