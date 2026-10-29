import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/env.dart';
import '../../core/services/push_platform.dart';
import '../../core/utils/app_error.dart';
import '../../data/models/messaging.dart';
import '../../data/providers.dart';
import '../../router.dart';

/// Estado de los avisos push en este teléfono.
enum PushState {
  /// La app se compiló sin Firebase (o es la demostración): solo avisos dentro de la app.
  unavailable,

  /// Este navegador no recibe avisos (en iPhone: falta agregar la app a la pantalla de inicio).
  unsupported,

  /// Se pueden activar.
  off,

  /// La persona los bloqueó en los ajustes del teléfono.
  denied,

  /// Activados y este teléfono registrado en la base.
  on,
}

/// Firebase en la app real con configuración; null en la demostración o sin ella.
final pushPlatformProvider = Provider<PushPlatform?>(
  (ref) => Env.hasBackend && PushConfig.isConfigured ? FirebasePushPlatform() : null,
);

class PushController extends AsyncNotifier<PushState> {
  // La persona apagó los avisos en este teléfono desde la app.
  static const _offKey = 'push_off_on_this_phone';

  StreamSubscription<String>? _refresh;
  StreamSubscription<Map<String, String>>? _opened;
  // Aviso tocado antes de que la sesión y la cuenta estén listas (por ejemplo,
  // con la app cerrada): se abre en cuanto se pueda, no se pierde.
  Map<String, String>? _pendingTap;

  @override
  Future<PushState> build() async {
    final platform = ref.watch(pushPlatformProvider);
    final user = ref.watch(authUserProvider).value;
    if (platform == null) return PushState.unavailable;
    final delegate = ref.read(routerProvider).routerDelegate;
    delegate.addListener(_openPending);
    ref.onDispose(() {
      _refresh?.cancel();
      _opened?.cancel();
      delegate.removeListener(_openPending);
    });
    if (!await platform.isSupported()) return PushState.unsupported;
    _opened = platform.opened.listen(_open);
    final permission = await platform.permission();
    if (permission == PushPermission.denied) return PushState.denied;
    if (permission == PushPermission.notAsked || user == null || _turnedOff) return PushState.off;
    _refresh = platform.tokenRefresh.listen((t) => _register(t).ignore());
    try {
      return await _register(await platform.token().timeout(tokenTimeout)) ? PushState.on : PushState.off;
    } catch (_) {
      // Al abrir la app no se interrumpe a nadie: queda "Activar avisos", y al
      // tocarlo se muestra el motivo.
      return PushState.off;
    }
  }

  bool get _turnedOff => ref.read(prefsProvider).getBool(_offKey) ?? false;

  Future<bool> _register(String? token) async {
    if (token == null || token.isEmpty || _turnedOff || ref.read(authUserProvider).value == null) return false;
    await ref.read(backendProvider).registerPushDevice(token, PushConfig.platform);
    PushTokens.current = token;
    return true;
  }

  /// Pide permiso y registra este teléfono. En la web debe llamarse desde un toque.
  /// Queda en "activados" solo si el servidor guardó el teléfono; si algo falla,
  /// vuelve a "Activar avisos" y lanza un [AppError] con el motivo en español.
  Future<void> enable() async {
    final platform = ref.read(pushPlatformProvider);
    if (platform == null) return;
    final permission = await platform.requestPermission();
    if (permission != PushPermission.granted) {
      state = AsyncData(permission == PushPermission.denied ? PushState.denied : PushState.off);
      return;
    }
    await ref.read(prefsProvider).remove(_offKey);
    state = const AsyncLoading();
    String? token;
    try {
      token = await platform.token().timeout(tokenTimeout);
      if (token == null || token.isEmpty) throw const _NoToken();
    } catch (e) {
      state = const AsyncData(PushState.off);
      throw pushError(e, PushStep.firebase);
    }
    try {
      if (!await _register(token)) throw const _NoToken();
    } catch (e) {
      state = const AsyncData(PushState.off);
      throw pushError(e, PushStep.server);
    }
    _refresh ??= platform.tokenRefresh.listen((t) => _register(t).ignore());
    state = const AsyncData(PushState.on);
    ref.invalidate(pushStatusProvider);
  }

  /// Cuánto se espera a Firebase antes de decir que no respondió.
  static const tokenTimeout = Duration(seconds: 25);

  /// Deja de recibir avisos en este teléfono (los de dentro de la app siguen).
  Future<void> disable() async {
    final backend = ref.read(backendProvider);
    // SharedPreferences guarda la marca en memoria al instante: si algo vuelve
    // a armar el estado mientras tanto, ya no se registra.
    final saved = ref.read(prefsProvider).setBool(_offKey, true);
    _refresh?.cancel().ignore();
    _refresh = null;
    final token = PushTokens.current;
    PushTokens.current = null;
    state = const AsyncData(PushState.off);
    if (token != null) await backend.unregisterPushDevice(token);
    await saved;
  }

