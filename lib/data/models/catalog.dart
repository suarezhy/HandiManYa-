class City {
  const City({required this.id, required this.name, required this.slug});

  final int id;
  final String name;
  final String slug;

  /// Nombre corto para el encabezado ("Santa Cruz" en vez de "Santa Cruz de la Sierra").
  String get shortName => name.replaceAll(' de la Sierra', '');

  factory City.fromMap(Map<String, dynamic> m) =>
      City(id: (m['id'] as num).toInt(), name: m['name'] as String, slug: m['slug'] as String);

  @override
  bool operator ==(Object other) => other is City && other.id == id;
  @override
  int get hashCode => id.hashCode;
}

class Zone {
  const Zone({required this.id, required this.cityId, required this.name});

  final int id;
  final int cityId;
  final String name;

  factory Zone.fromMap(Map<String, dynamic> m) =>
      Zone(id: (m['id'] as num).toInt(), cityId: (m['city_id'] as num).toInt(), name: m['name'] as String);
}

class ServiceCategory {
  const ServiceCategory({
    required this.id,
    required this.slug,
    required this.name,
    required this.icon,
    this.description,
  });

  final int id;
  final String slug;
  final String name;
  final String icon;
  final String? description;

  factory ServiceCategory.fromMap(Map<String, dynamic> m) => ServiceCategory(
    id: (m['id'] as num).toInt(),
    slug: m['slug'] as String,
    name: m['name'] as String,
    icon: (m['icon'] as String?) ?? 'build',
    description: m['description'] as String?,
  );
}

class Promotion {
  const Promotion({
    required this.id,
    required this.title,
    this.subtitle,
    required this.ctaLabel,
    required this.ctaRoute,
  });

  final int id;
  final String title;
  final String? subtitle;
  final String ctaLabel;
  final String ctaRoute;

  factory Promotion.fromMap(Map<String, dynamic> m) => Promotion(
    id: (m['id'] as num).toInt(),
    title: m['title'] as String,
    subtitle: m['subtitle'] as String?,
    ctaLabel: m['cta_label'] as String,
    ctaRoute: m['cta_route'] as String,
  );
}
