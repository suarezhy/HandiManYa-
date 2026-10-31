import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handimanya/app.dart';
import 'package:handimanya/core/services/push_platform.dart';
import 'package:handimanya/data/demo/demo_backend.dart';
import 'package:handimanya/data/models/booking.dart';
import 'package:handimanya/features/booking/booking_detail_page.dart';
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
  int settingsOpened = 0;
  @override
  Future<bool> openSettings() async {
    settingsOpened++;
    return true;
  }
}

/// Firebase que nunca contesta al revisar el permiso (como si se colgara).
class _HangingPush extends _FakePush {
  @override
  Future<PushPermission> permission() => Completer<PushPermission>().future;
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

Future<(_Backend, ProviderContainer)> _pump(
  WidgetTester tester,
  _FakePush push, {
  String phone = DemoBackend.customerPhone,
}) async {
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
  await loginWithPhone(tester, phone);
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

  test('errores nativos de Firebase en Android: un código claro y nunca el mensaje', () {
    String codeOf(String native) => pushError(Exception(native), PushStep.firebase).code!;
    // Así llega el error de una clave de API inválida (lo que pasó en el build 30).
    const invalid =
        '[firebase_messaging/unknown] java.io.IOException: java.util.concurrent.ExecutionException: '
        'com.google.firebase.installations.FirebaseInstallationsException: Firebase servers have received a bad '
        'request from this client. API key not valid. Please pass a valid API key. AIzaSyFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE0';
    expect(codeOf(invalid), 'push_API_KEY_INVALID');
    final message = pushError(Exception(invalid), PushStep.firebase).message;
    expect(message, contains('Firebase no aceptó la configuración'));
    expect(message, isNot(contains('AIza')), reason: 'nunca muestra la clave');
    expect(
      codeOf('[firebase_messaging/unknown] Requests from this Android client application <empty> are blocked.'),
      'push_API_KEY_BLOCKED',
    );
    expect(
      codeOf('FirebaseInstallationsException: Firebase servers have received a bad request from this client.'),
      'push_FIS_BAD_CONFIG',
    );
    expect(
      codeOf('FirebaseInstallationsException: Firebase Installations Service is unavailable. Please try again later.'),
      'push_FIS_UNAVAILABLE',
    );
    expect(codeOf('[core/no-app] No Firebase App \'[DEFAULT]\' has been created'), 'push_FIREBASE_INIT');
    expect(codeOf('java.io.IOException: SERVICE_NOT_AVAILABLE'), 'push_SERVICE_NOT_AVAILABLE');
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

  testWidgets('bloqueados: "Abrir ajustes" lleva a los ajustes y al volver se registra', (tester) async {
    final push = _FakePush()..perm = PushPermission.denied;
    final (backend, c) = await _pump(tester, push);
    await _openNotifications(tester, c);
    await tester.tap(find.byKey(const Key('push-settings')));
    await tester.pumpAndSettle();
    expect(push.settingsOpened, 1);
    expect(backend.registered, isEmpty);

    // La persona activa los avisos en los ajustes y vuelve a la app.
    push.perm = PushPermission.granted;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('Avisos activados en este teléfono'), findsOneWidget);
    expect(backend.registered, ['token-de-prueba-0000000000000/android']);
    PushTokens.current = null;
  });

  testWidgets('si Firebase no contesta al revisar, igual ofrece "Activar avisos"', (tester) async {
    final push = _HangingPush();
    final (_, c) = await _pump(tester, push);
    await _openNotifications(tester, c);
    await tester.pump(PushController.checkTimeout);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('push-enable')), findsOneWidget);
  });

  for (final (role, phone, profile) in [
    ('cliente', DemoBackend.customerPhone, Routes.profile),
    ('profesional', DemoBackend.professionalPhone, Routes.proProfile),
  ]) {
    testWidgets('Perfil del $role: dice cómo están los avisos y lleva a activarlos', (tester) async {
      final push = _FakePush();
      final (backend, c) = await _pump(tester, push, phone: phone);
      c.read(routerProvider).go(profile);
      await tester.pumpAndSettle();
      final row = find.byKey(const Key('profile-notifications'));
      // En el centro de la pantalla: la barra de abajo no la tapa.
      await tester.scrollUntilVisible(row, 200, scrollable: find.byType(Scrollable).first);
      await Scrollable.ensureVisible(tester.element(row), alignment: 0.5);
      await tester.pumpAndSettle();
      expect(find.text('Toca para activar los avisos en este teléfono'), findsOneWidget);
      await tester.tap(row);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('push-enable')));
      await tester.pumpAndSettle();
      expect(backend.registered, ['token-de-prueba-0000000000000/android']);
      c.read(routerProvider).go(profile);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(row, 200, scrollable: find.byType(Scrollable).first);
      expect(find.text('Avisos activados en este teléfono'), findsOneWidget);
      PushTokens.current = null;
    });
  }

  testWidgets('tocar un aviso abre el chat o la solicitud', (tester) async {
    final push = _FakePush()..perm = PushPermission.granted;
    final (_, _) = await _pump(tester, push);
    push.taps.add({'kind': 'message', 'conversation_id': 'conv-1'});
    await tester.pumpAndSettle();
    final chat = tester.widget<ChatPage>(find.byType(ChatPage));
    expect(chat.conversationId, 'conv-1');
    PushTokens.current = null;
  });

  testWidgets('un aviso tocado con la app recién abierta espera a la sesión y abre la solicitud', (tester) async {
    // Con la app cerrada, el toque llega antes de que la sesión y la cuenta
    // estén listas: antes se perdía y la app abría Inicio.
    final push = _FakePush()..perm = PushPermission.granted;
    final (backend, _) = await _pump(tester, push);
    final id = await backend.create(
      const BookingDraft(
        categoryId: 1,
        cityId: 1,
        mode: BookingMode.now,
        description: 'Gotea el caño de la cocina',
        address: 'Calle Los Pinos 123',
      ),
    );
    await backend.signOut();
    await tester.pumpAndSettle();
    push.taps.add({'kind': 'booking_status', 'booking_id': id});
    await tester.pumpAndSettle();
    expect(find.byType(BookingDetailPage), findsNothing);
    await backend.signInAs(DemoBackend.customerPhone);
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.widget<BookingDetailPage>(find.byType(BookingDetailPage)).id, id);
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
