import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handimanya/core/theme/app_theme.dart';
import 'package:handimanya/features/booking/request_flow_page.dart';
import 'package:intl/date_symbol_data_local.dart';

/// Programar: la hora se escribe con el teclado numérico (24 h) desde el
/// principio; el mismo diálogo de Android tiene el ícono del reloj circular.
void main() {
  testWidgets('la hora se abre para escribirla, en 24 horas, y se guarda tal cual', (tester) async {
    await initializeDateFormatting('es');
    TimeOfDay? chosen;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        locale: const Locale('es', 'BO'),
        supportedLocales: const [Locale('es', 'BO')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => ScheduleFields(
              date: DateTime(2026, 11, 2),
              time: chosen,
              duration: 120,
              onDate: (_) {},
              onTime: (t) => setState(() => chosen = t),
              onDuration: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Elegir hora'));
    await tester.pumpAndSettle();

    // Modo para escribir: dos campos numéricos, el de la hora con el cursor.
    final fields = find.descendant(of: find.byType(Dialog), matching: find.byType(TextField));
    expect(fields, findsNWidgets(2));
    final hour = tester.widget<TextField>(fields.first);
    expect(hour.keyboardType, TextInputType.number);
    expect(tester.testTextInput.isVisible, isTrue, reason: 'el teclado se abre solo');
    // 24 horas: sin a. m. / p. m.
    expect(find.textContaining('a. m.'), findsNothing);
    expect(find.textContaining('p. m.'), findsNothing);
    // El ícono para pasar al reloj circular sigue ahí.
    expect(find.byIcon(Icons.access_time), findsOneWidget);

    await tester.enterText(fields.first, '14');
    await tester.enterText(fields.last, '30');
    await tester.tap(find.text('ACEPTAR'));
    await tester.pumpAndSettle();
    expect(chosen, const TimeOfDay(hour: 14, minute: 30));
    expect(find.text('14:30'), findsOneWidget);
  });
}
