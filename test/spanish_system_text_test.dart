import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:handimanya/core/services/device_auth.dart';
import 'package:local_auth/local_auth.dart';
import 'package:local_auth_android/local_auth_android.dart';
import 'package:local_auth_darwin/local_auth_darwin.dart';

class _RecordingAuth implements LocalAuthentication {
  Iterable<AuthMessages>? messages;

  @override
  Future<bool> authenticate({
    required String localizedReason,
    Iterable<AuthMessages> authMessages = const <AuthMessages>[],
    bool biometricOnly = false,
    bool sensitiveTransaction = true,
    bool persistAcrossBackgrounding = false,
  }) async {
    messages = authMessages;
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Textos que dibuja el sistema y que la app sí puede poner en español.
void main() {
  test('el cuadro de la huella va en español (no "Authentication required")', () async {
    final auth = _RecordingAuth();
    expect(await LocalDeviceAuth(auth).authenticate('Desbloquea HandiMan ¡Ya!'), DeviceAuthResult.success);
    final android = auth.messages!.whereType<AndroidAuthMessages>().single.args;
    expect(android['signInTitle'], 'Autenticación requerida');
    expect(android['biometricHint'], 'Verifica tu identidad'); // el subtítulo (signInHint)
    expect(android['cancelButton'], 'Cancelar');
    expect(auth.messages!.whereType<IOSAuthMessages>().single.args['okButton'], 'Cancelar');
  });

  test('Android: el canal de avisos no se llama "Miscellaneous"', () {
    final xml = File('android/app/src/main/res/values/strings.xml').readAsStringSync();
    expect(xml, contains('<string name="fcm_fallback_notification_channel_label">Avisos de HandiMan ¡Ya!</string>'));
  });

  test('iPhone: la app se declara en español para los cuadros del sistema', () {
    final plist = File('ios/Runner/Info.plist').readAsStringSync();
    expect(plist, contains('<key>CFBundleLocalizations</key>\n\t<array>\n\t\t<string>es</string>'));
  });
}
