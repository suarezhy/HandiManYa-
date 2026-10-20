import 'dart:typed_data';

import '../models/admin.dart';
import '../models/booking.dart';
import '../models/catalog.dart';
import '../models/geo.dart';
import '../models/messaging.dart';
import '../models/professional.dart';
import '../models/user.dart';
import '../models/wallet.dart';

/// Contratos de acceso a datos. Hay dos implementaciones: Supabase (real) y
/// demostración (en memoria). La interfaz nunca decide permisos: eso lo hace
/// la base de datos con RLS y funciones del servidor.

abstract interface class AuthRepository {
  AuthUser? get currentUser;
  Stream<AuthUser?> authChanges();

  Future<void> signUp({
    required String email,
    required String password,
    required String fullName,
    required String phone,
    required int cityId,
    required bool wantsToBeProfessional,
  });

  Future<void> verifyEmailCode({required String email, required String code});
  Future<void> resendEmailCode(String email);
  Future<void> signIn({required String email, required String password});
  Future<void> sendPasswordReset(String email);
  Future<void> verifyRecoveryCode({required String email, required String code});
  Future<void> updatePassword(String newPassword);
  Future<void> signOut();
}

abstract interface class AccountRepository {
  Future<UserProfile> myAccount();
  Future<void> updateProfile({required String fullName, String? phone, int? cityId});
  Future<void> setActiveRole(AppRole role);
  Future<void> completeOnboarding();
  Future<void> requestAccountDeletion();
}

abstract interface class CatalogRepository {
  Future<List<City>> cities();
  Future<List<Zone>> zones(int cityId);
  Future<List<ServiceCategory>> categories();

  /// Opciones activas de "¿Qué necesitas solucionar?" de una categoría, en orden.
  Future<List<ServiceProblem>> problems(int categoryId);
  Future<List<Promotion>> promotions(int? cityId);
}

abstract interface class ProfessionalRepository {
  Future<List<ProfessionalSummary>> search(SearchFilters filters, {int limit = 20, int offset = 0});
  Future<ProfessionalDetail?> professionalDetail(String id);
  Future<List<Review>> reviews(String professionalId);
  Future<int> countYaAvailable({
    required int categoryId,
    required int cityId,
    int? zoneId,
    double? latitude,
    double? longitude,
  });
}

abstract interface class BookingRepository {
  /// Devuelve el id de la solicitud creada.
  Future<String> create(BookingDraft draft);
  Future<List<BookingSummary>> myBookings({required bool asProfessional});
  Future<BookingDetail> detail(String bookingId);

  /// Sube fotos del problema a una solicitud propia (máximo 5).
  Future<void> addPhotos(String bookingId, List<PhotoUpload> photos);

  /// Avisa cuando cambia alguna solicitud del usuario (tiempo real).
  Stream<void> changes();

  // Profesional
  Future<void> accept(String bookingId, {required bool isOffer});
  Future<void> decline(String bookingId, {required bool isOffer, String? reason});
  Future<void> sendQuote(String bookingId, double amount, String? note);
  Future<void> updateProgress(String bookingId, BookingStatus to, {double? finalAmount});

  // Cliente
  Future<void> respondQuote(String bookingId, {required bool accept});
  Future<void> confirmCompletion(String bookingId);
  Future<void> submitReview(String bookingId, int rating, String? comment);

  // Ambos
  Future<void> cancel(String bookingId, String reason);
  Future<void> openDispute(String bookingId, String reason);
  Future<void> acknowledgePayment(String bookingId, PaymentMethod method);
}

abstract interface class MessagingRepository {
  Future<List<Conversation>> conversations();
  Stream<List<ChatMessage>> watchMessages(String conversationId);
  Future<void> send(String conversationId, String body);
  Future<void> markRead(String conversationId);
}

abstract interface class NotificationRepository {
  Future<List<AppNotification>> list();
  Stream<int> unreadCount();
  Future<void> markAllRead();
}

abstract interface class ProRepository {
  Future<ProDashboard> dashboard();
  Future<void> setAvailability(bool available);

  Future<ProfessionalApplication> application();
  Future<void> saveApplication({
    required String displayName,
    required int primaryCategoryId,
    required int cityId,
    required String bio,
    int? yearsExperience,
    String? priceNote,
    required Set<int> categoryIds,
    required Set<int> zoneIds,
  });
  Future<void> uploadDocument({required String docType, required Uint8List bytes, required String fileName});
  Future<void> submitApplication();

