/// Los nueve departamentos de Bolivia (mismos id que public.departments).
const boliviaDepartments = <int, String>{
  1: 'Chuquisaca',
  2: 'La Paz',
  3: 'Cochabamba',
  4: 'Oruro',
  5: 'Potosí',
  6: 'Tarija',
  7: 'Santa Cruz',
  8: 'Beni',
  9: 'Pando',
};

/// Un municipio de Bolivia (la tabla se llama `cities` por historia).
class City {
  const City({
    required this.id,
    required this.name,
    required this.slug,
    this.departmentId,
    this.province,
    this.latitude,
    this.longitude,
  });

  final int id;
  final String name;
  final String slug;
  final int? departmentId;
  final String? province;

  /// Punto de referencia del municipio (en las capitales, la ciudad).
  final double? latitude;
  final double? longitude;

  /// Nombre corto para el encabezado ("Santa Cruz" en vez de "Santa Cruz de la Sierra").
  String get shortName => name.replaceAll(' de la Sierra', '');

  String? get department => boliviaDepartments[departmentId];

  /// "Provincia Cercado · Potosí", para distinguir municipios con el mismo nombre.
  String get place => [if (province != null) 'Prov. $province', ?department].join(' · ');

  factory City.fromMap(Map<String, dynamic> m) => City(
    id: (m['id'] as num).toInt(),
    name: m['name'] as String,
    slug: m['slug'] as String,
    departmentId: (m['department_id'] as num?)?.toInt(),
    province: m['province'] as String?,
    latitude: (m['latitude'] as num?)?.toDouble(),
    longitude: (m['longitude'] as num?)?.toDouble(),
  );

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
    this.allowsYa = true,
    this.requiredDoc,
    this.safetyNote,
    this.proNote,
    this.isActive = true,
    this.sortOrder = 100,
  });

  final int id;
  final String slug;
  final String name;
  final String icon;
  final String? description;

  /// Falso en servicios donde el cliente debe elegir a la persona (niñera, asesoría legal).
  final bool allowsYa;

  /// Documento que el profesional debe tener aceptado para atender esta
  /// categoría: `antecedentes` o `certificado`.
  final String? requiredDoc;

  /// Regla de seguridad que ve el cliente al pedir.
  final String? safetyNote;

  /// Requisito que ve el profesional al postularse.
  final String? proNote;
  final bool isActive;
  final int sortOrder;

  bool get isSensitive => requiredDoc != null;

  factory ServiceCategory.fromMap(Map<String, dynamic> m) => ServiceCategory(
    id: (m['id'] as num).toInt(),
    slug: m['slug'] as String,
    name: m['name'] as String,
    icon: (m['icon'] as String?) ?? 'build',
    description: m['description'] as String?,
    allowsYa: m['allows_ya'] as bool? ?? true,
    requiredDoc: m['required_doc'] as String?,
    safetyNote: m['safety_note'] as String?,
    proNote: m['pro_note'] as String?,
    isActive: m['is_active'] as bool? ?? true,
    sortOrder: (m['sort_order'] as num?)?.toInt() ?? 100,
  );

  Map<String, dynamic> toMap() => {
    'slug': slug,
    'name': name.trim(),
    'icon': icon,
    'description': (description ?? '').trim().isEmpty ? null : description!.trim(),
    'allows_ya': allowsYa,
    'required_doc': requiredDoc,
    'safety_note': (safetyNote ?? '').trim().isEmpty ? null : safetyNote!.trim(),
    'pro_note': (proNote ?? '').trim().isEmpty ? null : proNote!.trim(),
    'is_active': isActive,
    'sort_order': sortOrder,
  };

  ServiceCategory copyWith({
    String? name,
    String? icon,
    String? Function()? description,
    bool? allowsYa,
    String? Function()? requiredDoc,
    String? Function()? safetyNote,
    String? Function()? proNote,
    bool? isActive,
    int? sortOrder,
  }) => ServiceCategory(
    id: id,
    slug: slug,
    name: name ?? this.name,
    icon: icon ?? this.icon,
    description: description == null ? this.description : description(),
    allowsYa: allowsYa ?? this.allowsYa,
    requiredDoc: requiredDoc == null ? this.requiredDoc : requiredDoc(),
    safetyNote: safetyNote == null ? this.safetyNote : safetyNote(),
    proNote: proNote == null ? this.proNote : proNote(),
    isActive: isActive ?? this.isActive,
    sortOrder: sortOrder ?? this.sortOrder,
  );
}

/// Una opción de "¿Qué necesitas solucionar?" dentro de una categoría.
class ServiceProblem {
  const ServiceProblem({
    required this.id,
    required this.categoryId,
    required this.name,
    this.icon = 'build',
    this.isOther = false,
    this.isActive = true,
    this.sortOrder = 100,
  });

  final int id;
  final int categoryId;
  final String name;
  final String icon;

  /// "Otro problema" / "Otro servicio": pide que el cliente lo describa.
  final bool isOther;
  final bool isActive;
  final int sortOrder;

  factory ServiceProblem.fromMap(Map<String, dynamic> m) => ServiceProblem(
    id: (m['id'] as num).toInt(),
    categoryId: (m['category_id'] as num).toInt(),
    name: m['name'] as String,
    icon: (m['icon'] as String?) ?? 'build',
    isOther: m['is_other'] as bool? ?? false,
    isActive: m['is_active'] as bool? ?? true,
    sortOrder: (m['sort_order'] as num?)?.toInt() ?? 100,
  );

  Map<String, dynamic> toMap() => {
    'category_id': categoryId,
    'name': name.trim(),
    'icon': icon,
    'is_other': isOther,
    'is_active': isActive,
    'sort_order': sortOrder,
  };

  ServiceProblem copyWith({String? name, String? icon, bool? isOther, bool? isActive, int? sortOrder}) =>
      ServiceProblem(
        id: id,
        categoryId: categoryId,
        name: name ?? this.name,
        icon: icon ?? this.icon,
        isOther: isOther ?? this.isOther,
        isActive: isActive ?? this.isActive,
        sortOrder: sortOrder ?? this.sortOrder,
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
