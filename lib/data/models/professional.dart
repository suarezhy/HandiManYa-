double _d(Object? v) => v == null ? 0 : (v as num).toDouble();
List<String> _strings(Object? v) => v == null ? const [] : List<String>.from(v as List);

enum SortOption {
  recommended('recommended', 'Recomendados'),
  available('available', 'Disponibles ahora'),
  rating('rating', 'Mejor calificados');

  const SortOption(this.key, this.label);
  final String key;
  final String label;
}

class SearchFilters {
  const SearchFilters({
    this.cityId,
    this.categoryId,
    this.zoneId,
    this.query = '',
    this.availableNow = false,
    this.minRating,
    this.sort = SortOption.recommended,
  });

  final int? cityId;
  final int? categoryId;
  final int? zoneId;
  final String query;
  final bool availableNow;
  final double? minRating;
  final SortOption sort;

  int get activeFilterCount =>
      (categoryId != null ? 1 : 0) + (zoneId != null ? 1 : 0) + (availableNow ? 1 : 0) + (minRating != null ? 1 : 0);

  SearchFilters copyWith({
    int? Function()? cityId,
    int? Function()? categoryId,
    int? Function()? zoneId,
    String? query,
    bool? availableNow,
    double? Function()? minRating,
    SortOption? sort,
  }) => SearchFilters(
    cityId: cityId != null ? cityId() : this.cityId,
    categoryId: categoryId != null ? categoryId() : this.categoryId,
    zoneId: zoneId != null ? zoneId() : this.zoneId,
    query: query ?? this.query,
    availableNow: availableNow ?? this.availableNow,
    minRating: minRating != null ? minRating() : this.minRating,
    sort: sort ?? this.sort,
  );

  @override
  bool operator ==(Object other) =>
      other is SearchFilters &&
      other.cityId == cityId &&
      other.categoryId == categoryId &&
      other.zoneId == zoneId &&
      other.query == query &&
      other.availableNow == availableNow &&
      other.minRating == minRating &&
      other.sort == sort;

  @override
  int get hashCode => Object.hash(cityId, categoryId, zoneId, query, availableNow, minRating, sort);
}

/// Datos públicos de un profesional aprobado. Nunca incluye dirección,
/// coordenadas ni documentos.
class ProfessionalSummary {
  const ProfessionalSummary({
    required this.id,
    required this.displayName,
    this.photoUrl,
    this.primaryCategoryId,
    this.primaryCategory,
    this.specialties = const [],
    this.city,
    this.zones = const [],
    this.ratingAvg = 0,
    this.ratingCount = 0,
    this.completedJobs = 0,
    this.isAvailable = false,
    this.priceFrom,
    this.isVerified = false,
  });

  final String id;
  final String displayName;
  final String? photoUrl;
  final int? primaryCategoryId;
  final String? primaryCategory;
  final List<String> specialties;
  final String? city;
  final List<String> zones;
  final double ratingAvg;
  final int ratingCount;
  final int completedJobs;
  final bool isAvailable;
  final double? priceFrom;
  final bool isVerified;

  String get areaLabel {
    if (zones.isEmpty) return city ?? '';
    final z = zones.length > 2 ? '${zones.take(2).join(', ')} y más' : zones.join(', ');
    return city == null ? z : '$z · ${city!.replaceAll(' de la Sierra', '')}';
  }

  factory ProfessionalSummary.fromMap(Map<String, dynamic> m, {String? Function(String? path)? photo}) =>
      ProfessionalSummary(
        id: m['id'] as String,
        displayName: m['display_name'] as String,
        photoUrl: photo?.call(m['photo_path'] as String?),
        primaryCategoryId: (m['primary_category_id'] as num?)?.toInt(),
        primaryCategory: m['primary_category'] as String?,
        specialties: _strings(m['specialties']),
        city: m['city'] as String?,
        zones: _strings(m['zones']),
        ratingAvg: _d(m['rating_avg']),
        ratingCount: (m['rating_count'] as num?)?.toInt() ?? 0,
        completedJobs: (m['completed_jobs'] as num?)?.toInt() ?? 0,
        isAvailable: m['is_available'] as bool? ?? false,
        priceFrom: m['price_from'] == null ? null : _d(m['price_from']),
        isVerified: m['is_verified'] as bool? ?? false,
      );
}

class ProService {
  const ProService({required this.categoryId, required this.category, this.specialty, this.priceFrom});

  final int categoryId;
  final String category;
  final String? specialty;
  final double? priceFrom;

  factory ProService.fromMap(Map<String, dynamic> m) => ProService(
    categoryId: (m['category_id'] as num).toInt(),
    category: m['category'] as String,
    specialty: m['specialty'] as String?,
    priceFrom: m['price_from'] == null ? null : _d(m['price_from']),
  );
}

class AvailabilitySlot {
  const AvailabilitySlot({required this.weekday, required this.start, required this.end});

  /// 1 = lunes … 7 = domingo.
  final int weekday;
  final String start;
  final String end;

  static const weekdayNames = ['Lunes', 'Martes', 'Miércoles', 'Jueves', 'Viernes', 'Sábado', 'Domingo'];
  String get label => '${weekdayNames[weekday - 1]} ${start.substring(0, 5)} a ${end.substring(0, 5)}';

  factory AvailabilitySlot.fromMap(Map<String, dynamic> m) =>
      AvailabilitySlot(weekday: (m['weekday'] as num).toInt(), start: m['start'] as String, end: m['end'] as String);
}

class ProfessionalDetail {
  const ProfessionalDetail({
    required this.summary,
    this.bio,
    this.yearsExperience,
    this.priceNote,
    this.services = const [],
    this.portfolioUrls = const [],
    this.availability = const [],
  });

  final ProfessionalSummary summary;
  final String? bio;
  final int? yearsExperience;
  final String? priceNote;
  final List<ProService> services;
  final List<String> portfolioUrls;
  final List<AvailabilitySlot> availability;
}

class Review {
  const Review({
    required this.id,
    required this.rating,
    this.comment,
    required this.authorFirstName,
    this.professionalReply,
    required this.createdAt,
  });

  final int id;
  final int rating;
  final String? comment;
  final String authorFirstName;
  final String? professionalReply;
  final DateTime createdAt;

  factory Review.fromMap(Map<String, dynamic> m) => Review(
    id: (m['id'] as num).toInt(),
    rating: (m['rating'] as num).toInt(),
    comment: m['comment'] as String?,
    authorFirstName: m['author_first_name'] as String,
    professionalReply: m['professional_reply'] as String?,
    createdAt: DateTime.parse(m['created_at'] as String),
  );
}
