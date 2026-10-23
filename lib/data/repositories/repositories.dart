import 'dart:typed_data';

import '../models/admin.dart';
import '../models/ai_control.dart';
import '../models/booking.dart';
import '../models/catalog.dart';
import '../models/costs.dart';
import '../models/drilldown.dart';
import '../models/finance.dart';
import '../models/geo.dart';
import '../models/messaging.dart';
import '../models/professional.dart';
import '../models/staff.dart';
import '../models/user.dart';
import '../models/wallet.dart';

/// Contratos de acceso a datos. Hay dos implementaciones: Supabase (real) y
/// demostración (en memoria). La interfaz nunca decide permisos: eso lo hace
/// la base de datos con RLS y funciones del servidor.

abstract interface class AuthRepository {
  AuthUser? get currentUser;
  Stream<AuthUser?> authChanges();

  /// Envía un código de 6 dígitos al celular (+591…) por WhatsApp o SMS.
  /// Es lo mismo para entrar y para crear la cuenta.
  Future<void> sendPhoneCode({required String phone, required CodeChannel channel});

  /// Verifica el código. Si el número ya tiene cuenta, entra a esa cuenta; si
  /// es nuevo, la crea (un número, una cuenta). Un código recién verificado
  /// también sirve como confirmación ('otp') de una operación de dinero.
  Future<void> verifyPhoneCode({required String phone, required String code});

  /// Recuperar la cuenta sin el celular: código al correo que la persona
  /// agregó y confirmó en su perfil. No crea cuentas.
  Future<void> sendEmailLoginCode(String email);
  Future<void> verifyEmailLoginCode({required String email, required String code});

  Future<void> signOut();
}

abstract interface class AccountRepository {
  Future<UserProfile> myAccount();

  /// Después del primer código: nombre, ciudad y aceptación de términos.
  Future<void> completeSignup({required String fullName, required int cityId, required bool acceptTerms});
  Future<void> updateProfile({required String fullName, int? cityId});

  /// Foto de perfil (cliente y profesional). Se guarda en la carpeta del
  /// usuario del depósito público `avatars`; el carnet va en otro, privado.
  Future<void> setProfilePhoto({required Uint8List bytes, required String fileName});
  Future<void> removeProfilePhoto();

  /// Cambiar de número: código al número nuevo; al verificarlo, la cuenta
  /// (con sus pedidos y billetera) pasa a entrar con ese número.
  Future<void> requestPhoneChange({required String phone, required CodeChannel channel});
  Future<void> verifyPhoneChange({required String phone, required String code});

  /// Correo opcional (sirve para recuperar la cuenta): se confirma con un código.
  Future<void> requestEmailChange(String email);
  Future<void> verifyEmailChange({required String email, required String code});

  /// Quita el correo (y un cambio pendiente). Se sigue entrando con el celular.
  Future<void> removeEmail();
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

  /// "He llegado": el servidor genera el código y lo devuelve solo al
  /// profesional asignado. Pedir otro invalida el anterior (máximo 3).
  Future<ArrivalPin> markArrived(String bookingId);

  // Cliente
  Future<void> respondQuote(String bookingId, {required bool accept});

  /// "Verificar llegada": solo el cliente del pedido. Un código incorrecto o
  /// vencido no es un error: devuelve el resultado y los intentos que quedan.
  Future<ArrivalCheck> verifyArrivalPin(String bookingId, String pin);
  Future<void> confirmCompletion(String bookingId);
  Future<void> submitReview(String bookingId, int rating, String? comment);

  // Ambos
  Future<void> cancel(String bookingId, String reason);
  Future<void> openDispute(String bookingId, String reason);
  Future<void> acknowledgePayment(String bookingId, PaymentMethod method);

  /// Estado de la llegada (nunca el código).
  Future<BookingArrival> arrival(String bookingId);

  // Ubicación en vivo (solo "en camino" y hasta verificar la llegada).
  /// El profesional manda su posición; false si llegó muy seguido y se ignoró.
  Future<bool> shareTripLocation(String bookingId, GeoPoint point, {int? accuracyM});
  Future<void> stopTripLocation(String bookingId);

  /// Para el cliente: dónde va el profesional, distancia y tiempo estimado.
  Future<TripLocation> tripLocation(String bookingId);

  // Viaje compartido con un contacto de confianza.
  /// Devuelve el código del enlace (se muestra una sola vez).
  Future<String> createTripShare(String bookingId, {String? contactName});
  Future<List<TripShare>> tripShares(String bookingId);
  Future<void> revokeTripShare(int shareId);

