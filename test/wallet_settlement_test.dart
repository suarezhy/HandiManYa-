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

// El ejemplo del dueño: saldo Bs 100, precio acordado Bs 120, comisión Bs 12,
// con las reglas finales (0066): se cobra solo en "Ya pagué".
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

String _text(WidgetTester tester, String key) {
  final f = find.byKey(Key(key));
  final w = tester.widget(f);
  if (w is Text) return w.data!;
  return tester.widget<Text>(find.descendant(of: f, matching: find.byType(Text))).data!;
}

void main() {
  test('saldo total: nada reservado desde 0066', () {
    expect(Wallet.fromMap({'available': 88, 'reserved': 0, 'commissions_collected': 12}).total, 88);
    expect(Wallet.fromMap({'available': 100, 'reserved': 0}).total, 100);
  });

  testWidgets('acordado Bs 120, antes de "Ya pagué": total Bs 100, cobrado ${Fmt.bs(0)}', (tester) async {
    await _pump(tester, const Wallet(available: 100, reserved: 0));
    expect(_text(tester, 'wallet-total'), Fmt.bs(100));
    expect(_text(tester, 'wallet-collected'), 'Comisiones cobradas: ${Fmt.bs(0)}');
  });

  testWidgets('después de "Ya pagué": total Bs 88 y Bs 12 cobrados', (tester) async {
    await _pump(tester, const Wallet(available: 88, reserved: 0, commissionsCollected: 12));
    expect(_text(tester, 'wallet-total'), Fmt.bs(88));
    expect(_text(tester, 'wallet-collected'), 'Comisiones cobradas: ${Fmt.bs(12)}');
  });

  testWidgets('muestra solo saldo total, comisiones cobradas, recargar e historial', (tester) async {
    await _pump(tester, const Wallet(available: 88, reserved: 0, commissionPending: 5, extrasAwaitingFunds: 1));
    expect(find.text('Saldo total (Bs)'), findsOneWidget);
    expect(find.byKey(const Key('wallet-collected')), findsOneWidget);
    expect(find.byKey(const Key('wallet-recharge')), findsOneWidget);
    expect(find.text('Historial de movimientos'), findsOneWidget);
    expect(find.byKey(const Key('wallet-reserved')), findsNothing);
    expect(find.byKey(const Key('wallet-awaiting')), findsNothing);
    expect(find.textContaining('eservad'), findsNothing);
    expect(find.textContaining('disponible'), findsNothing);
    expect(find.textContaining('sin cobrar'), findsNothing);
    expect(find.textContaining('pendiente'), findsNothing);
  });

  testWidgets('la tarjeta cabe en un teléfono chico con letra grande', (tester) async {
    await _pump(tester, const Wallet(available: 88, reserved: 0), size: const Size(320, 568), textScale: 1.6);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('wallet-total')), findsOneWidget);
  });

  test('la política dice que la comisión se cobra en "Ya pagué" y nada se reserva', () {
    final body = LegalDoc.commissions.body;
    expect(body, contains('cuando el cliente marca "Ya pagué"'));
    expect(body, contains('Nada se reserva'));
    expect(body, contains('No recibí el pago'));
    expect(body, isNot(contains('se reserva de tu saldo')));
    expect(body, isNot(contains('próxima recarga')));
    expect(AppError.from(Exception('HMY_COMMISSION_DEBT')).message, isNot(contains('Recarga')));
  });
}
