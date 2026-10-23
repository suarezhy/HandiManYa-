import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handimanya/core/services/device_auth.dart';
import 'package:handimanya/core/theme/app_theme.dart';
import 'package:handimanya/core/theme/tokens.dart';
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

  test('la demostración tiene el mismo estado veraz que la migración 0036', () {
    final sql = File('supabase/migrations/20261022003600_truthful_agents.sql').readAsStringSync();
    String key(AgentStatus s) => switch (s) {
      AgentStatus.needsSetup => 'needs_setup',
      _ => s.name,
    };
    for (final a in demoAgents) {
      expect(sql.contains("('${a.key}', '${key(a.status)}',"), isTrue, reason: a.name);
    }
    expect(demoAgents.where((a) => a.status == AgentStatus.ai), isEmpty, reason: 'ningún agente usa IA');
    for (final k in ['recruitment', 'launch', 'qa', 'customer_assistant', 'notifications', 'marketing']) {
      expect(demoAgents.firstWhere((a) => a.key == k).status, AgentStatus.planned, reason: k);
    }
    expect(demoAgents.firstWhere((a) => a.key == 'support').status, AgentStatus.rules);
    for (final s in AgentStatus.values) {
      expect(s.label.contains('Activo'), isFalse, reason: 'la categoría nunca dice "Activo"');
    }
  });

  test('"Activo" solo con una ejecución correcta dentro de su horario', () {
    final now = DateTime(2026, 10, 22, 12);
    const base = AiAgent(
      key: 'wallet',
      number: 8,
      name: 'Billetera',
      purpose: 'x',
      phase: 'A',
      status: AgentStatus.rules,
      maxGapMinutes: 180,
    );
    expect(base.executionAt(now), AgentExecution.never);
    final ran = base.withRun(at: now.subtract(const Duration(minutes: 30)), status: 'ok');
    expect(ran.executionAt(now), AgentExecution.active);
    expect(ran.executionAt(now.add(const Duration(hours: 4))), AgentExecution.stale);
    expect(ran.withRun(at: now, status: 'failed', error: '42P01').executionAt(now), AgentExecution.failed);
    const planned = AiAgent(
      key: 'launch',
      number: 15,
      name: 'L',
      purpose: 'x',
      phase: 'A',
      status: AgentStatus.planned,
    );
    expect(planned.executionAt(now), AgentExecution.notBuilt);
    expect(
      AiAgent.fromMap({
        'key': 'support',
        'number': 7,
        'name': 'Soporte',
        'purpose': 'x',
        'phase': 'A',
        'status': 'rules',
        'execution': 'active',
        'last_ok_run_at': '2026-10-22T10:00:00Z',
      }).execution,
      AgentExecution.active,
    );
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
      await expectLater(backend.decideAiItem(req.id, AiDecision.completed, note: 'nota'), _code('HMY_INVALID_STATUS'));
      await backend.decideAiItem(req.id, AiDecision.approve, authMethod: 'otp');
      await backend.decideAiItem(req.id, AiDecision.completed, note: 'Revisado');
      expect((await backend.aiItems(statuses: ['completed'])).map((i) => i.id), contains(req.id));
      expect((await backend.auditLog()).map((e) => e.action), containsAll(['ai_item.approve', 'ai_item.completed']));
    });

    test('una alerta no se aprueba; se resuelve o se descarta', () async {
      final alert = (await backend.aiItems(statuses: ['open'])).firstWhere((i) => i.kind == 'alert');
      expect(alert.fromAi, isFalse, reason: 'las alertas de reglas son datos verificados');
      await expectLater(backend.decideAiItem(alert.id, AiDecision.approve), _code('HMY_INVALID_STATUS'));
      await expectLater(backend.decideAiItem(alert.id, AiDecision.dismiss), _code('HMY_NOTE_REQUIRED'));
      await expectLater(backend.decideAiItem(alert.id, AiDecision.dismiss, note: '  '), _code('HMY_NOTE_REQUIRED'));
      await backend.decideAiItem(alert.id, AiDecision.dismiss, note: 'Revisado: sin acción');
      await expectLater(
        backend.decideAiItem(alert.id, AiDecision.dismiss, note: 'otra vez'),
        _code('HMY_ALREADY_REVIEWED'),
      );
      final d = await backend.aiItemDetail(alert.id);
      expect(d.item.status, AiItemStatus.dismissed);
      expect(d.history.single.note, 'Revisado: sin acción');
    });

    test('"Revisar ahora" registra solo a los agentes que corren', () async {
      expect((await backend.aiAgents()).where((a) => a.executionAt(DateTime.now()) == AgentExecution.active), isEmpty);
      expect((await backend.aiOverview()).lastMonitorRun, isNull);
      await backend.runAllChecks();
      final agents = await backend.aiAgents();
      final active = {
        for (final a in agents)
          if (a.execution == AgentExecution.active) a.key,
      };
      expect(active, containsAll(['boss', 'wallet', 'support', 'finance', 'ai_auditor', 'service_safety']));
      expect(active, isNot(contains('daily_report')), reason: 'el reporte solo corre al generarse');
      for (final a in agents.where((a) => a.status != AgentStatus.rules)) {
        expect(a.lastRunAt, isNull, reason: a.key);
        expect(a.execution, isNot(AgentExecution.active), reason: a.key);
      }
      expect((await backend.aiOverview()).lastMonitorRun, isNotNull);
      expect((await backend.auditLog()).map((e) => e.action), contains('ai.run_checks'));
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
    // Cada aviso es corto; el origen se abre en "Ver detalles".
    expect(find.text('Ver detalles'), findsWidgets);
    final req = (await backend.aiItems(statuses: ['pending_approval'])).single;
    await tester.ensureVisible(find.byKey(Key('ai-item-details-${req.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('ai-item-details-${req.id}')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Recomendación de un modelo de IA'), findsOneWidget);
    expect(find.textContaining('Aprobar (con código)'), findsOneWidget);
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
    await tester.ensureVisible(find.text('Agentes IA'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Agentes IA'));
    await tester.pumpAndSettle();
    expect(find.textContaining('1. AI Boss'), findsOneWidget);

    await tester.ensureVisible(find.text('Reporte diario'));
    await tester.tap(find.text('Reporte diario'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Generar el de ayer ahora'));
    await tester.tap(find.text('Generar el de ayer ahora'));
    await tester.pumpAndSettle();
    expect(find.text('Prioridades del día'), findsOneWidget);
    expect(find.textContaining('Reporte del '), findsOneWidget);
    expect(find.textContaining('Hora de Miami'), findsWidgets);
    for (final t in ['Operaciones', 'Finanzas', 'Seguridad', 'Profesionales y clientes', 'Rendimiento de IA']) {
      expect(find.text(t), findsOneWidget, reason: t);
    }
    expect(find.text('Comisiones cobradas'), findsOneWidget);
    expect(find.text('Servicios completados'), findsOneWidget);
    expect(find.text('Sin dato'), findsWidgets, reason: 'lo que no se midió no sale como cero');
    expect(find.byKey(const Key('daily-report-stale')), findsNothing, reason: 'es el de ayer');
    expect(find.textContaining('Top priorities'), findsNothing);
  });

  Future<DemoAppBackend> pumpCenter(WidgetTester tester, Size size) async {
    await initializeDateFormatting('es');
    final backend = DemoAppBackend(simulateDelays: false, codeCooldown: Duration.zero);
    addTearDown(backend.dispose);
    await backend.signInAs(DemoBackend.adminPhone);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
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
    return backend;
  }

  testWidgets('abrir una alerta muestra su origen y resolverla pide una nota auditada', (tester) async {
    final backend = await pumpCenter(tester, const Size(390, 844));
    await tester.tap(find.text('Decisiones'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('ai-item-details-2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('ai-item-details-2')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('ai-item-open-2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('ai-item-open-2')));
    await tester.pumpAndSettle();
    expect(find.text('Origen del aviso'), findsOneWidget);
    expect(find.textContaining('8. Billetera y pagos'), findsOneWidget);
    expect(find.textContaining('Recarga pendiente más de 24 horas'), findsOneWidget);
    expect(find.textContaining('Recarga 1'), findsOneWidget);
    expect(find.textContaining('Regla sobre datos reales'), findsOneWidget);
    expect(find.text('Sin decisiones todavía.'), findsOneWidget);

    await tester.ensureVisible(find.text('Ya lo resolví'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ya lo resolví'));
    await tester.pumpAndSettle();
    expect(find.text('Marcar como resuelto'), findsOneWidget);
    await tester.tap(find.text('Guardar'));
    await tester.pumpAndSettle();
    expect(find.text('Escribe al menos 3 caracteres'), findsOneWidget, reason: 'sin nota no se resuelve');
    await tester.enterText(find.byType(TextFormField), 'Recarga verificada a mano');
    await tester.tap(find.text('Guardar'));
    await tester.pumpAndSettle();

    final d = await backend.aiItemDetail(2);
    expect(d.item.status, AiItemStatus.completed);
    expect(d.history.single.action, 'ai_item.completed');
    expect(find.textContaining('Recarga verificada a mano'), findsWidgets);
    expect(find.text('Ya lo resolví'), findsNothing);
    expect((await backend.auditLog()).first.details['note'], 'Recarga verificada a mano');
  });

  testWidgets('las alertas altas del resumen dicen de dónde vienen', (tester) async {
    await pumpCenter(tester, const Size(390, 844));
    await tester.ensureVisible(find.text('Alertas críticas y altas'));
    await tester.pumpAndSettle();
    expect(find.textContaining('11. Fraude y seguridad'), findsOneWidget);
    expect(find.textContaining('Todavía no hay revisiones registradas'), findsOneWidget);
  });

  testWidgets('agentes en una grilla compacta a 320 px, sin "Activo" hasta que corren', (tester) async {
    await pumpCenter(tester, const Size(320, 640));
    await tester.ensureVisible(find.text('Agentes IA'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Agentes IA'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final boss = tester.getRect(find.byKey(const Key('agent-card-boss')));
    final bg = tester.getRect(find.byKey(const Key('agent-card-background')));
    expect(boss.width, lessThanOrEqualTo(320 - 2 * HySpacing.md));
    expect(boss.left, greaterThanOrEqualTo(0));
    expect(bg.left, boss.left, reason: 'una columna');
    expect(bg.top, greaterThan(boss.bottom - 1));
    expect(find.text('Activo'), findsNothing);
    expect(find.text('Sin ejecuciones registradas'), findsWidgets);
    expect(find.textContaining('Integraciones de IA en funcionamiento (0)'), findsOneWidget);

    await tester.ensureVisible(find.text('Estado general'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Estado general'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Revisar ahora'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Revisar ahora'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Agentes IA'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Agentes IA'));
    await tester.pumpAndSettle();
    expect(find.text('Activo'), findsWidgets);
    await tester.ensureVisible(find.byKey(const Key('agent-card-recruitment')));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const Key('agent-card-recruitment')),
        matching: find.text('No corre: sin construir'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('en tableta los agentes van en tres columnas', (tester) async {
    await pumpCenter(tester, const Size(1024, 768));
    await tester.ensureVisible(find.text('Agentes IA'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Agentes IA'));
    await tester.pumpAndSettle();
    final a = tester.getRect(find.byKey(const Key('agent-card-boss')));
    final b = tester.getRect(find.byKey(const Key('agent-card-background')));
    final c = tester.getRect(find.byKey(const Key('agent-card-dispatch')));
    expect(a.top, b.top);
    expect(b.top, c.top);
    expect(a.right, lessThan(b.left));
    expect(tester.takeException(), isNull);
  });
}