  /// Lo que ve el contacto con el enlace, sin cuenta.
  Future<SharedTrip> sharedTrip(String token);
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

  /// Si la cuenta permite confirmar operaciones con huella o rostro.
  Future<bool> biometricEnabled();

  /// Activar exige un código recién verificado ([AuthRepository.verifyPhoneCode]
  /// con el celular de la cuenta); desactivar, no.
  Future<void> setBiometricEnabled(bool enabled, {String authMethod = 'otp'});

  /// Base y radio de trabajo del profesional (privados).
  Future<ServiceLocation?> serviceLocation();
  Future<void> setServiceLocation({required double latitude, required double longitude, required int radiusKm});

  /// Estado de la última verificación de identidad del profesional.
  Future<IdentityCheck> identityCheck();

  /// Pide (o retoma) la verificación de identidad y devuelve el enlace de Didit.
  /// Mientras Didit esté en modo de prueba, [sandbox] es true y el resultado no
  /// cuenta como verificación real.
  Future<({String url, bool sandbox})> startIdentityCheck();
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

  /// Excepción: el equipo verifica una llegada (por el código del pedido) con
  /// un motivo escrito, que queda en la auditoría.
  Future<void> adminVerifyArrival(String bookingCode, String reason);
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

  /// Costos del mes: uso de los planes gratis, cargos, proyección y alertas.
  Future<CostDashboard> costDashboard();

  /// Activa, autoriza o frena un proveedor. Más uso o más gasto exige
  /// [authMethod] confirmado recién; frenar, no.
  Future<void> setVendor(String key, VendorStatus status, {double monthlyCapUsd = 0, String? authMethod});
  Future<int> runCostMonitors();

  /// Exigir una verificación de identidad real para aprobar. Quitar la
  /// exigencia pide [authMethod].
  Future<void> setIdentityCheckRequired(bool required, {String? authMethod});
}

/// Centro de Control IA (solo administradores). Los agentes observan y
/// recomiendan; las decisiones con consecuencias las toma una persona.
abstract interface class AiControlRepository {
  Future<AiOverview> aiOverview();
  Future<List<AiAgent>> aiAgents();

  /// [statuses]: claves de estado (open, pending_approval, completed, ...). Vacío = todos.
  Future<List<AiItem>> aiItems({List<String> statuses = const []});

  /// La lista que abre un número de "Estado general", con su total real.
  Future<Listed<AiItem>> aiCardItems(AiCard card);

  /// Ejecuciones reales de los agentes en las últimas [window] con [status]
  /// ('ok' o 'failed'), del historial.
  Future<AiRuns> aiRuns({required String status, Duration window = const Duration(hours: 24)});

  /// Un aviso con su origen (agente, regla, registro, hora) y su historial.
  Future<AiItemDetail> aiItemDetail(int itemId);

  /// Aprobar exige [authMethod] confirmado recién (como las recargas).
  /// Rechazar, descartar y marcar el resultado exigen [note] (queda auditada).
  Future<void> decideAiItem(int itemId, AiDecision decision, {String? note, String? authMethod});
  Future<List<DailyReport>> dailyReports();
  Future<DailyReport> generateDailyReport();

  /// "Revisar ahora": agentes con reglas, costos y monitores, en el servidor.
  Future<AiCheckResult> runAllChecks();
}

/// Equipo de gestión: Gerente de Operaciones y Empleados. Cada acción la
/// vuelve a autorizar el servidor (hmy_can); ocultar pantallas no alcanza.
abstract interface class StaffRepository {
  /// Rol y permisos de la cuenta actual, como los decide el servidor.
  Future<StaffAccess> myStaffAccess();

  Future<OpsDashboard> opsDashboard();

  /// [scope]: 'mine', 'unassigned', 'escalated', 'escalated_owner', 'urgent'
  /// o 'all'. El empleado recibe solo los suyos.
  Future<List<OpsCase>> opsCases({String scope = 'mine', bool includeResolved = false});
  Future<OpsCaseDetail> opsCaseDetail(int caseId);
  Future<void> assignCase(int caseId, String? userId);
  Future<void> setCaseStatus(int caseId, OpsCaseStatus status, {String? note});
  Future<void> addCaseNote(int caseId, String body);
  Future<void> replyCase(int caseId, String message);

