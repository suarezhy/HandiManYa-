import 'package:handimanya/data/demo/demo_backend.dart';

import 'demo_login.dart';

/// Con la sesión del profesional de demostración: acuerda un precio y deja el
/// trabajo confirmado (0062). Si el cliente puso su precio, lo acepta; si no,
/// propone [amount], el cliente lo acepta y la sesión vuelve al profesional.
Future<void> agreeAsPro(DemoBackend backend, String bookingId, {double amount = 150}) async {
  final me = backend.currentUser!.id;
  final theirs = (await backend.detail(bookingId)).price.customerOfferFor(me);
  if (theirs != null) return backend.acceptPriceOffer(theirs.id);
  final offer = await backend.proposePrice(bookingId, amount);
  await backend.signInAs(DemoBackend.customerPhone);
  await backend.acceptPriceOffer(offer);
  await backend.signInAs(DemoBackend.professionalPhone);
}
