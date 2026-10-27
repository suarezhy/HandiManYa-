// Publicidad propia del inicio (0051). La administra solo el Propietario; el
// servidor decide qué anuncio sale y cuenta vistas y toques sin guardar quién.

int _i(Object? v) => v == null ? 0 : (v is num ? v.toInt() : int.tryParse('$v') ?? 0);
DateTime? _t(Object? v) => v == null ? null : DateTime.tryParse('$v')?.toLocal();

/// Etiqueta que lleva siempre el anuncio.
const adLabels = ['Publicidad', 'Patrocinado'];

/// Un anuncio para el inicio del cliente. Sin el enlace: se pide al tocarlo.
class HomeAd {
  const HomeAd({
    required this.id,
    required this.advertiser,
    required this.title,
    this.body,
    this.logoUrl,
    this.imageUrl,
    this.label = 'Publicidad',
    this.hasLink = false,
  });

  final int id;
  final String advertiser;
  final String title;
  final String? body;
  final String? logoUrl;
  final String? imageUrl;
  final String label;
  final bool hasLink;

  factory HomeAd.fromMap(Map<String, dynamic> m, {required String? Function(String?) image}) => HomeAd(
    id: _i(m['id']),
    advertiser: m['advertiser'] as String? ?? '',
    title: m['title'] as String? ?? '',
    body: m['body'] as String?,
    logoUrl: image(m['logo_path'] as String?),
    imageUrl: image(m['image_path'] as String?),
    label: m['label'] as String? ?? 'Publicidad',
    hasLink: m['has_link'] == true,
  );
}

enum AdStatus {
  draft('draft', 'Borrador'),
  approved('approved', 'Aprobado'),
  paused('paused', 'Pausado'),
  removed('removed', 'Quitado');

  const AdStatus(this.key, this.label);
  final String key;
  final String label;

  static AdStatus parse(String? v) => values.firstWhere((s) => s.key == v, orElse: () => draft);
}

/// Lo que el Propietario puede hacer con un anuncio.
enum AdAction {
  approve('approve'),
  pause('pause'),
  remove('remove');

  const AdAction(this.key);
  final String key;
}

/// Un anuncio como lo ve el Propietario, con sus cuentas.
class OwnerAd {
  const OwnerAd({
    required this.id,
    required this.advertiser,
    required this.title,
    this.body,
    this.logoPath,
    this.imagePath,
    this.logoUrl,
    this.imageUrl,
    this.linkUrl,
    this.label = 'Publicidad',
    this.cityId,
    this.cityName,
    this.status = AdStatus.draft,
    this.live = false,
    this.startsAt,
    this.endsAt,
    this.impressions = 0,
    this.clicks = 0,
    this.impressionsToday = 0,
    this.clicksToday = 0,
  });

  final int id;
  final String advertiser;
  final String title;
  final String? body;
  final String? logoPath;
  final String? imagePath;
  final String? logoUrl;
  final String? imageUrl;
  final String? linkUrl;
  final String label;
  final int? cityId;
  final String? cityName;
  final AdStatus status;

  /// Aprobado y dentro de sus fechas: se está mostrando.
  final bool live;
  final DateTime? startsAt;
  final DateTime? endsAt;
  final int impressions;
  final int clicks;
  final int impressionsToday;
  final int clicksToday;

  factory OwnerAd.fromMap(Map<String, dynamic> m, {required String? Function(String?) image}) => OwnerAd(
    id: _i(m['id']),
    advertiser: m['advertiser'] as String? ?? '',
    title: m['title'] as String? ?? '',
    body: m['body'] as String?,
    logoPath: m['logo_path'] as String?,
    imagePath: m['image_path'] as String?,
    logoUrl: image(m['logo_path'] as String?),
    imageUrl: image(m['image_path'] as String?),
    linkUrl: m['link_url'] as String?,
    label: m['label'] as String? ?? 'Publicidad',
    cityId: m['city_id'] == null ? null : _i(m['city_id']),
    cityName: m['city_name'] as String?,
    status: AdStatus.parse(m['status'] as String?),
    live: m['live'] == true,
    startsAt: _t(m['starts_at']),
    endsAt: _t(m['ends_at']),
    impressions: _i(m['impressions']),
    clicks: _i(m['clicks']),
    impressionsToday: _i(m['impressions_today']),
    clicksToday: _i(m['clicks_today']),
  );

  HomeAd get preview => HomeAd(
    id: id,
    advertiser: advertiser,
    title: title,
    body: body,
    logoUrl: logoUrl,
    imageUrl: imageUrl,
    label: label,
    hasLink: linkUrl != null,
  );
}

/// Lo que se guarda al crear o cambiar un anuncio. Siempre queda en borrador.
class AdDraft {
  const AdDraft({
    this.id,
    required this.advertiser,
    required this.title,
    this.body,
    this.logoPath,
    this.imagePath,
    this.linkUrl,
    this.label = 'Publicidad',
    this.cityId,
    this.startsAt,
    this.endsAt,
  });

  final int? id;
  final String advertiser;
  final String title;
  final String? body;
  final String? logoPath;
  final String? imagePath;
  final String? linkUrl;
  final String label;
  final int? cityId;
  final DateTime? startsAt;
  final DateTime? endsAt;
}

/// Solo enlaces https a un dominio (lo mismo que exige la base).
bool isValidAdLink(String url) =>
    RegExp(r'^https://[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+(:[0-9]+)?(/\S*)?$').hasMatch(url) && url.length <= 300;
