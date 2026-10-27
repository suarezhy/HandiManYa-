import 'package:flutter_test/flutter_test.dart';
import 'package:handimanya/core/services/device_auth.dart';
import 'package:local_auth/local_auth.dart';
import 'package:local_auth_android/local_auth_android.dart';

class _Phone implements LocalAuthentication {
  _Phone(this.types, {this.supported = true, this.error});

  final List<BiometricType> types;
  final bool supported;
  final LocalAuthException? error;
  bool? biometricOnly;

  @override
  Future<bool> isDeviceSupported() async => supported;

  @override
  Future<List<BiometricType>> getAvailableBiometrics() async => types;

  @override
  Future<bool> authenticate({
    required String localizedReason,
    Iterable<AuthMessages> authMessages = const <AuthMessages>[],
    bool biometricOnly = false,
    bool sensitiveTransaction = true,
    bool persistAcrossBackgrounding = false,
  }) async {
    this.biometricOnly = biometricOnly;
    if (error != null) throw error!;
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Qué biometría ofrece la app según lo que dice el teléfono. El sistema
/// verifica; la app solo recibe sí o no.
void main() {
  test('iPhone con Face ID: rostro', () async {
    expect(await LocalDeviceAuth(_Phone([BiometricType.face])).available(), {DeviceBiometric.face});
  });

  test('iPhone con Touch ID: huella', () async {
    expect(await LocalDeviceAuth(_Phone([BiometricType.fingerprint])).available(), {DeviceBiometric.fingerprint});
  });

  test('Android con huella (segura): huella o rostro, lo elige el sistema', () async {
    expect(await LocalDeviceAuth(_Phone([BiometricType.strong])).available(), {DeviceBiometric.any});
  });

  test('solo un rostro "débil" (se engaña con una foto): no se ofrece, se entra con código', () async {
    expect(await LocalDeviceAuth(_Phone([BiometricType.weak])).available(), isEmpty);
  });

  test('sin biometría o sin lector: no se ofrece', () async {
    expect(await LocalDeviceAuth(_Phone([])).available(), isEmpty);
    expect(await LocalDeviceAuth(_Phone([BiometricType.strong], supported: false)).available(), isEmpty);
  });

  test('solo biometría: el PIN o patrón del teléfono no sirven para entrar', () async {
    final phone = _Phone([BiometricType.strong]);
    expect(await LocalDeviceAuth(phone).authenticate('Desbloquea HandiMan ¡Ya!'), DeviceAuthResult.success);
    expect(phone.biometricOnly, isTrue);
  });

  test('cancelar, bloqueo por intentos y sin huella dan resultados distintos', () async {
    Future<DeviceAuthResult> run(LocalAuthExceptionCode code) =>
        LocalDeviceAuth(_Phone([BiometricType.strong], error: LocalAuthException(code: code))).authenticate('x');
    expect(await run(LocalAuthExceptionCode.userCanceled), DeviceAuthResult.canceled);
    expect(await run(LocalAuthExceptionCode.biometricLockout), DeviceAuthResult.lockedOut);
    expect(await run(LocalAuthExceptionCode.noBiometricsEnrolled), DeviceAuthResult.unavailable);
  });
}
