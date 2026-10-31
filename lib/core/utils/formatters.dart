import 'package:intl/intl.dart';

import '../config/country.dart';

abstract final class Fmt {
  // El símbolo va adelante ("Bs 80"). Con es_BO, intl usa los datos de "es"
  // (España), que lo ponen al final ("80 Bs"): por eso el formato es propio.
  static final _money = NumberFormat.currency(
    locale: kCountry.locale,
    symbol: kCountry.moneyPrefix,
    customPattern: '\u00A4#,##0.00',
    decimalDigits: 2,
  );
  static final _moneyShort = NumberFormat.currency(
    locale: kCountry.locale,
    symbol: kCountry.moneyPrefix,
    customPattern: '\u00A4#,##0',
    decimalDigits: 0,
  );

  static String bs(num value) => _money.format(value);

  /// Sin decimales cuando el monto es entero ("Bs 80").
  static String bsShort(num value) => value == value.roundToDouble() ? _moneyShort.format(value) : _money.format(value);

  static String rating(double value) => NumberFormat('0.0', kCountry.locale).format(value);

  /// "1,2 km" o "800 m".
  static String km(double value) =>
      value < 1 ? '${(value * 1000).round()} m' : '${NumberFormat('0.0', kCountry.locale).format(value)} km';

  static String date(DateTime d) => DateFormat("EEEE d 'de' MMMM", 'es').format(d.toLocal());
  static String shortDate(DateTime d) => DateFormat('d MMM', 'es').format(d.toLocal());
  static String time(DateTime d) => DateFormat('HH:mm', 'es').format(d.toLocal());
  static String dateTime(DateTime d) => '${shortDate(d)}, ${time(d)}';

  /// "hace 5 min", "ayer", "12 oct".
  static String relative(DateTime d, {DateTime? now}) {
    final n = now ?? DateTime.now();
    final diff = n.difference(d);
    if (diff.inMinutes < 1) return 'ahora';
    if (diff.inMinutes < 60) return 'hace ${diff.inMinutes} min';
    if (diff.inHours < 24 && n.day == d.day) return time(d);
    if (diff.inDays < 2) return 'ayer';
    return shortDate(d);
  }

  static String firstName(String full) {
    final t = full.trim();
    if (t.isEmpty) return '';
    return t.split(RegExp(r'\s+')).first;
  }

  static String initials(String full) {
    final parts = full.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return (parts[0][0] + parts[1][0]).toUpperCase();
  }
}

/// "+591 7••• ••05", como hmy_mask_phone en la base: nunca el número completo.
String? maskPhone(String? phone) {
  final d = (phone ?? '').replaceAll(RegExp(r'\D'), '');
  if (d.length < 6) return null;
  final cc = kCountry.dialCode;
  if (d.startsWith(cc) && d.length == cc.length + kCountry.mobileLength) {
    return '+$cc ${d[cc.length]}••• ••${d.substring(d.length - 2)}';
  }
  return '••• ${d.substring(d.length - 2)}';
}

/// "•••• 3456", como hmy_mask_account en la base.
String maskAccount(String number) {
  final d = number.replaceAll(RegExp(r'\D'), '');
  return d.length <= 4 ? '••••' : '•••• ${d.substring(d.length - 4)}';
}
