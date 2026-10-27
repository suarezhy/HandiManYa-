import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handimanya/app.dart';
import 'package:handimanya/core/services/push_platform.dart';
import 'package:handimanya/data/demo/demo_backend.dart';
import 'package:handimanya/data/providers.dart';
import 'package:handimanya/features/messages/chat_page.dart';
import 'package:handimanya/features/notifications/push_controller.dart';
import 'package:handimanya/router.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/demo_login.dart';

/// Avisos push (0045): la app pide permiso solo con un toque, registra el
/// teléfono, lo suelta al cerrar sesión y abre lo que se toca. Firebase es falso.

class _FakePush implements PushPlatform {
  PushPermission perm = PushPermission.notAsked;
  bool supported = true;
  final refresh = StreamController<String>.broadcast();
  final taps = StreamController<Map<String, String>>.broadcast();

  @override
  Future<bool> isSupported() async => supported;
  @override
  Future<PushPermission> permission() async => perm;
  @override
  Future<PushPermission> requestPermission() async => perm = PushPermission.granted;
  Object? tokenError;
  @override
  Future<String?> token() async {
    if (tokenError != null) throw tokenError!;
    return 'token-de-prueba-0000000000000';
  }

  @override
  Stream<String> get tokenRefresh => refresh.stream;
  @override
  Stream<Map<String, String>> get opened => taps.stream;
}

class _NoTokenPush extends _FakePush {
  @override
  Future<String?> token() async => null;
}

class _Backend extends DemoAppBackend {
  _Backend() : super(simulateDelays: false, codeCooldown: Duration.zero);
  final registered = <String>[];
  final unregistered = <String>[];
  Object? registerError;

  @override
  Future<void> registerPushDevice(String token, String platform) async {
    if (registerError != null) throw registerError!;
    registered.add('$token/$platform');
  }

  @override
  Future<void> unregisterPushDevice(String token) async => unregistered.add(token);
}

Future<(_Backend, ProviderContainer)> _pump(WidgetTester tester, _FakePush push) async {
  await initializeDateFormatting('es');
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final backend = _Backend();
  addTearDown(backend.dispose);
  tester.view.physicalSize = const Size(390, 844) * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      prefsProvider.overrideWithValue(prefs),
      backendProvider.overrideWithValue(backend),
      pushPlatformProvider.overrideWithValue(push),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const HandiManYaApp()));
  await tester.pumpAndSettle();
  await loginWithPhone(tester, DemoBackend.customerPhone);
  return (backend, container);
}

