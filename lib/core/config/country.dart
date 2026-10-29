/// País de la app: prefijo del celular, moneda, formato de números y hora.
///
/// Una sola app para Bolivia, Ecuador y Panamá: todo lo que cambia de un país
/// a otro sale de aquí, así que la app no repite "+591" ni "Bs" en cada
/// pantalla. Se lanza solo en Bolivia; Ecuador y Panamá quedan definidos pero
/// apagados hasta que el servidor (sus ciudades, el envío de códigos y los
/// cobros) y los textos legales de cada país estén listos.
///
/// Se elige al compilar con `--dart-define=HMY_COUNTRY=BO` (BO por defecto).
library;

class Country {
  const Country({
    required this.code,
    required this.name,
    required this.flag,
    required this.dialCode,
    required this.mobileRegex,
    required this.mobileExample,
    required this.mobileHint,
    required this.mobileGroups,
    required this.currencyCode,
    required this.currencySymbol,
    required this.currencyName,
    required this.locale,
    required this.timezone,
    required this.timezoneLabel,
    required this.launched,
  });

  /// ISO 3166-1, por ejemplo BO.
  final String code;
  final String name;
  final String flag;

  /// Sin el "+", por ejemplo 591.
  final String dialCode;

  /// El celular sin el prefijo del país.
  final String mobileRegex;
  final String mobileExample;
  final String mobileHint;

  /// Cómo se agrupan las cifras al mostrar el número, por ejemplo [4, 4].
  final List<int> mobileGroups;

  /// ISO 4217, por ejemplo BOB.
  final String currencyCode;
  final String currencySymbol;
  final String currencyName;
  /// Para los números (separador decimal y de miles).
  final String locale;
  final String timezone;
  final String timezoneLabel;

  /// Solo un país lanzado puede elegirse al compilar.
  final bool launched;

  int get mobileLength => mobileGroups.fold(0, (s, g) => s + g);

  /// "Bs " o "$ ": va delante de un monto en un campo.
  String get moneyPrefix => '$currencySymbol ';

  /// "🇧🇴 +591  ": va delante del celular en el campo.
  String get phonePrefix => '$flag +$dialCode  ';

  /// "+591XXXXXXXX", o null si no es un celular del país. Acepta espacios,
  /// guiones y el prefijo del país.
  String? normalizeMobile(String v) {
    var digits = v.replaceAll(RegExp(r'\D'), '');
    if (digits.startsWith(dialCode) && digits.length == dialCode.length + mobileLength) {
      digits = digits.substring(dialCode.length);
    }
    // En Ecuador se marca con un 0 delante dentro del país (09…).
    if (digits.length == mobileLength + 1 && digits.startsWith('0')) digits = digits.substring(1);
    return RegExp(mobileRegex).hasMatch(digits) ? '+$dialCode$digits' : null;
  }

  /// "+591 7123 4567", con espacios que no se cortan.
  String formatMobile(String phone) {
    final d = phone.replaceFirst('+$dialCode', '');
    if (d.length != mobileLength || !RegExp(r'^\d+$').hasMatch(d)) return phone;
    final parts = <String>[];
    var i = 0;
    for (final g in mobileGroups) {
      parts.add(d.substring(i, i + g));
      i += g;
    }
    return '+$dialCode ${parts.join(' ')}';
  }

  static const bolivia = Country(
    code: 'BO',
    name: 'Bolivia',
    flag: '🇧🇴',
    dialCode: '591',
    mobileRegex: r'^[67]\d{7}$',
    mobileExample: '71234567',
    mobileHint: '7123 4567',
    mobileGroups: [4, 4],
    currencyCode: 'BOB',
    currencySymbol: 'Bs',
    currencyName: 'Bolivianos',
    locale: 'es_BO',
    timezone: 'America/La_Paz',
    timezoneLabel: 'Hora de Bolivia',
    launched: true,
  );

  static const ecuador = Country(
    code: 'EC',
    name: 'Ecuador',
    flag: '🇪🇨',
    dialCode: '593',
    mobileRegex: r'^9\d{8}$',
    mobileExample: '991234567',
    mobileHint: '99 123 4567',
    mobileGroups: [2, 3, 4],
    currencyCode: 'USD',
    currencySymbol: r'$',
    currencyName: 'Dólares',
    // Punto decimal y coma de miles, como en Ecuador ($1,234.50).
    locale: 'es_419',
    timezone: 'America/Guayaquil',
    timezoneLabel: 'Hora de Ecuador',
    launched: false,
  );

  static const panama = Country(
    code: 'PA',
    name: 'Panamá',
    flag: '🇵🇦',
    dialCode: '507',
    mobileRegex: r'^6\d{7}$',
    mobileExample: '61234567',
    mobileHint: '6123 4567',
    mobileGroups: [4, 4],
    currencyCode: 'USD',
    currencySymbol: r'$',
    currencyName: 'Dólares',
    locale: 'es_419',
    timezone: 'America/Panama',
    timezoneLabel: 'Hora de Panamá',
    launched: false,
  );

  static const all = [bolivia, ecuador, panama];

  /// El país de esta compilación. Uno que no existe o que todavía no se lanzó
  /// vuelve a Bolivia: nunca se arranca a medias en otro país.
  static Country forCode(String code) {
    final c = all.where((c) => c.code == code.toUpperCase()).firstOrNull;
    return c != null && c.launched ? c : bolivia;
  }
}

/// El país de esta compilación.
final Country kCountry = Country.forCode(const String.fromEnvironment('HMY_COUNTRY', defaultValue: 'BO'));
