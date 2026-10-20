import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handimanya/data/demo/demo_backend.dart';
import 'package:handimanya/data/models/user.dart';

/// Entrar como en la app: celular, código de demostración.
extension DemoLogin on DemoBackend {
  Future<void> signInAs(String phone, {CodeChannel channel = CodeChannel.whatsapp}) async {
    await sendPhoneCode(phone: phone, channel: channel);
    await verifyPhoneCode(phone: phone, code: DemoBackend.demoCode);
  }

  /// Código recién verificado: confirma una operación de dinero ('otp').
  Future<void> confirmWithCode() => signInAs(currentUser!.phone!);
}

/// La pantalla única de acceso: celular, WhatsApp o SMS, código y "Continuar".
Future<void> loginWithPhone(WidgetTester tester, String phone, {CodeChannel channel = CodeChannel.whatsapp}) async {
  final skip = find.text('Omitir');
  if (skip.evaluate().isNotEmpty) {
    await tester.tap(skip);
    await tester.pumpAndSettle();
  }
  expect(find.text('Bienvenido a HandiMan ¡Ya!'), findsOneWidget);
  await tester.enterText(find.byKey(const Key('phone-field')), phone.replaceFirst('+591', ''));
  await tester.tap(find.byKey(Key('channel-${channel.key}')));
  await tester.pumpAndSettle();
  await _tapKey(tester, 'auth-continue');
  await tester.enterText(find.byKey(const Key('code-field')), DemoBackend.demoCode);
  await tester.pumpAndSettle();
}

Future<void> _tapKey(WidgetTester tester, String key) async {
  final f = find.byKey(Key(key));
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}
