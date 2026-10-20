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

/// Por dónde llega el código de 6 dígitos.
enum CodeChannel {
  whatsapp('whatsapp', 'WhatsApp'),
  sms('sms', 'SMS');

  const CodeChannel(this.key, this.label);
  final String key;
  final String label;

  static CodeChannel parse(String? v) => v == sms.key ? sms : whatsapp;
}

/// Sesión de autenticación (solo lo que necesita la navegación). Se entra con
/// el celular; el correo es opcional.
class AuthUser {
  const AuthUser({required this.id, this.phone, this.email});

  final String id;

  /// +591…, o null en cuentas antiguas creadas con correo.
  final String? phone;
  final String? email;
}

class UserProfile {
  const UserProfile({
    required this.id,
    required this.email,
    required this.fullName,
    this.phone,
    this.phoneVerified = false,
    this.emailConfirmed = false,
    this.profileComplete = true,
    this.cityId,
    this.activeRole = AppRole.customer,
    this.roles = const {AppRole.customer},
    this.professionalStatus = VerificationStatus.notStarted,
    this.onboardingCompleted = false,
    this.deletionRequested = false,
    this.suspensionReason,
    this.isSuspended = false,
    this.blockedIds = const {},
  });

  final String id;
  final String email;
  final String fullName;
  final String? phone;
  final bool phoneVerified;

  /// El correo es opcional; [email] queda vacío si no lo agregó.
  final bool emailConfirmed;

  /// Ya puso nombre y ciudad y aceptó los términos (después del código).
  final bool profileComplete;
  final int? cityId;
  final AppRole activeRole;
  final Set<AppRole> roles;
  final VerificationStatus professionalStatus;
  final bool onboardingCompleted;
  final bool deletionRequested;
  final bool isSuspended;
  final String? suspensionReason;

  /// Personas que este usuario bloqueó.
  final Set<String> blockedIds;

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
    Set<String>? blockedIds,
  }) => UserProfile(
    id: id,
    email: email,
    fullName: fullName ?? this.fullName,
    phone: phone != null ? phone() : this.phone,
    phoneVerified: phoneVerified,
    emailConfirmed: emailConfirmed,
    profileComplete: profileComplete,
    cityId: cityId != null ? cityId() : this.cityId,
    activeRole: activeRole ?? this.activeRole,
    roles: roles ?? this.roles,
    professionalStatus: professionalStatus ?? this.professionalStatus,
    onboardingCompleted: onboardingCompleted ?? this.onboardingCompleted,
    deletionRequested: deletionRequested ?? this.deletionRequested,
    isSuspended: isSuspended,
    suspensionReason: suspensionReason,
    blockedIds: blockedIds ?? this.blockedIds,
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
