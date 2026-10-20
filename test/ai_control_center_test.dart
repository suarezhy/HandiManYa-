import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handimanya/core/services/device_auth.dart';
import 'package:handimanya/core/theme/app_theme.dart';
import 'package:handimanya/core/utils/app_error.dart';
import 'package:handimanya/data/demo/demo_agents.dart';
import 'package:handimanya/data/demo/demo_backend.dart';
import 'package:handimanya/data/models/ai_control.dart';
import 'package:handimanya/data/providers.dart';
import 'package:handimanya/features/admin/ai_control_center_page.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/demo_login.dart';

class _NoBiometrics implements DeviceAuth {
  @override
  Future<Set<DeviceBiometric>> available() async => const {};

  @override
  Future<DeviceAuthResult> authenticate(String reason) async => DeviceAuthResult.unavailable;
}

Matcher _code(String code) => throwsA(isA<AppError>().having((e) => e.code, 'code', code));

void main() {
  test('la app muestra los mismos agentes que siembra la migración 0012', () {
    final sql = File('supabase/migrations/20261020001200_ai_control_center.sql').readAsStringSync();
    expect(demoAgents, hasLength(26));
    expect(demoAgents.where((a) => !a.addedByClaude), hasLength(18));
    for (final a in demoAgents) {
      expect(sql.contains("('${a.key}', ${a.number}, "), isTrue, reason: a.name);
    }
  });

  group('bandeja de aprobación (demostración, igual que la base)', () {
    late DemoBackend backend;
    setUp(() async {
      backend = DemoBackend(simulateDelays: false, codeCooldown: Duration.zero);
      await backend.signInAs(DemoBackend.adminPhone);
    });
    tearDown(() => backend.dispose());

    test('aprobar exige confirmar identidad y queda auditado', () async {
      final req = (await backend.aiItems(statuses: ['pending_approval'])).first;
      expect(req.fromAi, isTrue);
      await expectLater(backend.decideAiItem(req.id, AiDecision.approve), _code('HMY_CONFIRMATION_REQUIRED'));
      await expectLater(
        backend.decideAiItem(req.id, AiDecision.approve, authMethod: 'password'),
        _code('HMY_CONFIRMATION_REQUIRED'),
        reason: 'ya no hay contraseñas',
      );
      await expectLater(backend.decideAiItem(req.id, AiDecision.completed), _code('HMY_INVALID_STATUS'));
      await backend.decideAiItem(req.id, AiDecision.approve, authMethod: 'otp');
      await backend.decideAiItem(req.id, AiDecision.completed, note: 'Revisado');
      expect((await backend.aiItems(statuses: ['completed'])).map((i) => i.id), contains(req.id));
      expect((await backend.auditLog()).map((e) => e.action), containsAll(['ai_item.approve', 'ai_item.completed']));
    });

    test('una alerta no se aprueba; se resuelve o se descarta', () async {
      final alert = (await backend.aiItems(statuses: ['open'])).firstWhere((i) => i.kind == 'alert');
      expect(alert.fromAi, isFalse, reason: 'las alertas de reglas son datos verificados');
      await expectLater(backend.decideAiItem(alert.id, AiDecision.approve), _code('HMY_INVALID_STATUS'));
      await backend.decideAiItem(alert.id, AiDecision.dismiss);
      await expectLater(backend.decideAiItem(alert.id, AiDecision.dismiss), _code('HMY_ALREADY_REVIEWED'));
    });

    test('solo un administrador entra', () async {
      await backend.signInAs(DemoBackend.customerPhone);
      await expectLater(backend.aiOverview(), throwsA(isA<AppError>()));
    });
  });

  testWidgets('el dueño aprueba con un código y ve el reporte diario', (tester) async {
    await initializeDateFormatting('es');
    final backend = DemoAppBackend(simulateDelays: false, codeCooldown: Duration.zero);
    addTearDown(backend.dispose);
    await backend.signInAs(DemoBackend.adminPhone);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          prefsProvider.overrideWithValue(prefs),
          backendProvider.overrideWithValue(backend),
          deviceAuthProvider.overrideWithValue(_NoBiometrics()),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          locale: const Locale('es', 'BO'),
          supportedLocales: const [Locale('es', 'BO')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: const AiControlCenterPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Esperan tu aprobación'), findsOneWidget);

    await tester.tap(find.text('Decisiones'));
    await tester.pumpAndSettle();
    expect(find.text('Recomendación de IA'), findsOneWidget);
    expect(find.text('Dato verificado'), findsWidgets);
    await tester.ensureVisible(find.text('Aprobar'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Aprobar'));
    await tester.pumpAndSettle();
    expect(find.text('Confirma que eres tú'), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirm-submit')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('confirm-code-field')), DemoBackend.demoCode);
    await tester.pumpAndSettle();
    expect((await backend.aiItems(statuses: ['approved'])), hasLength(1));

    await tester.ensureVisible(find.text('Agentes IA'));
    await tester.tap(find.text('Agentes IA'));
    await tester.pumpAndSettle();
    expect(find.textContaining('1. AI Boss'), findsOneWidget);

    await tester.ensureVisible(find.text('Reporte diario'));
    await tester.tap(find.text('Reporte diario'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Generate now'));
    await tester.tap(find.text('Generate now'));
    await tester.pumpAndSettle();
    expect(find.text('Top priorities today'), findsOneWidget);
  });
}