  /// [category]: 'safety', 'fraud' o 'dispute' cuando el caso es eso.
  Future<void> escalateCase(int caseId, String reason, {String? category});
  Future<void> flagDocument(int documentId, String note);
  Future<List<StaffMember>> staffOverview();
  Future<List<StaffActivity>> myStaffActivity();

  /// Solo el propietario: cuentas por nombre o celular (con o sin +591), con
  /// el celular enmascarado y si pueden recibir un rol.
  Future<List<StaffCandidate>> staffCandidates(String query);

  /// Solo el propietario, por el id de una cuenta que ya entró con su celular
  /// (nunca por un número). [authMethod]: código verificado recién ('otp').
  Future<void> grantStaff(String userId, StaffRole role, {required String authMethod});

  /// 'active', 'suspended' o 'revoked'. Suspender o quitar pide un motivo;
  /// reactivar pide [authMethod] (devuelve el acceso).
  Future<void> setStaffStatus(String userId, String status, {String? reason, String? authMethod});
}

/// Finanzas y Bancos: solo el Propietario. El servidor exige is_admin() en
/// cada función; Gerente y Empleado reciben HMY_FORBIDDEN.
abstract interface class FinanceRepository {
  /// [month]: cualquier día del mes a resumir (hora de Bolivia). null = este mes.
  Future<FinanceSummary> financeSummary({DateTime? month});

  /// Libro de las billeteras, del más nuevo al más viejo. [kind]: tipo de
  /// movimiento (topup, commission_capture, ...); [before]: para paginar;
  /// [professionalId]: solo los de esa billetera.
  Future<List<FinanceTransaction>> financeTransactions({
    String? kind,
    int? before,
    int limit = 50,
    String? professionalId,
  });

  /// [bankStatus]: sin_verificar, conciliada, no_encontrada, pendiente o todas.
  Future<List<ReconcileTopup>> topupsForReconciliation(String bankStatus);

  /// Lo que hay detrás de cada tarjeta de Finanzas (0042), con las mismas
  /// definiciones del resumen. [kind]: tipo de movimiento; [month]: cualquier
  /// día del mes (hora de Bolivia), null = todos; [query]: nombre, pedido o
  /// referencia.
  Future<FinanceList<FinanceTransaction>> financeLedger({
    String? kind,
    DateTime? month,
    String query = '',
    String? professionalId,
  });

  /// Recargas por estado y mes de acreditación (null = todos los meses).
  Future<FinanceList<ReconcileTopup>> financeTopups(TopupFilter filter, {DateTime? month, String query = ''});

  /// Marca si una recarga acreditada aparece en el extracto del banco.
  /// Conciliar pide la referencia del banco. [authMethod]: código recién.
  Future<void> reconcileTopup(
    int topupId,
    BankStatus status, {
    String? bankReference,
    int? accountId,
    required String authMethod,
  });

  Future<List<ReceivingAccount>> receivingAccounts();

  /// Crea (id null) o cambia una cuenta de cobro y devuelve su id. Cambiar
  /// banco, titular, número o QR la vuelve a "sin verificar".
  Future<int> saveReceivingAccount(ReceivingAccountDraft draft, {required String authMethod});
  Future<void> setReceivingAccount(int id, {required bool active, required bool verified, required String authMethod});

  /// Sube la imagen del QR de cobro a la carpeta privada del Propietario y
  /// devuelve su ruta.
  Future<String> uploadReceivingQr(PhotoUpload image);

  /// Enlace temporal para ver un QR guardado.
  Future<String?> receivingQrUrl(String path);
  Future<List<FinanceAuditEntry>> financeAudit({int limit = 100});
}

/// Lo que hay detrás de cada número del panel (0041). El servidor decide
/// quién ve qué: pedidos y personas, propietario y gerente (montos solo el
/// propietario); billeteras, solo el propietario.
abstract interface class DrilldownRepository {
  Future<Listed<OpsBooking>> opsBookings(BookingFilter filter, {String query = ''});
  Future<OpsBookingDetail> opsBookingDetail(String bookingId);

  /// Abre (o devuelve el abierto) un caso para revisar el pedido.
  /// [category]: 'routine', 'safety' o 'fraud'.
  Future<int> openBookingCase(String bookingId, String reason, {String category = 'routine'});
  Future<Listed<PersonRow>> adminPeople(PeopleFilter filter, {String query = ''});
  Future<Listed<RiskItem>> riskItems(RiskKind kind);
  Future<WalletList> ownerWallets({String query = '', WalletSort sort = WalletSort.available});
}
