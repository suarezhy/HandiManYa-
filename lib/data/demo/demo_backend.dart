import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../core/utils/app_error.dart';
import '../../core/utils/formatters.dart';
import '../models/admin.dart';
import '../models/ads.dart';
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
import '../repositories/repositories.dart';
import 'demo_agents.dart';
import 'demo_data.dart';

/// Backend en memoria para probar la app sin Supabase. Imita las reglas del
/// servidor (estados, privacidad de la dirección, comisiones) para que el
/// recorrido se sienta real, pero nada se guarda.
///
/// Cuentas de prueba: cliente@demo.bo y profesional@demo.bo, contraseña
/// Demo1234. El código de verificación de correo es 123456.
class DemoBackend
    implements
        AuthRepository,
        AccountRepository,
        CatalogRepository,
        ProfessionalRepository,
        BookingRepository,
        MessagingRepository,
        NotificationRepository,
        ProRepository,
        SafetyRepository,
        AdminRepository,
        StaffRepository,
        DrilldownRepository,
        AiControlRepository,
        FinanceRepository,
        AdsRepository {
  DemoBackend({this.simulateDelays = true, this.codeCooldown = const Duration(seconds: 60)}) {
    _seed();
    _seedAdmin();
    _seedStaff();
  }

  /// En las pruebas automáticas se apaga para que todo sea inmediato.
  final bool simulateDelays;

  /// Espera mínima para pedir otro código al mismo número (como Supabase).
  final Duration codeCooldown;

  /// Solo modo demostración: el código siempre es este y no se envía nada.
  static const demoCode = '123456';
  static const customerPhone = '+59171234567';
  static const professionalPhone = '+59176543210';
  static const adminPhone = '+59170000000';

  /// Equipo de demostración (cuentas ficticias, solo en este modo).
  static const managerPhone = '+59173000001';
  static const employeePhones = ['+59173000011', '+59173000012', '+59173000013', '+59173000014', '+59173000015'];
  static const customerEmail = 'cliente@demo.bo';
  static const professionalEmail = 'profesional@demo.bo';
  static const adminEmail = 'admin@demo.bo';

  final _auth = StreamController<AuthUser?>.broadcast();
  final _changes = StreamController<void>.broadcast();
  final _messageStreams = <String, StreamController<List<ChatMessage>>>{};
  final _rng = Random(7);

  final _accounts = <String, _Account>{};
  final _pros = <String, _Pro>{};
  final _bookings = <String, _Booking>{};
  final _conversations = <String, _Conversation>{};
  final _notifications = <_Note>[];
  final _ledger = <String, List<LedgerEntry>>{};
  final _topups = <String, List<TopupRequest>>{};
  final _timers = <Timer>[];
  _Account? _session;
  int _seq = 1;

  // Administración (solo demostración)
  final _reports = <AdminReport>[];
  final _tickets = <AdminTicket>[];
  final _audit = <AuditEntry>[];
  final _auditActor = _ActorLog();
  final _rules = <CommissionRule>[];
  // Catálogo editable desde el panel. Los profesionales de ejemplo de
  // categorías sensibles se consideran con su documento ya aceptado.
  final _cats = [...DemoData.categories];
  final _problems = [...DemoData.problems];
  final _inactiveCities = <int>{};
  final _promos = <({Promotion promo, bool active})>[];
  final _topupProofs = <int, Uint8List>{};
  final _topupKeys = <String, int>{};
  late final _aiItems = <AiItem>[
    AiItem(
      id: 1,
      agentKey: 'fraud',
      kind: 'approval_request',
      severity: AiSeverity.high,
      status: AiItemStatus.pendingApproval,
      fromAi: true,
      title: 'Revisar una cuenta reportada por varias personas (ejemplo)',
      body: 'Recomendación de IA: revisar a mano los reportes antes de decidir. No es un hecho comprobado.',
      evidence: const {'reportes_30_dias': 3},
      proposedAction: const {'type': 'review_account'},
      createdAt: DateTime.now().subtract(const Duration(hours: 2)),
    ),
    AiItem(
      id: 2,
      agentKey: 'wallet',
      kind: 'alert',
      severity: AiSeverity.medium,
      status: AiItemStatus.open,
      fromAi: false,
      title: 'Recarga esperando verificación hace más de 24 horas (ejemplo)',
      body: 'Recarga de 100 Bs pedida ayer.',
      evidence: const {'topup_id': 1, 'amount': 100},
      dedupeKey: 'topup-late:1',
      targetTable: 'topup_requests',
      targetId: '1',
      createdAt: DateTime.now().subtract(const Duration(hours: 5)),
    ),
    AiItem(
      id: 3,
      agentKey: 'dispatch',
      kind: 'recommendation',
      severity: AiSeverity.medium,
      status: AiItemStatus.open,
      fromAi: false,
      title: 'Pedido ¡Ya! sin profesional (ejemplo)',
      body: 'Sugerencia: ampliar el radio o avisar a más profesionales.',
      dedupeKey: 'ya-unaccepted:demo',
      targetTable: 'bookings',
      targetId: 'demo',
      createdAt: DateTime.now().subtract(const Duration(minutes: 20)),
    ),
  ];

  /// Agentes con su última ejecución. En la demostración nada corre solo:
  /// empiezan sin ejecuciones y "Revisar ahora" las registra, como la base.
  final _agents = {for (final a in demoAgents) a.key: a};
  final _dailyReports = <DailyReport>[];
  final _confirmedAt = <String, DateTime>{};
  final _biometric = <String>{};
  final _consents = <String>{};

  // Como 0062: 10 % del precio acordado, sin reserva mínima.
  static const _ratePercent = 10.0;
  static const _reserveAmount = 0.0;

  static double _commissionOf(double amount) => (amount * _ratePercent).round() / 100;

  void dispose() {
    for (final t in _timers) {
      t.cancel();
    }
  }

  Future<void> _latency([int ms = 250]) => simulateDelays ? Future.delayed(Duration(milliseconds: ms)) : Future.value();

  void _later(Duration d, void Function() fn) {
    if (!simulateDelays) return;
    _timers.add(Timer(d, fn));
  }

  String _id(String prefix) => '$prefix-${_seq++}';

  _Account get _me {
    final s = _session;
    if (s == null) throw const AppError('Ingresa a tu cuenta para continuar.', code: 'HMY_AUTH_REQUIRED');
    return s;
  }

  void _seed() {
    for (final p in DemoData.professionals) {
      final account = _Account(id: p.$1, email: '${p.$1}@demo.bo', fullName: p.$2, cityId: p.$4)
        ..confirmed = true
        ..roles.add(AppRole.professional);
      _accounts[account.email] = account;
      _pros[p.$1] = _Pro(
        id: p.$1,
        displayName: p.$2,
        primaryCategoryId: p.$3,
        cityId: p.$4,
        zoneIds: {...p.$5},
        bio: p.$6,
        years: p.$7,
        priceFrom: p.$8,
        available: p.$9,
        ratingAvg: p.$10,
        ratingCount: p.$11,
        completedJobs: p.$12,
        status: VerificationStatus.approved,
      );
    }

    final customer = _Account(id: 'demo-cliente', email: customerEmail, fullName: 'Carla Rojas', cityId: 1)
      ..phone = customerPhone
      ..confirmed = true;
    _accounts[customer.email] = customer;

    final pro = _Account(id: 'demo-pro', email: professionalEmail, fullName: 'Miguel Ángel Suárez', cityId: 1)
      ..phone = professionalPhone
      ..confirmed = true
      ..roles.add(AppRole.professional)
      ..activeRole = AppRole.professional;
    _accounts[pro.email] = pro;
    _pros[pro.id] = _Pro(
      id: pro.id,
      displayName: 'Miguel Ángel Suárez',
      primaryCategoryId: 2,
      cityId: 1,
      zoneIds: {11, 12},
      bio: 'Electricista con 8 años de experiencia en Santa Cruz.',
      years: 8,
      priceFrom: 80,
      available: false,
      ratingAvg: 4.7,
      ratingCount: 14,
      completedJobs: 18,
      status: VerificationStatus.approved,
      location: const ServiceLocation(latitude: -17.7621, longitude: -63.1848, radiusKm: 8),
    )..documentCount = 2;
    _wallets[pro.id] = [50, 0];
    _ledger[pro.id] = [
      LedgerEntry(
        id: _seq++,
        type: LedgerType.topup,
        availableDelta: 50,
        reservedDelta: 0,
        availableAfter: 50,
        note: 'Recarga de bienvenida (ejemplo)',
        createdAt: DateTime.now().subtract(const Duration(days: 3)),
      ),
    ];
  }

  /// Datos de ejemplo para el panel de administración.
  void _seedAdmin() {
    final admin = _Account(id: 'demo-admin', email: adminEmail, fullName: 'Equipo HandiMan', cityId: 1)
      ..phone = adminPhone
      ..confirmed = true
      ..onboardingDone = true
      ..roles.add(AppRole.admin);
    _accounts[admin.email] = admin;

    final now = DateTime.now();
    for (final (id, name, cat, zone, bio, hours) in [
      (
        'demo-post-1',
        'Rubén Gutiérrez',
        1,
        12,
        'Plomero con 6 años de experiencia. Arreglo fugas y cambio griferías.',
        3,
      ),
      ('demo-post-2', 'Silvia Arancibia', 5, 11, 'Limpieza de casas y oficinas. Llevo mis propios productos.', 20),
    ]) {
      _accounts['$id@demo.bo'] = _Account(id: id, email: '$id@demo.bo', fullName: name, cityId: 1)
        ..confirmed = true
        ..phone = id.endsWith('1') ? '+59170012345' : '+59170054321';
      _pros[id] =
          _Pro(
              id: id,
              displayName: name,
              primaryCategoryId: cat,
              cityId: 1,
              zoneIds: {zone},
              bio: bio,
              years: 6,
              priceFrom: null,
              available: false,
              ratingAvg: 0,
              ratingCount: 0,
              completedJobs: 0,
              status: VerificationStatus.submitted,
            )
            ..submittedAt = now.subtract(Duration(hours: hours))
            ..docs.addAll([_Doc(_seq++, 'ci_anverso'), _Doc(_seq++, 'ci_reverso')])
            ..documentCount = 2
            ..history.add((status: VerificationStatus.submitted, note: null, at: now.subtract(Duration(hours: hours))));
    }

    for (final (pro, amount, ref) in [('p1', 100.0, 'TRX-558210'), ('p3', 50.0, 'QR-90321')]) {
      _wallets.putIfAbsent(pro, () => [40, 0]);
      _topups
          .putIfAbsent(pro, () => [])
          .add(
            TopupRequest(
              id: _seq++,
              amount: amount,
              status: TopupStatus.pending,
              reference: ref,
              createdAt: now.subtract(const Duration(hours: 2)),
            ),
          );
    }

    _reports.add(
      AdminReport(
        id: _seq++,
        reporterName: 'Doña Elena Paz',
        reportedId: 'p6',
        reportedName: 'Wilson Quispe',
        reason: ReportReason.overcharge,
        details: 'Acordamos Bs 150 y al terminar me cobró Bs 250.',
        status: CaseStatus.open,
        createdAt: now.subtract(const Duration(days: 1)),
      ),
    );
    _tickets.add(
      AdminTicket(
        id: _seq++,
        userName: 'Carla Rojas',
        subject: 'No sé cómo cambiar mi ciudad',
        body: 'Me mudé a Cochabamba y quiero ver profesionales de allá.',
        status: TicketStatus.open,
        createdAt: now.subtract(const Duration(hours: 5)),
      ),
    );

    final neighbor = _accounts.putIfAbsent(
      'vecino2@demo.bo',
      () =>
          _Account(id: 'demo-vecino2', email: 'vecino2@demo.bo', fullName: 'Jorge Salvatierra', cityId: 1)
            ..confirmed = true,
    );
    final disputed =
        _Booking(
            id: _id('b'),
            code: 'DSP482',
            customerId: neighbor.id,
            professionalId: 'p4',
            draft: const BookingDraft(
              categoryId: 4,
              cityId: 1,
              mode: BookingMode.now,
              description: 'Pintar el living y el pasillo.',
              address: 'Av. Beni 450',
              zoneId: 11,
              paymentMethod: PaymentMethod.cash,
            ),
            createdAt: now.subtract(const Duration(days: 2)),
          )
          ..status = BookingStatus.disputed
          ..disputeReason = 'Dejó el trabajo a medias y no responde los mensajes.'
          ..disputeOpenedBy = neighbor.id
          ..disputeAt = now.subtract(const Duration(hours: 9));
    disputed.events.add(
      BookingEvent(status: BookingStatus.disputed, note: disputed.disputeReason, at: disputed.disputeAt!),
    );
    _bookings[disputed.id] = disputed;

    _rules.add(CommissionRule(id: _seq++, name: 'Comisión general (10 %)', ratePercent: _ratePercent));
    _promos.addAll([for (final p in DemoData.promotions) (promo: p, active: true)]);
  }

  final _wallets = <String, List<double>>{}; // [disponible, reservado]

  AuthUser _authUser(_Account a) => AuthUser(id: a.id, phone: a.phone, email: a.email.isEmpty ? null : a.email);

  // ================================================================= Auth
  // Como Supabase Auth con ingreso por celular: código de 6 dígitos que vence
  // en 5 minutos, un minuto entre envíos al mismo número, hasta 5 por hora, y
  // el código se anula después de 5 intentos fallidos. Aquí no se envía nada:
  // el código de demostración es siempre [demoCode].
  static const codeExpiry = Duration(minutes: 5);
  static const maxCodeAttempts = 5;
  final _codes = <String, _PendingCode>{};
  final _codeSends = <String, List<DateTime>>{};

  @override
  AuthUser? get currentUser => _session == null ? null : _authUser(_session!);

  @override
  Stream<AuthUser?> authChanges() => _auth.stream;

  void _emitAuth() => _auth.add(currentUser);

  _Account? _byPhone(String phone) => _accounts.values.where((a) => a.phone == phone).firstOrNull;

  void _sendCode(String key, {required String purpose, String? target}) {
    final now = DateTime.now();
    final sends = (_codeSends[key] ??= [])..removeWhere((t) => now.difference(t) > const Duration(hours: 1));
    if (sends.isNotEmpty && now.difference(sends.last) < codeCooldown) {
      final wait = codeCooldown - now.difference(sends.last);
      throw AppError.from('HMY_OTP_TOO_SOON:${wait.inSeconds + 1}');
    }
    if (sends.length >= 5) throw AppError.from('HMY_OTP_LIMIT');
    sends.add(now);
    _codes[key] = _PendingCode(now, purpose, target);
  }

  /// Revisa el código y lo consume si es correcto.
  _PendingCode _checkCode(String key, String code, String purpose) {
    final pending = _codes[key];
    if (pending == null || pending.purpose != purpose || DateTime.now().difference(pending.sentAt) > codeExpiry) {
      _codes.remove(key);
      throw AppError.from('otp_expired');
    }
    if (code.trim() != demoCode) {
      pending.attempts++;
      if (pending.attempts >= maxCodeAttempts) {
        _codes.remove(key);
        throw AppError.from('HMY_OTP_TOO_MANY_ATTEMPTS');
      }
      throw AppError.from('otp_invalid');
    }
    _codes.remove(key);
    return pending;
  }

  /// Como el claim amr "otp": un código recién verificado confirma una operación.
  void _signInWithCode(_Account a) {
    _session = a;
    _confirmedAt[a.id] = DateTime.now();
    _emitAuth();
  }

  @override
  Future<void> sendPhoneCode({required String phone, required CodeChannel channel}) async {
    await _latency();
    if (!RegExp(r'^\+591[67][0-9]{7}$').hasMatch(phone)) throw AppError.from('HMY_INVALID_PHONE');
    _sendCode(phone, purpose: 'login');
  }

  @override
  Future<void> verifyPhoneCode({required String phone, required String code}) async {
    await _latency();
    _checkCode(phone, code, 'login');
    // Un número, una cuenta: si ya existe entra; si no, se crea.
    var a = _byPhone(phone);
    if (a == null) {
      a = _Account(id: _id('u'), fullName: '', termsAccepted: false)
        ..phone = phone
        ..confirmed = true;
      _accounts[phone] = a;
    }
    _signInWithCode(a);
  }

  @override
  Future<void> sendEmailLoginCode(String email) async {
    await _latency();
    final key = email.trim().toLowerCase();
    // Como Supabase: no dice si el correo existe (no crea cuentas).
    _sendCode('email:$key', purpose: 'email-login');
  }

  @override
  Future<void> verifyEmailLoginCode({required String email, required String code}) async {
    await _latency();
    final key = email.trim().toLowerCase();
    _checkCode('email:$key', code, 'email-login');
    final a = _accounts.values.where((a) => a.email == key && a.email.isNotEmpty).firstOrNull;
    if (a == null) throw AppError.from('otp_invalid');
    _signInWithCode(a);
  }

  @override
  Future<void> signOut() async {
    await _latency(100);
    _session = null;
    _emitAuth();
  }

  // ================================================================= Cuenta
  @override
  Future<UserProfile> myAccount() async {
    await _latency(120);
    final a = _me;
    final pro = _pros[a.id];
    return UserProfile(
      id: a.id,
      email: a.email,
      fullName: a.fullName,
      phone: a.phone,
      phoneVerified: a.phone != null,
      emailConfirmed: a.email.isNotEmpty,
      emailPending: a.pendingEmail,
      staffRole: _staffRoleOf(a.id) == StaffRole.owner ? null : _staffRoleOf(a.id),
      staffStatus: _staff[a.id]?.status,
      profileComplete: a.fullName.trim().length >= 3 && a.cityId != null && a.termsAccepted,
      cityId: a.cityId,
      activeRole: a.activeRole,
      roles: {...a.roles},
      professionalStatus: pro?.status ?? VerificationStatus.notStarted,
      onboardingCompleted: a.onboardingDone,
      deletionRequested: a.deletionRequested,
      isSuspended: a.suspendedAt != null,
      suspensionReason: a.suspensionReason,
      blockedIds: {...a.blocked},
      photoBytes: a.photo,
    );
  }

  @override
  Future<void> setProfilePhoto({required Uint8List bytes, required String fileName}) async {
    await _latency();
    if (bytes.isEmpty || bytes.length > 5 * 1024 * 1024) throw AppError.from('HMY_INVALID_PHOTO');
    _me.photo = bytes;
    _changes.add(null);
  }

  @override
  Future<void> removeProfilePhoto() async {
    await _latency();
    _me.photo = null;
    _changes.add(null);
  }

  @override
  Future<void> completeSignup({required String fullName, required int cityId, required bool acceptTerms}) async {
    await _latency();
    final name = fullName.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (name.length < 3 || name.length > 120) throw AppError.from('HMY_INVALID_NAME');
    if (!DemoData.cities.any((c) => c.id == cityId)) throw AppError.from('HMY_INVALID_CITY');
    if (!acceptTerms) throw AppError.from('HMY_TERMS_REQUIRED');
    _me
      ..fullName = name
      ..cityId = cityId
      ..termsAccepted = true;
  }

  @override
  Future<void> updateProfile({required String fullName, int? cityId}) async {
    await _latency();
    _me
      ..fullName = fullName.trim()
      ..cityId = cityId;
  }

  @override
  Future<void> requestPhoneChange({required String phone, required CodeChannel channel}) async {
    await _latency();
    final me = _me;
    if (!RegExp(r'^\+591[67][0-9]{7}$').hasMatch(phone)) throw AppError.from('HMY_INVALID_PHONE');
    if (phone == me.phone) throw AppError.from('HMY_SAME_PHONE');
    if (_byPhone(phone) != null) throw AppError.from('phone_exists');
    _sendCode('change:${me.id}', purpose: 'phone-change', target: phone);
  }

  @override
  Future<void> verifyPhoneChange({required String phone, required String code}) async {
    await _latency();
    final me = _me;
    final pending = _checkCode('change:${me.id}', code, 'phone-change');
    if (pending.target != phone) throw AppError.from('otp_invalid');
    if (_byPhone(phone) != null) throw AppError.from('phone_exists');
    me.phone = phone;
    _log('auth.phone_changed', 'profiles', me.id);
    _emitAuth();
  }

  @override
  Future<void> requestEmailChange(String email) async {
    await _latency();
    final key = email.trim().toLowerCase();
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(key)) throw AppError.from('HMY_INVALID_EMAIL');
    if (key == _me.email) throw AppError.from('HMY_SAME_EMAIL');
    if (_accounts.values.any((a) => a.email == key && a.id != _me.id)) throw AppError.from('email_exists');
    _sendCode('email-change:${_me.id}', purpose: 'email-change', target: key);
    _me.pendingEmail = key;
  }

  @override
  Future<void> verifyEmailChange({required String email, required String code}) async {
    await _latency();
    final me = _me;
    final pending = _checkCode('email-change:${me.id}', code, 'email-change');
    if (pending.target != email.trim().toLowerCase()) throw AppError.from('otp_invalid');
    me.email = pending.target!;
    me.pendingEmail = null;
    _emitAuth();
  }

  @override
  Future<void> removeEmail() async {
    await _latency();
    final me = _me;
    // Como en Supabase (remove_my_email): sin celular la cuenta quedaría sin
    // forma de entrar.
    if (me.phone == null) throw AppError.from('HMY_PHONE_REQUIRED');
    me.email = '';
    me.pendingEmail = null;
    _emitAuth();
  }

  @override
  Future<void> setActiveRole(AppRole role) async {
    await _latency();
    final a = _me;
    if (!a.roles.contains(role)) throw AppError.from('HMY_ROLE_NOT_GRANTED');
    if (role == AppRole.professional && _pros[a.id]?.status != VerificationStatus.approved) {
      throw AppError.from('HMY_PROFESSIONAL_NOT_APPROVED');
    }
    a.activeRole = role;
  }

  @override
  Future<void> completeOnboarding() async => _me.onboardingDone = true;

  @override
  Future<void> requestAccountDeletion() async {
    await _latency();
    _me.deletionRequested = true;
  }

  // ================================================================= Catálogo
  @override
  Future<List<City>> cities() async => DemoData.cities.where((c) => !_inactiveCities.contains(c.id)).toList();

  @override
  Future<List<Zone>> zones(int cityId) async => DemoData.zones.where((z) => z.cityId == cityId).toList();

  @override
  Future<List<ServiceCategory>> categories() async =>
      (_cats.where((c) => c.isActive).toList()..sort((a, b) => a.sortOrder.compareTo(b.sortOrder)));

  @override
  Future<List<ServiceProblem>> problems(int categoryId) async {
    await _latency(100);
    return _problems.where((p) => p.categoryId == categoryId && p.isActive).toList()..sort(_byOrder);
  }

  static int _byOrder(ServiceProblem a, ServiceProblem b) =>
      a.sortOrder != b.sortOrder ? a.sortOrder.compareTo(b.sortOrder) : a.id.compareTo(b.id);

  /// Igual que `hmy_problem_labels` en la base: valida y arma las etiquetas.
  List<String> _problemLabels(int categoryId, List<int> ids, String? otherText) {
    final unique = ids.toSet().toList();
    final other = (otherText ?? '').trim();
    if (unique.isEmpty) {
      if (other.isNotEmpty) throw AppError.from('HMY_INVALID_PROBLEM');
      return const [];
    }
    if (unique.length > 8) throw AppError.from('HMY_TOO_MANY_PROBLEMS');
    final chosen = _problems.where((p) => unique.contains(p.id) && p.categoryId == categoryId && p.isActive).toList();
    if (chosen.length != unique.length) throw AppError.from('HMY_INVALID_PROBLEM');
    final hasOther = chosen.any((p) => p.isOther);
    if (hasOther && other.length < 3) throw AppError.from('HMY_OTHER_REQUIRED');
    if (!hasOther && other.isNotEmpty) throw AppError.from('HMY_INVALID_PROBLEM');
    chosen.sort((a, b) => a.isOther != b.isOther ? (a.isOther ? 1 : -1) : _byOrder(a, b));
    return [
      for (final p in chosen) p.isOther ? '${p.name}: ${other.length > 200 ? other.substring(0, 200) : other}' : p.name,
    ];
  }

  @override
  Future<List<Promotion>> promotions(int? cityId) async => [
    for (final p in _promos)
      if (p.active) p.promo,
  ];

  // ================================================================= Profesionales
  ServiceCategory _cat(int id) => _cats.firstWhere((c) => c.id == id);
  String _catName(int id) => _cat(id).name;
  String _cityName(int id) => DemoData.cities.firstWhere((c) => c.id == id).name;
  String _zoneName(int id) => DemoData.zones.firstWhere((z) => z.id == id).name;

  static String _norm(String s) {
    const from = 'áéíóúüñÁÉÍÓÚÜÑ';
    const to = 'aeiouunAEIOUUN';
    final b = StringBuffer();
    for (final ch in s.split('')) {
      final i = from.indexOf(ch);
      b.write(i >= 0 ? to[i] : ch);
    }
    return b.toString().toLowerCase();
  }

  ProfessionalSummary _summary(_Pro p) => ProfessionalSummary(
    id: p.id,
    displayName: p.displayName,
    primaryCategoryId: p.primaryCategoryId,
    primaryCategory: _catName(p.primaryCategoryId),
    specialties: [_catName(p.primaryCategoryId)],
    city: _cityName(p.cityId),
    zones: [for (final z in p.zoneIds) _zoneName(z)],
    ratingAvg: p.ratingAvg,
    ratingCount: p.ratingCount,
    completedJobs: p.completedJobs,
    isAvailable: p.available,
    priceFrom: p.priceFrom,
    isVerified: p.status == VerificationStatus.approved,
    rankTier: _rankOf(p),
  );

  /// Las mismas reglas que el servidor (0063), con los datos de ejemplo.
  static RankTier _rankOf(_Pro p) {
    if (p.status != VerificationStatus.approved) return RankTier.none;
    bool meets(int jobs, int reviews, double rating) =>
        p.completedJobs >= jobs && p.ratingCount >= reviews && p.ratingAvg >= rating;
    if (meets(150, 100, 4.8)) return RankTier.diamante;
    if (meets(50, 30, 4.6)) return RankTier.oro;
    if (meets(10, 8, 4.3)) return RankTier.plata;
    return RankTier.none;
  }

  @override
  Future<List<ProfessionalSummary>> search(SearchFilters f, {int limit = 20, int offset = 0}) async {
    await _latency(300);
    final q = _norm(f.query.trim());
    final me = _session?.id;
    var list = _pros.values.where((p) {
      if (p.status != VerificationStatus.approved || p.id == me) return false;
      if (f.cityId != null && p.cityId != f.cityId) return false;
      if (f.categoryId != null && p.primaryCategoryId != f.categoryId) return false;
      if (f.zoneId != null && !p.zoneIds.contains(f.zoneId)) return false;
      if (f.availableNow && !p.available) return false;
      if (f.minRating != null && p.ratingAvg < f.minRating!) return false;
      if (q.isNotEmpty) {
        final hay = _norm(
          '${p.displayName} ${_catName(p.primaryCategoryId)} ${_cityName(p.cityId)} '
          '${p.zoneIds.map(_zoneName).join(' ')}',
        );
        if (!hay.contains(q)) return false;
      }
      return true;
    }).toList();
    int byAvail(_Pro a, _Pro b) => (b.available ? 1 : 0) - (a.available ? 1 : 0);
    switch (f.sort) {
      case SortOption.rating:
        list.sort((a, b) => b.ratingAvg.compareTo(a.ratingAvg));
      case SortOption.available:
        list.sort((a, b) => byAvail(a, b) != 0 ? byAvail(a, b) : a.displayName.compareTo(b.displayName));
      case SortOption.recommended:
        double score(_Pro p) => p.ratingAvg * log(p.ratingCount + 2);
        list.sort((a, b) => byAvail(a, b) != 0 ? byAvail(a, b) : score(b).compareTo(score(a)));
    }
    return list.skip(offset).take(limit).map(_summary).toList();
  }

  @override
  Future<ProfessionalDetail?> professionalDetail(String id) async {
    await _latency();
    final p = _pros[id];
    if (p == null || p.status != VerificationStatus.approved) return null;
    return ProfessionalDetail(
      summary: _summary(p),
      bio: p.bio,
      yearsExperience: p.years,
      priceNote: 'Precio final según el trabajo. Visita de diagnóstico sin costo si se realiza el trabajo.',
      services: [
        ProService(
          categoryId: p.primaryCategoryId,
          category: _catName(p.primaryCategoryId),
          specialty: _catName(p.primaryCategoryId),
          priceFrom: p.priceFrom,
        ),
      ],
      availability: const [
        AvailabilitySlot(weekday: 1, start: '08:00:00', end: '18:00:00'),
        AvailabilitySlot(weekday: 2, start: '08:00:00', end: '18:00:00'),
        AvailabilitySlot(weekday: 3, start: '08:00:00', end: '18:00:00'),
        AvailabilitySlot(weekday: 4, start: '08:00:00', end: '18:00:00'),
        AvailabilitySlot(weekday: 5, start: '08:00:00', end: '18:00:00'),
        AvailabilitySlot(weekday: 6, start: '09:00:00', end: '13:00:00'),
      ],
    );
  }

  @override
  Future<List<Review>> reviews(String professionalId) async {
    await _latency();
    final p = _pros[professionalId];
    if (p == null || p.ratingCount == 0) return const [];
    const samples = [
      (5, 'Muy puntual y prolijo. Lo recomiendo.', 'María'),
      (5, 'Resolvió el problema rápido y dejó todo limpio.', 'Jorge'),
      (4, 'Buen trabajo, llegó un poco tarde pero avisó.', 'Lucía'),
    ];
    return [
      for (var i = 0; i < samples.length; i++)
        Review(
          id: i,
          rating: samples[i].$1,
          comment: samples[i].$2,
          authorFirstName: samples[i].$3,
          createdAt: DateTime.now().subtract(Duration(days: 4 + i * 9)),
        ),
      ...p.realReviews,
    ];
  }

  Iterable<_Pro> _eligible(
    int categoryId,
    int cityId,
    int? zoneId,
    String customerId, {
    double? latitude,
    double? longitude,
    bool needsAvailable = true,
  }) => _pros.values.where((p) {
    if (p.status != VerificationStatus.approved || (needsAvailable && !p.available) || p.id == customerId) {
      return false;
    }
    if (_blockedBetween(p.id, customerId)) return false;
    if (p.primaryCategoryId != categoryId) return false;
    final base = p.location;
    // Igual que el servidor: con ubicación manda el radio (aunque el profesional
    // esté registrado en otro municipio); sin ella, el municipio y la zona.
    if (latitude != null && longitude != null && base != null) {
      return distanceKm(latitude, longitude, base.latitude, base.longitude) <= base.radiusKm;
    }
    return p.cityId == cityId && (zoneId == null || p.zoneIds.isEmpty || p.zoneIds.contains(zoneId));
  });

  double? _distanceFor(String proId, BookingDraft d) {
    final base = _pros[proId]?.location;
    if (base == null || d.latitude == null || d.longitude == null) return null;
    // Como el servidor: se mide desde el punto aproximado (~1 km).
    double round2(double v) => (v * 100).roundToDouble() / 100;
    final km = distanceKm(round2(d.latitude!), round2(d.longitude!), base.latitude, base.longitude);
    return (km * 10).roundToDouble() / 10;
  }

  @override
  Future<HomeMapData> homeMap(int cityId) async {
    await _latency(200);
    final city = DemoData.cities.firstWhere((c) => c.id == cityId);
    final me = _session?.id;
    final rnd = Random(cityId);
    final pros = _pros.values
        .where((p) => p.status == VerificationStatus.approved && p.available && p.id != me && p.cityId == cityId)
        .toList();
    return HomeMapData(
      cityName: city.name,
      cityLatitude: city.latitude,
      cityLongitude: city.longitude,
      professionals: [
        if (city.latitude != null && city.longitude != null)
          for (final p in pros)
            MapProfessional(
              id: p.id,
              displayName: p.displayName,
              category: _catName(p.primaryCategoryId),
              ratingAvg: p.ratingAvg,
              ratingCount: p.ratingCount,
              // Como el servidor: un punto aproximado, nunca la ubicación.
              latitude: city.latitude! + (rnd.nextDouble() - 0.5) * 0.06,
              longitude: city.longitude! + (rnd.nextDouble() - 0.5) * 0.06,
            ),
      ],
    );
  }

  @override
  Future<int> countYaAvailable({
    required int categoryId,
    required int cityId,
    int? zoneId,
    double? latitude,
    double? longitude,
  }) async {
    await _latency(150);
    return _eligible(categoryId, cityId, zoneId, _session?.id ?? '', latitude: latitude, longitude: longitude).length;
  }

  // ================================================================= Solicitudes
  void _notify(String userId, String kind, String title, String body, {String? bookingId, String? conversationId}) {
    _notifications.insert(
      0,
      _Note(
        AppNotification(
          id: _seq++,
          kind: kind,
          title: title,
          body: body,
          bookingId: bookingId,
          conversationId: conversationId,
          createdAt: DateTime.now(),
        ),
        userId,
      ),
    );
    _changes.add(null);
  }

  void _move(_Booking b, BookingStatus to, {String? note, required String actorId}) {
    // Al salir de "en camino" (cancelación, disputa), el código deja de servir.
    if (b.status == BookingStatus.onTheWay) b.pinVerifier = null;
    if (to != BookingStatus.onTheWay) _trips.remove(b.id);
    b.status = to;
    b.events.add(BookingEvent(status: to, note: note, at: DateTime.now()));
    b.actors[b.events.length - 1] = actorId;
    if (to == BookingStatus.confirmed) {
      _reserve(b);
      final c = _Conversation(
        id: _id('c'),
        bookingId: b.id,
        customerId: b.customerId,
        professionalId: b.professionalId!,
      );
      _conversations[c.id] = c;
      b.conversationId = c.id;
    } else if (to == BookingStatus.completed) {
      _capture(b);
      _pros[b.professionalId]?.completedJobs++;
    } else if (to == BookingStatus.cancelled) {
      _release(b);
    }
    final title = 'Solicitud ${b.code}: ${to.label}';
    if (actorId != b.customerId) _notify(b.customerId, 'booking_status', title, note ?? '', bookingId: b.id);
    if (b.professionalId != null && actorId != b.professionalId) {
      _notify(b.professionalId!, 'booking_status', title, note ?? '', bookingId: b.id);
    }
    _changes.add(null);
  }

  void _post(String proId, LedgerType type, double avail, double reserved, String note) {
    final w = _wallets.putIfAbsent(proId, () => [0, 0]);
    w[0] += avail;
    w[1] += reserved;
    _ledger
        .putIfAbsent(proId, () => [])
        .insert(
          0,
          LedgerEntry(
            id: _seq++,
            type: type,
            availableDelta: avail,
            reservedDelta: reserved,
            availableAfter: w[0],
            note: note,
            createdAt: DateTime.now(),
          ),
        );
  }

  /// Como 0062: al acordar se reserva el 10 % del precio acordado.
  void _reserve(_Booking b) {
    final pro = b.professionalId!;
    if (!_wallets.containsKey(pro)) return; // profesionales de ejemplo sin billetera simulada
    final fee = _commissionOf(b.agreedAmount ?? 0);
    if (fee <= 0) return;
    if (_wallets[pro]![0] < fee) throw AppError.from('HMY_INSUFFICIENT_BALANCE');
    _post(pro, LedgerType.commissionReserve, -fee, fee, 'Reserva de comisión ${b.code}');
    b.reserved = fee;
  }

  /// Al completar se cobra el 10 % del monto final, hasta lo reservado.
  void _capture(_Booking b) {
    if (b.reserved == 0 || b.captured) return;
    final fee = min(_commissionOf(b.finalAmount ?? b.agreedAmount ?? 0), b.reserved);
    _post(b.professionalId!, LedgerType.commissionCapture, b.reserved - fee, -b.reserved, 'Comisión ${b.code}');
    b
      ..reserved = 0
      ..captured = true;
  }

  void _release(_Booking b) {
    if (b.reserved == 0 || b.captured) return;
    _post(b.professionalId!, LedgerType.commissionRelease, b.reserved, -b.reserved, 'Liberación de comisión ${b.code}');
    b.reserved = 0;
  }

  _Booking _get(String id) {
    final b = _bookings[id];
    if (b == null) throw AppError.from('HMY_NOT_FOUND');
    return b;
  }

  void _requireStatus(_Booking b, Set<BookingStatus> allowed) {
    if (!allowed.contains(b.status)) throw AppError.from('HMY_INVALID_TRANSITION');
  }

  @override
  Future<String> create(BookingDraft input) async {
    await _latency(500);
    final me = _me;
    final labels = _problemLabels(input.categoryId, input.problemIds, input.otherText);
    // Como el servidor: Grúa exige el destino y nadie más lo acepta; una
    // opción que solo lleva a otra categoría no se pide.
    final tow = _cats.where((c) => c.id == input.categoryId).firstOrNull?.slug == 'grua';
    final destination = (input.destination ?? '').trim();
    if (_problems.any((p) => input.problemIds.contains(p.id) && p.opensCategoryId != null)) {
      throw AppError.from('HMY_INVALID_PROBLEM');
    }
    if (tow && destination.length < 3) throw AppError.from('HMY_DESTINATION_REQUIRED');
    if (!tow && destination.isNotEmpty) throw AppError.from('HMY_INVALID_PROBLEM');
    if (input.isYa && !(_cats.where((c) => c.id == input.categoryId).firstOrNull?.allowsYa ?? true)) {
      throw AppError.from('HMY_YA_NOT_ALLOWED');
    }
    final d = input.description.trim().isNotEmpty || labels.isEmpty
        ? input
        : BookingDraft(
            categoryId: input.categoryId,
            cityId: input.cityId,
            mode: input.mode,
            description: labels.join('. '),
            address: input.address,
            addressReference: input.addressReference,
            zoneId: input.zoneId,
            professionalId: input.professionalId,
            scheduledStart: input.scheduledStart,
            durationMinutes: input.durationMinutes,
            paymentMethod: input.paymentMethod,
            latitude: input.latitude,
            longitude: input.longitude,
            problemIds: input.problemIds,
            otherText: input.otherText,
            destination: input.destination,
            budget: input.budget,
          );
    if (me.suspendedAt != null) throw AppError.from('HMY_ACCOUNT_SUSPENDED');
    if (d.professionalId == me.id) throw AppError.from('HMY_CANNOT_BOOK_SELF');
    if (d.professionalId != null && _blockedBetween(me.id, d.professionalId!)) throw AppError.from('HMY_BLOCKED');
    final b = _Booking(
      id: _id('b'),
      code: List.generate(6, (_) => 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'[_rng.nextInt(31)]).join(),
      customerId: me.id,
      professionalId: d.professionalId,
      draft: d,
      createdAt: DateTime.now(),
    )..problems = labels;

    if (d.isYa) {
      final eligible = _eligible(
        d.categoryId,
        d.cityId,
        d.zoneId,
        me.id,
        latitude: d.latitude,
        longitude: d.longitude,
      ).toList();
      if (eligible.isEmpty) {
        throw const AppError(
          'No hay profesionales disponibles ahora para este servicio en tu zona. Prueba en otra zona o programa para después.',
          code: 'HMY_NO_PROFESSIONALS_AVAILABLE',
        );
      }
      b
        ..status = BookingStatus.awaitingResponse
        ..offers = {for (final p in eligible) p.id}
        ..events.add(BookingEvent(status: BookingStatus.awaitingResponse, at: DateTime.now()));
      _bookings[b.id] = b;
      for (final p in eligible) {
        _notify(p.id, 'ya_offer', '¡Pedido ¡Ya! cerca de ti!', d.description, bookingId: b.id);
      }
      // Simula que el primer profesional disponible responde en unos segundos:
      // acepta el precio del cliente o, si no puso, propone el suyo.
      final winner = eligible.firstWhere((p) => p.id != 'demo-pro', orElse: () => eligible.first);
      if (winner.id != 'demo-pro') {
        _later(const Duration(seconds: 5), () {
          if (b.status != BookingStatus.awaitingResponse) return;
          final budget = _openOffer(b, null, byCustomer: true);
          if (budget == null) {
            _addOffer(b, winner.id, byCustomer: false, kind: PriceKind.service, amount: 150, authorId: winner.id);
            _changes.add(null);
            return;
          }
          _agree(b, budget, winner.id);
          _assign(b, winner.id, 'Precio acordado: ${Fmt.bs(budget.amount)}', actorId: winner.id);
          _later(const Duration(seconds: 2), () {
            _sendAs(
              b.conversationId!,
              winner.id,
              '¡Hola! Soy ${winner.displayName.split(' ').first}. Ya vi tu pedido, salgo para allá en unos minutos.',
            );
          });
        });
      }
    } else if (d.mode == BookingMode.scheduled && d.professionalId == null) {
      // Como el servidor (0055): queda "Pendiente de profesional" y le llega a
      // los profesionales de la zona, aunque no estén disponibles ahora. Nadie
      // la acepta solo en la demostración.
      final start = d.scheduledStart;
      final now = DateTime.now();
      if (start == null ||
          start.isBefore(now.add(const Duration(minutes: 30))) ||
          start.isAfter(now.add(const Duration(days: 60))) ||
          d.durationMinutes < 30 ||
          d.durationMinutes > 720) {
        throw AppError.from('HMY_INVALID_SCHEDULE');
      }
      final end = start.add(Duration(minutes: d.durationMinutes));
      final duplicate = _bookings.values.any(
        (o) =>
            o.customerId == me.id &&
            o.draft.categoryId == d.categoryId &&
            o.draft.mode == BookingMode.scheduled &&
            o.draft.scheduledStart != null &&
            {BookingStatus.requested, BookingStatus.awaitingResponse, BookingStatus.quoteSent}.contains(o.status) &&
            o.draft.scheduledStart!.isBefore(end) &&
            o.draft.scheduledStart!.add(Duration(minutes: o.draft.durationMinutes)).isAfter(start),
      );
      if (duplicate) throw AppError.from('HMY_DUPLICATE_REQUEST');
      final eligible = _eligible(
        d.categoryId,
        d.cityId,
        d.zoneId,
        me.id,
        latitude: d.latitude,
        longitude: d.longitude,
        needsAvailable: false,
      ).toList();
      b
        ..status = BookingStatus.awaitingResponse
        ..offers = {for (final p in eligible) p.id}
        ..events.add(BookingEvent(status: BookingStatus.awaitingResponse, at: DateTime.now()));
      _bookings[b.id] = b;
      for (final p in eligible) {
        _notify(p.id, 'booking_new', 'Solicitud programada cerca de ti', d.description, bookingId: b.id);
      }
    } else {
      final pro = _pros[d.professionalId];
      if (pro == null || pro.status != VerificationStatus.approved) {
        throw AppError.from('HMY_PROFESSIONAL_NOT_AVAILABLE');
      }
      if (d.mode == BookingMode.now && !pro.available) throw AppError.from('HMY_PROFESSIONAL_NOT_AVAILABLE');
      if (d.mode == BookingMode.scheduled) {
        final start = d.scheduledStart;
        if (start == null || start.isBefore(DateTime.now().add(const Duration(minutes: 30)))) {
          throw AppError.from('HMY_INVALID_SCHEDULE');
        }
        final end = start.add(Duration(minutes: d.durationMinutes));
        final clash = _bookings.values.any(
          (o) =>
              o.professionalId == pro.id &&
              o.draft.mode == BookingMode.scheduled &&
              {BookingStatus.confirmed, BookingStatus.onTheWay, BookingStatus.inProgress}.contains(o.status) &&
              o.draft.scheduledStart!.isBefore(end) &&
              o.draft.scheduledStart!.add(Duration(minutes: o.draft.durationMinutes)).isAfter(start),
        );
        if (clash) throw AppError.from('HMY_SLOT_TAKEN');
      }
      b
        ..status = BookingStatus.requested
        ..events.add(BookingEvent(status: BookingStatus.requested, at: DateTime.now()));
      _bookings[b.id] = b;
      _notify(
        pro.id,
        'booking_new',
        d.mode == BookingMode.now ? '¡Nueva solicitud para ahora!' : 'Nueva solicitud programada',
        d.description,
        bookingId: b.id,
      );
      if (pro.id != 'demo-pro') {
        _later(const Duration(seconds: 6), () {
          if (b.status != BookingStatus.requested) return;
          final budget = _openOffer(b, pro.id, byCustomer: true);
          if (budget == null) {
            _addOffer(b, pro.id, byCustomer: false, kind: PriceKind.service, amount: 150, authorId: pro.id);
            _move(b, BookingStatus.quoteSent, note: 'Propuesta de precio: ${Fmt.bs(150)}', actorId: pro.id);
            return;
          }
          _agree(b, budget, pro.id);
          _move(b, BookingStatus.confirmed, note: 'Precio acordado: ${Fmt.bs(budget.amount)}', actorId: pro.id);
        });
      }
    }
    if (d.budget != null) {
      if (d.budget! <= 0 || d.budget! > 100000) throw AppError.from('HMY_INVALID_AMOUNT');
      _addOffer(b, b.professionalId, byCustomer: true, kind: PriceKind.service, amount: d.budget!, authorId: me.id);
    }
    _changes.add(null);
    return b.id;
  }

  BookingSummary _toSummary(_Booking b, {required bool asProfessional}) {
    final pro = b.professionalId == null ? null : _pros[b.professionalId];
    final customer = _accounts.values.firstWhere((a) => a.id == b.customerId);
    return BookingSummary(
      id: b.id,
      code: b.code,
      status: b.status,
      mode: b.draft.mode,
      categoryId: b.draft.categoryId,
      category: _catName(b.draft.categoryId),
      city: _cityName(b.draft.cityId),
      zone: b.draft.zoneId == null ? null : _zoneName(b.draft.zoneId!),
      description: b.draft.description,
      scheduledStart: b.draft.scheduledStart,
      createdAt: b.createdAt,
      otherUserId: asProfessional ? b.customerId : b.professionalId,
      otherName: asProfessional ? customer.fullName.split(' ').first : pro?.displayName,
      quoteAmount: b.quoteAmount,
      finalAmount: b.finalAmount,
      hasReview: b.hasReview,
      isOffer: b.professionalId == null,
      distanceKm: asProfessional ? _distanceFor(_me.id, b.draft) : null,
      problems: b.problems,
      agreedAmount: b.agreedAmount,
      extrasAmount: b.extras,
    );
  }

  @override
  Future<List<BookingSummary>> myBookings({required bool asProfessional}) async {
    await _latency(200);
    final me = _me.id;
    final list =
        _bookings.values
            .where(
              (b) => asProfessional
                  ? (b.professionalId == me || (b.status == BookingStatus.awaitingResponse && b.offers.contains(me)))
                  : b.customerId == me,
            )
            .toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return [for (final b in list) _toSummary(b, asProfessional: asProfessional)];
  }

  @override
  Future<BookingDetail> detail(String bookingId) async {
    await _latency(200);
    final me = _me.id;
    final b = _get(bookingId);
    final isCustomer = b.customerId == me;
    final isOffer = b.status == BookingStatus.awaitingResponse && b.offers.contains(me);
    if (!isCustomer && b.professionalId != me && !isOffer) throw AppError.from('HMY_NOT_FOUND');
    final pro = b.professionalId == null ? null : _pros[b.professionalId];
    final customer = _accounts.values.firstWhere((a) => a.id == b.customerId);
    final addressVisible =
        isCustomer ||
        (b.professionalId == me &&
            {
              BookingStatus.confirmed,
              BookingStatus.onTheWay,
              BookingStatus.inProgress,
              BookingStatus.workFinished,
              BookingStatus.disputed,
            }.contains(b.status));
    return BookingDetail(
      id: b.id,
      code: b.code,
      status: b.status,
      mode: b.draft.mode,
      categoryId: b.draft.categoryId,
      category: _catName(b.draft.categoryId),
      city: _cityName(b.draft.cityId),
      zone: b.draft.zoneId == null ? null : _zoneName(b.draft.zoneId!),
      description: b.draft.description,
      scheduledStart: b.draft.scheduledStart,
      quoteAmount: b.quoteAmount,
      quoteNote: b.quoteNote,
      finalAmount: b.finalAmount,
      paymentMethod: b.paidWith ?? b.draft.paymentMethod,
      customerPaidAck: b.customerPaid,
      professionalPaidAck: b.professionalPaid,
      createdAt: b.createdAt,
      cancelReason: b.status == BookingStatus.cancelled ? b.events.last.note : null,
      viewerIsCustomer: isCustomer,
      isOffer: b.professionalId == null,
      customerId: b.customerId,
      customerFirstName: customer.fullName.split(' ').first,
      professional: pro == null
          ? null
          : BookingProfessional(
              id: pro.id,
              displayName: pro.displayName,
              ratingAvg: pro.ratingAvg,
              ratingCount: pro.ratingCount,
              isVerified: true,
            ),
      address: addressVisible
          ? BookingAddress(
              line: b.draft.address,
              reference: b.draft.addressReference,
              latitude: b.draft.latitude,
              longitude: b.draft.longitude,
              destination: b.draft.destination,
            )
          : null,
      conversationId: b.conversationId,
      hasReview: b.hasReview,
      offersSent: isCustomer ? b.offersCount : null,
      events: List.of(b.events),
      distanceKm: isCustomer ? null : _distanceFor(me, b.draft),
      photos: List.of(b.photos),
      problems: b.problems,
      safetyNote: _cat(b.draft.categoryId).safetyNote,
      price: BookingPrice(
        agreedAmount: b.agreedAmount,
        agreedKind: b.agreedKind,
        extrasAmount: b.extras,
        offers: [
          for (final o in b.priceOffers)
            if (isCustomer || o.professionalId == null || o.professionalId == me)
              PriceOffer(
                id: o.id,
                professionalId: o.professionalId,
                byCustomer: o.byCustomer,
                kind: o.kind,
                amount: o.amount,
                note: o.note,
                status: o.status,
                createdAt: o.createdAt,
                professional: isCustomer && o.professionalId != null && _pros[o.professionalId] != null
                    ? BookingProfessional(
                        id: o.professionalId!,
                        displayName: _pros[o.professionalId]!.displayName,
                        ratingAvg: _pros[o.professionalId]!.ratingAvg,
                        ratingCount: _pros[o.professionalId]!.ratingCount,
                        isVerified: true,
                      )
                    : null,
              ),
        ],
      ),
    );
  }

  @override
  Stream<void> changes() => _changes.stream;

  @override
  Future<void> decline(String bookingId, {required bool isOffer, String? reason}) async {
    await _latency();
    final me = _me.id;
    final b = _get(bookingId);
    if (isOffer) {
      b.offers.remove(me);
      _changes.add(null);
      return;
    }
    if (b.professionalId != me) throw AppError.from('HMY_FORBIDDEN');
    _requireStatus(b, {BookingStatus.requested});
    _move(b, BookingStatus.cancelled, note: reason ?? 'El profesional no puede atender esta solicitud', actorId: me);
  }

  // ---------------------------------------------------------------- Precio
  // Como 0062: propuestas y contraofertas hasta que uno acepta la del otro.
  _DemoOffer _addOffer(
    _Booking b,
    String? professionalId, {
    required bool byCustomer,
    required PriceKind kind,
    required double amount,
    required String authorId,
    String? note,
  }) {
    for (final o in b.priceOffers) {
      if (o.status == OfferStatus.open && o.professionalId == professionalId && o.kind.beforeJob == kind.beforeJob) {
        o.status = OfferStatus.superseded;
      }
    }
    final o = _DemoOffer(
      id: _seq++,
      professionalId: professionalId,
      byCustomer: byCustomer,
      authorId: authorId,
      kind: kind,
      amount: (amount * 100).round() / 100,
      note: note,
    );
    b.priceOffers.add(o);
    return o;
  }

  _DemoOffer? _openOffer(_Booking b, String? professionalId, {required bool byCustomer}) => b.priceOffers.reversed
      .where(
        (o) =>
            o.status == OfferStatus.open &&
            o.professionalId == professionalId &&
            o.byCustomer == byCustomer &&
            o.kind.beforeJob,
      )
      .firstOrNull;

  String? _priceRole(_Booking b, String me) {
    if (b.customerId == me) return 'customer';
    if (b.professionalId == me) return 'professional';
    if (b.professionalId == null && b.status == BookingStatus.awaitingResponse && b.offers.contains(me)) {
      return 'professional';
    }
    return null;
  }

  bool _beforeJob(_Booking b) =>
      b.agreedAmount == null &&
      {BookingStatus.requested, BookingStatus.awaitingResponse, BookingStatus.quoteSent}.contains(b.status);

  void _agree(_Booking b, _DemoOffer o, String by) {
    o.status = OfferStatus.accepted;
    for (final x in b.priceOffers) {
      if (x != o && x.status == OfferStatus.open && x.kind.beforeJob) x.status = OfferStatus.expired;
    }
    b
      ..agreedAmount = o.amount
      ..agreedKind = o.kind
      ..quoteAmount = o.amount
      ..quoteNote = o.note;
  }

  void _assign(_Booking b, String pro, String note, {required String actorId}) {
    b
      ..professionalId = pro
      ..offers = {};
    _move(b, BookingStatus.confirmed, note: note, actorId: actorId);
  }

  @override
  Future<int> proposePrice(
    String bookingId,
    double amount, {
    PriceKind kind = PriceKind.service,
    String? note,
    String? professionalId,
  }) async {
    await _latency();
    final me = _me.id;
    final b = _get(bookingId);
    final role = _priceRole(b, me);
    if (role == null) throw AppError.from('HMY_FORBIDDEN');
    if (amount <= 0 || amount > 100000) throw AppError.from('HMY_INVALID_AMOUNT');
    final before = _beforeJob(b);
    if (before) {
      if (!kind.beforeJob) throw AppError.from('HMY_INVALID_PRICE_KIND');
    } else if (b.agreedAmount != null &&
        {BookingStatus.confirmed, BookingStatus.onTheWay, BookingStatus.inProgress}.contains(b.status)) {
      if (kind.beforeJob) throw AppError.from('HMY_INVALID_PRICE_KIND');
      if (kind == PriceKind.repair &&
          (b.agreedKind != PriceKind.inspection ||
              b.priceOffers.any((o) => o.kind == PriceKind.repair && o.status == OfferStatus.accepted))) {
        throw AppError.from('HMY_INVALID_PRICE_KIND');
      }
    } else {
      throw AppError.from('HMY_NOT_NEGOTIABLE');
    }
    final thread = role == 'professional' ? me : (b.professionalId ?? professionalId);
    if (role == 'professional' && before && _wallets.containsKey(me) && _wallets[me]![0] < _commissionOf(amount)) {
      throw AppError.from('HMY_INSUFFICIENT_BALANCE');
    }
    final o = _addOffer(
      b,
      thread,
      byCustomer: role == 'customer',
      kind: kind,
      amount: amount,
      authorId: me,
      note: (note ?? '').trim().isEmpty ? null : note!.trim(),
    );
    if (before && role == 'professional' && b.status == BookingStatus.requested) {
      _move(b, BookingStatus.quoteSent, note: 'Propuesta de precio: ${Fmt.bs(o.amount)}', actorId: me);
    } else {
      final to = role == 'professional' ? b.customerId : thread;
      if (to != null) {
        _notify(to, 'price_offer', 'Te propusieron un precio', '${kind.label}: ${Fmt.bs(o.amount)}', bookingId: b.id);
      }
      _changes.add(null);
    }
    return o.id;
  }

  _DemoOffer _offer(int offerId) {
    for (final b in _bookings.values) {
      for (final o in b.priceOffers) {
        if (o.id == offerId) return o;
      }
    }
    throw AppError.from('HMY_NOT_FOUND');
  }

  _Booking _bookingOf(_DemoOffer o) => _bookings.values.firstWhere((b) => b.priceOffers.contains(o));

  @override
  Future<void> acceptPriceOffer(int offerId) async {
    await _latency();
    final me = _me.id;
    final o = _offer(offerId);
    final b = _bookingOf(o);
    if (b.status == BookingStatus.cancelled) throw AppError.from('HMY_REQUEST_CANCELLED');
    final role = _priceRole(b, me);
    if (role == null) {
      throw AppError.from(b.professionalId != null ? 'HMY_ALREADY_TAKEN' : 'HMY_FORBIDDEN');
    }
    if (o.kind.beforeJob && !_beforeJob(b)) throw AppError.from('HMY_ALREADY_TAKEN');
    if ((role == 'customer') == o.byCustomer ||
        (role == 'professional' && o.professionalId != null && o.professionalId != me)) {
      throw AppError.from('HMY_FORBIDDEN');
    }
    if (o.status != OfferStatus.open) throw AppError.from('HMY_OFFER_CHANGED');
    if (!o.kind.beforeJob) {
      final pro = b.professionalId!;
      final fee = _wallets.containsKey(pro) ? _commissionOf(o.amount) : 0.0;
      if (fee > 0 && _wallets[pro]![0] < fee) {
        o.status = OfferStatus.awaitingFunds;
        _notify(
          pro,
          'price_offer',
          'Recarga tu saldo para el monto aparte',
          '${o.kind.label}: ${Fmt.bs(o.amount)}',
          bookingId: b.id,
        );
      } else {
        if (fee > 0) {
          _post(pro, LedgerType.commissionReserve, -fee, fee, 'Reserva de comisión ${b.code} (monto aparte)');
          b.reserved += fee;
        }
        o.status = OfferStatus.accepted;
        b.extras += o.amount;
      }
      _changes.add(null);
      return;
    }
    if (o.forEveryone && role == 'professional' && _openOffer(b, me, byCustomer: true) != null) {
      throw AppError.from('HMY_OFFER_CHANGED');
    }
    final pro = b.professionalId ?? (role == 'professional' ? me : o.professionalId!);
    final before = (status: b.status, pro: b.professionalId, offers: b.offers, events: b.events.length);
    final reopen = [
      for (final x in b.priceOffers)
        if (x.status == OfferStatus.open) x,
    ];
    _agree(b, o, me);
    final note = 'Precio acordado: ${Fmt.bs(o.amount)}';
    try {
      if (b.professionalId == null) {
        _assign(b, pro, note, actorId: me);
      } else {
        _move(b, BookingStatus.confirmed, note: note, actorId: me);
      }
    } on AppError catch (e) {
      // Como la base: si no se pudo confirmar, no cambia nada.
      for (final x in reopen) {
        x.status = OfferStatus.open;
      }
      b
        ..status = before.status
        ..professionalId = before.pro
        ..offers = before.offers
        ..agreedAmount = null
        ..agreedKind = null
        ..quoteAmount = null;
      b.events.removeRange(before.events, b.events.length);
      if (role == 'customer' && e.code == 'HMY_INSUFFICIENT_BALANCE') throw AppError.from('HMY_PRO_UNAVAILABLE');
      rethrow;
    }
  }

  @override
  Future<void> rejectPriceOffer(int offerId) async {
    await _latency();
    final o = _offer(offerId);
    final b = _bookingOf(o);
    final role = _priceRole(b, _me.id);
    if (role == null || (role == 'customer') == o.byCustomer || o.forEveryone) throw AppError.from('HMY_FORBIDDEN');
    if (o.status != OfferStatus.open) throw AppError.from('HMY_OFFER_CHANGED');
    o.status = OfferStatus.rejected;
    _changes.add(null);
  }

  @override
  Future<void> cancelPriceOffer(int offerId) async {
    await _latency();
    final me = _me.id;
    final o = _offer(offerId);
    final b = _bookingOf(o);
    final ok =
        (o.status == OfferStatus.open && o.authorId == me) ||
        (o.status == OfferStatus.awaitingFunds && (b.customerId == me || b.professionalId == me));
    if (!ok) throw AppError.from('HMY_OFFER_CHANGED');
    o.status = OfferStatus.withdrawn;
    _changes.add(null);
  }

  @override
  Future<CommissionQuote> commissionForAmount(String bookingId, double amount) async {
    await _latency(80);
    final b = _get(bookingId);
    final me = _me.id;
    if (_priceRole(b, me) != 'professional') throw AppError.from('HMY_FORBIDDEN');
    final fee = _commissionOf(amount);
    final available = _wallets[me]?[0] ?? 0;
    final simulated = !_wallets.containsKey(me);
    return CommissionQuote(
      hasRule: true,
      ratePercent: _ratePercent,
      amount: amount,
      commission: fee,
      net: amount - fee,
      available: available,
      pendingDebt: 0,
      canCover: simulated || available >= fee,
      missing: simulated ? 0 : max(fee - available, 0),
    );
  }

  @override
  Future<void> updateProgress(String bookingId, BookingStatus to) async {
    await _latency();
    final b = _get(bookingId);
    if (b.professionalId != _me.id) throw AppError.from('HMY_FORBIDDEN');
    final allowed = switch (to) {
      BookingStatus.onTheWay => {BookingStatus.confirmed},
      BookingStatus.inProgress => {BookingStatus.confirmed, BookingStatus.onTheWay},
      BookingStatus.workFinished => {BookingStatus.inProgress},
      _ => <BookingStatus>{},
    };
    _requireStatus(b, allowed);
    if (to == BookingStatus.inProgress && b.arrivalVerifiedAt == null) throw AppError.from('HMY_ARRIVAL_NOT_VERIFIED');
    if (to == BookingStatus.workFinished) {
      // El monto final es el acordado más lo aprobado aparte; lo demás vence.
      if (b.agreedAmount != null) b.finalAmount = b.agreedAmount! + b.extras;
      for (final o in b.priceOffers) {
        if (o.status == OfferStatus.open || o.status == OfferStatus.awaitingFunds) o.status = OfferStatus.expired;
      }
    }
    _move(b, to, actorId: _me.id);
  }

  static const arrivalPinTtl = Duration(minutes: 10);
  final _pinRandom = Random.secure();
  final _pinAttempts = <String, List<DateTime>>{};

  // En el servidor es bcrypt; aquí basta con no guardar el código tal cual.
  static String _pinVerifier(String bookingId, String pin) => '$bookingId:${pin.hashCode ^ bookingId.hashCode}';

  @override
  Future<ArrivalPin> markArrived(String bookingId) async {
    await _latency();
    final b = _get(bookingId);
    if (b.professionalId != _me.id) throw AppError.from('HMY_FORBIDDEN');
    _requireStatus(b, {BookingStatus.onTheWay});
    if (b.arrivalVerifiedAt != null) throw AppError.from('HMY_ARRIVAL_ALREADY_VERIFIED');
    if (b.pinsIssued >= 3) throw AppError.from('HMY_ARRIVAL_PIN_LIMIT');
    final wait = b.lastPinAt == null ? 0 : 30 - DateTime.now().difference(b.lastPinAt!).inSeconds;
    if (wait > 0) throw AppError.from('HMY_ARRIVAL_PIN_TOO_SOON:$wait');
    final pin = _pinRandom.nextInt(1000000).toString().padLeft(6, '0');
    final first = b.arrivedAt == null;
    b
      ..pinVerifier = _pinVerifier(b.id, pin)
      ..pinExpiresAt = DateTime.now().add(arrivalPinTtl)
      ..wrongAttempts = 0
      ..pinsIssued += 1
      ..lastPinAt = DateTime.now()
      ..arrivedAt ??= DateTime.now();
    if (first) {
      _notify(
        b.customerId,
        'arrival',
        'Tu profesional llegó',
        'Pídele el código de 6 números y escríbelo en "Verificar llegada".',
        bookingId: b.id,
      );
    }
    _changes.add(null);
    return ArrivalPin(pin: pin, expiresAt: b.pinExpiresAt!, pinsLeft: 3 - b.pinsIssued);
  }

  @override
  Future<ArrivalCheck> verifyArrivalPin(String bookingId, String pin) async {
    await _latency();
    final b = _get(bookingId);
    final me = _me.id;
    if (b.customerId != me) throw AppError.from('HMY_FORBIDDEN');
    _requireStatus(b, {BookingStatus.onTheWay});
    if (!RegExp(r'^[0-9]{6}$').hasMatch(pin)) throw AppError.from('HMY_INVALID_PIN');
    final hourAgo = DateTime.now().subtract(const Duration(hours: 1));
    final fails = (_pinAttempts[me] ??= [])..removeWhere((t) => t.isBefore(hourAgo));
    if (fails.length >= 10) throw AppError.from('HMY_TOO_MANY_ATTEMPTS');
    if (b.arrivalVerifiedAt != null) throw AppError.from('HMY_ARRIVAL_ALREADY_VERIFIED');
    if (b.pinVerifier == null) throw AppError.from('HMY_ARRIVAL_NO_PIN');
    if (!b.pinExpiresAt!.isAfter(DateTime.now())) {
      b.pinVerifier = null;
      _changes.add(null);
      return const ArrivalCheck(ArrivalCheckResult.expired);
    }
    if (_pinVerifier(b.id, pin) != b.pinVerifier) {
      fails.add(DateTime.now());
      b.wrongAttempts++;
      final left = 5 - b.wrongAttempts;
      if (left <= 0) b.pinVerifier = null;
      _changes.add(null);
      return ArrivalCheck(left <= 0 ? ArrivalCheckResult.locked : ArrivalCheckResult.wrong, attemptsLeft: max(left, 0));
    }
    _verifyArrival(b, method: 'pin');
    _notify(
      b.professionalId!,
      'arrival',
      'Llegada verificada',
      'El cliente confirmó tu llegada. Ya puedes empezar el trabajo.',
      bookingId: b.id,
    );
    return const ArrivalCheck(ArrivalCheckResult.verified);
  }

  final _trips = <String, ({GeoPoint point, DateTime at})>{};
  final _shares = <String, List<({int id, String token, String? contact, DateTime created, DateTime expires})>>{};
  final _revokedShares = <int>{};

  bool _tripLive(_Booking b) => b.status == BookingStatus.onTheWay && b.arrivalVerifiedAt == null;

  @override
  Future<bool> shareTripLocation(String bookingId, GeoPoint point, {int? accuracyM}) async {
    await _latency(100);
    final b = _get(bookingId);
    if (b.professionalId != _me.id) throw AppError.from('HMY_FORBIDDEN');
    if (!_tripLive(b)) throw AppError.from('HMY_TRIP_NOT_ACTIVE');
    if (point.latitude < -23.5 || point.latitude > -9 || point.longitude < -70 || point.longitude > -57) {
      throw AppError.from('HMY_INVALID_LOCATION');
    }
    final last = _trips[b.id];
    if (last != null && DateTime.now().difference(last.at) < const Duration(seconds: 5)) return false;
    _trips[b.id] = (point: point, at: DateTime.now());
    _changes.add(null);
    return true;
  }

  @override
  Future<void> stopTripLocation(String bookingId) async {
    await _latency(100);
    final b = _get(bookingId);
    if (b.professionalId != _me.id) throw AppError.from('HMY_FORBIDDEN');
    _trips.remove(b.id);
    _changes.add(null);
  }

  TripLocation? _tripOf(_Booking b) {
    final t = _trips[b.id];
    if (!_tripLive(b) || t == null) return null;
    return TripLocation(
      live: true,
      latitude: t.point.latitude,
      longitude: t.point.longitude,
      updatedAt: t.at,
      stale: DateTime.now().difference(t.at) > const Duration(minutes: 2),
    );
  }

  @override
  Future<TripLocation> tripLocation(String bookingId) async {
    await _latency(100);
    final b = _get(bookingId);
    if (b.customerId != _me.id && !_me.roles.contains(AppRole.admin)) throw AppError.from('HMY_FORBIDDEN');
    final t = _tripOf(b);
    if (t == null) return TripLocation(live: _tripLive(b));
    final lat = b.draft.latitude;
    final lng = b.draft.longitude;
    final km = lat == null || lng == null ? null : distanceKm(t.latitude!, t.longitude!, lat, lng);
    return TripLocation(
      live: true,
      latitude: t.latitude,
      longitude: t.longitude,
      updatedAt: t.updatedAt,
      stale: t.stale,
      distanceKm: km == null ? null : (km * 10).round() / 10,
      etaMinutes: km == null ? null : max(1, (km / 20 * 60).ceil()),
    );
  }

  @override
  Future<String> createTripShare(String bookingId, {String? contactName}) async {
    await _latency();
    final b = _get(bookingId);
    if (b.customerId != _me.id) throw AppError.from('HMY_FORBIDDEN');
    if (!b.status.isActive) throw AppError.from('HMY_INVALID_TRANSITION');
    final list = _shares[b.id] ??= [];
    final active = list.where((x) => !_revokedShares.contains(x.id) && x.expires.isAfter(DateTime.now()));
    if (active.length >= 3) throw AppError.from('HMY_TOO_MANY_SHARES');
    final token = List.generate(
      32,
      (_) => 'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'[_pinRandom.nextInt(56)],
    ).join();
    final name = contactName?.trim();
    list.add((
      id: _seq++,
      token: token,
      contact: name == null || name.isEmpty ? null : name,
      created: DateTime.now(),
      expires: DateTime.now().add(const Duration(hours: 12)),
    ));
    return token;
  }

  @override
  Future<List<TripShare>> tripShares(String bookingId) async {
    await _latency(100);
    final b = _get(bookingId);
    if (b.customerId != _me.id) return const [];
    return [
      for (final x in (_shares[b.id] ?? const []).reversed)
        if (!_revokedShares.contains(x.id) && x.expires.isAfter(DateTime.now()) && !b.status.isClosed)
          TripShare(id: x.id, contactName: x.contact, createdAt: x.created, expiresAt: x.expires),
    ];
  }

  @override
  Future<void> revokeTripShare(int shareId) async {
    await _latency(100);
    final mine = _shares.entries.any((e) => _get(e.key).customerId == _me.id && e.value.any((x) => x.id == shareId));
    if (!mine || _revokedShares.contains(shareId)) throw AppError.from('HMY_NOT_FOUND');
    _revokedShares.add(shareId);
  }

  @override
  Future<SharedTrip> sharedTrip(String token) async {
    await _latency();
    for (final e in _shares.entries) {
      for (final x in e.value) {
        if (x.token != token) continue;
        final b = _get(e.key);
        if (_revokedShares.contains(x.id) || !x.expires.isAfter(DateTime.now()) || b.status.isClosed) break;
        final customer = _accounts.values.firstWhere((a) => a.id == b.customerId);
        return SharedTrip(
          code: b.code,
          status: b.status,
          customerFirstName: customer.fullName.split(' ').first,
          professionalName: _pros[b.professionalId]?.displayName ?? '',
          professionalVerified: true,
          category: _catName(b.draft.categoryId),
          arrivalVerifiedAt: b.arrivalVerifiedAt,
          trip: _tripOf(b),
        );
      }
    }
    throw AppError.from('HMY_SHARE_NOT_FOUND');
  }

  /// Solo pruebas: hace como si el último código se hubiera generado hace [ago].
  @visibleForTesting
  void debugAgeArrivalPin(String bookingId, Duration ago) {
    final b = _get(bookingId);
    b
      ..lastPinAt = b.lastPinAt?.subtract(ago)
      ..pinExpiresAt = b.pinExpiresAt?.subtract(ago);
  }

  void _verifyArrival(_Booking b, {required String method}) {
    final start = b.draft.scheduledStart;
    _trips.remove(b.id);
    b
      ..pinVerifier = null
      ..arrivedAt ??= DateTime.now()
      ..arrivalVerifiedAt = DateTime.now()
      ..arrivalMethod = method
      ..delayMinutes = b.draft.mode == BookingMode.scheduled && start != null
          ? max(0, DateTime.now().difference(start).inMinutes)
          : null;
    _changes.add(null);
  }

  @override
  Future<BookingArrival> arrival(String bookingId) async {
    await _latency();
    final b = _get(bookingId);
    final me = _me.id;
    if (b.customerId != me && b.professionalId != me && !_me.roles.contains(AppRole.admin)) {
      throw AppError.from('HMY_FORBIDDEN');
    }
    final live = b.pinVerifier != null && b.pinExpiresAt!.isAfter(DateTime.now());
    return BookingArrival(
      stage: b.arrivalVerifiedAt != null
          ? ArrivalStage.verified
          : live
          ? ArrivalStage.waitingPin
          : b.arrivedAt != null
          ? ArrivalStage.arrived
          : ArrivalStage.none,
      arrivedAt: b.arrivedAt,
      pinExpiresAt: b.pinVerifier != null ? b.pinExpiresAt : null,
      attemptsLeft: b.pinVerifier != null ? 5 - b.wrongAttempts : null,
      pinsLeft: 3 - b.pinsIssued,
      verifiedAt: b.arrivalVerifiedAt,
      byTeam: b.arrivalMethod == 'admin',
      delayMinutes: b.delayMinutes,
    );
  }

  @override
  Future<void> confirmCompletion(String bookingId) async {
    await _latency();
    final b = _get(bookingId);
    if (b.customerId != _me.id) throw AppError.from('HMY_FORBIDDEN');
    _requireStatus(b, {BookingStatus.workFinished});
    _move(b, BookingStatus.completed, note: 'Trabajo confirmado por el cliente', actorId: _me.id);
  }

  @override
  Future<void> submitReview(String bookingId, int rating, String? comment) async {
    await _latency();
    final b = _get(bookingId);
    if (b.customerId != _me.id) throw AppError.from('HMY_FORBIDDEN');
    if (b.status != BookingStatus.completed) throw AppError.from('HMY_REVIEW_NOT_ALLOWED');
    if (b.hasReview) throw AppError.from('HMY_ALREADY_RATED');
    b.hasReview = true;
    final pro = _pros[b.professionalId]!;
    pro.ratingAvg = ((pro.ratingAvg * pro.ratingCount) + rating) / (pro.ratingCount + 1);
    pro.ratingCount++;
    pro.realReviews.insert(
      0,
      Review(
        id: _seq++,
        rating: rating,
        comment: comment,
        authorFirstName: _me.fullName.split(' ').first,
        createdAt: DateTime.now(),
      ),
    );
    _changes.add(null);
  }

  @override
  Future<void> cancel(String bookingId, String reason) async {
    await _latency();
    final b = _get(bookingId);
    final me = _me.id;
    final isCustomer = b.customerId == me;
    if (!isCustomer && b.professionalId != me) throw AppError.from('HMY_FORBIDDEN');
    // Como el servidor: cancelar dos veces no repite nada, y el cliente no
    // tiene que dar un motivo (el profesional sí).
    if (b.status == BookingStatus.cancelled) return;
    if (!isCustomer && reason.trim().isEmpty) throw AppError.from('HMY_REASON_REQUIRED');
    _requireStatus(
      b,
      isCustomer
          ? {BookingStatus.requested, BookingStatus.awaitingResponse, BookingStatus.quoteSent, BookingStatus.confirmed}
          : {BookingStatus.requested, BookingStatus.quoteSent, BookingStatus.confirmed, BookingStatus.onTheWay},
    );
    b.offers = {};
    _move(b, BookingStatus.cancelled, note: reason.trim().isEmpty ? customerCancelNote : reason.trim(), actorId: me);
  }

  @override
  Future<void> openDispute(String bookingId, String reason) async {
    await _latency();
    final b = _get(bookingId);
    final me = _me.id;
    if (b.customerId != me && b.professionalId != me) throw AppError.from('HMY_FORBIDDEN');
    if (reason.trim().length < 5) throw AppError.from('HMY_REASON_REQUIRED');
    _requireStatus(b, {BookingStatus.onTheWay, BookingStatus.inProgress, BookingStatus.workFinished});
    b
      ..disputeReason = reason.trim()
      ..disputeOpenedBy = me
      ..disputeAt = DateTime.now()
      ..disputeResolution = null;
    _move(b, BookingStatus.disputed, note: reason.trim(), actorId: me);
  }

  @override
  Future<void> acknowledgePayment(String bookingId, PaymentMethod method) async {
    await _latency();
    final b = _get(bookingId);
    _requireStatus(b, {BookingStatus.workFinished, BookingStatus.completed});
    if (b.customerId == _me.id) {
      b.customerPaid = true;
      // El cliente dice cómo pagó; el servidor hace lo mismo.
      b.paidWith = method;
    } else if (b.professionalId == _me.id) {
      b.professionalPaid = true;
    } else {
      throw AppError.from('HMY_FORBIDDEN');
    }
    _changes.add(null);
  }

  // ================================================================= Mensajes
  StreamController<List<ChatMessage>> _streamFor(String id) =>
      _messageStreams.putIfAbsent(id, () => StreamController<List<ChatMessage>>.broadcast());

  void _sendAs(String conversationId, String senderId, String body) {
    final c = _conversations[conversationId];
    if (c == null) return;
    final m = ChatMessage(id: _seq++, conversationId: c.id, senderId: senderId, body: body, createdAt: DateTime.now());
    c.messages.add(m);
    c.readAt[senderId] = m.createdAt;
    _streamFor(c.id).add(List.of(c.messages));
    final other = senderId == c.customerId ? c.professionalId : c.customerId;
    _notify(other, 'message', 'Nuevo mensaje', body, conversationId: c.id, bookingId: c.bookingId);
  }

  @override
  Future<List<Conversation>> conversations() async {
    await _latency(150);
    final me = _me.id;
    final list = _conversations.values.where((c) => c.customerId == me || c.professionalId == me).toList()
      ..sort(
        (a, b) => (b.messages.lastOrNull?.createdAt ?? DateTime(0)).compareTo(
          a.messages.lastOrNull?.createdAt ?? DateTime(0),
        ),
      );
    return [
      for (final c in list)
        Conversation(
          id: c.id,
          bookingId: c.bookingId,
          bookingCode: _bookings[c.bookingId]!.code,
          otherId: me == c.customerId ? c.professionalId : c.customerId,
          otherName: me == c.customerId
              ? _pros[c.professionalId]!.displayName
              : _accounts.values.firstWhere((a) => a.id == c.customerId).fullName.split(' ').first,
          lastMessageAt: c.messages.lastOrNull?.createdAt,
          lastMessagePreview: c.messages.lastOrNull?.body,
          unreadCount: c.messages
              .where((m) => m.senderId != me && m.createdAt.isAfter(c.readAt[me] ?? DateTime(0)))
              .length,
          bookingStatus: _bookings[c.bookingId]!.status,
        ),
    ];
  }

  @override
  Stream<List<ChatMessage>> watchMessages(String conversationId) async* {
    final c = _conversations[conversationId];
    if (c == null || (c.customerId != _me.id && c.professionalId != _me.id)) {
      throw AppError.from('HMY_FORBIDDEN');
    }
    yield List.of(c.messages);
    yield* _streamFor(conversationId).stream;
  }

  @override
  Future<void> send(String conversationId, String body) async {
    await _latency(120);
    final c = _conversations[conversationId];
    final me = _me.id;
    if (c == null || (c.customerId != me && c.professionalId != me)) throw AppError.from('HMY_FORBIDDEN');
    if (!_bookings[c.bookingId]!.status.chatOpen) throw AppError.from('HMY_CHAT_CLOSED');
    if (_me.suspendedAt != null) throw AppError.from('HMY_ACCOUNT_SUSPENDED');
    if (_blockedBetween(c.customerId, c.professionalId)) throw AppError.from('HMY_BLOCKED');
    _sendAs(conversationId, me, body.trim());
    // Respuesta simulada del profesional de ejemplo.
    final other = me == c.customerId ? c.professionalId : c.customerId;
    if (_pros.containsKey(other) && other != 'demo-pro' && c.messages.where((m) => m.senderId == other).length < 3) {
      _later(const Duration(seconds: 3), () => _sendAs(conversationId, other, 'Perfecto, entendido. 👍'));
    }
  }

  @override
  Future<void> markRead(String conversationId) async {
    _conversations[conversationId]?.readAt[_me.id] = DateTime.now();
    _changes.add(null);
  }

  // ================================================================= Notificaciones
  @override
  Future<List<AppNotification>> list() async {
    await _latency(150);
    final me = _session?.id;
    return [
      for (final n in _notifications)
        if (n.userId == me) n.value,
    ];
  }

  @override
  Stream<int> unreadCount() async* {
    int count() => _notifications.where((n) => n.userId == _session?.id && !n.value.isRead).length;
    yield count();
    yield* _changes.stream.map((_) => count());
  }

  // En la demostración no hay avisos push (no hay servidor que los mande).
  @override
  Future<void> registerPushDevice(String token, String platform) async {}

  @override
  Future<void> unregisterPushDevice(String token) async {}

  @override
  Future<PushStatus?> pushStatus() async => null;

  @override
  Future<int> sendTestPush() async => throw const AppError('Los avisos push no existen en la demostración.');

  @override
  Future<void> markAllRead() async {
    final me = _session?.id;
    for (var i = 0; i < _notifications.length; i++) {
      final n = _notifications[i];
      if (n.userId == me && !n.value.isRead) {
        _notifications[i] = _Note(
          AppNotification(
            id: n.value.id,
            kind: n.value.kind,
            title: n.value.title,
            body: n.value.body,
            bookingId: n.value.bookingId,
            conversationId: n.value.conversationId,
            readAt: DateTime.now(),
            createdAt: n.value.createdAt,
          ),
          n.userId,
        );
      }
    }
    _changes.add(null);
  }

  // ================================================================= Profesional
  @override
  Future<ProDashboard> dashboard() async {
    await _latency(200);
    final me = _me.id;
    final p = _pros[me];
    if (p == null) throw AppError.from('HMY_PROFESSIONAL_NOT_APPROVED');
    final mine = _bookings.values.where((b) => b.professionalId == me);
    final w = _wallets[me] ?? [0, 0];
    return ProDashboard(
      isAvailable: p.available,
      ratingAvg: p.ratingAvg,
      ratingCount: p.ratingCount,
      completedJobs: p.completedJobs,
      walletAvailable: w[0],
      walletReserved: w[1],
      incoming: _bookings.values
          .where(
            (b) =>
                (b.professionalId == me && b.status == BookingStatus.requested) ||
                (b.status == BookingStatus.awaitingResponse && b.offers.contains(me)),
          )
          .length,
      active: mine.where((b) => b.status.isActive).length,
      upcoming: mine
          .where(
            (b) =>
                b.draft.mode == BookingMode.scheduled &&
                b.status == BookingStatus.confirmed &&
                b.draft.scheduledStart!.isAfter(DateTime.now()),
          )
          .length,
      earningsMonth: mine
          .where((b) => b.status == BookingStatus.completed)
          .fold(0.0, (sum, b) => sum + (b.finalAmount ?? 0)),
    );
  }

  @override
  Future<void> setAvailability(bool available) async {
    await _latency();
    final me = _me.id;
    final p = _pros[me];
    if (p == null || p.status != VerificationStatus.approved) throw AppError.from('HMY_PROFESSIONAL_NOT_APPROVED');
    p.available = available;
    _changes.add(null);
    if (available && me == 'demo-pro') {
      // Simula un pedido ¡Ya! de un cliente cercano.
      _later(const Duration(seconds: 6), () {
        if (!p.available) return;
        final ghost = _accounts.putIfAbsent(
          'vecino@demo.bo',
          () =>
              _Account(id: 'demo-vecino', email: 'vecino@demo.bo', fullName: 'Doña Elena Paz', cityId: 1)
                ..confirmed = true,
        );
        final b =
            _Booking(
                id: _id('b'),
                code: 'YA${_rng.nextInt(9000) + 1000}',
                customerId: ghost.id,
                draft: const BookingDraft(
                  categoryId: 2,
                  cityId: 1,
                  mode: BookingMode.now,
                  description: 'Se fue la luz en la mitad de la casa y el disyuntor no sube.',
                  address: 'Calle Los Pinos 123, Barrio Equipetrol',
                  addressReference: 'Casa de rejas blancas, frente a la plaza',
                  zoneId: 12,
                  paymentMethod: PaymentMethod.qr,
                  latitude: -17.7712,
                  longitude: -63.1951,
                ),
                createdAt: DateTime.now(),
              )
              ..status = BookingStatus.awaitingResponse
              ..offers = {me};
        b.events.add(BookingEvent(status: BookingStatus.awaitingResponse, at: DateTime.now()));
        _bookings[b.id] = b;
        _notify(me, 'ya_offer', '¡Pedido ¡Ya! cerca de ti!', b.draft.description, bookingId: b.id);
      });
    }
  }

  @override
  Future<ProfessionalApplication> application() async {
    await _latency(150);
    final p = _pros[_me.id];
    if (p == null) return const ProfessionalApplication();
    return ProfessionalApplication(
      status: p.status,
      displayName: p.displayName,
      primaryCategoryId: p.primaryCategoryId,
      bio: p.bio,
      yearsExperience: p.years,
      cityId: p.cityId,
      categoryIds: {p.primaryCategoryId},
      zoneIds: p.zoneIds,
      documentCount: p.documentCount,
    );
  }

  @override
  Future<void> saveApplication({
    required String displayName,
    required int primaryCategoryId,
    required int cityId,
    required String bio,
    int? yearsExperience,
    String? priceNote,
    required Set<int> categoryIds,
    required Set<int> zoneIds,
  }) async {
    await _latency();
    final me = _me;
    final existing = _pros[me.id];
    if (existing != null && !existing.status.canEdit) throw AppError.from('HMY_INVALID_TRANSITION');
    _pros[me.id] = _Pro(
      id: me.id,
      displayName: displayName.trim(),
      primaryCategoryId: primaryCategoryId,
      cityId: cityId,
      zoneIds: zoneIds,
      bio: bio.trim(),
      years: yearsExperience ?? 0,
      priceFrom: null,
      available: false,
      ratingAvg: 0,
      ratingCount: 0,
      completedJobs: 0,
      status: existing?.status ?? VerificationStatus.draft,
    )..documentCount = existing?.documentCount ?? 0;
  }

  @override
  Future<void> uploadDocument({required String docType, required Uint8List bytes, required String fileName}) async {
    await _latency(600);
    final p = _pros[_me.id];
    if (p == null) throw AppError.from('HMY_NO_APPLICATION');
    p.documentCount++;
    p.docs.add(_Doc(_seq++, docType, bytes));
  }

  @override
  Future<void> submitApplication() async {
    await _latency();
    final p = _pros[_me.id];
    if (p == null) throw AppError.from('HMY_NO_APPLICATION');
    if (p.documentCount == 0) throw AppError.from('HMY_DOCUMENTS_REQUIRED');
    if (p.displayName.length < 3) throw AppError.from('HMY_APPLICATION_INCOMPLETE');
    p
      ..status = VerificationStatus.submitted
      ..submittedAt = DateTime.now()
      ..history.add((status: VerificationStatus.submitted, note: null, at: DateTime.now()));
    // Demostración: el "equipo de verificación" aprueba solo a los pocos segundos.
    final account = _me;
    _later(const Duration(seconds: 8), () {
      p.status = VerificationStatus.approved;
      account.roles.add(AppRole.professional);
      _post(account.id, LedgerType.topup, 30, 0, 'Saldo de prueba (demostración)');
      _notify(
        account.id,
        'verification',
        '¡Tu perfil fue aprobado!',
        'Ya puedes usar el modo profesional y recibir pedidos ¡Ya!.',
      );
    });
  }

  @override
  Future<Wallet> wallet() async {
    await _latency(150);
    final w = _wallets[_me.id] ?? [0, 0];
    final ledger = _ledger[_me.id] ?? const <LedgerEntry>[];
    return Wallet(
      available: w[0],
      reserved: w[1],
      commissionsCollected: ledger
          .where((e) => e.type == LedgerType.commissionCapture)
          .fold(0.0, (sum, e) => sum - e.availableDelta - e.reservedDelta),
      extrasAwaitingFunds: _bookings.values
          .where((b) => b.professionalId == _me.id)
          .expand((b) => b.priceOffers)
          .where((o) => o.status == OfferStatus.awaitingFunds)
          .length,
    );
  }

  @override
  Future<List<LedgerEntry>> ledger() async => List.of(_ledger[_me.id] ?? const []);

  @override
  Future<List<TopupMethod>> topupMethods() async => const [
    TopupMethod(
      id: 1,
      name: 'QR (ejemplo)',
      instructions: 'Escanea el QR de HandiMan ¡Ya! desde la app de tu banco y escribe tu correo en la glosa. Luego ingresa aquí el número de transacción.',
    ),
    TopupMethod(
      id: 2,
      name: 'Transferencia bancaria (ejemplo)',
      instructions: 'Banco de ejemplo · Cuenta 000-0000000 · A nombre de HandiMan ¡Ya!. Usa tu correo como referencia.',
    ),
  ];

  @override
  Future<List<TopupRequest>> topups() async => List.of(_topups[_me.id] ?? const []);

  @override
  Future<int> requestTopup({
    required double amount,
    required int methodId,
    String? reference,
    PhotoUpload? proof,
    required String authMethod,
    required String clientKey,
  }) async {
    await _latency();
    final me = _me;
    // Mismas reglas que request_topup en la base.
    final previous = _topupKeys['${me.id}:$clientKey'];
    if (previous != null) return previous;
    if (amount <= 0 || amount > 10000) throw AppError.from('HMY_INVALID_AMOUNT');
    final list = _topups.putIfAbsent(me.id, () => []);
    if (list.where((t) => t.status == TopupStatus.pending).length >= 3) throw AppError.from('HMY_TOO_MANY_PENDING');
    _requireConfirmation(authMethod);
    list.insert(
      0,
      TopupRequest(
        id: _seq++,
        amount: amount,
        status: TopupStatus.pending,
        reference: reference,
        createdAt: DateTime.now(),
      ),
    );
    final proId = me.id;
    final id = list.first.id;
    _topupKeys['${me.id}:$clientKey'] = id;
    if (proof != null) _topupProofs[id] = proof.bytes;
    _log('topup.request', 'topup_requests', '$id', {
      'amount': amount,
      'method_id': methodId,
      'auth_method': authMethod,
    });
    // Demostración: la recarga se acredita sola a los pocos segundos.
    _later(const Duration(seconds: 6), () {
      final i = list.indexWhere((t) => t.id == id);
      if (i < 0 || list[i].status != TopupStatus.pending) return;
      final t = list[i];
      list[i] = TopupRequest(
        id: t.id,
        amount: t.amount,
        status: TopupStatus.approved,
        reference: t.reference,
        createdAt: t.createdAt,
      );
      _post(proId, LedgerType.topup, amount, 0, 'Recarga acreditada');
      _notify(proId, 'topup', 'Recarga acreditada', 'Sumamos ${amount.toStringAsFixed(2)} Bs a tu billetera.');
    });
    return id;
  }

  // Recargas por QR: en la demostración el QR siempre es simulado.
  final _qr = <String, QrRecharge>{};
  final _qrOwner = <String, String>{};

  QrRecharge _qrNow(QrRecharge r) => r.status == QrRechargeStatus.pendingPayment && !r.expiresAt.isAfter(DateTime.now())
      ? _qrWith(r, QrRechargeStatus.expired)
      : r;

  QrRecharge _qrWith(QrRecharge r, QrRechargeStatus s, {double? credited, String? reason}) => QrRecharge(
    id: r.id,
    reference: r.reference,
    amount: r.amount,
    status: s,
    simulated: r.simulated,
    qrPayload: s == QrRechargeStatus.pendingPayment ? r.qrPayload : null,
    createdAt: r.createdAt,
    expiresAt: r.expiresAt,
    paidAmount: credited ?? r.paidAmount,
    creditedAmount: credited ?? r.creditedAmount,
    reviewReason: reason ?? r.reviewReason,
    professionalName: r.professionalName,
  );

  @override
  Future<QrRecharge> createQrRecharge(double amount) async {
    await _latency(200);
    final me = _me.id;
    if (!_wallets.containsKey(me)) throw AppError.from('HMY_WALLET_NOT_FOUND');
    if (amount < 10 || amount > 5000) throw AppError.from('HMY_INVALID_AMOUNT');
    final pending = _qr.values.where(
      (r) => _qrOwner[r.id] == me && _qrNow(r).status == QrRechargeStatus.pendingPayment,
    );
    if (pending.length >= 3) throw AppError.from('HMY_TOO_MANY_QR');
    final n = _qr.length + 1;
    final ref = 'HMY${(0xA1B2C3D400 + n).toRadixString(16).toUpperCase()}';
    final now = DateTime.now();
    final r = QrRecharge(
      id: 'qr$n',
      reference: ref,
      amount: amount,
      status: QrRechargeStatus.pendingPayment,
      simulated: true,
      qrPayload: 'HANDIMANYA-DEV|SIMULADO-NO-PAGAR|$ref|BOB|${amount.toStringAsFixed(2)}',
      createdAt: now,
      expiresAt: now.add(const Duration(minutes: 15)),
      professionalName: _pros[me]?.displayName,
    );
    _qr[r.id] = r;
    _qrOwner[r.id] = me;
    return r;
  }

  @override
  Future<QrRecharge?> qrRecharge(String id) async {
    final r = _qr[id];
    return r == null || _qrOwner[id] != _me.id ? null : _qrNow(r);
  }

  @override
  Future<List<QrRecharge>> qrRecharges() async =>
      [for (final r in _qr.values.where((r) => _qrOwner[r.id] == _me.id)) _qrNow(r)]
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  @override
  Future<String> simulateQrPayment(String id) async {
    final r = _qr[id];
    if (r == null || _qrOwner[id] != _me.id || !r.simulated) throw AppError.from('HMY_FORBIDDEN');
    final now = _qrNow(r);
    if (now.status == QrRechargeStatus.credited) return 'already_credited';
    if (now.status == QrRechargeStatus.expired) {
      _qr[id] = _qrWith(r, QrRechargeStatus.verifying, reason: 'paid_after_expiry');
      return 'verifying_paid_after_expiry';
    }
    if (now.status != QrRechargeStatus.pendingPayment) return 'already_${now.status.key}';
    _qr[id] = _qrWith(r, QrRechargeStatus.credited, credited: r.amount);
    _post(_me.id, LedgerType.topup, r.amount, 0, 'Recarga simulada (no es dinero real) ${r.reference}');
    _notify(_me.id, 'wallet_credited', 'Recarga acreditada', 'Se acreditaron ${Fmt.bs(r.amount)} a tu billetera.');
    _changes.add(null);
    return 'credited';
  }

  @override
  Future<List<RechargeBankAccount>> rechargeBankAccounts() async => const [];

  @override
  Future<QrRechargeReport> ownerQrRecharges({QrRechargeStatus? status}) async {
    final all = [for (final r in _qr.values) _qrNow(r)]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final counts = <QrRechargeStatus, int>{};
    for (final r in all) {
      counts[r.status] = (counts[r.status] ?? 0) + 1;
    }
    return QrRechargeReport(
      items: status == null ? all : all.where((r) => r.status == status).toList(),
      counts: counts,
      unmatchedEvents: 0,
    );
  }

  @override
  Future<void> reviewQrRecharge(
    String id, {
    required bool approve,
    required String note,
    required String authMethod,
  }) async {
    final r = _qr[id];
    if (r == null) throw AppError.from('HMY_NOT_FOUND');
    if (note.trim().isEmpty) throw AppError.from('HMY_REASON_REQUIRED');
    if (r.status != QrRechargeStatus.verifying) throw AppError.from('HMY_ALREADY_REVIEWED');
    final paid = r.paidAmount ?? r.amount;
    _qr[id] = _qrWith(
      r,
      approve ? QrRechargeStatus.credited : QrRechargeStatus.rejected,
      credited: approve ? paid : null,
    );
    if (approve) _post(_qrOwner[id]!, LedgerType.topup, paid, 0, 'Recarga simulada (no es dinero real) ${r.reference}');
    _changes.add(null);
  }

  @override
  Future<void> reverseQrRecharge(String id, {required String reason, required String authMethod}) async {
    final r = _qr[id];
    if (r == null) throw AppError.from('HMY_NOT_FOUND');
    if (reason.trim().isEmpty) throw AppError.from('HMY_REASON_REQUIRED');
    if (r.status != QrRechargeStatus.credited) throw AppError.from('HMY_INVALID_STATUS');
    final pro = _qrOwner[id]!;
    final amount = r.creditedAmount ?? r.amount;
    if ((_wallets[pro]?[0] ?? 0) < amount) throw AppError.from('HMY_INSUFFICIENT_BALANCE');
    _post(pro, LedgerType.adjustment, -amount, 0, 'Reversión de la recarga ${r.reference}: $reason');
    _qr[id] = _qrWith(r, QrRechargeStatus.reversed);
    _changes.add(null);
  }

  @override
  Future<bool> biometricEnabled() async => _biometric.contains(_me.id);

  @override
  Future<void> setBiometricEnabled(bool enabled, {String authMethod = 'otp'}) async {
    await _latency(100);
    final me = _me;
    if (enabled) {
      if (authMethod != 'otp') throw AppError.from('HMY_CONFIRMATION_REQUIRED');
      _requireConfirmation('otp');
      _biometric.add(me.id);
    } else {
      _biometric.remove(me.id);
    }
    _log(enabled ? 'security.biometric_on' : 'security.biometric_off', 'security_settings', me.id);
  }

  /// Como hmy_require_confirmation: código verificado hace menos de 5 minutos
  /// y de un solo uso, o huella/rostro activados en la cuenta.
  void _requireConfirmation(String method) {
    final me = _me;
    switch (method) {
      case 'otp':
        final at = _confirmedAt.remove(me.id);
        if (at == null || DateTime.now().difference(at) > const Duration(minutes: 5)) {
          throw AppError.from('HMY_CONFIRMATION_EXPIRED');
        }
      case 'biometric':
        if (!_biometric.contains(me.id)) throw AppError.from('HMY_BIOMETRIC_DISABLED');
      default:
        throw AppError.from('HMY_CONFIRMATION_REQUIRED');
    }
  }

  @override
  Future<void> addPhotos(String bookingId, List<PhotoUpload> photos) async {
    await _latency(400);
    final b = _get(bookingId);
    if (b.customerId != _me.id) throw AppError.from('HMY_FORBIDDEN');
    if (b.photos.length + photos.length > 5) throw AppError.from('HMY_TOO_MANY_PHOTOS');
    b.photos.addAll([for (final p in photos) BookingPhoto(bytes: p.bytes)]);
    _changes.add(null);
  }

  @override
  Future<ServiceLocation?> serviceLocation() async {
    await _latency(100);
    return _pros[_me.id]?.location;
  }

  @override
  Future<void> setServiceLocation({required double latitude, required double longitude, required int radiusKm}) async {
    await _latency();
    final p = _pros[_me.id];
    if (p == null) throw AppError.from('HMY_NO_APPLICATION');
    if (latitude < -23.5 || latitude > -9 || longitude < -70 || longitude > -57) {
      throw AppError.from('HMY_INVALID_LOCATION');
    }
    if (radiusKm < 1 || radiusKm > 50) throw AppError.from('HMY_INVALID_RADIUS');
    p.location = ServiceLocation(latitude: latitude, longitude: longitude, radiusKm: radiusKm);
  }

  @override
  Future<IdentityCheck> identityCheck() async {
    await _latency(100);
    return _pros[_me.id]?.identity.lastOrNull ?? IdentityCheck.none;
  }

  /// En la demo no hay Didit: se crea una verificación de prueba (sandbox), que
  /// nunca cuenta como real. El resultado lo pone [debugIdentityResult].
  @override
  Future<({String url, bool sandbox})> startIdentityCheck() async {
    await _latency();
    final p = _pros[_me.id];
    if (p == null) throw AppError.from('HMY_NO_APPLICATION');
    if (!{
      VerificationStatus.draft,
      VerificationStatus.submitted,
      VerificationStatus.underReview,
      VerificationStatus.reverificationRequired,
    }.contains(p.status)) {
      throw AppError.from('HMY_INVALID_STATUS');
    }
    final last = p.identity.lastOrNull;
    if (last?.status == IdentityStatus.approved && p.status != VerificationStatus.reverificationRequired) {
      throw AppError.from('HMY_IDENTITY_ALREADY_APPROVED');
    }
    final didit = _vendors['didit_kyc']!;
    if (didit.status == VendorStatus.off) throw AppError.from('HMY_IDENTITY_PAUSED');
    if (last == null || !{IdentityStatus.created, IdentityStatus.inProgress}.contains(last.status)) {
      didit.sandboxUsed++;
      p.identity.add(IdentityCheck(id: _seq++, status: IdentityStatus.created, createdAt: DateTime.now()));
    }
    return (url: 'https://verify.didit.me/demo', sandbox: true);
  }

  /// Solo pruebas: lo que respondería el sandbox de Didit.
  @visibleForTesting
  void debugIdentityResult(String professionalId, IdentityStatus status, {double? faceMatch, bool sandbox = true}) {
    final p = _pros[professionalId]!;
    final last = p.identity.isEmpty ? null : p.identity.removeLast();
    p.identity.add(
      IdentityCheck(
        id: last?.id ?? _seq++,
        status: status,
        sandbox: sandbox,
        documentType: 'Identity Card',
        livenessScore: status == IdentityStatus.approved ? 95 : null,
        faceMatchScore: faceMatch,
        createdAt: last?.createdAt ?? DateTime.now(),
        decidedAt: DateTime.now(),
        vendorDeleted: status == IdentityStatus.approved || status == IdentityStatus.declined,
      ),
    );
  }

  // ================================================================= Seguridad
  _Account? _account(String id) => _accounts.values.where((a) => a.id == id).firstOrNull;

  bool _blockedBetween(String a, String b) =>
      (_account(a)?.blocked.contains(b) ?? false) || (_account(b)?.blocked.contains(a) ?? false);

  String _nameOf(String id) => _pros[id]?.displayName ?? _account(id)?.fullName ?? 'Usuario';

  @override
  Future<void> reportUser({
    required String userId,
    required ReportReason reason,
    String? details,
    String? bookingId,
  }) async {
    await _latency();
    final me = _me;
    if (userId == me.id) throw AppError.from('HMY_NOT_FOUND');
    final today = DateTime.now().subtract(const Duration(days: 1));
    if (_reports.where((r) => r.reporterName == me.fullName && r.createdAt.isAfter(today)).length >= 5) {
      throw AppError.from('HMY_RATE_LIMITED');
    }
    _reports.add(
      AdminReport(
        id: _seq++,
        reporterName: me.fullName,
        reportedId: userId,
        reportedName: _nameOf(userId),
        bookingId: bookingId,
        reason: reason,
        details: (details ?? '').trim().isEmpty ? null : details!.trim(),
        status: CaseStatus.open,
        createdAt: DateTime.now(),
        reportsAgainst: _reports.where((r) => r.reportedId == userId).length + 1,
      ),
    );
  }

  @override
  Future<void> blockUser(String userId) async {
    await _latency();
    if (userId == _me.id) throw AppError.from('HMY_NOT_FOUND');
    _me.blocked.add(userId);
    _changes.add(null);
  }

  @override
  Future<void> unblockUser(String userId) async {
    await _latency();
    _me.blocked.remove(userId);
    _changes.add(null);
  }

  @override
  Future<void> recordConsent(String document, String version) async => _consents.add('${_me.id}:$document:$version');

  /// Solo para pruebas: si el usuario aceptó esa versión.
  bool hasConsent(String userId, String document, String version) => _consents.contains('$userId:$document:$version');

  @override
  Future<void> contactSupport({required String subject, required String body, String? bookingId}) async {
    await _latency();
    final me = _me;
    final today = DateTime.now().subtract(const Duration(days: 1));
    if (_tickets.where((t) => t.userName == me.fullName && t.createdAt.isAfter(today)).length >= 5) {
      throw AppError.from('HMY_RATE_LIMITED');
    }
    _tickets.add(
      AdminTicket(
        id: _seq++,
        userName: me.fullName,
        bookingId: bookingId,
        subject: subject.trim(),
        body: body.trim(),
        status: TicketStatus.open,
        createdAt: DateTime.now(),
      ),
    );
  }

  // ================================================================= Administración
  _Account _admin() {
    final me = _me;
    if (!me.roles.contains(AppRole.admin)) throw AppError.from('HMY_FORBIDDEN');
    return me;
  }

  // ------------------------------------------------- Centro de Control IA (demo)
  @override
  Future<AiOverview> aiOverview() async {
    await _latency(150);
    _admin();
    final now = DateTime.now();
    // Las mismas definiciones que la base y que las listas que abren.
    int n(AiCard c) => _aiItems.where((i) => c.matches(i, now)).length;
    final dayAgo = now.subtract(const Duration(hours: 24));
    return AiOverview(
      pendingApproval: n(AiCard.approval),
      open: n(AiCard.open),
      critical: n(AiCard.critical),
      high: n(AiCard.high),
      completed7d: n(AiCard.completed7d),
      failed7d: n(AiCard.failed7d),
      aiRecommendationsOpen: n(AiCard.aiRecommendations),
      aiCostMonthUsd: 0,
      aiBudgetMonthUsd: 0,
      lastReportDate: _dailyReports.isEmpty ? null : _dailyReports.first.date,
      lastMonitorRun: _agents['boss']?.lastOkRunAt,
      // Del historial, como la base: el mismo número que abre la lista.
      runsOk24h: _aiRuns.where((r) => r.status == 'ok' && r.startedAt.isAfter(dayAgo)).length,
      runsFailed24h: _aiRuns.where((r) => r.status == 'failed' && r.startedAt.isAfter(dayAgo)).length,
    );
  }

  @override
  Future<List<AiAgent>> aiAgents() async {
    await _latency(100);
    _admin();
    final now = DateTime.now();
    return [
      for (final a in _agents.values.toList()..sort((a, b) => a.number.compareTo(b.number)))
        a.copyWith(
          execution: a.executionAt(now),
          openItems: _aiItems.where((i) => i.agentKey == a.key && i.status.isPending).length,
        ),
    ];
  }

  /// Historial de ejecuciones de la demostración (como ai_agent_runs).
  final _aiRuns = <AiRun>[];

  void _recordRun(String key, String summary) {
    final a = _agents[key];
    if (a == null) return;
    final now = DateTime.now();
    _agents[key] = a.withRun(at: now, status: 'ok', summary: summary);
    _aiRuns.add(
      AiRun(id: _aiRuns.length + 1, agentKey: key, startedAt: now, finishedAt: now, status: 'ok', summary: summary),
    );
  }

  @override
  Future<Listed<AiItem>> aiCardItems(AiCard card) async {
    await _latency(100);
    _admin();
    final now = DateTime.now();
    final list = [
      for (final i in _aiItems)
        if (card.matches(i, now)) i,
    ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return Listed(list.take(100).toList(), list.length);
  }

  @override
  Future<AiRuns> aiRuns({required String status, Duration window = const Duration(hours: 24)}) async {
    await _latency(100);
    _admin();
    final to = DateTime.now();
    final from = to.subtract(window);
    final list = [
      for (final r in _aiRuns.reversed)
        if (r.status == status && r.startedAt.isAfter(from)) r,
    ];
    return AiRuns(
      items: list.take(AiRuns.limit).toList(),
      total: list.length,
      withAiModel: list.where((r) => r.usedAiModel).length,
      from: from,
      to: to,
    );
  }

  @override
  Future<List<AiItem>> aiItems({List<String> statuses = const []}) async {
    await _latency(100);
    _admin();
    return [
      for (final i in _aiItems)
        if (statuses.isEmpty || statuses.contains(i.status.key)) i,
    ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  @override
  Future<AiItemDetail> aiItemDetail(int itemId) async {
    await _latency(100);
    _admin();
    final i = _aiItems.where((i) => i.id == itemId).firstOrNull;
    if (i == null) throw AppError.from('HMY_NOT_FOUND');
    final agent = _agents[i.agentKey];
    return AiItemDetail(
      item: i,
      agentName: agent?.name ?? i.agentKey,
      agentNumber: agent?.number,
      decidedByName: i.decidedAt == null ? null : _me.fullName,
      history: [
        for (final e in _audit.reversed)
          if (e.targetTable == 'ai_items' && e.targetId == '$itemId')
            AiItemEvent(
              action: e.action,
              actorName: e.actorName,
              note: e.details['note'] as String?,
              createdAt: e.createdAt,
            ),
      ],
    );
  }

  @override
  Future<void> decideAiItem(int itemId, AiDecision decision, {String? note, String? authMethod}) async {
    await _latency(150);
    _admin();
    final idx = _aiItems.indexWhere((i) => i.id == itemId);
    if (idx < 0) throw AppError.from('HMY_NOT_FOUND');
    final i = _aiItems[idx];
    final cleanNote = (note ?? '').trim().isEmpty ? null : note!.trim();
    void requireNote() {
      if ((cleanNote ?? '').length < 3) throw AppError.from('HMY_NOTE_REQUIRED');
    }

    const closed = {
      AiItemStatus.approved,
      AiItemStatus.rejected,
      AiItemStatus.completed,
      AiItemStatus.failed,
      AiItemStatus.dismissed,
    };
    final AiItemStatus next;
    switch (decision) {
      case AiDecision.approve:
        if (closed.contains(i.status)) throw AppError.from('HMY_ALREADY_REVIEWED');
        if (i.status != AiItemStatus.pendingApproval) throw AppError.from('HMY_INVALID_STATUS');
        _requireConfirmation(authMethod ?? '');
        next = AiItemStatus.approved;
      case AiDecision.reject || AiDecision.moreInfo || AiDecision.dismiss:
        if (closed.contains(i.status)) throw AppError.from('HMY_ALREADY_REVIEWED');
        if (decision == AiDecision.dismiss && i.needsApproval) throw AppError.from('HMY_INVALID_STATUS');
        if (decision != AiDecision.moreInfo) requireNote();
        next = switch (decision) {
          AiDecision.reject => AiItemStatus.rejected,
          AiDecision.moreInfo => AiItemStatus.moreInfo,
          _ => AiItemStatus.dismissed,
        };
      case AiDecision.completed || AiDecision.failed:
        if (i.needsApproval && i.status != AiItemStatus.approved) throw AppError.from('HMY_INVALID_STATUS');
        if ({
          AiItemStatus.completed,
          AiItemStatus.failed,
          AiItemStatus.rejected,
          AiItemStatus.dismissed,
        }.contains(i.status)) {
          throw AppError.from('HMY_ALREADY_REVIEWED');
        }
        requireNote();
        next = decision == AiDecision.completed ? AiItemStatus.completed : AiItemStatus.failed;
    }
    final now = DateTime.now();
    _aiItems[idx] = i.copyWith(
      status: next,
      decisionNote: cleanNote,
      decidedAt: i.decidedAt ?? now,
      completedAt: next == AiItemStatus.completed ? now : null,
    );
    _log('ai_item.${decision.key}', 'ai_items', '$itemId', {'note': cleanNote, 'auth_method': authMethod});
  }

  @override
  Future<List<DailyReport>> dailyReports() async {
    await _latency(100);
    _admin();
    return List.of(_dailyReports);
  }

  @override
  Future<DailyReport> generateDailyReport() async {
    await _latency(200);
    final dash = await adminDashboard();
    final topups = _topups.values.expand((l) => l).where((t) => t.status == TopupStatus.pending);
    final now = DateTime.now();
    final day = DateTime(now.year, now.month, now.day).subtract(const Duration(days: 1));
    bool yesterday(DateTime d) => !d.isBefore(day) && d.isBefore(day.add(const Duration(days: 1)));
    final captures = _ledger.values
        .expand((l) => l)
        .where((l) => l.type == LedgerType.commissionCapture && yesterday(l.createdAt));
    final report = DailyReport(
      date: day,
      timezone: 'America/New_York',
      generatedAt: now,
      data: {
        'timezone_label': 'Hora de Miami',
        'snapshot_at': now.toUtc().toIso8601String(),
        // Solo lo que la demostración sabe contar; lo demás sale "Sin dato".
        'today': {
          'commission_revenue_bs': captures.fold<double>(0, (a, l) => a - (l.availableDelta + l.reservedDelta)),
          'commissions_captured': captures.length,
        },
        'previous_day': const <String, dynamic>{},
        'current': {
          'bookings_pending': dash.activeBookings,
          'recharges_pending': topups.length,
          'recharges_pending_bs': topups.fold<double>(0, (a, t) => a + t.amount),
          'verifications_pending': dash.pendingApplications,
          'disputes_open': dash.openDisputes,
          'decisions_pending': _aiItems.where((i) => i.status == AiItemStatus.pendingApproval).length,
        },
        'priorities': [
          if (topups.isNotEmpty) 'Verificar ${topups.length} recarga(s) pendiente(s).',
          if (dash.pendingApplications > 0) 'Revisar ${dash.pendingApplications} postulación(es) de profesionales.',
          if (_aiItems.any((i) => i.status == AiItemStatus.pendingApproval))
            'Decidir los pedidos que esperan tu aprobación.',
        ],
        'unavailable': const ['Modo demostración: datos de ejemplo', 'Gastos operativos: todavía no se registran'],
      },
    );
    _dailyReports.insert(0, report);
    _recordRun('daily_report', 'Reporte del ${report.date.toIso8601String().substring(0, 10)} (a pedido)');
    return report;
  }

  /// Como admin_run_all_checks: reglas, costos y monitores; el AI Boss al
  /// final. La demostración no crea avisos nuevos, pero sí registra cada
  /// ejecución para que el panel muestre solo lo que corrió.
  @override
  Future<AiCheckResult> runAllChecks() async {
    await _latency(100);
    _admin();
    for (final a in demoAgents) {
      if (a.status == AgentStatus.rules && a.key != 'daily_report' && a.key != 'boss') {
        _recordRun(a.key, 'Revisión de demostración; 0 aviso(s) nuevo(s)');
      }
    }
    _recordRun('boss', 'Revisión de demostración; 0 aviso(s) nuevo(s)');
    _log('ai.run_checks', 'ai_agent_runs', '', {'rules': 0, 'costs': 0, 'monitors': 0});
    return const AiCheckResult();
  }

  void _log(String action, String table, String id, [Map<String, dynamic> details = const {}]) => _audit.insert(
    0,
    AuditEntry(
      id: _auditActor.add(_me.id),
      actorName: _me.fullName,
      action: action,
      targetTable: table,
      targetId: id,
      details: details,
      createdAt: DateTime.now(),
    ),
  );

  AdminApplication _application(_Pro p) {
    final a = _account(p.id);
    return AdminApplication(
      userId: p.id,
      displayName: p.displayName,
      fullName: a?.fullName ?? p.displayName,
      phone: a?.phone,
      email: a?.email,
      cityName: _cityName(p.cityId),
      categoryName: _catName(p.primaryCategoryId),
      status: p.status,
      submittedAt: p.submittedAt,
      documents: p.docs.isEmpty ? p.documentCount : p.docs.length,
    );
  }

  @override
  Future<AdminDashboard> adminDashboard() async {
    await _latency(200);
    _admin();
    final today = DateTime.now();
    final start = DateTime(today.year, today.month, today.day);
    final topups = _topups.values.expand((l) => l);
    return AdminDashboard({
      'pending_applications': _pros.values
          .where((p) => p.status == VerificationStatus.submitted || p.status == VerificationStatus.underReview)
          .length,
      'pending_topups': topups.where((t) => t.status == TopupStatus.pending).length,
      'open_disputes': _bookings.values.where((b) => b.status == BookingStatus.disputed).length,
      'open_reports': _reports.where((r) => r.status.isOpen).length,
      'open_tickets': _tickets.where((t) => t.status != TicketStatus.closed).length,
      'bookings_today': _bookings.values.where((b) => _bookingIn(b, BookingFilter.today)).length,
      'active_bookings': _bookings.values.where((b) => _bookingIn(b, BookingFilter.active)).length,
      'approved_professionals': _pros.values.where((p) => p.status == VerificationStatus.approved).length,
      'available_professionals': _pros.values
          .where((p) => p.status == VerificationStatus.approved && p.available)
          .length,
      'users': _accounts.length,
      'active_commission_rules': _rules.where((r) => r.isActive).length,
      ..._ownerExtras(start),
    });
  }

  /// Lo mismo que owner_dashboard() calcula en el servidor, con los datos de
  /// la demostración.
  Map<String, dynamic> _ownerExtras(DateTime today) {
    final month = DateTime(today.year, today.month);
    final bookings = _bookings.values.where((b) => b.status != BookingStatus.draft).toList();
    DateTime? at(_Booking b, BookingStatus s) => b.events.where((e) => e.status == s).map((e) => e.at).lastOrNull;
    bool since(_Booking b, BookingStatus s, DateTime from) => b.status == s && (at(b, s)?.isAfter(from) ?? false);
    final completedMonth = bookings.where((b) => since(b, BookingStatus.completed, month));
    final docs = _pros.values
        .where((p) => p.status == VerificationStatus.submitted || p.status == VerificationStatus.underReview)
        .expand((p) => p.docs);
    final open = _cases.where((c) => c.status != OpsCaseStatus.resolved);
    final openReports = _reports.where((r) => r.status.isOpen);
    bool aiOpen(AiItem i) =>
        i.status == AiItemStatus.open || i.status == AiItemStatus.pendingApproval || i.status == AiItemStatus.moreInfo;
    final approvedPros = _pros.values.where((p) => p.status == VerificationStatus.approved);
    final last30 = DateTime.now().subtract(const Duration(days: 30));
    final recent = bookings.where((b) => b.createdAt.isAfter(last30));
    List<Map<String, dynamic>> top(Map<String, Map<String, dynamic>> rows) =>
        (rows.values.toList()..sort((a, b) => (b['count'] as int).compareTo(a['count'] as int))).take(10).toList();
    final byCity = <String, Map<String, dynamic>>{};
    final byDept = <String, Map<String, dynamic>>{};
    final byCat = <String, Map<String, dynamic>>{};
    for (final b in recent) {
      final city = DemoData.cities.firstWhere((c) => c.id == b.draft.cityId);
      final pros = approvedPros.where((p) => p.cityId == city.id).length;
      byCity.putIfAbsent(
        city.name,
        () => {'name': city.name, 'department': city.department, 'count': 0, 'professionals': pros},
      );
      byCity[city.name]!['count'] = (byCity[city.name]!['count'] as int) + 1;
      final dept = city.department ?? 'Sin departamento';
      byDept.putIfAbsent(dept, () => {'name': dept, 'count': 0});
      byDept[dept]!['count'] = (byDept[dept]!['count'] as int) + 1;
      final cat = _catName(b.draft.categoryId);
      byCat.putIfAbsent(cat, () => {'name': cat, 'count': 0});
      byCat[cat]!['count'] = (byCat[cat]!['count'] as int) + 1;
    }
    final me = _me.id;
    return {
      'completed_today': bookings.where((b) => since(b, BookingStatus.completed, today)).length,
      'cancelled_today': bookings.where((b) => since(b, BookingStatus.cancelled, today)).length,
      'completed_month': completedMonth.length,
      'cancelled_month': bookings.where((b) => since(b, BookingStatus.cancelled, month)).length,
      'customers': _accounts.values
          .where((a) => !a.roles.contains(AppRole.admin) && !approvedPros.any((p) => p.id == a.id))
          .length,
      'pending_documents': docs.where((d) => d.status == DocumentStatus.pending).length,
      'flagged_documents': docs.where((d) => d.status == DocumentStatus.pending && d.flagNote != null).length,
      'identity_in_review': _pros.values
          .expand((p) => p.identity)
          .where(
            (i) => const {
              IdentityStatus.created,
              IdentityStatus.inProgress,
              IdentityStatus.inReview,
              IdentityStatus.resubmitted,
            }.contains(i.status),
          )
          .length,
      'identity_sandbox_only': true,
      'identity_required': false,
      'revenue_month': completedMonth.fold<double>(0, (t, b) => t + (b.finalAmount ?? 0)),
      // Como Finanzas (0043): cobros del libro por fecha de cobro.
      'commission_month': _ledger.values
          .expand((l) => l)
          .where((l) => l.type == LedgerType.commissionCapture && !l.createdAt.isBefore(month))
          .fold<double>(0, (t, l) => t - (l.availableDelta + l.reservedDelta)),
      'wallet_available': _wallets.values.fold<double>(0, (t, w) => t + w[0]),
      'wallet_reserved': _wallets.values.fold<double>(0, (t, w) => t + w[1]),
      'pending_topups_amount': _topups.values
          .expand((l) => l)
          .where((t) => t.status == TopupStatus.pending)
          .fold<double>(0, (t, r) => t + r.amount),
      'safety_incidents':
          openReports.where((r) => r.reason == ReportReason.harassment).length +
          open.where((c) => c.category == 'safety' && c.kind != OpsCaseKind.report).length,
      'fraud_alerts':
          openReports.where((r) => r.reason == ReportReason.fraud || r.reason == ReportReason.overcharge).length +
          open.where((c) => c.category == 'fraud' && c.kind != OpsCaseKind.report).length +
          _aiItems.where((i) => i.agentKey == 'fraud' && aiOpen(i)).length,
      'urgent_cases': open.where((c) => c.priority == 'urgent').length,
      'escalated_to_owner': open.where((c) => c.status == OpsCaseStatus.escalated && c.escalatedTo == 'owner').length,
      'unassigned_cases': open.where((c) => c.assignedTo == null).length,
      'active_managers': _staff.values.where((m) => m.role == StaffRole.manager && m.status == 'active').length,
      'active_employees': _staff.values.where((m) => m.role == StaffRole.employee && m.status == 'active').length,
      'ai_pending': _aiItems.where(aiOpen).length,
      'ai_critical': _aiItems
          .where((i) => aiOpen(i) && (i.severity == AiSeverity.high || i.severity == AiSeverity.critical))
          .length,
      'costs_month_usd': 0,
      'paid_vendors': _vendors.values.where((v) => v.status == VendorStatus.paid).length,
      'unread_notifications': _notifications.where((n) => n.userId == me && n.value.readAt == null).length,
      'audit_24h': _audit.where((a) => a.createdAt.isAfter(DateTime.now().subtract(const Duration(hours: 24)))).length,
      'demand_municipality': top(byCity),
      'demand_department': top(byDept),
      'demand_category': top(byCat),
      'coverage_gaps': top({
        for (final e in byCity.entries)
          if (e.value['professionals'] == 0)
            e.key: {'name': e.value['name'], 'department': e.value['department'], 'count': e.value['count']},
      }),
    };
  }

  @override
  Future<List<AdminApplication>> adminApplications({String status = 'pending'}) async {
    await _latency(200);
    _need('applications.list');
    bool keep(_Pro p) => switch (status) {
      'pending' => p.status == VerificationStatus.submitted || p.status == VerificationStatus.underReview,
      'all' => true,
      _ => p.status.key == status,
    };
    final list = _pros.values.where(keep).map(_application).toList()
      ..sort((a, b) => (a.submittedAt ?? DateTime(2000)).compareTo(b.submittedAt ?? DateTime(2000)));
    return list;
  }

  @override
  Future<AdminApplicationDetail> adminApplicationDetail(String professionalId) async {
    await _latency(200);
    _need('applications.list');
    final p = _pros[professionalId];
    if (p == null) throw AppError.from('HMY_NOT_FOUND');
    return AdminApplicationDetail(
      summary: _application(p),
      bio: p.bio,
      yearsExperience: p.years,
      reviewNote: p.reviewNote,
      zones: [for (final z in DemoData.zones.where((z) => p.zoneIds.contains(z.id))) z.name],
      categories: [_catName(p.primaryCategoryId)],
      documents: [
        for (final d in p.docs)
          AdminDocument(id: d.id, docType: d.type, status: d.status, bytes: d.bytes, reviewNote: d.note),
      ],
      history: p.history.reversed.toList(),
      identityChecks: p.identity.reversed.toList(),
      identityCheckRequired: _identityRequired,
    );
  }

  @override
  Future<void> reviewApplication(String professionalId, VerificationStatus decision, {String? note}) async {
    await _latency();
    _need('applications.decide');
    final p = _pros[professionalId];
    if (p == null) throw AppError.from('HMY_NO_APPLICATION');
    final needsReason =
        decision == VerificationStatus.rejected || decision == VerificationStatus.reverificationRequired;
    if (needsReason && (note ?? '').trim().isEmpty) throw AppError.from('HMY_REASON_REQUIRED');
    final approving =
        decision == VerificationStatus.approved &&
        p.status != VerificationStatus.approved &&
        p.status != VerificationStatus.suspended;
    final idAccepted = {
      for (final d in p.docs)
        if (d.status == DocumentStatus.accepted && (d.type == 'ci_anverso' || d.type == 'ci_reverso')) d.type,
    };
    if (approving && idAccepted.length < 2) throw AppError.from('HMY_ID_DOCUMENTS_REQUIRED');
    // Como en el servidor: el gerente no pasa por alto una verificación real rechazada.
    final real = p.identity.where((c) => !c.sandbox).toList();
    if (decision == VerificationStatus.approved &&
        !_me.roles.contains(AppRole.admin) &&
        real.isNotEmpty &&
        real.first.status == IdentityStatus.declined) {
      throw AppError.from('HMY_IDENTITY_DECLINED');
    }
    if (approving && _identityRequired && !p.identity.any((c) => !c.sandbox && c.status == IdentityStatus.approved)) {
      throw AppError.from('HMY_IDENTITY_CHECK_REQUIRED');
    }
    p
      ..status = decision
      ..reviewNote = note
      ..history.add((status: decision, note: note, at: DateTime.now()));
    if (decision != VerificationStatus.approved) p.available = false;
    final a = _account(professionalId);
    if (decision == VerificationStatus.approved) {
      a?.roles.add(AppRole.professional);
      _wallets.putIfAbsent(professionalId, () => [0, 0]);
      _notify(professionalId, 'verification', '¡Tu perfil fue aprobado!', 'Ya puedes recibir pedidos ¡Ya!.');
    } else if (decision == VerificationStatus.rejected || decision == VerificationStatus.suspended) {
      if (a != null && a.activeRole == AppRole.professional) a.activeRole = AppRole.customer;
      _notify(professionalId, 'verification', 'Revisamos tu perfil', note ?? decision.label);
    } else if (decision == VerificationStatus.reverificationRequired) {
      _notify(professionalId, 'verification', 'Necesitamos que revises tu postulación', note!);
    }
    _log('professional.${decision.key}', 'professional_profiles', professionalId, {'note': ?note});
    _changes.add(null);
  }

  @override
  Future<void> reviewDocument(int documentId, DocumentStatus status, {String? note}) async {
    await _latency();
    _need('documents.review');
    if (status == DocumentStatus.rejected && (note ?? '').trim().isEmpty) throw AppError.from('HMY_REASON_REQUIRED');
    final doc = _pros.values.expand((p) => p.docs).where((d) => d.id == documentId).firstOrNull;
    if (doc == null) throw AppError.from('HMY_NOT_FOUND');
    doc
      ..status = status
      ..note = (note ?? '').trim().isEmpty ? null : note!.trim();
    _log('document.${status.key}', 'professional_documents', '$documentId', {'note': ?note});
  }

  @override
  Future<List<AdminTopup>> adminTopups({String status = 'pending'}) async {
    await _latency(200);
    _admin();
    return [
      for (final e in _topups.entries)
        for (final t in e.value)
          if (status == 'all' || t.status.key == status)
            AdminTopup(
              id: t.id,
              professionalId: e.key,
              displayName: _nameOf(e.key),
              amount: t.amount,
              methodName: 'QR (ejemplo)',
              reference: t.reference,
              proofBytes: _topupProofs[t.id],
              status: t.status,
              reviewNote: t.reviewNote,
              createdAt: t.createdAt,
            ),
    ]..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  }

  @override
  Future<void> reviewTopup(int topupId, {required bool approve, String? note}) async {
    await _latency();
    _admin();
    for (final e in _topups.entries) {
      final i = e.value.indexWhere((t) => t.id == topupId);
      if (i < 0) continue;
      final t = e.value[i];
      if (t.status != TopupStatus.pending) throw AppError.from('HMY_ALREADY_REVIEWED');
      e.value[i] = TopupRequest(
        id: t.id,
        amount: t.amount,
        status: approve ? TopupStatus.approved : TopupStatus.rejected,
        reference: t.reference,
        reviewNote: note,
        createdAt: t.createdAt,
      );
      if (approve) {
        _topupCreditedAt[t.id] = DateTime.now();
        _post(e.key, LedgerType.topup, t.amount, 0, 'Recarga acreditada');
        _notify(e.key, 'topup', 'Recarga acreditada', 'Sumamos ${t.amount.toStringAsFixed(2)} Bs a tu billetera.');
      } else {
        _notify(e.key, 'topup', 'Recarga rechazada', note ?? 'No pudimos verificar el pago.');
      }
      _log(approve ? 'topup.approve' : 'topup.reject', 'topup_requests', '$topupId', {'amount': t.amount});
      _changes.add(null);
      return;
    }
    throw AppError.from('HMY_NOT_FOUND');
  }

  @override
  Future<void> adminVerifyArrival(String bookingCode, String reason) async {
    await _latency();
    _admin();
    if (reason.trim().length < 5) throw AppError.from('HMY_REASON_REQUIRED');
    final code = bookingCode.trim().toUpperCase();
    final b = _bookings.values.where((x) => x.code == code).firstOrNull;
    if (b == null) throw AppError.from('HMY_NOT_FOUND');
    _requireStatus(b, {BookingStatus.onTheWay});
    if (b.arrivalVerifiedAt != null) throw AppError.from('HMY_ARRIVAL_ALREADY_VERIFIED');
    _verifyArrival(b, method: 'admin');
    _log('arrival.admin_verified', 'bookings', b.id, {'reason': reason.trim()});
    for (final u in [b.professionalId!, b.customerId]) {
      _notify(u, 'arrival', 'Llegada verificada por el equipo', reason.trim(), bookingId: b.id);
    }
  }

  @override
  Future<void> adjustWallet(String professionalId, double amount, String reason) async {
    await _latency();
    _admin();
    if (reason.trim().isEmpty) throw AppError.from('HMY_REASON_REQUIRED');
    final w = _wallets[professionalId];
    if (w == null) throw AppError.from('HMY_WALLET_NOT_FOUND');
    if (w[0] + amount < 0) throw AppError.from('HMY_INSUFFICIENT_BALANCE');
    _post(professionalId, LedgerType.adjustment, amount, 0, reason.trim());
    _log('wallet.adjust', 'wallets', professionalId, {'amount': amount, 'reason': reason.trim()});
  }

  @override
  Future<List<AdminReport>> adminReports({String status = 'open'}) async {
    await _latency(200);
    _need('reports.view');
    return [
      for (final r in _reports)
        if (status == 'all' || (status == 'open' ? r.status.isOpen : r.status.key == status))
          AdminReport(
            id: r.id,
            reporterName: r.reporterName,
            reportedId: r.reportedId,
            reportedName: r.reportedName,
            bookingId: r.bookingId,
            reason: r.reason,
            details: r.details,
            status: r.status,
            resolution: r.resolution,
            createdAt: r.createdAt,
            reportsAgainst: _reports.where((x) => x.reportedId == r.reportedId).length,
          ),
    ];
  }

  @override
  Future<void> reviewReport(int reportId, CaseStatus status, {String? resolution}) async {
    await _latency();
    _need('reports.decide');
    final closing = status == CaseStatus.resolved || status == CaseStatus.dismissed;
    if (closing && (resolution ?? '').trim().isEmpty) throw AppError.from('HMY_REASON_REQUIRED');
    final i = _reports.indexWhere((r) => r.id == reportId);
    if (i < 0) throw AppError.from('HMY_NOT_FOUND');
    final r = _reports[i];
    _reports[i] = AdminReport(
      id: r.id,
      reporterName: r.reporterName,
      reportedId: r.reportedId,
      reportedName: r.reportedName,
      bookingId: r.bookingId,
      reason: r.reason,
      details: r.details,
      status: status,
      resolution: (resolution ?? '').trim().isEmpty ? r.resolution : resolution!.trim(),
      createdAt: r.createdAt,
    );
    _log('report.${status.key}', 'user_reports', '$reportId', {'resolution': ?resolution});
  }

  @override
  Future<List<AdminDispute>> adminDisputes({String status = 'open'}) async {
    await _latency(200);
    _need('disputes.view');
    return [
      for (final b in _bookings.values)
        if (b.disputeReason != null && (status == 'all' || (status == 'open') == (b.status == BookingStatus.disputed)))
          AdminDispute(
            bookingId: b.id,
            reason: b.disputeReason!,
            isOpen: b.status == BookingStatus.disputed,
            resolution: b.disputeResolution,
            createdAt: b.disputeAt ?? b.createdAt,
            openedByName: _nameOf(b.disputeOpenedBy ?? b.customerId),
            customerName: _nameOf(b.customerId),
            professionalName: b.professionalId == null ? null : _nameOf(b.professionalId!),
            categoryName: _catName(b.draft.categoryId),
          ),
    ];
  }

  @override
  Future<void> resolveDispute(String bookingId, DisputeOutcome outcome, String resolution) async {
    await _latency();
    final admin = _admin();
    if (resolution.trim().isEmpty) throw AppError.from('HMY_REASON_REQUIRED');
    final b = _get(bookingId);
    _requireStatus(b, {BookingStatus.disputed});
    b.disputeResolution = resolution.trim();
    _move(b, outcome.status, note: resolution.trim(), actorId: admin.id);
    _log('dispute.resolve', 'bookings', bookingId, {'outcome': outcome.status.key, 'resolution': resolution.trim()});
  }

  @override
  Future<List<AdminTicket>> adminTickets({String status = 'open'}) async {
    await _latency(200);
    _need('tickets.view');
    return [
      for (final t in _tickets)
        if (status == 'all' || (status == 'open' ? t.status != TicketStatus.closed : t.status.key == status)) t,
    ];
  }

  @override
  Future<void> updateTicket(int ticketId, TicketStatus status, {String? note}) async {
    await _latency();
    _need('tickets.reply');
    final i = _tickets.indexWhere((t) => t.id == ticketId);
    if (i < 0) throw AppError.from('HMY_NOT_FOUND');
    final t = _tickets[i];
    _tickets[i] = AdminTicket(
      id: t.id,
      userName: t.userName,
      bookingId: t.bookingId,
      subject: t.subject,
      body: t.body,
      status: status,
      adminNote: (note ?? '').trim().isEmpty ? t.adminNote : note!.trim(),
      createdAt: t.createdAt,
    );
    final user = _accounts.values.where((a) => a.fullName == t.userName).firstOrNull;
    if (user != null && (note ?? '').trim().isNotEmpty) {
      _notify(user.id, 'support', 'Respuesta de soporte', note!.trim());
    }
    _log('ticket.${status.key}', 'support_tickets', '$ticketId', {'note': ?note});
  }

  @override
  Future<List<AdminUser>> adminUsers(String query) async {
    await _latency(200);
    _need('users.view');
    final q = query.trim().toLowerCase();
    final list = [
      for (final a in _accounts.values)
        if (a.phone != null || a.id.startsWith('demo-') || _pros.containsKey(a.id))
          if (q.isEmpty ||
              a.fullName.toLowerCase().contains(q) ||
              a.email.toLowerCase().contains(q) ||
              (a.phone ?? '').contains(q))
            AdminUser(
              id: a.id,
              fullName: a.fullName,
              email: a.email,
              phone: a.phone,
              cityName: a.cityId == null ? null : _cityName(a.cityId!),
              roles: {...a.roles},
              professionalStatus: _pros[a.id]?.status,
              suspendedAt: a.suspendedAt,
              suspensionReason: a.suspensionReason,
              reportsAgainst: _reports.where((r) => r.reportedId == a.id).length,
            ),
    ]..sort((a, b) => (b.isSuspended ? 1 : 0).compareTo(a.isSuspended ? 1 : 0));
    return list.take(50).toList();
  }

  @override
  Future<void> setSuspension(String userId, {required bool suspend, String? reason}) async {
    await _latency();
    final admin = _need('users.suspend');
    final a = _account(userId);
    if (a == null) throw AppError.from('HMY_NOT_FOUND');
    if (a.id == admin.id || a.roles.contains(AppRole.admin)) throw AppError.from('HMY_FORBIDDEN');
    if (!admin.roles.contains(AppRole.admin) && _staff.containsKey(a.id)) throw AppError.from('HMY_FORBIDDEN');
    if (suspend && (reason ?? '').trim().isEmpty) throw AppError.from('HMY_REASON_REQUIRED');
    a
      ..suspendedAt = suspend ? (a.suspendedAt ?? DateTime.now()) : null
      ..suspensionReason = suspend ? reason!.trim() : null;
    if (suspend) a.activeRole = AppRole.customer;
    final p = _pros[userId];
    if (p != null && suspend && p.status == VerificationStatus.approved) {
      await reviewApplication(userId, VerificationStatus.suspended, note: reason);
    } else if (p != null && !suspend && p.status == VerificationStatus.suspended) {
      await reviewApplication(userId, VerificationStatus.approved, note: 'Suspensión levantada');
    }
    _notify(
      userId,
      'account',
      suspend ? 'Tu cuenta fue suspendida' : 'Tu cuenta está activa otra vez',
      suspend
          ? 'Motivo: ${reason!.trim()}. Si crees que es un error, escríbenos desde Ayuda.'
          : 'Ya puedes volver a usar HandiMan ¡Ya!.',
    );
    _log(suspend ? 'account.suspend' : 'account.reactivate', 'profiles', userId, {'reason': ?reason});
    _changes.add(null);
  }

  @override
  Future<List<CommissionRule>> commissionRules() async {
    await _latency(150);
    return List.of(_rules);
  }

  @override
  Future<void> saveCommissionRule(CommissionRule r) async {
    await _latency();
    _admin();
    if (r.name.trim().length < 3) throw AppError.from('HMY_NAME_REQUIRED');
    if (r.ratePercent == null && r.fixedFee == null) throw AppError.from('HMY_COMMISSION_REQUIRED');
    final saved = CommissionRule(
      id: r.id ?? _seq++,
      name: r.name.trim(),
      categoryId: r.categoryId,
      cityId: r.cityId,
      ratePercent: r.ratePercent,
      fixedFee: r.fixedFee,
      reserveAmount: r.reserveAmount,
      minBalance: r.minBalance,
      captureAt: r.captureAt,
      isActive: r.isActive,
    );
    final i = _rules.indexWhere((x) => x.id == r.id);
    if (r.id != null && i < 0) throw AppError.from('HMY_NOT_FOUND');
    if (i < 0) {
      _rules.add(saved);
    } else {
      _rules[i] = saved;
    }
    _log(i < 0 ? 'commission_rules.insert' : 'commission_rules.update', 'commission_rules', '${saved.id}');
  }

  @override
  Future<List<CatalogItem>> adminCategories() async {
    await _latency(150);
    _admin();
    return [for (final c in _cats) CatalogItem(id: c.id, name: c.name, subtitle: c.description, isActive: c.isActive)];
  }

  @override
  Future<void> setCategoryActive(int id, bool active) async {
    await _latency();
    _admin();
    final i = _cats.indexWhere((c) => c.id == id);
    _cats[i] = _cats[i].copyWith(isActive: active);
    _log('service_categories.update', 'service_categories', '$id', {'is_active': active});
  }

  @override
  Future<List<ServiceCategory>> adminServiceCategories() async {
    await _latency(150);
    _admin();
    return List.of(_cats)..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
  }

  @override
  Future<void> saveCategory(ServiceCategory c) async {
    await _latency();
    _admin();
    if (c.name.trim().length < 2) throw AppError.from('HMY_NAME_REQUIRED');
    if (c.id == 0) {
      final id = _cats.fold(0, (m, e) => max(m, e.id)) + 1;
      _cats.add(
        ServiceCategory(
          id: id,
          slug: c.slug,
          name: c.name.trim(),
          icon: c.icon,
          description: c.description,
          allowsYa: c.allowsYa,
          requiredDoc: c.requiredDoc,
          safetyNote: c.safetyNote,
          proNote: c.proNote,
          isActive: c.isActive,
          sortOrder: c.sortOrder,
        ),
      );
      // Igual que en la base: toda categoría nueva nace con "Otro servicio".
      _problems.add(
        ServiceProblem(
          id: _nextProblemId(),
          categoryId: id,
          name: 'Otro servicio',
          icon: 'other',
          isOther: true,
          sortOrder: 1000,
        ),
      );
      _log('service_categories.insert', 'service_categories', '$id', {'name': c.name});
    } else {
      final i = _cats.indexWhere((e) => e.id == c.id);
      _cats[i] = c;
      _log('service_categories.update', 'service_categories', '${c.id}', {'name': c.name});
    }
  }

  @override
  Future<void> reorderCategories(List<int> orderedIds) async {
    await _latency();
    _admin();
    for (var i = 0; i < orderedIds.length; i++) {
      final j = _cats.indexWhere((c) => c.id == orderedIds[i]);
      _cats[j] = _cats[j].copyWith(sortOrder: (i + 1) * 10);
    }
    _log('service_categories.update', 'service_categories', 'orden');
  }

  int _nextProblemId() => _problems.fold(0, (m, e) => max(m, e.id)) + 1;

  @override
  Future<List<ServiceProblem>> adminProblems(int categoryId) async {
    await _latency(150);
    _admin();
    return _problems.where((p) => p.categoryId == categoryId).toList()..sort(_byOrder);
  }

  @override
  Future<void> saveProblem(ServiceProblem p) async {
    await _latency();
    _admin();
    if (p.name.trim().length < 2) throw AppError.from('HMY_NAME_REQUIRED');
    if (_problems.any((e) => e.id != p.id && e.categoryId == p.categoryId && e.name == p.name.trim())) {
      throw const AppError('Ya existe una opción con ese nombre en esta categoría.');
    }
    if (p.id == 0) {
      final id = _nextProblemId();
      _problems.add(
        ServiceProblem(
          id: id,
          categoryId: p.categoryId,
          name: p.name.trim(),
          icon: p.icon,
          isOther: p.isOther,
          isActive: p.isActive,
          sortOrder: p.sortOrder,
        ),
      );
      _log('service_problems.insert', 'service_problems', '$id', {'name': p.name});
    } else {
      final i = _problems.indexWhere((e) => e.id == p.id);
      _problems[i] = p.copyWith(name: p.name.trim());
      _log('service_problems.update', 'service_problems', '${p.id}', {'name': p.name, 'is_active': p.isActive});
    }
  }

  @override
  Future<void> reorderProblems(List<int> orderedIds) async {
    await _latency();
    _admin();
    for (var i = 0; i < orderedIds.length; i++) {
      final j = _problems.indexWhere((p) => p.id == orderedIds[i]);
      _problems[j] = _problems[j].copyWith(sortOrder: (i + 1) * 10);
    }
    _log('service_problems.update', 'service_problems', 'orden');
  }

  @override
  Future<List<CatalogItem>> adminCities() async {
    await _latency(150);
    _admin();
    return [
      for (final c in DemoData.cities) CatalogItem(id: c.id, name: c.name, isActive: !_inactiveCities.contains(c.id)),
    ];
  }

  @override
  Future<void> setCityActive(int id, bool active) async {
    await _latency();
    _admin();
    active ? _inactiveCities.remove(id) : _inactiveCities.add(id);
    _log('cities.update', 'cities', '$id', {'is_active': active});
  }

  @override
  Future<List<CatalogItem>> adminPromotions() async {
    await _latency(150);
    _admin();
    return [
      for (final p in _promos)
        CatalogItem(id: p.promo.id, name: p.promo.title, subtitle: p.promo.subtitle, isActive: p.active),
    ];
  }

  @override
  Future<void> setPromotionActive(int id, bool active) async {
    await _latency();
    _admin();
    final i = _promos.indexWhere((p) => p.promo.id == id);
    if (i < 0) throw AppError.from('HMY_NOT_FOUND');
    _promos[i] = (promo: _promos[i].promo, active: active);
    _log('promotions.update', 'promotions', '$id', {'is_active': active});
  }

  @override
  Future<void> createPromotion({required String title, String? subtitle, int? cityId}) async {
    await _latency();
    _admin();
    if (title.trim().length < 3) throw AppError.from('HMY_NAME_REQUIRED');
    final promo = Promotion(
      id: _seq++,
      title: title.trim(),
      subtitle: (subtitle ?? '').trim().isEmpty ? null : subtitle!.trim(),
      ctaLabel: '¡Encuéntrala Ya!',
      ctaRoute: '/buscar',
    );
    _promos.add((promo: promo, active: true));
    _log('promotions.insert', 'promotions', '${promo.id}', {'title': promo.title});
  }

  @override
  Future<List<AuditEntry>> auditLog() async {
    await _latency(150);
    _admin();
    return List.of(_audit);
  }

  // ========================================================= Costos operativos
  bool _identityRequired = false;

  final Map<String, _Vendor> _vendors = {
    for (final v in [
      _Vendor(
        'supabase',
        'Supabase (base de datos, cuentas y archivos)',
        'infraestructura',
        'mes',
        'mensual',
        0,
        0,
        25,
        VendorStatus.free,
        notes: 'Hoy en el plan Free (USD 0). El plan Pro cuesta USD 25 al mes.',
      ),
      _Vendor(
        'didit_kyc',
        'Didit: identidad (carnet, prueba de vida y rostro)',
        'identidad',
        'verificación',
        'uso',
        30,
        0.33,
        0,
        VendorStatus.sandbox,
        sandbox: true,
        notes: 'Sandbox gratis. Real: desde el 1/11/2026, USD 10 de crédito al mes (unas 30 verificaciones).',
      ),
      _Vendor('didit_segip', 'Didit: consulta al SEGIP', 'identidad', 'consulta', 'uso', 0, 0.20, 0, VendorStatus.off),
      _Vendor(
        'veriff',
        'Veriff (respaldo, sin integrar)',
        'identidad',
        'verificación',
        'uso',
        0,
        0.80,
        49,
        VendorStatus.off,
      ),
      _Vendor(
        'whatsapp_otp',
        'WhatsApp: códigos de acceso (Meta)',
        'mensajes',
        'mensaje',
        'uso',
        0,
        0.0113,
        0,
        VendorStatus.off,
      ),
      _Vendor(
        'sms_otp',
        'SMS: códigos de acceso (Twilio)',
        'mensajes',
        'mensaje',
        'uso',
        0,
        0.2215,
        0,
        VendorStatus.off,
      ),
      _Vendor('push', 'Notificaciones push (Firebase y Apple)', 'mensajes', 'aviso', 'uso', 0, 0, 0, VendorStatus.off),
      _Vendor('ai_model', 'Modelo de IA', 'ia', 'USD', 'uso', 0, 1, 0, VendorStatus.off),
      _Vendor('apple_dev', 'Apple Developer Program', 'tiendas', 'año', 'anual', 0, 0, 99, VendorStatus.off),
      _Vendor('google_play', 'Google Play (registro)', 'tiendas', 'pago único', 'unico', 0, 0, 25, VendorStatus.off),
      _Vendor('trip_page', 'Página pública del viaje compartido', 'web', 'mes', 'mensual', 0, 0, 0, VendorStatus.off),
    ])
      v.key: v,
  };

  @override
  Future<CostDashboard> costDashboard() async {
    await _latency(150);
    _admin();
    final now = DateTime.now().toUtc();
    final start = DateTime.utc(now.year, now.month);
    final days = DateTime.utc(now.year, now.month + 1).difference(start).inDays.toDouble();
    final elapsed = max(now.difference(start).inMinutes / 1440, 1.0);
    final vendors = <CostVendor>[];
    final alerts = <({String vendor, CostLevel level, String message})>[];
    var projectedTotal = 0.0;
    for (final v in _vendors.values) {
      final projectedUnits = (v.used / elapsed * days * 10).roundToDouble() / 10;
      var projected = v.status == VendorStatus.paid && v.price > 0
          ? min(max(projectedUnits - v.freeUnits, 0) * v.price, v.cap)
          : 0.0;
      if (v.status == VendorStatus.paid) {
        projected += v.billing == 'mensual' ? v.fixed : (v.billing == 'anual' ? v.fixed / 12 : 0);
      }
      final level = v.blocked > 0
          ? CostLevel.blocked
          : v.freeUnits > 0 && v.used >= v.freeUnits * 0.8
          ? CostLevel.nearFreeLimit
          : CostLevel.ok;
      if (level == CostLevel.blocked) {
        alerts.add((
          vendor: v.key,
          level: level,
          message: '${v.name}: se frenaron ${v.blocked} usos este mes. No se cobró nada de más.',
        ));
      } else if (level == CostLevel.nearFreeLimit) {
        alerts.add((
          vendor: v.key,
          level: level,
          message: '${v.name}: se usó ${v.used.toStringAsFixed(0)} de ${v.freeUnits} gratis este mes.',
        ));
      }
      projectedTotal += projected;
      vendors.add(
        CostVendor(
          key: v.key,
          name: v.name,
          category: v.category,
          unit: v.unit,
          billing: v.billing,
          status: v.status,
          freeUnits: v.freeUnits,
          usedUnits: v.used,
          sandboxUnits: v.sandboxUsed,
          freeUsedPercent: v.freeUnits > 0 ? min(100, (100 * v.used / v.freeUnits).round()) : null,
          unitPriceUsd: v.price,
          fixedUsd: v.fixed,
          costSoFarUsd: v.spent,
          projectedUnits: projectedUnits,
          projectedUsd: projected,
          monthlyCapUsd: v.cap,
          blocked: v.blocked,
          level: level,
          notes: v.notes,
        ),
      );
    }
    return CostDashboard(
      month: '${now.year}-${now.month.toString().padLeft(2, '0')}',
      daysElapsed: elapsed,
      daysInMonth: days,
      costSoFarUsd: _vendors.values.fold(0, (a, v) => a + v.spent),
      projectedUsd: projectedTotal,
      vendors: vendors,
      alerts: alerts,
      history: [
        for (var i = 0; i < 6; i++)
          (
            month:
                '${DateTime.utc(now.year, now.month - i).year}-${DateTime.utc(now.year, now.month - i).month.toString().padLeft(2, '0')}',
            costUsd: i == 0 ? _vendors.values.fold(0.0, (a, v) => a + v.spent) : 0.0,
          ),
      ],
    );
  }

  @override
  Future<void> setVendor(String key, VendorStatus status, {double monthlyCapUsd = 0, String? authMethod}) async {
    await _latency();
    _admin();
    final v = _vendors[key];
    if (v == null) throw AppError.from('HMY_NOT_FOUND');
    if (monthlyCapUsd < 0 || monthlyCapUsd > 10000) throw AppError.from('HMY_INVALID_SETTING');
    if (status == VendorStatus.paid && monthlyCapUsd == 0 && v.billing == 'uso') {
      throw AppError.from('HMY_CAP_REQUIRED');
    }
    if (status == VendorStatus.sandbox && !v.sandbox) throw AppError.from('HMY_NO_SANDBOX');
    if (status.index > v.status.index || (status == VendorStatus.paid && monthlyCapUsd > v.cap)) {
      _requireConfirmation(authMethod ?? '');
    }
    _log('costs.vendor', 'cost_vendors', key, {'from': v.status.key, 'to': status.key, 'cap_usd': monthlyCapUsd});
    v
      ..status = status
      ..cap = status == VendorStatus.paid ? monthlyCapUsd : 0;
  }

  @override
  Future<int> runCostMonitors() async {
    await _latency(100);
    _admin();
    return 0;
  }

  @override
  Future<void> setIdentityCheckRequired(bool required, {String? authMethod}) async {
    await _latency();
    _admin();
    if (!required) _requireConfirmation(authMethod ?? '');
    _identityRequired = required;
    _log('settings.identity_check', 'app_settings', 'identity_check', {'required': required});
  }

  // ================================================================ Equipo (demo)
  // Igual que 0035_management_roles: el propietario es el admin; gerente y
  // empleado tienen su fila con estado; cada acción revisa el permiso.
  final _staff = <String, _Staff>{};
  final _cases = <_Case>[];

  static const _rolePermissions = <StaffRole, Set<String>>{
    StaffRole.manager: {
      'ops.dashboard', 'cases.view_all', 'cases.assign', 'cases.update', 'cases.note', 'cases.reply', //
      'cases.escalate', 'applications.list', 'applications.decide', 'documents.view', 'documents.review',
      'documents.flag', 'reports.view', 'reports.decide', 'disputes.view', 'tickets.view', 'tickets.reply',
      'users.view', 'users.suspend', 'staff.view', 'bookings.monitor',
    },
    StaffRole.employee: {
      'ops.dashboard',
      'cases.view_own',
      'cases.update_own',
      'cases.note',
      'cases.reply',
      'cases.escalate',
      'documents.flag',
    },
  };

  void _seedStaff() {
    final manager = _Account(id: 'demo-gerente', email: 'gerente@demo.bo', fullName: 'Lucía Fernández', cityId: 1)
      ..phone = managerPhone
      ..confirmed = true
      ..onboardingDone = true;
    _accounts[manager.email] = manager;
    _staff[manager.id] = _Staff(StaffRole.manager);
    const names = ['Diego Rojas', 'Paola Quiroga', 'Marco Antezana', 'Elena Vargas', 'Tomás Céspedes'];
    for (var i = 0; i < employeePhones.length; i++) {
      final e = _Account(id: 'demo-empleado-${i + 1}', email: 'empleado${i + 1}@demo.bo', fullName: names[i], cityId: 1)
        ..phone = employeePhones[i]
        ..confirmed = true
        ..onboardingDone = true;
      _accounts[e.email] = e;
      _staff[e.id] = _Staff(StaffRole.employee);
    }
    _syncCases();
    // Un caso de soporte ya asignado a la primera empleada, para ver el panel.
    final support = _cases.where((c) => c.kind == OpsCaseKind.support).firstOrNull;
    if (support != null) {
      support
        ..assignedTo = 'demo-empleado-1'
        ..assignedAt = DateTime.now();
    }
  }

  StaffRole? _staffRoleOf(String userId) {
    final a = _account(userId);
    if (a == null) return null;
    if (a.roles.contains(AppRole.admin)) return StaffRole.owner;
    final st = _staff[userId];
    if (st == null || st.status != 'active' || a.suspendedAt != null) return null;
    return st.role;
  }

  bool _can(String permission) {
    final role = _staffRoleOf(_me.id);
    if (role == null) return false;
    return role == StaffRole.owner || (_rolePermissions[role]?.contains(permission) ?? false);
  }

  _Account _need(String permission) {
    if (!_can(permission)) throw AppError.from('HMY_FORBIDDEN');
    return _me;
  }

  /// Como los disparadores del servidor: cada ticket, reporte, disputa y
  /// postulación tiene su caso.
  void _syncCases() {
    bool has(OpsCaseKind k, String ref) => _cases.any((c) => c.kind == k && c.refId == ref);
    for (final t in _tickets) {
      if (!has(OpsCaseKind.support, '${t.id}') && t.status != TicketStatus.closed) {
        _cases.add(_Case(_seq++, OpsCaseKind.support, '${t.id}', t.subject, createdAt: t.createdAt));
      }
    }
    for (final r in _reports) {
      if (!has(OpsCaseKind.report, '${r.id}') && (r.status == CaseStatus.open || r.status == CaseStatus.reviewing)) {
        final category = switch (r.reason) {
          ReportReason.harassment => 'safety',
          ReportReason.fraud || ReportReason.overcharge => 'fraud',
          _ => 'routine',
        };
        _cases.add(
          _Case(
              _seq++,
              OpsCaseKind.report,
              '${r.id}',
              'Reporte: ${r.reason.label.toLowerCase()}',
              createdAt: r.createdAt,
            )
            ..category = category
            ..priority = category == 'routine' ? 'normal' : 'high',
        );
      }
    }
    for (final b in _bookings.values) {
      if (b.disputeReason != null && b.status == BookingStatus.disputed && !has(OpsCaseKind.dispute, b.id)) {
        _cases.add(
          _Case(_seq++, OpsCaseKind.dispute, b.id, 'Disputa de un servicio', createdAt: b.disputeAt ?? DateTime.now())
            ..category = 'dispute'
            ..priority = 'high',
        );
      }
    }
    for (final p in _pros.values) {
      final pending = p.status == VerificationStatus.submitted || p.status == VerificationStatus.underReview;
      final existing = _cases.where((c) => c.kind == OpsCaseKind.application && c.refId == p.id).firstOrNull;
      if (pending && existing == null) {
        _cases.add(
          _Case(_seq++, OpsCaseKind.application, p.id, 'Postulación: ${p.displayName}', createdAt: p.submittedAt),
        );
      } else if (existing != null && !pending && existing.status != OpsCaseStatus.resolved) {
        existing
          ..status = OpsCaseStatus.resolved
          ..resolvedAt = DateTime.now();
      }
    }
  }

  bool _canSee(_Case c) => _can('cases.view_all') || (_can('cases.view_own') && c.assignedTo == _me.id);

  _Case _caseFor(int id, String all, String own) {
    final c = _cases.where((c) => c.id == id).firstOrNull;
    if (c == null) throw AppError.from('HMY_NOT_FOUND');
    final ok = (_can(all) && _can('cases.view_all')) || (_can(own) && c.assignedTo == _me.id);
    if (!ok) throw AppError.from('HMY_FORBIDDEN');
    return c;
  }

  void _note(_Case c, String kind, String body) {
    c.notes.add(OpsCaseNote(kind: kind, body: body, authorName: _me.fullName, createdAt: DateTime.now()));
    c.updatedAt = DateTime.now();
  }

  OpsCase _caseView(_Case c) => OpsCase(
    id: c.id,
    kind: c.kind,
    refId: c.refId,
    title: c.title,
    category: c.category,
    status: c.status,
    priority: c.priority,
    assignedTo: c.assignedTo,
    assignedName: c.assignedTo == null ? null : _account(c.assignedTo!)?.fullName,
    escalatedTo: c.escalatedTo,
    firstResponseAt: c.firstResponseAt,
    resolvedAt: c.resolvedAt,
    createdAt: c.createdAt,
  );

  Map<String, dynamic> _caseSource(_Case c) {
    switch (c.kind) {
      case OpsCaseKind.support:
        final t = _tickets.where((t) => '${t.id}' == c.refId).firstOrNull;
        return t == null
            ? {}
            : {
                'user_name': t.userName,
                'subject': t.subject,
                'body': t.body,
                'status': t.status.key,
                'last_reply': t.adminNote,
              };
      case OpsCaseKind.report:
        final r = _reports.where((r) => '${r.id}' == c.refId).firstOrNull;
        return r == null
            ? {}
            : {
                'reporter_name': r.reporterName,
                'reported_name': r.reportedName,
                'reason': r.reason.key,
                'details': r.details,
                'status': r.status.key,
              };
      case OpsCaseKind.dispute:
        final b = _bookings[c.refId];
        return b == null
            ? {}
            : {
                'reason': b.disputeReason,
                'status': b.status == BookingStatus.disputed ? 'open' : 'resolved',
                'customer_name': _account(b.customerId)?.fullName,
                'professional_name': b.professionalId == null ? null : _pros[b.professionalId]?.displayName,
              };
      case OpsCaseKind.booking:
        final b = _bookings[c.refId];
        return b == null
            ? {}
            : {
                'booking_id': b.id,
                'code': b.code,
                'booking_status': b.status.key,
                'mode': b.draft.mode.key,
                'customer_name': _account(b.customerId)?.fullName,
                'professional_name': b.professionalId == null ? null : _pros[b.professionalId]?.displayName,
                'category_name': _catName(b.draft.categoryId),
                'city_name': _cityName(b.draft.cityId),
              };
      case OpsCaseKind.application:
        final p = _pros[c.refId];
        return p == null
            ? {}
            : {
                'professional_id': p.id,
                'display_name': p.displayName,
                'status': p.status.key,
                'years_experience': p.years,
                'documents': [
                  for (final d in p.docs)
                    {'id': d.id, 'doc_type': d.type, 'status': d.status.key, 'flag_note': d.flagNote},
                ],
              };
    }
  }

  @override
  Future<StaffAccess> myStaffAccess() async {
    final role = _staffRoleOf(_me.id);
    if (role == null) return StaffAccess(status: _staff[_me.id]?.status);
    return StaffAccess(
      role: role,
      status: _staff[_me.id]?.status ?? 'active',
      permissions: _rolePermissions[role] ?? {},
    );
  }

  @override
  Future<OpsDashboard> opsDashboard() async {
    await _latency(150);
    _need('ops.dashboard');
    _syncCases();
    final me = _me.id;
    final open = _cases.where((c) => c.status != OpsCaseStatus.resolved);
    final week = DateTime.now().subtract(const Duration(days: 7));
    final m = <String, dynamic>{
      'role': _staffRoleOf(me)?.key,
      'my_open_cases': open.where((c) => c.assignedTo == me).length,
      'my_escalated': open.where((c) => c.assignedTo == me && c.status == OpsCaseStatus.escalated).length,
      'my_resolved_7d': _cases
          .where((c) => c.assignedTo == me && c.status == OpsCaseStatus.resolved && c.resolvedAt!.isAfter(week))
          .length,
    };
    if (_can('cases.view_all')) {
      final dash = await adminDashboardCounts();
      final docs = _pros.values.expand((p) => p.docs);
      m.addAll({
        'unassigned_cases': open.where((c) => c.assignedTo == null).length,
        'escalated_cases': open.where((c) => c.status == OpsCaseStatus.escalated).length,
        'urgent_cases': open.where((c) => c.priority == 'urgent').length,
        'pending_documents': docs.where((d) => d.status == DocumentStatus.pending).length,
        'flagged_documents': docs.where((d) => d.status == DocumentStatus.pending && d.flagNote != null).length,
        ...dash,
      });
    }
    return OpsDashboard(m);
  }

  /// Conteos operativos (sin dinero) que comparten el panel del propietario y
  /// el del gerente.
  Future<Map<String, int>> adminDashboardCounts() async {
    final bookings = _bookings.values;
    return {
      'pending_applications': _pros.values
          .where((p) => p.status == VerificationStatus.submitted || p.status == VerificationStatus.underReview)
          .length,
      'open_tickets': _tickets.where((t) => t.status != TicketStatus.closed).length,
      'open_reports': _reports.where((r) => r.status == CaseStatus.open || r.status == CaseStatus.reviewing).length,
      'open_disputes': bookings.where((b) => b.status == BookingStatus.disputed).length,
      'active_bookings': bookings.where((b) => _bookingIn(b, BookingFilter.active)).length,
      'bookings_today': bookings.where((b) => _bookingIn(b, BookingFilter.today)).length,
      'available_professionals': _pros.values
          .where((p) => p.status == VerificationStatus.approved && p.available)
          .length,
      'approved_professionals': _pros.values.where((p) => p.status == VerificationStatus.approved).length,
    };
  }

  @override
  Future<List<OpsCase>> opsCases({String scope = 'mine', bool includeResolved = false}) async {
    await _latency(150);
    final all = _can('cases.view_all');
    if (!all && !_can('cases.view_own')) throw AppError.from('HMY_FORBIDDEN');
    _syncCases();
    final me = _me.id;
    int rank(String p) => p == 'urgent' ? 0 : (p == 'high' ? 1 : 2);
    return [
      for (final c in _cases)
        if ((includeResolved || c.status != OpsCaseStatus.resolved) &&
            (!all || scope == 'mine'
                ? c.assignedTo == me
                : scope == 'unassigned'
                ? c.assignedTo == null
                : scope == 'escalated'
                ? c.status == OpsCaseStatus.escalated
                : scope == 'escalated_owner'
                ? c.status == OpsCaseStatus.escalated && c.escalatedTo == 'owner'
                : scope == 'urgent'
                ? c.priority == 'urgent'
                : true))
          _caseView(c),
    ]..sort((a, b) {
      final r = rank(a.priority).compareTo(rank(b.priority));
      return r != 0 ? r : a.createdAt.compareTo(b.createdAt);
    });
  }

  @override
  Future<OpsCaseDetail> opsCaseDetail(int caseId) async {
    await _latency(150);
    final c = _cases.where((c) => c.id == caseId).firstOrNull;
    if (c == null || !_canSee(c)) throw AppError.from(c == null ? 'HMY_NOT_FOUND' : 'HMY_FORBIDDEN');
    return OpsCaseDetail(item: _caseView(c), source: _caseSource(c), notes: List.of(c.notes));
  }

  @override
  Future<void> assignCase(int caseId, String? userId) async {
    await _latency();
    _need('cases.assign');
    if (userId != null && !{StaffRole.manager, StaffRole.employee}.contains(_staffRoleOf(userId))) {
      throw AppError.from('HMY_STAFF_NOT_ACTIVE');
    }
    final c = _cases.where((c) => c.id == caseId).firstOrNull;
    if (c == null) throw AppError.from('HMY_NOT_FOUND');
    c
      ..assignedTo = userId
      ..assignedAt = DateTime.now();
    _note(c, 'assign', userId == null ? 'Sin asignar' : 'Asignado a ${_account(userId)?.fullName}');
    if (userId != null) _notify(userId, 'staff', 'Tienes un caso nuevo', c.title);
    _log('case.assign', 'ops_cases', '$caseId', {'to': userId});
  }

  @override
  Future<void> setCaseStatus(int caseId, OpsCaseStatus status, {String? note}) async {
    await _latency();
    if (status == OpsCaseStatus.escalated) throw AppError.from('HMY_INVALID_STATUS');
    final c = _caseFor(caseId, 'cases.update', 'cases.update_own');
    final manager = _can('cases.update');
    if (!manager) {
      if (status == OpsCaseStatus.resolved &&
          (!{OpsCaseKind.support, OpsCaseKind.report}.contains(c.kind) || c.category != 'routine')) {
        throw AppError.from('HMY_ESCALATE_REQUIRED');
      }
      if (c.status == OpsCaseStatus.escalated) throw AppError.from('HMY_FORBIDDEN');
    }
    if (status == OpsCaseStatus.resolved && c.kind == OpsCaseKind.application) {
      throw AppError.from('HMY_DECISION_REQUIRED');
    }
    final text = (note ?? '').trim();
    if (status == OpsCaseStatus.resolved && text.isEmpty) throw AppError.from('HMY_REASON_REQUIRED');
    c
      ..status = status
      ..escalatedTo = status == OpsCaseStatus.resolved ? c.escalatedTo : null
      ..resolvedAt = status == OpsCaseStatus.resolved ? DateTime.now() : null;
    if (c.kind == OpsCaseKind.support) {
      final i = _tickets.indexWhere((t) => '${t.id}' == c.refId);
      if (i >= 0) {
        final t = _tickets[i];
        _tickets[i] = AdminTicket(
          id: t.id,
          userName: t.userName,
          bookingId: t.bookingId,
          subject: t.subject,
          body: t.body,
          status: switch (status) {
            OpsCaseStatus.resolved => TicketStatus.closed,
            OpsCaseStatus.open => TicketStatus.open,
            _ => TicketStatus.inProgress,
          },
          adminNote: t.adminNote,
          createdAt: t.createdAt,
        );
      }
    } else if (c.kind == OpsCaseKind.report) {
      final i = _reports.indexWhere((r) => '${r.id}' == c.refId);
      if (i >= 0) {
        final r = _reports[i];
        _reports[i] = AdminReport(
          id: r.id,
          reporterName: r.reporterName,
          reportedId: r.reportedId,
          reportedName: r.reportedName,
          bookingId: r.bookingId,
          reason: r.reason,
          details: r.details,
          status: status == OpsCaseStatus.resolved ? CaseStatus.resolved : CaseStatus.reviewing,
          resolution: status == OpsCaseStatus.resolved ? text : r.resolution,
          createdAt: r.createdAt,
          reportsAgainst: r.reportsAgainst,
        );
      }
    }
    _note(c, 'status', text.isEmpty ? status.key : '${status.key}: $text');
    _log('case.${status.key}', 'ops_cases', '$caseId', {'kind': c.kind.key, 'note': ?(text.isEmpty ? null : text)});
  }

  @override
  Future<void> addCaseNote(int caseId, String body) async {
    await _latency();
    final c = _caseFor(caseId, 'cases.note', 'cases.note');
    if (body.trim().length < 2) throw AppError.from('HMY_REASON_REQUIRED');
    _note(c, 'note', body.trim());
    _log('case.note', 'ops_cases', '$caseId');
  }

  @override
  Future<void> replyCase(int caseId, String message) async {
    await _latency();
    final c = _caseFor(caseId, 'cases.reply', 'cases.reply');
    if (c.kind != OpsCaseKind.support) throw AppError.from('HMY_INVALID_STATUS');
    final text = message.trim();
    if (text.length < 2) throw AppError.from('HMY_REASON_REQUIRED');
    final i = _tickets.indexWhere((t) => '${t.id}' == c.refId);
    if (i >= 0) {
      final t = _tickets[i];
      _tickets[i] = AdminTicket(
        id: t.id,
        userName: t.userName,
        bookingId: t.bookingId,
        subject: t.subject,
        body: t.body,
        status: t.status == TicketStatus.open ? TicketStatus.inProgress : t.status,
        adminNote: text,
        createdAt: t.createdAt,
      );
      final user = _accounts.values.where((a) => a.fullName == t.userName).firstOrNull;
      if (user != null) _notify(user.id, 'support', 'Respuesta de soporte', text);
    }
    c
      ..firstResponseAt ??= DateTime.now()
      ..status = c.status == OpsCaseStatus.open ? OpsCaseStatus.inProgress : c.status;
    _note(c, 'reply', text);
    _log('case.reply', 'ops_cases', '$caseId');
  }

  @override
  Future<void> escalateCase(int caseId, String reason, {String? category}) async {
    await _latency();
    final c = _caseFor(caseId, 'cases.escalate', 'cases.escalate');
    if (reason.trim().isEmpty) throw AppError.from('HMY_REASON_REQUIRED');
    if (category != null && !const {'safety', 'fraud', 'dispute'}.contains(category)) {
      throw AppError.from('HMY_INVALID_STATUS');
    }
    final to = _staffRoleOf(_me.id) == StaffRole.employee ? 'manager' : 'owner';
    c
      ..status = OpsCaseStatus.escalated
      ..escalatedTo = to
      ..category = category ?? c.category
      ..priority = const {'safety', 'fraud'}.contains(category ?? c.category) ? 'urgent' : 'high';
    _note(c, 'escalate', 'Escalado a ${to == 'owner' ? 'propietario' : 'gerente'}: ${reason.trim()}');
    _log('case.escalate', 'ops_cases', '$caseId', {'to': to, 'category': ?category, 'reason': reason.trim()});
  }

  @override
  Future<void> flagDocument(int documentId, String note) async {
    await _latency();
    _need('documents.flag');
    if (note.trim().length < 3) throw AppError.from('HMY_REASON_REQUIRED');
    final pro = _pros.values.where((p) => p.docs.any((d) => d.id == documentId)).firstOrNull;
    if (pro == null) throw AppError.from('HMY_NOT_FOUND');
    final c = _cases.where((c) => c.kind == OpsCaseKind.application && c.refId == pro.id).firstOrNull;
    if (!_can('cases.view_all') && c?.assignedTo != _me.id) throw AppError.from('HMY_FORBIDDEN');
    pro.docs.firstWhere((d) => d.id == documentId).flagNote = note.trim();
    if (c != null) _note(c, 'flag', note.trim());
    _log('document.flag', 'professional_documents', '$documentId', {'professional': pro.id, 'note': note.trim()});
  }

  @override
  Future<List<StaffMember>> staffOverview() async {
    await _latency(150);
    _need('staff.view');
    final week = DateTime.now().subtract(const Duration(days: 7));
    return [
      for (final e in _staff.entries)
        StaffMember(
          userId: e.key,
          fullName: _account(e.key)?.fullName ?? '',
          phoneMasked: maskPhone(_account(e.key)?.phone),
          role: e.value.role,
          status: e.value.status,
          statusReason: e.value.reason,
          openCases: _cases.where((c) => c.assignedTo == e.key && c.status != OpsCaseStatus.resolved).length,
          resolved7d: _cases
              .where((c) => c.assignedTo == e.key && c.status == OpsCaseStatus.resolved && c.resolvedAt!.isAfter(week))
              .length,
          avgFirstResponseMin: () {
            final times = [
              for (final c in _cases)
                if (c.assignedTo == e.key && c.firstResponseAt != null)
                  c.firstResponseAt!.difference(c.assignedAt ?? c.createdAt).inMinutes,
            ];
            return times.isEmpty ? null : (times.reduce((a, b) => a + b) / times.length).round();
          }(),
        ),
    ];
  }

  @override
  Future<List<StaffActivity>> myStaffActivity() async {
    await _latency(100);
    if (_staffRoleOf(_me.id) == null) throw AppError.from('HMY_FORBIDDEN');
    return [
      for (final a in _audit)
        if (_auditActor.of(a.id) == _me.id)
          StaffActivity(action: a.action, targetTable: a.targetTable, targetId: a.targetId, createdAt: a.createdAt),
    ];
  }

  @override
  Future<List<StaffCandidate>> staffCandidates(String query) async {
    await _latency(200);
    final owner = _admin();
    final q = query.trim().toLowerCase();
    if (q.length < 2) return const [];
    var digits = query.replaceAll(RegExp(r'\D'), '');
    if (digits.length == 8) digits = '591$digits';
    final list = [
      for (final a in _accounts.values)
        if (a.fullName.toLowerCase().contains(q) ||
            (digits.length >= 4 && (a.phone ?? '').replaceAll(RegExp(r'\D'), '').contains(digits)))
          () {
            final st = _staff[a.id];
            final reason = a.id == owner.id
                ? 'self'
                : a.roles.contains(AppRole.admin)
                ? 'owner'
                : a.suspendedAt != null
                ? 'suspended'
                : a.phone == null
                ? 'phone_unconfirmed'
                : st?.status == 'active'
                ? 'already_staff'
                : null;
            return StaffCandidate(
              id: a.id,
              fullName: a.fullName,
              phoneMasked: maskPhone(a.phone),
              cityName: a.cityId == null ? null : _cityName(a.cityId!),
              staffRole: st?.role,
              staffStatus: st?.status,
              eligible: reason == null,
              reason: reason,
            );
          }(),
    ]..sort((a, b) => a.eligible == b.eligible ? a.fullName.compareTo(b.fullName) : (a.eligible ? -1 : 1));
    return list.take(20).toList();
  }

  /// Como hmy_require_strong_confirmation: solo un código verificado recién.
  void _requireStrong(String? method) {
    if (method != 'otp') throw AppError.from('HMY_CONFIRMATION_REQUIRED');
    _requireConfirmation('otp');
  }

  @override
  Future<void> grantStaff(String userId, StaffRole role, {required String authMethod}) async {
    await _latency();
    final owner = _admin();
    if (role == StaffRole.owner) throw AppError.from('HMY_INVALID_ROLE');
    final a = _account(userId);
    if (a == null || a.id == owner.id || a.roles.contains(AppRole.admin)) throw AppError.from('HMY_FORBIDDEN');
    if (a.phone == null || a.suspendedAt != null) throw AppError.from('HMY_STAFF_ACCOUNT_REQUIRED');
    final old = _staff[userId];
    if (old != null && old.status == 'active' && old.role == role) throw AppError.from('HMY_ALREADY_STAFF');
    _requireStrong(authMethod);
    _staff[userId] = _Staff(role);
    _log('staff.grant', 'staff_members', userId, {
      'role': role.key,
      'previous_role': ?old?.role.key,
      'previous_status': ?old?.status,
      'auth_method': authMethod,
    });
  }

  @override
  Future<void> setStaffStatus(String userId, String status, {String? reason, String? authMethod}) async {
    await _latency();
    _admin();
    if (!const {'active', 'suspended', 'revoked'}.contains(status)) throw AppError.from('HMY_INVALID_STATUS');
    if (status != 'active' && (reason ?? '').trim().isEmpty) throw AppError.from('HMY_REASON_REQUIRED');
    final st = _staff[userId];
    if (st == null) throw AppError.from('HMY_NOT_FOUND');
    final previous = st.status;
    if (status == 'active') {
      if (_account(userId)?.suspendedAt != null) throw AppError.from('HMY_STAFF_ACCOUNT_REQUIRED');
      _requireStrong(authMethod);
    }
    st
      ..status = status
      ..reason = status == 'active' ? null : reason!.trim();
    var released = 0;
    if (status != 'active') {
      for (final c in _cases.where((c) => c.assignedTo == userId && c.status != OpsCaseStatus.resolved)) {
        c.assignedTo = null;
        released++;
      }
    }
    _log('staff.$status', 'staff_members', userId, {
      'reason': ?reason?.trim(),
      'previous_status': previous,
      'released_cases': ?(released == 0 ? null : released),
      'auth_method': ?authMethod,
    });
  }

  // ------------------------------------------------- Finanzas y Bancos (demo)
  final _receiving = <int, _Receiving>{};
  final _bankChecks = <int, ({BankStatus status, String? reference, int? account, DateTime at})>{};
  final _topupCreditedAt = <int, DateTime>{};
  final _receivingQr = <String, Uint8List>{};

  Iterable<(String, TopupRequest)> get _allTopups => [
    for (final e in _topups.entries)
      for (final t in e.value) (e.key, t),
  ];

  BankStatus _bankOf(int topupId) => _bankChecks[topupId]?.status ?? BankStatus.unverified;

  // ---------------------------------------------------------------- Detalle del panel
  /// Las mismas definiciones que ops_bookings y owner_dashboard (0037, 0041).
  bool _bookingIn(_Booking b, BookingFilter f) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final month = DateTime(now.year, now.month);
    DateTime? at(BookingStatus s) => b.events.where((e) => e.status == s).map((e) => e.at).lastOrNull;
    bool since(BookingStatus s, DateTime from) => b.status == s && (at(s)?.isAfter(from) ?? false);
    if (b.status == BookingStatus.draft) return false;
    return switch (f) {
      BookingFilter.today => !b.createdAt.isBefore(today),
      BookingFilter.active => b.status != BookingStatus.completed && b.status != BookingStatus.cancelled,
      BookingFilter.completedToday => since(BookingStatus.completed, today),
      BookingFilter.cancelledToday => since(BookingStatus.cancelled, today),
      BookingFilter.completedMonth => since(BookingStatus.completed, month),
      BookingFilter.cancelledMonth => since(BookingStatus.cancelled, month),
      BookingFilter.recent => b.createdAt.isAfter(now.subtract(const Duration(days: 30))),
    };
  }

  OpsBooking _opsBooking(_Booking b) {
    final money = _me.roles.contains(AppRole.admin);
    DateTime? at(BookingStatus s) => b.events.where((e) => e.status == s).map((e) => e.at).lastOrNull;
    final openCase = _cases
        .where(
          (c) =>
              (c.kind == OpsCaseKind.booking || c.kind == OpsCaseKind.dispute) &&
              c.refId == b.id &&
              c.status != OpsCaseStatus.resolved,
        )
        .firstOrNull;
    return OpsBooking(
      id: b.id,
      code: b.code,
      status: b.status,
      mode: b.draft.mode,
      categoryName: _catName(b.draft.categoryId),
      cityName: _cityName(b.draft.cityId),
      zoneName: b.draft.zoneId == null ? null : _zoneName(b.draft.zoneId!),
      customerName: _account(b.customerId)?.fullName ?? '',
      professionalName: b.professionalId == null ? null : _pros[b.professionalId]?.displayName,
      scheduledStart: b.draft.scheduledStart,
      acceptedAt: at(BookingStatus.confirmed),
      completedAt: b.status == BookingStatus.completed ? at(BookingStatus.completed) : null,
      cancelledAt: b.status == BookingStatus.cancelled ? at(BookingStatus.cancelled) : null,
      cancelReason: b.status == BookingStatus.cancelled ? b.events.last.note : null,
      paymentMethod: b.paidWith,
      createdAt: b.createdAt,
      hasDispute: b.status == BookingStatus.disputed,
      openCaseId: openCase?.id,
      finalAmount: money ? b.finalAmount : null,
      quoteAmount: money ? b.quoteAmount : null,
      commissionReserved: money ? b.reserved : null,
      commissionCaptured: money && b.captured ? b.reserved : null,
    );
  }

  @override
  Future<DemandBookings?> demandBookings(DemandKind kind, String name, {String? department}) async {
    await _latency(150);
    _admin();
    final last30 = DateTime.now().subtract(const Duration(days: 30));
    bool hit(_Booking b) {
      final city = DemoData.cities.firstWhere((c) => c.id == b.draft.cityId);
      return switch (kind) {
        DemandKind.municipality => city.name == name && (department == null || city.department == department),
        DemandKind.department => (city.department ?? 'Sin departamento') == name,
        DemandKind.category => _catName(b.draft.categoryId) == name,
      };
    }

    final list = [
      for (final b in _bookings.values)
        if (b.status != BookingStatus.draft && b.createdAt.isAfter(last30) && hit(b)) _opsBooking(b),
    ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    int? pros;
    if (kind == DemandKind.municipality) {
      final ids = DemoData.cities.where((c) => c.name == name && (department == null || c.department == department));
      pros = _pros.values
          .where((p) => p.status == VerificationStatus.approved && ids.any((c) => c.id == p.cityId))
          .length;
    }
    return DemandBookings(Listed(list.take(100).toList(), list.length), professionals: pros);
  }

  @override
  Future<Listed<OpsBooking>> opsBookings(BookingFilter filter, {String query = ''}) async {
    await _latency(150);
    _need('bookings.monitor');
    _syncCases();
    final q = _norm(query.trim());
    final list = [
      for (final b in _bookings.values)
        if (_bookingIn(b, filter) &&
            (q.isEmpty ||
                b.code.toLowerCase().contains(q) ||
                _norm(_account(b.customerId)?.fullName ?? '').contains(q) ||
                _norm(b.professionalId == null ? '' : _pros[b.professionalId]?.displayName ?? '').contains(q)))
          _opsBooking(b),
    ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return Listed(list.take(100).toList(), list.length);
  }

  @override
  Future<OpsBookingDetail> opsBookingDetail(String bookingId) async {
    await _latency(150);
    _need('bookings.monitor');
    _syncCases();
    final b = _bookings[bookingId];
    if (b == null) throw AppError.from('HMY_NOT_FOUND');
    String? actor(int i) {
      final id = b.actors[i];
      if (id == null) return i == 0 ? 'cliente' : null;
      if (id == b.customerId) return 'cliente';
      if (id == b.professionalId) return 'profesional';
      return 'equipo';
    }

    final reportIds = {
      for (final r in _reports)
        if (r.bookingId == b.id) '${r.id}',
    };
    final ticketIds = {
      for (final t in _tickets)
        if (t.bookingId == b.id) '${t.id}',
    };
    return OpsBookingDetail(
      booking: _opsBooking(b),
      description: b.draft.description,
      events: [
        for (var i = 0; i < b.events.length; i++)
          OpsBookingEvent(
            from: i == 0 ? null : b.events[i - 1].status,
            to: b.events[i].status,
            note: b.events[i].note,
            actor: actor(i),
            at: b.events[i].at,
          ),
      ],
      cases: [
        for (final c in _cases)
          if (((c.kind == OpsCaseKind.booking || c.kind == OpsCaseKind.dispute) && c.refId == b.id) ||
              (c.kind == OpsCaseKind.report && reportIds.contains(c.refId)) ||
              (c.kind == OpsCaseKind.support && ticketIds.contains(c.refId)))
            _caseView(c),
      ],
      disputeStatus: b.disputeReason == null ? null : (b.status == BookingStatus.disputed ? 'open' : 'resolved'),
      disputeReason: b.disputeReason,
      disputeResolution: b.disputeResolution,
    );
  }

  @override
  Future<int> openBookingCase(String bookingId, String reason, {String category = 'routine'}) async {
    await _latency();
    if (!_can('bookings.monitor') || !_can('cases.update')) throw AppError.from('HMY_FORBIDDEN');
    if (reason.trim().length < 5) throw AppError.from('HMY_REASON_REQUIRED');
    if (!const {'routine', 'safety', 'fraud'}.contains(category)) throw AppError.from('HMY_INVALID_STATUS');
    final b = _bookings[bookingId];
    if (b == null) throw AppError.from('HMY_NOT_FOUND');
    var c = _cases.where((c) => c.kind == OpsCaseKind.booking && c.refId == b.id).firstOrNull;
    if (c != null && c.status != OpsCaseStatus.resolved) return c.id;
    if (c == null) {
      c = _Case(_seq++, OpsCaseKind.booking, b.id, 'Revisar el pedido ${b.code}');
      _cases.add(c);
    }
    c
      ..status = OpsCaseStatus.open
      ..resolvedAt = null
      ..escalatedTo = null
      ..category = category
      ..priority = category == 'routine' ? 'normal' : 'urgent';
    _note(c, 'note', 'Caso abierto desde el pedido: ${reason.trim()}');
    _log('case.open_booking', 'ops_cases', '${c.id}', {
      'booking': b.id,
      'code': b.code,
      'category': category,
      'reason': reason.trim(),
    });
    return c.id;
  }

  @override
  Future<Listed<PersonRow>> adminPeople(PeopleFilter filter, {String query = ''}) async {
    await _latency(200);
    _need('users.view');
    final q = _norm(query.trim());
    const reviewing = {
      IdentityStatus.created,
      IdentityStatus.inProgress,
      IdentityStatus.inReview,
      IdentityStatus.resubmitted,
    };
    final rows = <PersonRow>[];
    for (final a in _accounts.values) {
      final pro = _pros[a.id];
      final approved = pro?.status == VerificationStatus.approved;
      final match = switch (filter) {
        PeopleFilter.all => true,
        PeopleFilter.customers => !a.roles.contains(AppRole.admin) && !approved,
        PeopleFilter.professionals => approved,
        PeopleFilter.available => approved && pro!.available,
        PeopleFilter.identity => pro?.identity.any((i) => reviewing.contains(i.status)) ?? false,
        PeopleFilter.suspended => a.suspendedAt != null,
      };
      if (!match) continue;
      if (q.isNotEmpty &&
          !_norm(a.fullName).contains(q) &&
          !a.email.toLowerCase().contains(q) &&
          !(a.phone ?? '').contains(query.trim())) {
        continue;
      }
      rows.add(
        PersonRow(
          user: AdminUser(
            id: a.id,
            fullName: a.fullName,
            email: a.email.isEmpty ? null : a.email,
            phone: a.phone,
            cityName: a.cityId == null ? null : _cityName(a.cityId!),
            roles: {...a.roles},
            professionalStatus: pro?.status,
            suspendedAt: a.suspendedAt,
            suspensionReason: a.suspensionReason,
            reportsAgainst: _reports.where((r) => r.reportedId == a.id).length,
          ),
          isAvailable: pro?.available,
          identityStatus: pro?.identity.lastOrNull?.status,
        ),
      );
    }
    rows.sort((a, b) => (b.user.isSuspended ? 1 : 0).compareTo(a.user.isSuspended ? 1 : 0));
    return Listed(rows.take(100).toList(), rows.length);
  }

  @override
  Future<Listed<RiskItem>> riskItems(RiskKind kind) async {
    await _latency(150);
    _need('reports.view');
    _syncCases();
    final ai = _me.roles.contains(AppRole.admin);
    bool reasonMatch(ReportReason r) => kind == RiskKind.safety
        ? r == ReportReason.harassment
        : (r == ReportReason.fraud || r == ReportReason.overcharge);
    final items = <(int, RiskItem)>[
      for (final r in _reports)
        if (r.status.isOpen && reasonMatch(r.reason))
          (
            0,
            RiskItem(
              source: 'report',
              id: '${r.id}',
              title: 'Reporte por ${r.reason.label.toLowerCase()}',
              reason: r.reason.key,
              detail: r.details,
              status: r.status == CaseStatus.reviewing ? 'reviewing' : 'open',
              severity: 'high',
              person: r.reportedName,
              personId: r.reportedId,
              caseId: _cases.where((c) => c.kind == OpsCaseKind.report && c.refId == '${r.id}').firstOrNull?.id,
              createdAt: r.createdAt,
            ),
          ),
      for (final c in _cases)
        if (c.status != OpsCaseStatus.resolved && c.category == kind.key && c.kind != OpsCaseKind.report)
          (
            c.priority == 'urgent' ? 0 : 1,
            RiskItem(
              source: 'case',
              id: '${c.id}',
              title: c.title,
              status: c.status.key,
              severity: c.priority == 'urgent' ? 'critical' : (c.priority == 'high' ? 'high' : 'medium'),
              person: c.assignedTo == null ? null : _account(c.assignedTo!)?.fullName,
              caseId: c.id,
              createdAt: c.createdAt,
            ),
          ),
      if (ai && kind == RiskKind.fraud)
        for (final i in _aiItems)
          if (i.agentKey == 'fraud' &&
              (i.status == AiItemStatus.open ||
                  i.status == AiItemStatus.pendingApproval ||
                  i.status == AiItemStatus.moreInfo))
            (
              i.severity == AiSeverity.high || i.severity == AiSeverity.critical ? 0 : 1,
              RiskItem(
                source: 'ai',
                id: '${i.id}',
                title: i.title,
                status: i.status.key,
                severity: i.severity.name,
                createdAt: i.createdAt,
              ),
            ),
    ]..sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : b.$2.createdAt.compareTo(a.$2.createdAt));
    return Listed([for (final (_, i) in items) i], items.length);
  }

  @override
  Future<WalletList> ownerWallets({String query = '', WalletSort sort = WalletSort.available}) async {
    await _latency(150);
    _admin();
    final q = _norm(query.trim());
    final rows = [
      for (final e in _wallets.entries)
        if (q.isEmpty || _norm(_nameOf(e.key)).contains(q))
          OwnerWallet(
            professionalId: e.key,
            name: _nameOf(e.key),
            cityName: _pros[e.key] == null ? null : _cityName(_pros[e.key]!.cityId),
            available: e.value[0],
            reserved: e.value[1],
            lastMovementAt: _ledger[e.key]
                ?.map((l) => l.createdAt)
                .fold<DateTime?>(null, (m, d) => m == null || d.isAfter(m) ? d : m),
            pendingTopups: (_topups[e.key] ?? const []).where((t) => t.status == TopupStatus.pending).length,
          ),
    ];
    int byDate(OwnerWallet a, OwnerWallet b) =>
        (b.lastMovementAt ?? DateTime(2000)).compareTo(a.lastMovementAt ?? DateTime(2000));
    rows.sort(
      (a, b) => switch (sort) {
        WalletSort.available => b.available != a.available ? b.available.compareTo(a.available) : byDate(a, b),
        WalletSort.reserved => b.reserved != a.reserved ? b.reserved.compareTo(a.reserved) : byDate(a, b),
        WalletSort.recent => byDate(a, b),
      },
    );
    return WalletList(
      items: rows.take(100).toList(),
      total: _wallets.length,
      available: _wallets.values.fold<double>(0, (t, w) => t + w[0]),
      reserved: _wallets.values.fold<double>(0, (t, w) => t + w[1]),
    );
  }

  @override
  Future<FinanceSummary> financeSummary({DateTime? month}) async {
    await _latency(200);
    _admin();
    final m = month ?? DateTime.now();
    bool inMonth(DateTime d, DateTime ref) => d.year == ref.year && d.month == ref.month;
    final ledger = _ledger.values.expand((l) => l);
    double commission(DateTime ref) => ledger
        .where((l) => l.type == LedgerType.commissionCapture && inMonth(l.createdAt, ref))
        .fold(0.0, (t, l) => t - (l.availableDelta + l.reservedDelta));
    final credited = [
      for (final (pro, t) in _allTopups)
        if (t.status == TopupStatus.approved) (pro, t, _topupCreditedAt[t.id] ?? t.createdAt),
    ];
    double funds(DateTime ref, [BankStatus? status]) => credited
        .where((c) => inMonth(c.$3, ref) && (status == null || _bankOf(c.$2.id) == status))
        .fold(0.0, (t, c) => t + c.$2.amount);
    final pending = _allTopups.where((p) => p.$2.status == TopupStatus.pending).map((p) => p.$2).toList();
    final unverified = credited.where((c) => _bankOf(c.$2.id) == BankStatus.unverified).toList();
    String key(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}';
    return FinanceSummary(
      month: key(m),
      timezone: 'America/La_Paz',
      generatedAt: DateTime.now(),
      commissionEarnedBs: commission(m),
      commissionsCount: ledger.where((l) => l.type == LedgerType.commissionCapture && inMonth(l.createdAt, m)).length,
      commissionRefundedBs: ledger
          .where((l) => l.type == LedgerType.refund && inMonth(l.createdAt, m))
          .fold(0.0, (t, l) => t + l.availableDelta),
      walletFundsReceivedBs: funds(m),
      walletFundsReceivedCount: credited.where((c) => inMonth(c.$3, m)).length,
      walletFundsReconciledBs: funds(m, BankStatus.reconciled),
      walletFundsUnverifiedBs: funds(m, BankStatus.unverified),
      walletFundsNotFoundBs: funds(m, BankStatus.notFound),
      manualAdjustmentsBs: ledger
          .where((l) => l.type == LedgerType.adjustment && inMonth(l.createdAt, m))
          .fold(0.0, (t, l) => t + l.availableDelta),
      topupsPending: pending.length,
      topupsPendingBs: pending.fold(0.0, (t, x) => t + x.amount),
      topupsUnverifiedTotal: unverified.length,
      topupsUnverifiedTotalBs: unverified.fold(0.0, (t, c) => t + c.$2.amount),
      walletsAvailableBs: _wallets.values.fold(0.0, (t, w) => t + w[0]),
      walletsReservedBs: _wallets.values.fold(0.0, (t, w) => t + w[1]),
      walletsCount: _wallets.length,
      receivingAccountsActive: _receiving.values.where((a) => a.active).length,
      receivingAccountsVerified: _receiving.values.where((a) => a.active && a.verified).length,
      bankIntegration: 'pendiente_configuracion',
      months: [
        for (var i = 5; i >= 0; i--)
          () {
            final d = DateTime(m.year, m.month - i);
            return FinanceMonth(month: key(d), walletFundsBs: funds(d), commissionBs: commission(d));
          }(),
      ],
    );
  }

  @override
  Future<List<FinanceTransaction>> financeTransactions({
    String? kind,
    int? before,
    int limit = 50,
    String? professionalId,
  }) async {
    await _latency(150);
    _admin();
    final list = [
      for (final e in _ledger.entries)
        if (professionalId == null || e.key == professionalId)
          for (final l in e.value)
            if ((kind == null || l.type.key == kind) && (before == null || l.id < before))
              FinanceTransaction(
                id: l.id,
                professionalId: e.key,
                professionalName: _nameOf(e.key),
                entryType: l.type.key,
                availableDelta: l.availableDelta,
                reservedDelta: l.reservedDelta,
                note: l.note,
                createdAt: l.createdAt,
              ),
    ]..sort((a, b) => b.id.compareTo(a.id));
    return list.take(limit).toList();
  }

  @override
  Future<FinanceList<FinanceTransaction>> financeLedger({
    String? kind,
    DateTime? month,
    String query = '',
    String? professionalId,
  }) async {
    final rows = (await financeTransactions(kind: kind, limit: 1 << 20, professionalId: professionalId))
        .where((t) => month == null || (t.createdAt.year == month.year && t.createdAt.month == month.month))
        .where((t) => _hit(query, [t.professionalName, t.bookingCode, t.reference, t.note]))
        .toList();
    return FinanceList(
      rows.take(100).toList(),
      total: rows.length,
      sumBs: rows.fold(0.0, (s, t) => s + (t.entryType == 'commission_capture' ? t.platformRevenue : t.availableDelta)),
    );
  }

  @override
  Future<FinanceList<CommissionDebt>?> commissionDebts() async {
    await _latency(100);
    _admin();
    // La regla de la demostración es un cargo fijo que se reserva completo:
    // nunca falta saldo al completar.
    return const FinanceList(<CommissionDebt>[], total: 0, sumBs: 0);
  }

  @override
  Future<CommissionPreview?> commissionPreview(String bookingId) async {
    await _latency(80);
    final b = _get(bookingId);
    final me = _me.id;
    if (b.professionalId != me && !b.offers.contains(me)) {
      throw AppError.from('HMY_FORBIDDEN');
    }
    final fee = _commissionOf(b.agreedAmount ?? 0);
    return CommissionPreview(
      hasRule: true,
      ratePercent: _ratePercent,
      expected: fee,
      reserve: fee,
      minBalance: _reserveAmount,
      available: _wallets[me]?[0],
    );
  }

  @override
  Future<FinanceList<ReconcileTopup>> financeTopups(TopupFilter filter, {DateTime? month, String query = ''}) async {
    final rows = (await topupsForReconciliation('todas'))
        .where(filter.matches)
        .where((t) {
          final at = t.isCredited ? (t.reviewedAt ?? t.createdAt) : t.createdAt;
          return month == null || (at.year == month.year && at.month == month.month);
        })
        .where((t) => _hit(query, [t.professionalName, t.reference, t.bankReference, '${t.id}']))
        .toList();
    return FinanceList(rows.take(100).toList(), total: rows.length, sumBs: rows.fold(0.0, (s, t) => s + t.amount));
  }

  bool _hit(String query, List<String?> fields) {
    final q = _norm(query.trim());
    return q.isEmpty || fields.whereType<String>().any((f) => _norm(f).contains(q));
  }

  @override
  Future<List<ReconcileTopup>> topupsForReconciliation(String bankStatus) async {
    await _latency(150);
    _admin();
    final list = [
      for (final (pro, t) in _allTopups)
        if (switch (bankStatus) {
          'todas' => true,
          'pendiente' => t.status == TopupStatus.pending,
          _ => t.status == TopupStatus.approved && _bankOf(t.id).key == bankStatus,
        })
          ReconcileTopup(
            id: t.id,
            professionalId: pro,
            professionalName: _nameOf(pro),
            amount: t.amount,
            methodName: 'QR (ejemplo)',
            reference: t.reference,
            hasProof: _topupProofs.containsKey(t.id),
            status: t.status.key,
            bankStatus: _bankOf(t.id),
            bankReference: _bankChecks[t.id]?.reference,
            bankAccountId: _bankChecks[t.id]?.account,
            bankAccountLabel: _receiving[_bankChecks[t.id]?.account]?.label,
            bankCheckedAt: _bankChecks[t.id]?.at,
            reviewedAt: _topupCreditedAt[t.id],
            createdAt: t.createdAt,
          ),
    ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  @override
  Future<void> reconcileTopup(
    int topupId,
    BankStatus status, {
    String? bankReference,
    int? accountId,
    required String authMethod,
  }) async {
    await _latency();
    _admin();
    final found = _allTopups.where((p) => p.$2.id == topupId).firstOrNull;
    if (found == null) throw AppError.from('HMY_NOT_FOUND');
    if (found.$2.status != TopupStatus.approved) throw AppError.from('HMY_TOPUP_NOT_CREDITED');
    final ref = bankReference?.trim();
    if (status == BankStatus.reconciled && (ref ?? '').isEmpty) throw AppError.from('HMY_BANK_REFERENCE_REQUIRED');
    if (accountId != null && !_receiving.containsKey(accountId)) throw AppError.from('HMY_NOT_FOUND');
    _requireStrong(authMethod);
    final from = _bankOf(topupId);
    _bankChecks[topupId] = (
      status: status,
      reference: (ref ?? '').isEmpty ? null : ref,
      account: accountId,
      at: DateTime.now(),
    );
    _log('finance.reconcile', 'topup_requests', '$topupId', {
      'from': from.key,
      'to': status.key,
      'amount': found.$2.amount,
      'account': ?accountId,
      'bank_reference': ?((ref ?? '').isEmpty ? null : ref),
      'auth_method': authMethod,
    });
  }

  @override
  Future<List<ReceivingAccount>> receivingAccounts() async {
    await _latency(150);
    _admin();
    return [
      for (final a
          in _receiving.values.toList()
            ..sort((a, b) => a.active == b.active ? a.id.compareTo(b.id) : (a.active ? -1 : 1)))
        a.toModel(),
    ];
  }

  @override
  Future<int> saveReceivingAccount(ReceivingAccountDraft d, {required String authMethod}) async {
    await _latency();
    final me = _admin();
    final number = d.accountNumber?.trim();
    if (d.label.trim().length < 2 || d.bankName.trim().length < 2 || d.holderName.trim().length < 2) {
      throw AppError.from('HMY_NAME_REQUIRED');
    }
    if (number != null && number.isNotEmpty && !RegExp(r'^[0-9][0-9 -]{3,29}$').hasMatch(number)) {
      throw AppError.from('HMY_INVALID_ACCOUNT');
    }
    final hasNumber = (number ?? '').isNotEmpty;
    if (d.type != ReceivingAccountType.qr && !hasNumber) throw AppError.from('HMY_INVALID_ACCOUNT');
    if (d.type == ReceivingAccountType.qr && !hasNumber && d.qrPath == null) throw AppError.from('HMY_QR_REQUIRED');
    if (d.qrPath != null && !d.qrPath!.startsWith('${me.id}/')) throw AppError.from('HMY_FORBIDDEN');
    final old = d.id == null ? null : _receiving[d.id];
    if (d.id != null && old == null) throw AppError.from('HMY_NOT_FOUND');
    _requireStrong(authMethod);
    final a = old ?? _Receiving(_seq++);
    final changed =
        old == null ||
        old.number != (hasNumber ? number : null) ||
        old.qrPath != d.qrPath ||
        old.holder != d.holderName.trim() ||
        old.bank != d.bankName.trim();
    a
      ..label = d.label.trim()
      ..type = d.type
      ..bank = d.bankName.trim()
      ..holder = d.holderName.trim()
      ..number = hasNumber ? number : null
      ..currency = d.currency
      ..qrPath = d.qrPath
      ..notes = (d.notes ?? '').trim().isEmpty ? null : d.notes!.trim()
      ..updatedAt = DateTime.now();
    if (changed) a.verified = false;
    _receiving[a.id] = a;
    _log(old == null ? 'finance.account_created' : 'finance.account_updated', 'receiving_accounts', '${a.id}', {
      'label': a.label,
      'account': ?_maskAccount(a.number),
      'auth_method': authMethod,
    });
    return a.id;
  }

  @override
  Future<void> setReceivingAccount(
    int id, {
    required bool active,
    required bool verified,
    required String authMethod,
  }) async {
    await _latency();
    _admin();
    final a = _receiving[id];
    if (a == null) throw AppError.from('HMY_NOT_FOUND');
    _requireStrong(authMethod);
    _log('finance.account_status', 'receiving_accounts', '$id', {
      'active': active,
      'verification': verified ? 'verificada' : 'sin_verificar',
      'was_active': a.active,
      'was': a.verified ? 'verificada' : 'sin_verificar',
      'auth_method': authMethod,
    });
    a
      ..active = active
      ..verified = verified
      ..updatedAt = DateTime.now();
  }

  @override
  Future<String> uploadReceivingQr(PhotoUpload image) async {
    await _latency(300);
    final me = _admin();
    final path = '${me.id}/cobro_${_seq++}.png';
    _receivingQr[path] = image.bytes;
    return path;
  }

  @override
  Future<String?> receivingQrUrl(String path) async => null;

  /// En la demostración la imagen del QR está en memoria.
  Uint8List? receivingQrBytes(String path) => _receivingQr[path];

  // ------------------------------------------------- Publicidad (demo)
  /// Un anuncio de ejemplo aprobado, para ver el espacio en la demostración.
  final Map<int, OwnerAd> _ads = {
    1: const OwnerAd(
      id: 1,
      advertiser: 'Ferretería El Tornillo',
      title: '10% en herramientas',
      body: 'Presenta la app en caja. Válido esta semana.',
      linkUrl: 'https://ferreteria.example.bo',
      status: AdStatus.approved,
      live: true,
    ),
  };
  final Map<(int, String), int> _adStats = {};

  String get _adDay => DateTime.now().toIso8601String().substring(0, 10);
  int _adCount(int id, String what) => _adStats[(id, '$_adDay $what')] ?? 0;
  void _adBump(int id, String what) => _adStats[(id, '$_adDay $what')] = _adCount(id, what) + 1;
  final Map<int, int> _adTotals = {};
  final Map<int, int> _adClickTotals = {};

  bool _adLive(OwnerAd a) {
    final now = DateTime.now();
    return a.status == AdStatus.approved &&
        (a.startsAt == null || !a.startsAt!.isAfter(now)) &&
        (a.endsAt == null || a.endsAt!.isAfter(now));
  }

  OwnerAd _adWith(OwnerAd a, {AdStatus? status}) => OwnerAd(
    id: a.id,
    advertiser: a.advertiser,
    title: a.title,
    body: a.body,
    logoPath: a.logoPath,
    imagePath: a.imagePath,
    linkUrl: a.linkUrl,
    label: a.label,
    cityId: a.cityId,
    cityName: a.cityId == null ? null : _cityName(a.cityId!),
    status: status ?? a.status,
    startsAt: a.startsAt,
    endsAt: a.endsAt,
  );

  @override
  Future<HomeAd?> homeAd(int cityId) async {
    await _latency(150);
    _me;
    final live = _ads.values.where((a) => _adLive(a) && (a.cityId == null || a.cityId == cityId)).toList()
      ..shuffle()
      ..sort((a, b) => _adCount(a.id, 'v').compareTo(_adCount(b.id, 'v')));
    if (live.isEmpty) return null;
    final ad = live.first;
    _adBump(ad.id, 'v');
    _adTotals[ad.id] = (_adTotals[ad.id] ?? 0) + 1;
    return ad.preview;
  }

  @override
  Future<String?> adClick(int id) async {
    await _latency(100);
    final ad = _ads[id];
    if (ad == null || !_adLive(ad)) throw AppError.from('HMY_NOT_FOUND');
    _adBump(id, 'c');
    _adClickTotals[id] = (_adClickTotals[id] ?? 0) + 1;
    return ad.linkUrl;
  }

  @override
  Future<List<OwnerAd>> ownerAds() async {
    await _latency();
    _admin();
    final list = [
      for (final a in _ads.values)
        OwnerAd(
          id: a.id,
          advertiser: a.advertiser,
          title: a.title,
          body: a.body,
          logoPath: a.logoPath,
          imagePath: a.imagePath,
          linkUrl: a.linkUrl,
          label: a.label,
          cityId: a.cityId,
          cityName: a.cityName,
          status: a.status,
          live: _adLive(a),
          startsAt: a.startsAt,
          endsAt: a.endsAt,
          impressions: _adTotals[a.id] ?? 0,
          clicks: _adClickTotals[a.id] ?? 0,
          impressionsToday: _adCount(a.id, 'v'),
          clicksToday: _adCount(a.id, 'c'),
        ),
    ];
    list.sort((a, b) {
      final r = (a.status == AdStatus.removed ? 1 : 0).compareTo(b.status == AdStatus.removed ? 1 : 0);
      if (r != 0) return r;
      final l = (b.live ? 1 : 0).compareTo(a.live ? 1 : 0);
      return l != 0 ? l : b.id.compareTo(a.id);
    });
    return list;
  }

  @override
  Future<int> saveAd(AdDraft d) async {
    await _latency();
    _admin();
    final link = d.linkUrl?.trim();
    if (link != null && link.isNotEmpty && !isValidAdLink(link)) throw AppError.from('HMY_INVALID_LINK');
    if (d.advertiser.trim().length < 2 || d.title.trim().length < 2) throw AppError.from('HMY_INVALID_INPUT');
    if (d.startsAt != null && d.endsAt != null && !d.endsAt!.isAfter(d.startsAt!)) {
      throw AppError.from('HMY_INVALID_DATES');
    }
    if (d.id != null && (_ads[d.id] == null || _ads[d.id]!.status == AdStatus.removed)) {
      throw AppError.from('HMY_NOT_FOUND');
    }
    final id = d.id ?? (_ads.keys.fold(0, max) + 1);
    final body = d.body?.trim();
    _ads[id] = OwnerAd(
      id: id,
      advertiser: d.advertiser.trim(),
      title: d.title.trim(),
      body: (body == null || body.isEmpty) ? null : body,
      logoPath: d.logoPath,
      imagePath: d.imagePath,
      linkUrl: (link == null || link.isEmpty) ? null : link,
      label: d.label,
      cityId: d.cityId,
      cityName: d.cityId == null ? null : _cityName(d.cityId!),
      startsAt: d.startsAt,
      endsAt: d.endsAt,
    );
    return id;
  }

  @override
  Future<void> setAdStatus(int id, AdAction action) async {
    await _latency();
    _admin();
    final ad = _ads[id];
    if (ad == null || ad.status == AdStatus.removed) throw AppError.from('HMY_NOT_FOUND');
    switch (action) {
      case AdAction.approve:
        if (ad.status != AdStatus.draft && ad.status != AdStatus.paused) throw AppError.from('HMY_INVALID_STATE');
        if (ad.endsAt != null && !ad.endsAt!.isAfter(DateTime.now())) throw AppError.from('HMY_AD_EXPIRED');
        _ads[id] = _adWith(ad, status: AdStatus.approved);
      case AdAction.pause:
        if (ad.status != AdStatus.approved) throw AppError.from('HMY_INVALID_STATE');
        _ads[id] = _adWith(ad, status: AdStatus.paused);
      case AdAction.remove:
        _ads[id] = _adWith(ad, status: AdStatus.removed);
    }
  }

  @override
  Future<String> uploadAdImage(PhotoUpload image) async {
    await _latency(300);
    final me = _admin();
    return '${me.id}/anuncio_${_seq++}.png';
  }

  @override
  Future<List<FinanceAuditEntry>> financeAudit({int limit = 100}) async {
    await _latency(150);
    _admin();
    bool money(AuditEntry a) =>
        a.action.startsWith('finance.') ||
        a.action.startsWith('topup.') ||
        a.action.startsWith('wallet.') ||
        a.action.startsWith('commission') ||
        const {
          'topup_requests',
          'wallets',
          'wallet_ledger',
          'commission_rules',
          'receiving_accounts',
        }.contains(a.targetTable);
    return [
      for (final a in _audit.where(money).take(limit))
        FinanceAuditEntry(
          id: a.id,
          actorName: a.actorName,
          action: a.action,
          targetTable: a.targetTable,
          targetId: a.targetId,
          details: a.details,
          createdAt: a.createdAt,
        ),
    ];
  }
}

String? _maskAccount(String? n) {
  final d = (n ?? '').replaceAll(RegExp(r'\D'), '');
  if (d.isEmpty) return null;
  return d.length <= 4 ? '••••' : '•••• ${d.substring(d.length - 4)}';
}

class _Receiving {
  _Receiving(this.id);

  final int id;
  String label = '';
  ReceivingAccountType type = ReceivingAccountType.savings;
  String bank = '';
  String holder = '';
  String? number;
  String currency = 'BOB';
  String? qrPath;
  String? notes;
  bool verified = false;
  bool active = true;
  DateTime updatedAt = DateTime.now();

  ReceivingAccount toModel() => ReceivingAccount(
    id: id,
    label: label,
    type: type,
    bankName: bank,
    holderName: holder,
    accountNumber: number,
    accountMasked: _maskAccount(number),
    currency: currency,
    qrPath: qrPath,
    notes: notes,
    verified: verified,
    isActive: active,
    updatedAt: updatedAt,
  );
}

class _Account {
  _Account({required this.id, this.email = '', required this.fullName, this.cityId, this.termsAccepted = true});

  final String id;

  /// Correo confirmado (opcional); vacío si no agregó uno.
  String email;

  /// Correo pedido y todavía sin confirmar.
  String? pendingEmail;
  String fullName;
  String? phone;
  bool termsAccepted;
  int? cityId;
  bool confirmed = false;
  bool onboardingDone = false;
  bool deletionRequested = false;
  AppRole activeRole = AppRole.customer;
  final Set<AppRole> roles = {AppRole.customer};
  DateTime? suspendedAt;
  String? suspensionReason;
  final Set<String> blocked = {};
  Uint8List? photo;
}

class _PendingCode {
  _PendingCode(this.sentAt, this.purpose, this.target);

  final DateTime sentAt;
  final String purpose;

  /// Número o correo nuevo, en un cambio.
  final String? target;
  int attempts = 0;
}

class _Doc {
  _Doc(this.id, this.type, [this.bytes]);

  final int id;
  final String type;
  final Uint8List? bytes;
  DocumentStatus status = DocumentStatus.pending;
  String? note;

  /// Marca de un miembro del equipo: falta o es dudoso (no lo acepta ni lo rechaza).
  String? flagNote;
}

class _Pro {
  _Pro({
    required this.id,
    required this.displayName,
    required this.primaryCategoryId,
    required this.cityId,
    required this.zoneIds,
    required this.bio,
    required this.years,
    required this.priceFrom,
    required this.available,
    required this.ratingAvg,
    required this.ratingCount,
    required this.completedJobs,
    required this.status,
    this.location,
  });

  final String id;
  ServiceLocation? location;
  final String displayName;
  final int primaryCategoryId;
  final int cityId;
  final Set<int> zoneIds;
  final String bio;
  final int years;
  final double? priceFrom;
  bool available;
  double ratingAvg;
  int ratingCount;
  int completedJobs;
  VerificationStatus status;
  int documentCount = 0;
  final List<Review> realReviews = [];
  final List<_Doc> docs = [];
  DateTime? submittedAt;
  String? reviewNote;
  final List<({VerificationStatus status, String? note, DateTime at})> history = [];
  final List<IdentityCheck> identity = [];
}

/// Proveedor medido, con el mismo plan gratis y precio que la migración 0016.
class _Vendor {
  _Vendor(
    this.key,
    this.name,
    this.category,
    this.unit,
    this.billing,
    this.freeUnits,
    this.price,
    this.fixed,
    this.status, {
    this.sandbox = false,
    this.notes,
  });

  final String key;
  final String name;
  final String category;
  final String unit;
  final String billing;
  final int freeUnits;
  final double price;
  final double fixed;
  final bool sandbox;
  final String? notes;
  VendorStatus status;
  double cap = 0;
  double used = 0;
  double sandboxUsed = 0;
  double spent = 0;
  int blocked = 0;
}

class _Booking {
  _Booking({
    required this.id,
    required this.code,
    required this.customerId,
    this.professionalId,
    required this.draft,
    required this.createdAt,
  });

  final String id;
  final String code;
  final String customerId;
  String? professionalId;
  final BookingDraft draft;
  final DateTime createdAt;
  BookingStatus status = BookingStatus.draft;
  List<String> problems = const [];
  final List<BookingEvent> events = [];

  /// Quién hizo cada cambio (por posición en [events]), como booking_events.actor_id.
  final Map<int, String> actors = {};
  Set<String> _offers = {};
  int offersCount = 0;
  double? quoteAmount;
  String? quoteNote;
  double? finalAmount;
  final List<_DemoOffer> priceOffers = [];
  double? agreedAmount;
  PriceKind? agreedKind;
  double extras = 0;
  bool customerPaid = false;
  bool professionalPaid = false;
  PaymentMethod? paidWith;
  bool hasReview = false;
  double reserved = 0;
  bool captured = false;
  String? conversationId;
  final List<BookingPhoto> photos = [];
  String? disputeReason;
  String? disputeOpenedBy;
  DateTime? disputeAt;
  String? disputeResolution;

  // Código de llegada: solo el verificador vive "en el servidor".
  String? pinVerifier;
  DateTime? pinExpiresAt;
  int wrongAttempts = 0;
  int pinsIssued = 0;
  DateTime? lastPinAt;
  DateTime? arrivedAt;
  DateTime? arrivalVerifiedAt;
  String? arrivalMethod;
  int? delayMinutes;

  Set<String> get offers => _offers;
  set offers(Set<String> v) {
    _offers = v;
    if (v.length > offersCount) offersCount = v.length;
  }
}

class _Conversation {
  _Conversation({required this.id, required this.bookingId, required this.customerId, required this.professionalId});

  final String id;
  final String bookingId;
  final String customerId;
  final String professionalId;
  final List<ChatMessage> messages = [];
  final Map<String, DateTime> readAt = {};
}

class _Note {
  const _Note(this.value, this.userId);

  final AppNotification value;
  final String userId;
}

class _Staff {
  _Staff(this.role);

  final StaffRole role;
  String status = 'active';
  String? reason;
}

class _Case {
  _Case(this.id, this.kind, this.refId, this.title, {DateTime? createdAt}) : createdAt = createdAt ?? DateTime.now();

  final int id;
  final OpsCaseKind kind;
  final String refId;
  final String title;
  String category = 'routine';
  OpsCaseStatus status = OpsCaseStatus.open;
  String priority = 'normal';
  String? assignedTo;
  DateTime? assignedAt;
  String? escalatedTo;
  DateTime? firstResponseAt;
  DateTime? resolvedAt;
  final DateTime createdAt;
  DateTime updatedAt = DateTime.now();
  final List<OpsCaseNote> notes = [];
}

/// Quién hizo cada entrada de la auditoría (la entrada guarda el nombre).
class _ActorLog {
  final _actors = <int, String>{};
  var _next = 1;

  int add(String actorId) {
    final id = _next++;
    _actors[id] = actorId;
    return id;
  }

  String? of(int id) => _actors[id];
}

class _DemoOffer {
  _DemoOffer({
    required this.id,
    this.professionalId,
    required this.byCustomer,
    required this.authorId,
    required this.kind,
    required this.amount,
    this.note,
  }) : createdAt = DateTime.now();

  final int id;
  final String? professionalId;
  final bool byCustomer;
  final String authorId;
  final PriceKind kind;
  final double amount;
  final String? note;
  final DateTime createdAt;
  OfferStatus status = OfferStatus.open;

  bool get forEveryone => professionalId == null;
}
