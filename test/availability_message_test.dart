import 'package:flutter_test/flutter_test.dart';
import 'package:handimanya/features/booking/request_flow_page.dart';

void main() {
  test('sin profesionales en una zona sugiere "Todo el municipio"', () {
    expect(availabilityMessage(0, wholeCity: false), contains('"Todo el municipio"'));
  });

  test('con "Todo el municipio" ya elegido no lo sugiere otra vez', () {
    final text = availabilityMessage(0, wholeCity: true);
    expect(text, isNot(contains('Todo el municipio')));
    expect(text, contains('Programa para después'));
  });

  test('con profesionales dice cuántos recibirán el pedido', () {
    expect(availabilityMessage(1, wholeCity: true), startsWith('1 profesional disponible'));
    expect(availabilityMessage(3, wholeCity: false), startsWith('3 profesionales disponibles'));
  });
}
