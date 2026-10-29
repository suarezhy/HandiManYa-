import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handimanya/core/theme/app_theme.dart';
import 'package:handimanya/data/demo/demo_backend.dart';
import 'package:handimanya/data/providers.dart';
import 'package:handimanya/features/auth/auth_scaffold.dart';
import 'package:handimanya/features/security/confirm_identity.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/demo_login.dart';

/// Barras de abajo: tres botones de Android, gestos de Android e indicador
/// del iPhone (en píxeles lógicos).
const _bars = {'tres botones': 48.0, 'gestos': 24.0, 'iPhone': 34.0};

const _sizes = {'Android chico': Size(320, 640), 'teléfono': Size(390, 844), 'tablet': Size(800, 1280)};

Future<void> _openSheet(
  WidgetTester tester, {
  required Size size,
  required double bar,
  double keyboard = 0,
  double textScale = 1,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final backend = DemoAppBackend(simulateDelays: false, codeCooldown: Duration.zero);
  addTearDown(backend.dispose);
  // La cuenta 03 de prueba tiene este formato: +591 7000 0003.
  await backend.signInAs(DemoBackend.adminPhone);
  const dpr = 3.0;
  tester.view.devicePixelRatio = dpr;
  tester.view.physicalSize = size * dpr;
  tester.view.viewPadding = FakeViewPadding(top: 24 * dpr, bottom: bar * dpr);
  tester.view.padding = FakeViewPadding(top: 24 * dpr, bottom: keyboard > 0 ? 0 : bar * dpr);
  tester.view.viewInsets = FakeViewPadding(bottom: keyboard * dpr);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [prefsProvider.overrideWithValue(prefs), backendProvider.overrideWithValue(backend)],
      child: MaterialApp(
        theme: AppTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => confirmIdentity(context, operation: 'Recargar saldo', amount: 50, codeOnly: true),
                child: const Text('abrir'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('abrir'));
  await tester.pumpAndSettle();
}

void main() {
  group('Confirma que eres tú: "Cancelar" sobre la barra de navegación', () {
    for (final size in _sizes.entries) {
      for (final bar in _bars.entries) {
        for (final scale in [1.0, 1.3]) {
          testWidgets('${size.key}, ${bar.key}, letra x$scale', (tester) async {
            await _openSheet(tester, size: size.value, bar: bar.value, textScale: scale);
            final cancel = find.byKey(const Key('confirm-cancel'));
            await tester.ensureVisible(cancel);
            await tester.pumpAndSettle();
            final limit = size.value.height - bar.value;
            final rect = tester.getRect(cancel);
            expect(rect.bottom, lessThanOrEqualTo(limit), reason: '"Cancelar" no queda debajo de la barra');
            expect(rect.height, greaterThanOrEqualTo(48), reason: 'se puede tocar');
            expect(
              tester.getRect(find.byKey(const Key('confirm-submit'))).bottom,
              lessThanOrEqualTo(limit),
              reason: '"Enviarme el código" también se ve',
            );
            await tester.tap(cancel);
            await tester.pumpAndSettle();
            expect(find.byType(ConfirmIdentitySheet), findsNothing, reason: 'Cancelar cierra sin confirmar');
            expect(tester.takeException(), isNull);
          });
        }
      }
    }

    testWidgets('con el teclado abierto, "Cancelar" queda arriba del teclado', (tester) async {
      await _openSheet(tester, size: const Size(360, 740), bar: 48, keyboard: 300);
      final cancel = find.byKey(const Key('confirm-cancel'));
      await tester.ensureVisible(cancel);
      await tester.pumpAndSettle();
      expect(tester.getRect(cancel).bottom, lessThanOrEqualTo(740 - 300));
      expect(tester.takeException(), isNull);
    });
  });

  group('Código por celular: el número en una sola línea', () {
    for (final size in _sizes.entries) {
      for (final scale in [1.0, 1.3, 2.0]) {
        testWidgets('${size.key}, letra x$scale', (tester) async {
          await _openSheet(tester, size: size.value, bar: 48, textScale: scale);
          final tile = find.byKey(const Key('confirm-code'));
          expect(find.descendant(of: tile, matching: find.text('Código por celular')), findsOneWidget);
          final phone = find.byKey(const Key('confirm-code-phone'));
          expect(tester.widget<Text>(phone).data, formatPhone(DemoBackend.adminPhone));
          expect(tester.widget<Text>(phone).data, '+591 7000 0000');
          final paragraph = tester.renderObject<RenderParagraph>(phone);
          final length = paragraph.text.toPlainText().length;
          final boxes = paragraph.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: length));
          expect(boxes.map((b) => b.top).toSet(), hasLength(1), reason: 'todo el número en una línea');
          final tileRect = tester.getRect(find.descendant(of: tile, matching: find.byType(InkWell)));
          final phoneRect = tester.getRect(phone);
          expect(phoneRect.right, lessThanOrEqualTo(tileRect.right), reason: 'el número no se sale de la tarjeta');
          final radio = find.descendant(of: tile, matching: find.byIcon(Icons.radio_button_checked));
          expect(
            (tester.getCenter(radio).dy - tileRect.center.dy).abs(),
            lessThan(4),
            reason: 'el círculo queda centrado con el texto',
          );
          expect(tester.getRect(radio).left, greaterThan(phoneRect.right - 1), reason: 'el número no tapa el círculo');
          // WhatsApp o SMS sigue disponible.
          expect(find.byKey(const Key('channel-whatsapp')), findsOneWidget);
          expect(find.byKey(const Key('channel-sms')), findsOneWidget);
          expect(tester.takeException(), isNull);
        });
      }
    }
  });

  test('el número se arma con espacios que no se cortan', () {
    expect(formatPhone('+59170000003'), '+591 7000 0003');
  });
}
