import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';
import 'package:local_auth_android/local_auth_android.dart';
import 'package:local_auth_darwin/local_auth_darwin.dart';

/// Biometría del teléfono (Face ID, reconocimiento facial o huella de Android).
/// La verifica el sistema operativo: la app solo recibe "sí" o "no" y nunca
/// ve ni guarda datos biométricos.
enum DeviceBiometric {
  face('Reconocimiento facial', 'rostro'),
  fingerprint('Huella digital', 'huella'),

  /// Android a veces no dice si es huella o rostro, solo que es segura.
  any('Huella o rostro', 'huella o rostro');

  const DeviceBiometric(this.label, this.short);
  final String label;
  final String short;
}

enum DeviceAuthResult { success, failed, canceled, unavailable, lockedOut }

abstract interface class DeviceAuth {
  /// Las biometrías configuradas en este teléfono (vacío en la web o si no hay).
  Future<Set<DeviceBiometric>> available();

  /// Pide la biometría del teléfono, sin PIN ni patrón como alternativa.
  Future<DeviceAuthResult> authenticate(String reason);
}

class LocalDeviceAuth implements DeviceAuth {
  LocalDeviceAuth([LocalAuthentication? auth]) : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  @override
  Future<Set<DeviceBiometric>> available() async {
    try {
      if (!await _auth.isDeviceSupported()) return const {};
      final types = await _auth.getAvailableBiometrics();
      return {
        if (types.contains(BiometricType.face)) DeviceBiometric.face,
        if (types.contains(BiometricType.fingerprint)) DeviceBiometric.fingerprint,
        if (!types.contains(BiometricType.face) &&
            !types.contains(BiometricType.fingerprint) &&
            types.contains(BiometricType.strong))
          DeviceBiometric.any,
      };
    } catch (_) {
      return const {};
    }
  }

  @override
  Future<DeviceAuthResult> authenticate(String reason) async {
    try {
      final ok = await _auth.authenticate(
        localizedReason: reason,
        authMessages: spanishAuthMessages,
        biometricOnly: true,
      );
      return ok ? DeviceAuthResult.success : DeviceAuthResult.failed;
    } on LocalAuthException catch (e) {
      return switch (e.code) {
        LocalAuthExceptionCode.userCanceled ||
        LocalAuthExceptionCode.systemCanceled ||
        LocalAuthExceptionCode.timeout ||
        LocalAuthExceptionCode.userRequestedFallback => DeviceAuthResult.canceled,
        LocalAuthExceptionCode.temporaryLockout ||
        LocalAuthExceptionCode.biometricLockout => DeviceAuthResult.lockedOut,
        LocalAuthExceptionCode.noBiometricsEnrolled ||
        LocalAuthExceptionCode.noBiometricHardware ||
        LocalAuthExceptionCode.noCredentialsSet ||
        LocalAuthExceptionCode.biometricHardwareTemporarilyUnavailable ||
        LocalAuthExceptionCode.uiUnavailable => DeviceAuthResult.unavailable,
        _ => DeviceAuthResult.failed,
      };
    } catch (_) {
      return DeviceAuthResult.failed;
    }
  }
}

/// Textos del cuadro de huella o rostro que dibuja el sistema. Sin ellos,
/// Android los muestra en inglés ("Authentication required", "Verify
/// identity", "Cancel") aunque el teléfono esté en español.
const spanishAuthMessages = <AuthMessages>[
  AndroidAuthMessages(
    signInTitle: 'Autenticación requerida',
    signInHint: 'Verifica tu identidad',
    cancelButton: 'Cancelar',
  ),
  IOSAuthMessages(cancelButton: 'Cancelar'),
];

/// En la web no hay biometría: solo contraseña.
class NoDeviceAuth implements DeviceAuth {
  const NoDeviceAuth();

  @override
  Future<Set<DeviceBiometric>> available() async => const {};

  @override
  Future<DeviceAuthResult> authenticate(String reason) async => DeviceAuthResult.unavailable;
}

final deviceAuthProvider = Provider<DeviceAuth>((ref) => kIsWeb ? const NoDeviceAuth() : LocalDeviceAuth());

/// Clave única por intento de operación (formato UUID v4), para que el
/// servidor reconozca un mismo intento repetido.
String newOperationKey() {
  final r = Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}