  Future<Wallet> wallet();
  Future<List<LedgerEntry>> ledger();
  Future<List<TopupMethod>> topupMethods();
  Future<List<TopupRequest>> topups();

  /// Pide una recarga (queda pendiente hasta que el equipo verifica el pago) y
  /// devuelve su número. [authMethod] es `password` o `biometric`, confirmado
  /// recién en este intento. [clientKey] identifica el intento: repetirlo
  /// (doble toque, reintento) devuelve la misma solicitud.
  Future<int> requestTopup({
    required double amount,
    required int methodId,
    String? reference,
    PhotoUpload? proof,
    required String authMethod,
    required String clientKey,
  });

  /// Confirmación de identidad: vuelve a verificar la contraseña de la cuenta
  /// en el servidor. La contraseña no se guarda.
  Future<void> confirmPassword(String password);

  /// Si la cuenta permite confirmar operaciones con huella o rostro.
  Future<bool> biometricEnabled();

  /// Activar exige [confirmPassword] justo antes; desactivar, no.
  Future<void> setBiometricEnabled(bool enabled);

  /// Base y radio de trabajo del profesional (privados).
  Future<ServiceLocation?> serviceLocation();
  Future<void> setServiceLocation({required double latitude, required double longitude, required int radiusKm});
}

/// Seguridad entre usuarios y consentimientos (para todos).
abstract interface class SafetyRepository {
  Future<void> reportUser({required String userId, required ReportReason reason, String? details, String? bookingId});
  Future<void> blockUser(String userId);
  Future<void> unblockUser(String userId);

  /// Guarda qué versión de un documento legal aceptó el usuario.
  Future<void> recordConsent(String document, String version);

  /// Mensaje al equipo de soporte.
  Future<void> contactSupport({required String subject, required String body, String? bookingId});
}

/// Panel de administración. Cada función vuelve a verificar en el servidor
/// que quien llama es administrador.
abstract interface class AdminRepository {
  Future<AdminDashboard> adminDashboard();

  Future<List<AdminApplication>> adminApplications({String status = 'pending'});
  Future<AdminApplicationDetail> adminApplicationDetail(String professionalId);
  Future<void> reviewApplication(String professionalId, VerificationStatus decision, {String? note});
  Future<void> reviewDocument(int documentId, DocumentStatus status, {String? note});

  Future<List<AdminTopup>> adminTopups({String status = 'pending'});
  Future<void> reviewTopup(int topupId, {required bool approve, String? note});
  Future<void> adjustWallet(String professionalId, double amount, String reason);

  Future<List<AdminReport>> adminReports({String status = 'open'});
  Future<void> reviewReport(int reportId, CaseStatus status, {String? resolution});

  Future<List<AdminDispute>> adminDisputes({String status = 'open'});
  Future<void> resolveDispute(String bookingId, DisputeOutcome outcome, String resolution);

  Future<List<AdminTicket>> adminTickets({String status = 'open'});
  Future<void> updateTicket(int ticketId, TicketStatus status, {String? note});

  Future<List<AdminUser>> adminUsers(String query);
  Future<void> setSuspension(String userId, {required bool suspend, String? reason});

  Future<List<CommissionRule>> commissionRules();
  Future<void> saveCommissionRule(CommissionRule rule);

  Future<List<CatalogItem>> adminCategories();
  Future<void> setCategoryActive(int id, bool active);

  /// Categorías y sus problemas, incluidas las apagadas. `id == 0` crea una nueva.
  Future<List<ServiceCategory>> adminServiceCategories();
  Future<void> saveCategory(ServiceCategory category);
  Future<void> reorderCategories(List<int> orderedIds);
  Future<List<ServiceProblem>> adminProblems(int categoryId);
  Future<void> saveProblem(ServiceProblem problem);
  Future<void> reorderProblems(List<int> orderedIds);
  Future<List<CatalogItem>> adminCities();
  Future<void> setCityActive(int id, bool active);
  Future<List<CatalogItem>> adminPromotions();
  Future<void> setPromotionActive(int id, bool active);
  Future<void> createPromotion({required String title, String? subtitle, int? cityId});

  Future<List<AuditEntry>> auditLog();
}