  void _open(Map<String, String> data) {
    _pendingTap = data;
    _openPending();
  }

  void _openPending() {
    final data = _pendingTap;
    if (data == null) return;
    final router = ref.read(routerProvider);
    final loc = router.routerDelegate.currentConfiguration.uri.path;
    final ready =
        ref.read(accountProvider).value?.profileComplete == true &&
        loc != Routes.splash &&
        loc != Routes.completeProfile &&
        !Routes.publicRoutes.contains(loc);
    if (!ready) return;
    _pendingTap = null;
    final conversation = data['conversation_id'];
    final booking = data['booking_id'];
    if (conversation != null && conversation.isNotEmpty) {
      router.push(Routes.chat(conversation));
    } else if (booking != null && booking.isNotEmpty) {
      router.push(Routes.booking(booking));
    } else {
      router.push(Routes.notifications);
    }
  }
}

enum PushStep { firebase, server }

class _NoToken implements Exception {
  const _NoToken();
  @override
  String toString() => 'NO_TOKEN';
}

/// Mensaje claro para cuando no se pudo activar los avisos. Lleva un código
/// corto para revisar el problema (nunca el token ni claves).
AppError pushError(Object error, PushStep step) {
  final raw = error.toString();
  final code = error is TimeoutException
      ? 'TIMEOUT'
      : _firebaseCause(raw) ??
            RegExp(
              r'FIS_AUTH_ERROR|SERVICE_NOT_AVAILABLE|AUTHENTICATION_FAILED|MISSING_INSTANCEID_SERVICE|'
              r'TOO_MANY_REGISTRATIONS|PHONE_REGISTRATION_ERROR|INVALID_SENDER|API_KEY|PERMISSION_DENIED|NO_TOKEN|'
              r'HMY_[A-Z_]+|PGRST\d+|\b\d{5}\b',
            ).firstMatch(raw)?.group(0) ??
            (step == PushStep.firebase ? 'FIREBASE' : 'SERVIDOR');
  final String message;
  if (step == PushStep.server) {
    final network = AppError.from(error).code == 'network';
    message = network
        ? 'No hay conexión a internet. Revisa tu conexión y vuelve a intentar.'
        : 'No pudimos guardar este teléfono para los avisos. Vuelve a intentar en un momento.';
  } else {
    message = switch (code) {
      'SERVICE_NOT_AVAILABLE' ||
      'TIMEOUT' => 'Firebase no respondió. Revisa tu conexión a internet y vuelve a intentar.',
      'FIS_AUTH_ERROR' ||
      'API_KEY_INVALID' ||
      'API_KEY_BLOCKED' ||
      'FIS_BAD_CONFIG' ||
      'AUTHENTICATION_FAILED' ||
      'API_KEY' ||
      'INVALID_SENDER' ||
      'PERMISSION_DENIED' => 'Firebase no aceptó la configuración de esta versión de la app. Avísanos para revisarla.',
      'MISSING_INSTANCEID_SERVICE' ||
      'NO_PLAY_SERVICES' => 'Este teléfono no tiene los servicios de Google Play necesarios para los avisos.',
      'FIS_UNAVAILABLE' => 'Firebase no está disponible ahora. Vuelve a intentar en un momento.',
      _ => 'No pudimos activar los avisos en este teléfono. Vuelve a intentar en un momento.',
    };
  }
  return AppError('$message (código: $code)', code: 'push_$code');
}

/// Causa de un error de Firebase en Android, según el mensaje de la excepción
/// nativa (llega como texto). Nunca devuelve el mensaje: solo un código fijo,
/// para no mostrar claves, tokens ni datos de la persona.
String? _firebaseCause(String raw) {
  final m = raw.toLowerCase();
  if (m.contains('api key not valid') || m.contains('api_key_invalid')) return 'API_KEY_INVALID';
  if (m.contains('are blocked') || m.contains('api_key_android_app_blocked') || m.contains('api_key_service_blocked')) {
    return 'API_KEY_BLOCKED';
  }
  if (m.contains('bad request from this client') || m.contains('bad_config') || m.contains('invalid configuration')) {
    return 'FIS_BAD_CONFIG';
  }
  if (m.contains('installations service is unavailable')) return 'FIS_UNAVAILABLE';
  if (m.contains('google play services') || m.contains('service_missing')) return 'NO_PLAY_SERVICES';
  if (m.contains('[core/') || m.contains('no firebase app')) return 'FIREBASE_INIT';
  return null;
}

final pushControllerProvider = AsyncNotifierProvider<PushController, PushState>(PushController.new);

/// Último envío a los teléfonos de la persona, tal como lo anotó el servidor.
final pushStatusProvider = FutureProvider.autoDispose<PushStatus?>((ref) {
  if (ref.watch(authUserProvider).value == null) return null;
  return ref.watch(backendProvider).pushStatus();
});

/// En la web del iPhone los avisos solo existen con la app agregada a la pantalla de inicio.
bool get pushNeedsHomeScreen => kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
