enum AppRole {
  customer('customer'),
  professional('professional'),
  admin('admin');

  const AppRole(this.key);
  final String key;

  static AppRole parse(String? v) => AppRole.values.firstWhere((r) => r.key == v, orElse: () => AppRole.customer);
}

enum VerificationStatus {
  notStarted('not_started', 'Sin empezar'),
  draft('draft', 'Borrador'),
  submitted('submitted', 'Enviada'),
  underReview('under_review', 'En revisión'),
  approved('approved', 'Aprobada'),
  rejected('rejected', 'Rechazada'),
  suspended('suspended', 'Suspendida'),
  reverificationRequired('reverification_required', 'Requiere nueva verificación');

  const VerificationStatus(this.key, this.label);
  final String key;
  final String label;

  bool get canEdit => this == draft || this == rejected || this == reverificationRequired || this == notStarted;

  static VerificationStatus parse(String? v) =>
      VerificationStatus.values.firstWhere((s) => s.key == v, orElse: () => VerificationStatus.notStarted);
}

/// Sesión de autenticación (solo lo que necesita la navegación).
class AuthUser {
  const AuthUser({required this.id, required this.email, required this.emailConfirmed});

  final String id;
  final String email;
  final bool emailConfirmed;
}

class UserProfile {
  const UserProfile({
    required this.id,
    required this.email,
    required this.fullName,
    this.phone,
    this.cityId,
    this.activeRole = AppRole.customer,
    this.roles = const {AppRole.customer},
    this.professionalStatus = VerificationStatus.notStarted,
    this.onboardingCompleted = false,
    this.deletionRequested = false,
  });

  final String id;
  final String email;
  final String fullName;
  final String? phone;
  final int? cityId;
  final AppRole activeRole;
  final Set<AppRole> roles;
  final VerificationStatus professionalStatus;
  final bool onboardingCompleted;
  final bool deletionRequested;

  bool get isApprovedProfessional =>
      roles.contains(AppRole.professional) && professionalStatus == VerificationStatus.approved;
  bool get isProfessionalMode => activeRole == AppRole.professional && isApprovedProfessional;
  bool get isAdmin => roles.contains(AppRole.admin);

  UserProfile copyWith({
    String? fullName,
    String? Function()? phone,
    int? Function()? cityId,
    AppRole? activeRole,
    Set<AppRole>? roles,
    VerificationStatus? professionalStatus,
    bool? onboardingCompleted,
    bool? deletionRequested,
  }) => UserProfile(
    id: id,
    email: email,
    fullName: fullName ?? this.fullName,
    phone: phone != null ? phone() : this.phone,
    cityId: cityId != null ? cityId() : this.cityId,
    activeRole: activeRole ?? this.activeRole,
    roles: roles ?? this.roles,
    professionalStatus: professionalStatus ?? this.professionalStatus,
    onboardingCompleted: onboardingCompleted ?? this.onboardingCompleted,
    deletionRequested: deletionRequested ?? this.deletionRequested,
  );
}

/// Borrador de la postulación profesional (lo que edita el propio usuario).
class ProfessionalApplication {
  const ProfessionalApplication({
    this.status = VerificationStatus.notStarted,
    this.displayName = '',
    this.primaryCategoryId,
    this.bio = '',
    this.yearsExperience,
    this.cityId,
    this.priceNote = '',
    this.categoryIds = const {},
    this.zoneIds = const {},
    this.documentCount = 0,
    this.reviewNote,
  });

  final VerificationStatus status;
  final String displayName;
  final int? primaryCategoryId;
  final String bio;
  final int? yearsExperience;
  final int? cityId;
  final String priceNote;
  final Set<int> categoryIds;
  final Set<int> zoneIds;
  final int documentCount;
  final String? reviewNote;
}
