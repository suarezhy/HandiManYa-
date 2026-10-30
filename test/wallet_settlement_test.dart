import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handimanya/core/theme/app_theme.dart';
import 'package:handimanya/core/utils/app_error.dart';
import 'package:handimanya/core/utils/formatters.dart';
import 'package:handimanya/data/demo/demo_backend.dart';
import 'package:handimanya/data/models/wallet.dart';
import 'package:handimanya/data/providers.dart';
import 'package:handimanya/features/legal/legal_texts.dart';
import 'package:handimanya/features/pro_mode/wallet_page.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/demo_login.dart';

// El ejemplo del dueño: saldo Bs 100, precio acordado Bs 120, comisión Bs 12.
Future<void> _pump(WidgetTester tester, Wallet wallet, {Size size = const Size(390, 844), double textScale = 1}) async {
  await initializeDateFormatting('es');
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final backend = DemoAppBackend(simulateDelays: false, codeCooldown: Duration.zero);
  addTearDown(backend.dispose);
  await backend.signInAs(DemoBackend.professionalPhone);
  tester.view.physicalSize = size * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        backendProvider.overrideWithValue(backend),
        walletProvider.overrideWith((ref) async => wallet),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        locale: const Locale('es', 'BO'),
        supportedLocales: const [Locale('es', 'BO')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        builder: (c, w) => MediaQuery(
          data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(textScale)),
          child: w!,
        ),
        home: const WalletPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

String _text(WidgetTester tester, String key) =>
    tester.widget<Text>(find.descendant(of: find.byKey(Key(key)), matching: find.byType(Text))).data!;

void main() {
  test('saldo total = disponible + reservado', () {
    const w = Wallet(available: 88, reserved: 12);
    expect(w.total, 100);
    expect(Wallet.fromMap({'available': 88, 'reserved': 0, 'commissions_collected': 12}).total, 88);
  });

  testWidgets('acordado, antes de confirmar: total Bs 100, reservado Bs 12, cobrado ${Fmt.bs(0)}', (tester) async {
    await _pump(tester, const Wallet(available: 88, reserved: 12));
    expect(find.text(Fmt.bs(88)), findsOneWidget);
    expect(_text(tester, 'wallet-total'), 'Saldo total: ${Fmt.bs(100)}');
    expect(_text(tester, 'wallet-reserved'), 'Saldo reservado: ${Fmt.bs(12)}');
    expect(_text(tester, 'wallet-collected'), 'Comisiones cobradas: ${Fmt.bs(0)}');
  });

  testWidgets('después de que el cliente confirma: total Bs 88 y Bs 12 cobrados', (tester) async {
    await _pump(tester, const Wallet(available: 88, reserved: 0, commissionsCollected: 12));
    expect(_text(tester, 'wallet-total'), 'Saldo total: ${Fmt.bs(88)}');
    expect(_text(tester, 'wallet-reserved'), 'Saldo reservado: ${Fmt.bs(0)}');
    expect(_text(tester, 'wallet-collected'), 'Comisiones cobradas: ${Fmt.bs(12)}');
  });

  testWidgets('explica el cobro al confirmar, sin deudas ni descuentos de recargas', (tester) async {
    await _pump(tester, const Wallet(available: 88, reserved: 12));
    expect(find.textContaining('cuando el cliente confirma que el trabajo terminó'), findsOneWidget);
    expect(find.textContaining('nunca queda negativo'), findsOneWidget);
    expect(find.textContaining('próxima recarga'), findsNothing);
    expect(find.textContaining('pendiente y se descuenta'), findsNothing);
  });

  testWidgets('la tarjeta cabe en un teléfono chico con letra grande', (tester) async {
    await _pump(tester, const Wallet(available: 88, reserved: 12), size: const Size(320, 568), textScale: 1.6);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('wallet-total')), findsOneWidget);
  });

  test('los textos legales y de error ya no prometen cobrar de la próxima recarga', () {
    expect(LegalDoc.commissions.body, isNot(contains('próxima recarga')));
    expect(LegalDoc.commissions.body, contains('cuando el cliente confirma que el trabajo terminó'));
    expect(AppError.from(Exception('HMY_COMMISSION_DEBT')).message, isNot(contains('Recarga')));
  });
}
