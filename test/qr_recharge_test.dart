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
import 'package:handimanya/features/pro_mode/recharge_page.dart';
import 'package:handimanya/features/pro_mode/wallet_page.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/demo_login.dart';

/// El servidor sin proveedor de QR: como hoy fuera de desarrollo.
class _NoQrBackend extends DemoAppBackend {
  _NoQrBackend() : super(simulateDelays: false, codeCooldown: Duration.zero);

  @override
  Future<QrRecharge> createQrRecharge(double amount) async => throw AppError.from('HMY_QR_UNAVAILABLE');
}

Future<DemoAppBackend> _pump(
  WidgetTester tester,
  Widget page, {
  DemoAppBackend? backend,
  Size size = const Size(390, 844),
  double textScale = 1,
}) async {
  await initializeDateFormatting('es');
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final b = backend ?? DemoAppBackend(simulateDelays: false, codeCooldown: Duration.zero);
  addTearDown(b.dispose);
  await b.signInAs(DemoBackend.professionalPhone);
  tester.view.physicalSize = size * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [prefsProvider.overrideWithValue(prefs), backendProvider.overrideWithValue(b)],
      child: MaterialApp(
        theme: AppTheme.light(),
        locale: const Locale('es', 'BO'),
        supportedLocales: const [Locale('es', 'BO')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        builder: (c, w) => MediaQuery(
          data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(textScale)),
          child: w!,
        ),
        home: page,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return b;
}

void main() {
  test('estados de recarga en español', () {
    expect(QrRechargeStatus.values.map((s) => s.label), [
      'Pendiente de pago',
      'Pago en verificación',
      'Acreditada',
      'Rechazada',
      'Vencida',
      'Revertida',
    ]);
    expect(QrRechargeStatus.parse('credited').isFinal, isTrue);
    expect(QrRechargeStatus.parse('verifying').isFinal, isFalse);
  });

  testWidgets('Mi billetera → Recargar saldo abre "Recargar mi billetera"', (tester) async {
    await _pump(tester, const WalletPage());
    await tester.tap(find.byKey(const Key('wallet-recharge')));
    await tester.pumpAndSettle();
    expect(find.text('Recargar mi billetera'), findsOneWidget);
    for (final k in ['20', '50', '100', 'other']) {
      expect(find.byKey(Key('recharge-preset-$k')), findsOneWidget);
    }
    expect(find.text('Generar QR bancario'), findsOneWidget);
    expect(find.text('Transferencia bancaria'), findsOneWidget);
  });

  testWidgets('QR simulado: dice que no se paga; el saldo sube solo tras el aviso, una vez', (tester) async {
    final b = await _pump(tester, const RechargePage());
    final before = (await b.wallet()).available;
    await tester.tap(find.byKey(const Key('recharge-preset-100')));
    await tester.tap(find.byKey(const Key('recharge-generate-qr')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('qr-simulated')), findsOneWidget);
    expect(find.text('QR SIMULADO'), findsOneWidget);
    expect(find.textContaining('No se puede pagar en ningún banco'), findsOneWidget);
    expect(find.text('Pendiente de pago'), findsOneWidget);
    expect(find.textContaining('Referencia HMY'), findsOneWidget);
    // Generar el QR no acredita nada.
    expect((await b.wallet()).available, before);

    await tester.tap(find.byKey(const Key('qr-simulate')));
    await tester.pumpAndSettle();
    expect(find.text('Acreditada'), findsOneWidget);
    expect(find.byKey(const Key('qr-credited')), findsOneWidget);
    expect(find.textContaining('no dinero real'), findsOneWidget);
    expect((await b.wallet()).available, before + 100);
    final id = (await b.qrRecharges()).first.id;
    expect(await b.simulateQrPayment(id), 'already_credited');
    expect((await b.wallet()).available, before + 100);
    expect((await b.ledger()).where((e) => e.note?.contains('Recarga simulada') ?? false), hasLength(1));
  });

  testWidgets('otro monto: valida el mínimo y el máximo', (tester) async {
    await _pump(tester, const RechargePage());
    await tester.tap(find.byKey(const Key('recharge-preset-other')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('recharge-other-amount')), '5');
    await tester.pump();
    expect(find.text('El mínimo es ${Fmt.bsShort(10)}'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.descendant(of: find.byKey(const Key('recharge-generate-qr')), matching: find.byType(FilledButton)),
          )
          .onPressed,
      isNull,
    );
    await tester.enterText(find.byKey(const Key('recharge-other-amount')), '6000');
    await tester.pump();
    expect(find.text('El máximo es ${Fmt.bsShort(5000)}'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('recharge-other-amount')), '75');
    await tester.pump();
    expect(find.textContaining('El m'), findsNothing);
  });

  testWidgets('sin proveedor de QR avisa y ofrece transferencia', (tester) async {
    await _pump(tester, const RechargePage(), backend: _NoQrBackend());
    await tester.tap(find.byKey(const Key('recharge-generate-qr')));
    await tester.pumpAndSettle();
    expect(find.textContaining('todavía no está disponible'), findsOneWidget);
    await tester.tap(find.byKey(const Key('recharge-transfer')));
    await tester.pumpAndSettle();
    expect(find.textContaining('verifica el pago con el banco'), findsOneWidget);
    expect(find.byKey(const Key('official-accounts-none')), findsOneWidget);
  });

  testWidgets('historial: muestra cada QR con su estado', (tester) async {
    final b = DemoAppBackend(simulateDelays: false, codeCooldown: Duration.zero);
    await b.signInAs(DemoBackend.professionalPhone);
    final r = await b.createQrRecharge(20);
    await b.simulateQrPayment(r.id);
    await b.createQrRecharge(50);
    await _pump(tester, const RechargePage(), backend: b);
    expect(find.text('Acreditada'), findsOneWidget);
    expect(find.text('Pendiente de pago'), findsOneWidget);
  });

  for (final (size, scale) in [(const Size(320, 568), 2.0), (const Size(360, 640), 1.3)]) {
    testWidgets('cabe en ${size.width.toInt()}x${size.height.toInt()} con letra x$scale', (tester) async {
      await _pump(tester, const RechargePage(), size: size, textScale: scale);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.byKey(const Key('recharge-generate-qr')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('recharge-generate-qr')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('qr-simulated')), findsOneWidget);
    });
  }

  testWidgets('Propietario: aprueba un pago en verificación y ve el estado', (tester) async {
    final b = DemoAppBackend(simulateDelays: false, codeCooldown: Duration.zero);
    await b.signInAs(DemoBackend.professionalPhone);
    final r = await b.createQrRecharge(30);
    await b.simulateQrPayment(r.id);
    final report = await b.ownerQrRecharges();
    expect(report.counts[QrRechargeStatus.credited], 1);
    await expectLater(
      b.reviewQrRecharge(r.id, approve: true, note: 'x', authMethod: 'otp'),
      throwsA(isA<AppError>().having((e) => e.code, 'code', 'HMY_ALREADY_REVIEWED')),
    );
    await expectLater(
      b.reverseQrRecharge(r.id, reason: '', authMethod: 'otp'),
      throwsA(isA<AppError>().having((e) => e.code, 'code', 'HMY_REASON_REQUIRED')),
    );
    await b.reverseQrRecharge(r.id, reason: 'El banco anuló el pago', authMethod: 'otp');
    expect((await b.qrRecharge(r.id))!.status, QrRechargeStatus.reversed);
    b.dispose();
  });
}
