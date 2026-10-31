import 'package:flutter_test/flutter_test.dart';
import 'package:handimanya/core/utils/validators.dart';

void main() {
  group('Celular de Bolivia', () {
    test('acepta números móviles con o sin +591', () {
      expect(Validators.phone('71234567'), isNull);
      expect(Validators.phone('+591 6123 4567'), isNull);
      expect(Validators.normalizePhone('712-345-67'), '+59171234567');
      expect(Validators.normalizePhone('+59161234567'), '+59161234567');
    });

    test('rechaza números que no son móviles bolivianos', () {
      expect(Validators.phone('51234567'), isNotNull);
      expect(Validators.phone('7123456'), isNotNull);
      expect(Validators.phone(''), isNotNull);
    });
  });

  test('correo', () {
    expect(Validators.email('ana@correo.bo'), isNull);
    expect(Validators.email('ana@correo'), isNotNull);
    expect(Validators.email(''), isNotNull);
  });

  test('contraseña: mínimo 8, con letras y números', () {
    expect(Validators.password('Demo1234'), isNull);
    expect(Validators.password('corta1'), isNotNull);
    expect(Validators.password('soloLetras'), isNotNull);
    expect(Validators.password('12345678'), isNotNull);
  });

  test('código de 6 dígitos', () {
    expect(Validators.otp('123456'), isNull);
    expect(Validators.otp('12345'), isNotNull);
    expect(Validators.otp('abcdef'), isNotNull);
  });
}