Future<void> _openNotifications(WidgetTester tester, ProviderContainer c) async {
  c.read(routerProvider).push(Routes.notifications);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('no pide permiso solo: se activa con un toque y registra el teléfono', (tester) async {
    final push = _FakePush();
    final (backend, c) = await _pump(tester, push);
    expect(backend.registered, isEmpty, reason: 'sin permiso no se registra nada');
    await _openNotifications(tester, c);
    expect(find.text('Recibe avisos en este teléfono'), findsOneWidget);
    await tester.tap(find.byKey(const Key('push-enable')));
    await tester.pumpAndSettle();
    expect(backend.registered, ['token-de-prueba-0000000000000/android']);
    expect(find.text('Avisos activados en este teléfono'), findsOneWidget);
    expect(find.byKey(const Key('push-test')), findsOneWidget);
    expect(PushTokens.current, 'token-de-prueba-0000000000000');

    // Un token nuevo de Firebase se registra solo.
    push.refresh.add('token-nuevo-000000000000000000');
    await tester.pumpAndSettle();
    expect(backend.registered.last, 'token-nuevo-000000000000000000/android');

    // Desactivar suelta el teléfono y no vuelve a registrarse solo.
    await tester.tap(find.byKey(const Key('push-disable')));
    for (var i = 0; i < 20 && backend.unregistered.isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();
    expect(backend.unregistered, isNotEmpty);
    expect(find.byKey(const Key('push-enable')), findsOneWidget);
    PushTokens.current = null;
  });

  testWidgets('dice "Avisos activados" solo cuando el servidor guardó el teléfono', (tester) async {
    final push = _FakePush();
    final (_, c) = await _pump(tester, push);
    await _openNotifications(tester, c);
    await tester.tap(find.byKey(const Key('push-enable')));
    await tester.pumpAndSettle();
    expect(find.text('Avisos activados'), findsOneWidget);
    PushTokens.current = null;
  });

  testWidgets('si Firebase no da el registro, lo explica en español y no dice activados', (tester) async {
    final push = _FakePush()
      ..tokenError = Exception('[firebase_messaging/unknown] java.io.IOException: FIS_AUTH_ERROR');
    final (backend, c) = await _pump(tester, push);
    await _openNotifications(tester, c);
    await tester.tap(find.byKey(const Key('push-enable')));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Firebase no aceptó la configuración de esta versión de la app. Avísanos para revisarla. '
        '(código: FIS_AUTH_ERROR)',
      ),
      findsOneWidget,
    );
    expect(find.text('Avisos activados'), findsNothing);
    expect(find.byKey(const Key('push-enable')), findsOneWidget, reason: 'se puede volver a intentar');
    expect(backend.registered, isEmpty);
    expect(PushTokens.current, isNull);
  });

  testWidgets('sin token de Firebase tampoco dice activados', (tester) async {
    final push = _NoTokenPush();
    final (backend, c) = await _pump(tester, push);
    await _openNotifications(tester, c);
    await tester.tap(find.byKey(const Key('push-enable')));
    await tester.pumpAndSettle();
    expect(find.textContaining('(código: NO_TOKEN)'), findsOneWidget);
    expect(find.byKey(const Key('push-enable')), findsOneWidget);
    expect(backend.registered, isEmpty);
  });

  testWidgets('si el servidor no guarda el teléfono, lo explica y se puede reintentar', (tester) async {
    final push = _FakePush();
    final (backend, c) = await _pump(tester, push);
    backend.registerError = Exception('PostgrestException(message: permission denied, code: 42501)');
    await _openNotifications(tester, c);
    await tester.tap(find.byKey(const Key('push-enable')));
    await tester.pumpAndSettle();
    expect(
      find.text('No pudimos guardar este teléfono para los avisos. Vuelve a intentar en un momento. (código: 42501)'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('push-enable')), findsOneWidget);

    backend.registerError = null;
    await tester.tap(find.byKey(const Key('push-enable')));
    await tester.pumpAndSettle();
    expect(backend.registered, ['token-de-prueba-0000000000000/android']);
    expect(find.text('Avisos activados en este teléfono'), findsOneWidget);
    PushTokens.current = null;
  });

  testWidgets('Firebase que no responde: aviso claro, sin quedarse cargando', (tester) async {
    expect(
      pushError(TimeoutException('x'), PushStep.firebase).message,
      'Firebase no respondió. Revisa tu conexión a internet y vuelve a intentar. (código: TIMEOUT)',
    );
    expect(
      pushError(Exception('SocketException: Failed host lookup'), PushStep.server).message,
      startsWith('No hay conexión a internet.'),
    );
  });

  testWidgets('con permiso ya dado, se registra al iniciar sesión', (tester) async {
    final push = _FakePush()..perm = PushPermission.granted;
    final (backend, _) = await _pump(tester, push);
    expect(backend.registered, ['token-de-prueba-0000000000000/android']);
    PushTokens.current = null;
  });

  testWidgets('bloqueados o sin soporte: lo dice sin prometer avisos', (tester) async {
    final push = _FakePush()..perm = PushPermission.denied;
    final (backend, c) = await _pump(tester, push);
    await _openNotifications(tester, c);
    expect(find.text('Avisos bloqueados'), findsOneWidget);
    expect(find.byKey(const Key('push-enable')), findsNothing);
    expect(backend.registered, isEmpty);

    push.supported = false;
    c.invalidate(pushControllerProvider);
    await tester.pumpAndSettle();
    expect(find.text('Avisos en este navegador'), findsOneWidget);
  });

  testWidgets('tocar un aviso abre el chat o la solicitud', (tester) async {
    final push = _FakePush()..perm = PushPermission.granted;
    final (_, _) = await _pump(tester, push);
    push.taps.add({'kind': 'message', 'conversation_id': 'conv-1'});
    await tester.pumpAndSettle();
    final chat = tester.widget<ChatPage>(find.byType(ChatPage));
    expect(chat.conversationId, 'conv-1');
    PushTokens.current = null;
  });

  testWidgets('sin Firebase configurado (como hoy en la demostración) no muestra nada de push', (tester) async {
    await initializeDateFormatting('es');
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final backend = DemoAppBackend(simulateDelays: false, codeCooldown: Duration.zero);
    addTearDown(backend.dispose);
    final container = ProviderContainer(
      overrides: [prefsProvider.overrideWithValue(prefs), backendProvider.overrideWithValue(backend)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const HandiManYaApp()));
    await tester.pumpAndSettle();
    await loginWithPhone(tester, DemoBackend.customerPhone);
    await _openNotifications(tester, container);
    expect(container.read(pushControllerProvider).value, PushState.unavailable);
    expect(find.byKey(const Key('push-enable')), findsNothing);
  });
}
