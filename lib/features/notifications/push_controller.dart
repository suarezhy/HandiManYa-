import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/env.dart';
import '../../core/services/push_platform.dart';
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

  @override
  Future<PushState> build() async {
    final platform = ref.watch(pushPlatformProvider);
    final user = ref.watch(authUserProvider).value;
    if (platform == null) return PushState.unavailable;
    ref.onDispose(() {
      _refresh?.cancel();
      _opened?.cancel();
    });
    if (!await platform.isSupported()) return PushState.unsupported;
    _opened = platform.opened.listen(_open);
    final permission = await platform.permission();
    if (permission == PushPermission.denied) return PushState.denied;
    if (permission == PushPermission.notAsked || user == null || _turnedOff) return PushState.off;
    _refresh = platform.tokenRefresh.listen((t) => _register(t).ignore());
    return await _register(await platform.token()) ? PushState.on : PushState.off;
  }

  bool get _turnedOff => ref.read(prefsProvider).getBool(_offKey) ?? false;

  Future<bool> _register(String? token) async {
    if (token == null || token.isEmpty || _turnedOff || ref.read(authUserProvider).value == null) return false;
    await ref.read(backendProvider).registerPushDevice(token, PushConfig.platform);
    PushTokens.current = token;
    return true;
  }

  /// Pide permiso y registra este teléfono. En la web debe llamarse desde un toque.
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
    state = await AsyncValue.guard(() async {
      final ok = await _register(await platform.token());
      _refresh ??= platform.tokenRefresh.listen((t) => _register(t).ignore());
      return ok ? PushState.on : PushState.off;
    });
    ref.invalidate(pushStatusProvider);
  }

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
    final router = ref.read(routerProvider);
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

final pushControllerProvider = AsyncNotifierProvider<PushController, PushState>(PushController.new);

/// Último envío a los teléfonos de la persona, tal como lo anotó el servidor.
final pushStatusProvider = FutureProvider.autoDispose<PushStatus?>((ref) {
  if (ref.watch(authUserProvider).value == null) return null;
  return ref.watch(backendProvider).pushStatus();
});

/// En la web del iPhone los avisos solo existen con la app agregada a la pantalla de inicio.
bool get pushNeedsHomeScreen => kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
