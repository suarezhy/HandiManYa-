import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Lo que los avisos push necesitan en Android e iPhone antes de que el dueño
/// configure Firebase. Así, cuando lleguen sus valores, lo único que falta es
/// el archivo config/firebase-dev.json.
void main() {
  test('iPhone: permiso de avisos (aps-environment) en las tres compilaciones', () {
    expect(File('ios/Runner/Runner.entitlements').readAsStringSync(), contains('<key>aps-environment</key>'));
    final project = File('ios/Runner.xcodeproj/project.pbxproj').readAsStringSync();
    expect('CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements;'.allMatches(project).length, 3);
    expect(File('ios/Runner/Info.plist').readAsStringSync(), contains('<string>remote-notification</string>'));
  });

  test('Android: ícono y color de los avisos', () {
    final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    expect(manifest, contains('com.google.firebase.messaging.default_notification_icon'));
    expect(manifest, contains('com.google.firebase.messaging.default_notification_color'));
  });

  test('config de Firebase: si existe, tiene solo valores públicos con el formato correcto', () {
    for (final env in ['dev', 'prod']) {
      final f = File('config/firebase-$env.json');
      if (!f.existsSync()) continue;
      final text = f.readAsStringSync();
      expect(text, isNot(contains('private_key')), reason: 'la cuenta de servicio nunca va en el repositorio');
      final cfg = Map<String, String>.from(jsonDecode(text) as Map);
      expect(cfg['FIREBASE_API_KEY'], matches(RegExp(r'^AIza[0-9A-Za-z_-]{35}$')));
      final sender = cfg['FIREBASE_SENDER_ID']!;
      for (final kind in ['android', 'ios', 'web']) {
        expect(cfg['FIREBASE_APP_ID_${kind.toUpperCase()}'], matches(RegExp('^1:$sender:$kind:[0-9a-f]+\$')));
      }
      expect(cfg['FIREBASE_VAPID_KEY'], matches(RegExp(r'^[A-Za-z0-9_-]{80,100}$')));
    }
  });
}
