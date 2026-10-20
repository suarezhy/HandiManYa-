import 'package:intl/intl.dart';

abstract final class Fmt {
  static final _money = NumberFormat.currency(locale: 'es_BO', symbol: 'Bs ', decimalDigits: 2);
  static final _moneyShort = NumberFormat.currency(locale: 'es_BO', symbol: 'Bs ', decimalDigits: 0);

  static String bs(num value) => _money.format(value);

  /// Sin decimales cuando el monto es entero ("Bs 80").
  static String bsShort(num value) => value == value.roundToDouble() ? _moneyShort.format(value) : _money.format(value);

  static String rating(double value) => NumberFormat('0.0', 'es_BO').format(value);

  /// "1,2 km" o "800 m".
  static String km(double value) =>
      value < 1 ? '${(value * 1000).round()} m' : '${NumberFormat('0.0', 'es_BO').format(value)} km';

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
