import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../core/utils/app_error.dart';
import '../models/admin.dart';
import '../models/ai_control.dart';
import '../models/booking.dart';
import '../models/catalog.dart';
import '../models/costs.dart';
import '../models/geo.dart';
import '../models/messaging.dart';
import '../models/professional.dart';
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
        AiControlRepository {
  DemoBackend({this.simulateDelays = true, this.codeCooldown = const Duration(seconds: 60)}) {
    _seed();
    _seedAdmin();
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
      createdAt: DateTime.now().subtract(const Duration(minutes: 20)),
    ),
  ];
  final _dailyReports = <DailyReport>[];
  final _confirmedAt = <String, DateTime>{};
  final _biometric = <String>{};
  final _consents = <String>{};

  static const _reserveAmount = 5.0;
  static const _commissionFee = 10.0;

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

    _rules.add(
      CommissionRule(
        id: _seq++,
        name: 'Regla de demostración (ejemplo, no es una tarifa real)',
        fixedFee: _commissionFee,
        reserveAmount: _reserveAmount,
        minBalance: _reserveAmount,
      ),
    );
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
    );
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
    if (_accounts.values.any((a) => a.email == key && a.id != _me.id)) throw AppError.from('email_exists');
    _sendCode('email-change:${_me.id}', purpose: 'email-change', target: key);
  }

  @override
  Future<void> verifyEmailChange({required String email, required String code}) async {
    await _latency();
    final me = _me;
    final pending = _checkCode('email-change:${me.id}', code, 'email-change');
    if (pending.target != email.trim().toLowerCase()) throw AppError.from('otp_invalid');
    me.email = pending.target!;
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
  );

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
  }) => _pros.values.where((p) {
    if (p.status != VerificationStatus.approved || !p.available || p.id == customerId) return false;
    if (_blockedBetween(p.id, customerId)) return false;
    if (p.cityId != cityId || p.primaryCategoryId != categoryId) return false;
    final base = p.location;
    // Igual que el servidor: con ubicación manda el radio; sin ella, la zona.
    if (latitude != null && longitude != null && base != null) {
      return distanceKm(latitude, longitude, base.latitude, base.longitude) <= base.radiusKm;
    }
    return zoneId == null || p.zoneIds.isEmpty || p.zoneIds.contains(zoneId);
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

  void _reserve(_Booking b) {
    final pro = b.professionalId!;
    if (!_wallets.containsKey(pro)) return; // profesionales de ejemplo sin billetera simulada
    if (_wallets[pro]![0] < _reserveAmount) throw AppError.from('HMY_INSUFFICIENT_BALANCE');
    _post(pro, LedgerType.commissionReserve, -_reserveAmount, _reserveAmount, 'Reserva de comisión ${b.code}');
    b.reserved = _reserveAmount;
  }

  void _capture(_Booking b) {
    if (b.reserved == 0 || b.captured) return;
    _post(
      b.professionalId!,
      LedgerType.commissionCapture,
      b.reserved - _commissionFee,
      -b.reserved,
      'Comisión ${b.code}',
    );
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
      // Simula que el primer profesional disponible acepta en unos segundos.
      final winner = eligible.firstWhere((p) => p.id != 'demo-pro', orElse: () => eligible.first);
      if (winner.id != 'demo-pro') {
        _later(const Duration(seconds: 5), () {
          if (b.status != BookingStatus.awaitingResponse) return;
          b
            ..professionalId = winner.id
            ..offers = {};
          _move(b, BookingStatus.confirmed, note: 'Aceptado por ${winner.displayName}', actorId: winner.id);
          _later(const Duration(seconds: 2), () {
            _sendAs(
              b.conversationId!,
              winner.id,
              '¡Hola! Soy ${winner.displayName.split(' ').first}. Ya vi tu pedido, salgo para allá en unos minutos.',
            );
          });
        });
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
          _move(b, BookingStatus.confirmed, note: 'Aceptado por ${pro.displayName}', actorId: pro.id);
        });
      }
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
      paymentMethod: b.draft.paymentMethod,
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
    );
  }

  @override
  Stream<void> changes() => _changes.stream;

  @override
  Future<void> accept(String bookingId, {required bool isOffer}) async {
    await _latency();
    final me = _me.id;
    final b = _get(bookingId);
    if (isOffer) {
      if (b.status != BookingStatus.awaitingResponse || b.professionalId != null) {
        throw const AppError('Otro profesional ya tomó este pedido.', code: 'HMY_ALREADY_TAKEN');
      }
      if (!b.offers.contains(me)) throw AppError.from('HMY_FORBIDDEN');
      b
        ..professionalId = me
        ..offers = {};
      try {
        _move(b, BookingStatus.confirmed, note: 'Aceptado por el profesional', actorId: me);
      } catch (_) {
        b.professionalId = null;
        b.status = BookingStatus.awaitingResponse;
        b.events.removeLast();
        rethrow;
      }
    } else {
      if (b.professionalId != me) throw AppError.from('HMY_FORBIDDEN');
      _requireStatus(b, {BookingStatus.requested});
      _move(b, BookingStatus.confirmed, actorId: me);
    }
  }

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

  @override
  Future<void> sendQuote(String bookingId, double amount, String? note) async {
    await _latency();
    final b = _get(bookingId);
    if (b.professionalId != _me.id) throw AppError.from('HMY_FORBIDDEN');
    _requireStatus(b, {BookingStatus.requested});
    if (amount <= 0) throw AppError.from('HMY_INVALID_AMOUNT');
    b
      ..quoteAmount = amount
      ..quoteNote = note;
    _move(b, BookingStatus.quoteSent, note: 'Cotización: Bs ${amount.toStringAsFixed(2)}', actorId: _me.id);
  }

  @override
  Future<void> updateProgress(String bookingId, BookingStatus to, {double? finalAmount}) async {
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
    if (to == BookingStatus.workFinished && finalAmount != null) b.finalAmount = finalAmount;
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
  Future<void> respondQuote(String bookingId, {required bool accept}) async {
    await _latency();
    final b = _get(bookingId);
    if (b.customerId != _me.id) throw AppError.from('HMY_FORBIDDEN');
    _requireStatus(b, {BookingStatus.quoteSent});
    _move(
      b,
      accept ? BookingStatus.confirmed : BookingStatus.cancelled,
      note: accept ? 'Cotización aceptada' : 'Cotización rechazada',
      actorId: _me.id,
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
    if (b.hasReview) throw const AppError('Ya calificaste este trabajo.');
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
    if (reason.trim().isEmpty) throw AppError.from('HMY_REASON_REQUIRED');
    final isCustomer = b.customerId == me;
    if (!isCustomer && b.professionalId != me) throw AppError.from('HMY_FORBIDDEN');
    _requireStatus(
      b,
      isCustomer
          ? {BookingStatus.requested, BookingStatus.awaitingResponse, BookingStatus.quoteSent, BookingStatus.confirmed}
          : {BookingStatus.requested, BookingStatus.quoteSent, BookingStatus.confirmed, BookingStatus.onTheWay},
    );
    b.offers = {};
    _move(b, BookingStatus.cancelled, note: reason.trim(), actorId: me);
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
    return Wallet(available: w[0], reserved: w[1]);
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
    bool open(AiItem i) => i.status.isPending;
    return AiOverview(
      pendingApproval: _aiItems.where((i) => i.status == AiItemStatus.pendingApproval).length,
      open: _aiItems.where((i) => i.status == AiItemStatus.open || i.status == AiItemStatus.moreInfo).length,
      critical: _aiItems.where((i) => open(i) && i.severity == AiSeverity.critical).length,
      high: _aiItems.where((i) => open(i) && i.severity == AiSeverity.high).length,
      completed7d: _aiItems.where((i) => i.status == AiItemStatus.completed).length,
      failed7d: _aiItems.where((i) => i.status == AiItemStatus.failed).length,
      aiRecommendationsOpen: _aiItems.where((i) => i.fromAi && open(i)).length,
      aiCostMonthUsd: 0,
      aiBudgetMonthUsd: 0,
      lastReportDate: _dailyReports.isEmpty ? null : _dailyReports.first.date,
    );
  }

  @override
  Future<List<AiAgent>> aiAgents() async {
    await _latency(100);
    _admin();
    return demoAgents;
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
  Future<void> decideAiItem(int itemId, AiDecision decision, {String? note, String? authMethod}) async {
    await _latency(150);
    _admin();
    final idx = _aiItems.indexWhere((i) => i.id == itemId);
    if (idx < 0) throw AppError.from('HMY_NOT_FOUND');
    final i = _aiItems[idx];
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
        if (i.status != AiItemStatus.pendingApproval) throw AppError.from('HMY_INVALID_STATUS');
        _requireConfirmation(authMethod ?? '');
        next = AiItemStatus.approved;
      case AiDecision.reject || AiDecision.moreInfo || AiDecision.dismiss:
        if (closed.contains(i.status)) throw AppError.from('HMY_ALREADY_REVIEWED');
        if (decision == AiDecision.dismiss && i.needsApproval) throw AppError.from('HMY_INVALID_STATUS');
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
        next = decision == AiDecision.completed ? AiItemStatus.completed : AiItemStatus.failed;
    }
    _aiItems[idx] = AiItem(
      id: i.id,
      agentKey: i.agentKey,
      kind: i.kind,
      severity: i.severity,
      status: next,
      fromAi: i.fromAi,
      title: i.title,
      body: i.body,
      evidence: i.evidence,
      proposedAction: i.proposedAction,
      decisionNote: note,
      createdAt: i.createdAt,
    );
    _log('ai_item.${decision.key}', 'ai_items', '$itemId', {'note': note, 'auth_method': authMethod});
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
    final report = DailyReport(
      date: DateTime(now.year, now.month, now.day).subtract(const Duration(days: 1)),
      timezone: 'America/New_York',
      generatedAt: now,
      data: {
        'today': {'bookings_created': dash.bookingsToday, 'commission_revenue_bs': 0},
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
          if (dash.pendingApplications > 0) 'Review ${dash.pendingApplications} professional application(s).',
          if (topups.isNotEmpty) 'Verify ${topups.length} pending recharge(s).',
          if (_aiItems.any((i) => i.status == AiItemStatus.pendingApproval))
            'Decide the items waiting for your approval.',
        ],
        'unavailable': const ['Demo mode: sample data only'],
      },
    );
    _dailyReports.insert(0, report);
    return report;
  }

  @override
  Future<int> runMonitors() async {
    await _latency(100);
    _admin();
    return 0;
  }

  void _log(String action, String table, String id, [Map<String, dynamic> details = const {}]) => _audit.insert(
    0,
    AuditEntry(
      id: _seq++,
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
      'bookings_today': _bookings.values.where((b) => b.createdAt.isAfter(start)).length,
      'active_bookings': _bookings.values.where((b) => b.status.isActive).length,
      'approved_professionals': _pros.values.where((p) => p.status == VerificationStatus.approved).length,
      'available_professionals': _pros.values
          .where((p) => p.status == VerificationStatus.approved && p.available)
          .length,
      'users': _accounts.length,
      'active_commission_rules': _rules.where((r) => r.isActive).length,
    });
  }

  @override
  Future<List<AdminApplication>> adminApplications({String status = 'pending'}) async {
    await _latency(200);
    _admin();
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
    _admin();
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
    _admin();
    final p = _pros[professionalId];
    if (p == null) throw AppError.from('HMY_NO_APPLICATION');
    final needsReason =
        decision == VerificationStatus.rejected || decision == VerificationStatus.reverificationRequired;
    if (needsReason && (note ?? '').trim().isEmpty) throw AppError.from('HMY_REASON_REQUIRED');
    if (decision == VerificationStatus.approved &&
        p.status != VerificationStatus.approved &&
        p.status != VerificationStatus.suspended &&
        _identityRequired &&
        !p.identity.any((c) => !c.sandbox && c.status == IdentityStatus.approved)) {
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
    _admin();
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
    _admin();
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
    _admin();
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
    _admin();
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
    _admin();
    return [
      for (final t in _tickets)
        if (status == 'all' || (status == 'open' ? t.status != TicketStatus.closed : t.status.key == status)) t,
    ];
  }

  @override
  Future<void> updateTicket(int ticketId, TicketStatus status, {String? note}) async {
    await _latency();
    _admin();
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
    _admin();
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
    final admin = _admin();
    final a = _account(userId);
    if (a == null) throw AppError.from('HMY_NOT_FOUND');
    if (a.id == admin.id || a.roles.contains(AppRole.admin)) throw AppError.from('HMY_FORBIDDEN');
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
}

class _Account {
  _Account({required this.id, this.email = '', required this.fullName, this.cityId, this.termsAccepted = true});

  final String id;

  /// Correo confirmado (opcional); vacío si no agregó uno.
  String email;
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
  Set<String> _offers = {};
  int offersCount = 0;
  double? quoteAmount;
  String? quoteNote;
  double? finalAmount;
  bool customerPaid = false;
  bool professionalPaid = false;
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
