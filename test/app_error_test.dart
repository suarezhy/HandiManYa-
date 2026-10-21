import 'package:flutter_test/flutter_test.dart';
import 'package:handimanya/core/utils/app_error.dart';

void main() {
  test('los rechazos de ¡Ya! del servidor se muestran claros, igual que en el modo demo', () {
    final none = AppError.from(Exception('PostgrestException(message: HMY_NO_PROFESSIONALS_AVAILABLE, code: P0001)'));
    expect(none.code, 'HMY_NO_PROFESSIONALS_AVAILABLE');
    expect(none.message, startsWith('No hay profesionales disponibles'));
    final taken = AppError.from(Exception('PostgrestException(message: HMY_ALREADY_TAKEN, code: P0001)'));
    expect(taken.code, 'HMY_ALREADY_TAKEN');
    expect(taken.message, 'Otro profesional ya tomó este pedido.');
  });
}
