import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

export 'push_tokens.dart';

/// Configuración de Firebase (solo mensajería) que llega al compilar con
/// `--dart-define-from-file=config/firebase-<entorno>.json`. Son
/// identificadores públicos del proyecto de Firebase, no secretos. Sin ellos
/// la app no ofrece avisos push y sigue avisando solo dentro de la app.
abstract final class PushConfig {
  static const apiKey = String.fromEnvironment('FIREBASE_API_KEY');
  static const projectId = String.fromEnvironment('FIREBASE_PROJECT_ID');
  static const senderId = String.fromEnvironment('FIREBASE_SENDER_ID');
  static const appIdAndroid = String.fromEnvironment('FIREBASE_APP_ID_ANDROID');
  static const appIdIos = String.fromEnvironment('FIREBASE_APP_ID_IOS');
  static const appIdWeb = String.fromEnvironment('FIREBASE_APP_ID_WEB');

  /// Clave pública VAPID (Firebase → Cloud Messaging → Web Push certificates).
  static const vapidKey = String.fromEnvironment('FIREBASE_VAPID_KEY');

  static String get appId => kIsWeb
      ? appIdWeb
      : defaultTargetPlatform == TargetPlatform.iOS
      ? appIdIos
      : appIdAndroid;

  static bool get isConfigured =>
      apiKey.isNotEmpty &&
      projectId.isNotEmpty &&
      senderId.isNotEmpty &&
      appId.isNotEmpty &&
      (!kIsWeb || vapidKey.isNotEmpty);

  /// 'android', 'ios' o 'web', como lo guarda la base.
  static String get platform => kIsWeb
      ? 'web'
      : defaultTargetPlatform == TargetPlatform.iOS
      ? 'ios'
      : 'android';
}

enum PushPermission { notAsked, denied, granted }

/// Lo que la app necesita de Firebase Cloud Messaging. En las pruebas se
/// reemplaza por uno falso.
abstract interface class PushPlatform {
  /// Falso en navegadores sin avisos (por ejemplo Safari del iPhone fuera de
  /// la app agregada a la pantalla de inicio).
  Future<bool> isSupported();
  Future<PushPermission> permission();

  /// Pide permiso al teléfono. En la web tiene que llamarse desde un toque.
  Future<PushPermission> requestPermission();
  Future<String?> token();
  Stream<String> get tokenRefresh;

  /// Datos de un aviso que la persona tocó (incluido el que abrió la app).
  Stream<Map<String, String>> get opened;

  /// Abre los ajustes de avisos de esta app en el teléfono (para activarlos
  /// cuando el teléfono ya no muestra la pregunta). Falso si no se pudo.
  Future<bool> openSettings();
}

class FirebasePushPlatform implements PushPlatform {
  Future<FirebaseMessaging>? _ready;
  final _opened = StreamController<Map<String, String>>.broadcast();
  Map<String, String>? _initial;

  Future<FirebaseMessaging> _messaging() => _ready ??= () async {
    await Firebase.initializeApp(
      options: FirebaseOptions(
        apiKey: PushConfig.apiKey,
        appId: PushConfig.appId,
        messagingSenderId: PushConfig.senderId,
        projectId: PushConfig.projectId,
      ),
    );
    final m = FirebaseMessaging.instance;
    FirebaseMessaging.onMessageOpenedApp.listen((msg) => _opened.add(_data(msg)));
    final initial = await m.getInitialMessage();
    if (initial != null) _initial = _data(initial);
    return m;
  }();

  static Map<String, String> _data(RemoteMessage msg) => {for (final e in msg.data.entries) e.key: '${e.value}'};

  static PushPermission _map(AuthorizationStatus s) => switch (s) {
    AuthorizationStatus.authorized || AuthorizationStatus.provisional => PushPermission.granted,
    AuthorizationStatus.denied || AuthorizationStatus.deniedPermanently => PushPermission.denied,
    AuthorizationStatus.notDetermined => PushPermission.notAsked,
  };

  @override
  Future<bool> isSupported() async {
    try {
      final m = await _messaging();
      return await m.isSupported();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<PushPermission> permission() async =>
      _map((await (await _messaging()).getNotificationSettings()).authorizationStatus);

  @override
  Future<PushPermission> requestPermission() async =>
      _map((await (await _messaging()).requestPermission()).authorizationStatus);

  @override
  Future<String?> token() async {
    final m = await _messaging();
    // Mientras exista la API de token (FCM HTTP v1 la usa para enviar).
    // ignore: deprecated_member_use
    return m.getToken(
      vapidKey: kIsWeb ? PushConfig.vapidKey : null,
      // En la web, el service worker vive junto a la app (no en la raíz del
      // dominio) y recibe la configuración pública en la dirección.
      serviceWorkerScriptPath: kIsWeb ? webWorkerPath : null,
    );
  }

  @override
  Stream<String> get tokenRefresh async* {
    final m = await _messaging();
    // ignore: deprecated_member_use
    yield* m.onTokenRefresh;
  }

  @override
  Stream<Map<String, String>> get opened async* {
    await _messaging();
    final initial = _initial;
    _initial = null;
    if (initial != null) yield initial;
    yield* _opened.stream;
  }

  static const _settings = MethodChannel('bo.handimanya/notifications');

  @override
  Future<bool> openSettings() async {
    if (kIsWeb) return false;
    if (defaultTargetPlatform == TargetPlatform.iOS) return launchUrl(Uri.parse('app-settings:'));
    return await _settings.invokeMethod<bool>('openSettings') ?? false;
  }

  static String get webWorkerPath => Uri(
    path: 'firebase-messaging-sw.js',
    queryParameters: {
      'apiKey': PushConfig.apiKey,
      'projectId': PushConfig.projectId,
      'messagingSenderId': PushConfig.senderId,
      'appId': PushConfig.appIdWeb,
    },
  ).toString();
}
