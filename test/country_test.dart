import 'package:flutter_test/flutter_test.dart';
import 'package:handimanya/core/config/country.dart';
import 'package:handimanya/core/utils/formatters.dart';
import 'package:handimanya/core/utils/validators.dart';
import 'package:handimanya/features/auth/auth_scaffold.dart';

void main() {
  test('la app compila para Bolivia: celular, moneda y hora como siempre', () {
    expect(kCountry.code, 'BO');
    expect(Validators.normalizePhone('7123 4567'), '+59171234567');
    expect(Validators.normalizePhone('+591 6-123-4567'), '+59161234567');
    expect(Validators.normalizePhone('81234567'), isNull);
    expect(Validators.phone('123'), 'Debe ser un celular de 8 dígitos, por ejemplo 71234567');
    expect(formatPhone('+59171234567'), '+591 7123 4567');
    expect(maskPhone('+59170000005'), '+591 7••• ••05');
    expect(Fmt.bsShort(80), 'Bs 80');
    expect(Fmt.bs(1234.5), 'Bs 1.234,50');
    expect(kCountry.phonePrefix, '🇧🇴 +591  ');
    expect(kCountry.timezone, 'America/La_Paz');
  });

  test('Ecuador y Panamá están definidos pero no se lanzan todavía', () {
    expect(Country.forCode('EC'), same(Country.bolivia));
    expect(Country.forCode('pa'), same(Country.bolivia));
    expect(Country.forCode('XX'), same(Country.bolivia));
    expect(Country.all.where((c) => c.launched).map((c) => c.code), ['BO']);
  });

  test('las reglas de celular de Ecuador y Panamá', () {
    expect(Country.ecuador.normalizeMobile('099 123 4567'), '+593991234567');
    expect(Country.ecuador.normalizeMobile('+593 99 123 4567'), '+593991234567');
    expect(Country.ecuador.normalizeMobile('71234567'), isNull);
    expect(Country.ecuador.formatMobile('+593991234567'), '+593 99 123 4567');
    expect(Country.panama.normalizeMobile('6123-4567'), '+50761234567');
    expect(Country.panama.normalizeMobile('71234567'), isNull);
    expect(Country.panama.currencyCode, 'USD');
    expect(Country.ecuador.currencyCode, 'USD');
  });

  test('los montos en Bolivia llevan el símbolo adelante y coma decimal', () {
    expect(Fmt.bs(0), 'Bs 0,00');
    expect(Fmt.bs(1234567.891), 'Bs 1.234.567,89');
    expect(Fmt.bsShort(1234), 'Bs 1.234');
    expect(Fmt.bsShort(12.5), 'Bs 12,50');
    expect(Fmt.bs(-5), '-Bs 5,00');
  });
}
