import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import '../../core/utils/app_error.dart';
import '../models/admin.dart';
import '../models/booking.dart';
import '../models/catalog.dart';
import '../models/geo.dart';
import '../models/messaging.dart';
import '../models/professional.dart';
import '../models/user.dart';
import '../models/wallet.dart';
import '../repositories/repositories.dart';
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
        AdminRepository {
  DemoBackend({this.simulateDelays = true}) {
    _seed();
    _seedAdmin();
  }

  /// En las pruebas automáticas se apaga para que todo sea inmediato.
  final bool simulateDelays;

  static const demoPassword = 'Demo1234';
  static const demoCode = '123456';
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
  final _inactiveCategories = <int>{};
  final _inactiveCities = <int>{};
  final _promos = <({Promotion promo, bool active})>[];
  final _topupProofs = <int, Uint8List>{};
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
      final account = _Account(id: p.$1, email: '${p.$1}@demo.bo', password: '', fullName: p.$2, cityId: p.$4)
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

    final customer =
        _Account(id: 'demo-cliente', email: customerEmail, password: demoPassword, fullName: 'Carla Rojas', cityId: 1)
          ..phone = '+59171234567'
          ..confirmed = true;
    _accounts[customer.email] = customer;

    final pro =
        _Account(
            id: 'demo-pro',
            email: professionalEmail,
            password: demoPassword,
            fullName: 'Miguel Ángel Suárez',
            cityId: 1,
          )
          ..phone = '+59176543210'
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
    final admin =
        _Account(id: 'demo-admin', email: adminEmail, password: demoPassword, fullName: 'Equipo HandiMan', cityId: 1)
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
      _accounts['$id@demo.bo'] = _Account(id: id, email: '$id@demo.bo', password: '', fullName: name, cityId: 1)
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
          _Account(id: 'demo-vecino2', email: 'vecino2@demo.bo', password: '', fullName: 'Jorge Salvatierra', cityId: 1)
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

  AuthUser _authUser(_Account a) => AuthUser(id: a.id, email: a.email, emailConfirmed: a.confirmed);

  // ================================================================= Auth
  @override
  AuthUser? get currentUser => _session == null ? null : _authUser(_session!);

  @override
  Stream<AuthUser?> authChanges() => _auth.stream;

  void _emitAuth() => _auth.add(currentUser);

  @override
  Future<void> signUp({
    required String email,
    required String password,
    required String fullName,
    required String phone,
    required int cityId,
    required bool wantsToBeProfessional,
  }) async {
    await _latency();
    final key = email.trim().toLowerCase();
    if (_accounts.containsKey(key)) {
      throw const AppError('Ya existe una cuenta con ese correo. Prueba ingresar.', code: 'user_exists');
    }
    final a = _Account(id: _id('u'), email: key, password: password, fullName: fullName.trim(), cityId: cityId)
      ..phone = phone;
    _accounts[key] = a;
    _session = a;
    _emitAuth();
  }

  @override
  Future<void> verifyEmailCode({required String email, required String code}) async {
    await _latency();
    final a = _accounts[email.trim().toLowerCase()];
    if (a == null || code.trim() != demoCode) {
      throw const AppError('El código no es válido o ya venció. Pide uno nuevo.', code: 'otp_invalid');
    }
    a.confirmed = true;
    _session = a;
    _emitAuth();
  }

  @override
  Future<void> resendEmailCode(String email) => _latency();

  @override
  Future<void> signIn({required String email, required String password}) async {
    await _latency();
    final a = _accounts[email.trim().toLowerCase()];
    if (a == null || a.password != password) {
      throw const AppError('Correo o contraseña incorrectos.', code: 'invalid_credentials');
    }
    _session = a;
    _emitAuth();
  }

  @override
  Future<void> sendPasswordReset(String email) => _latency();

  @override
  Future<void> verifyRecoveryCode({required String email, required String code}) async {
    await _latency();
    final a = _accounts[email.trim().toLowerCase()];
    if (a == null || code.trim() != demoCode) {
      throw const AppError('El código no es válido o ya venció. Pide uno nuevo.', code: 'otp_invalid');
    }
    _session = a;
    _emitAuth();
  }

  @override
  Future<void> updatePassword(String newPassword) async {
    await _latency();
    _me.password = newPassword;
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
  Future<void> updateProfile({required String fullName, String? phone, int? cityId}) async {
    await _latency();
    _me
      ..fullName = fullName.trim()
      ..phone = phone
      ..cityId = cityId;
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
      DemoData.categories.where((c) => !_inactiveCategories.contains(c.id)).toList();

  @override
  Future<List<Promotion>> promotions(int? cityId) async => [
    for (final p in _promos)
      if (p.active) p.promo,
  ];

  // ================================================================= Profesionales
  String _catName(int id) => DemoData.categories.firstWhere((c) => c.id == id).name;
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
  Future<String> create(BookingDraft d) async {
    await _latency(500);
    final me = _me;
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
    );

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
    if (to == BookingStatus.workFinished && finalAmount != null) b.finalAmount = finalAmount;
    _move(b, to, actorId: _me.id);
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
              _Account(id: 'demo-vecino', email: 'vecino@demo.bo', password: '', fullName: 'Doña Elena Paz', cityId: 1)
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
  Future<void> requestTopup({
    required double amount,
    required int methodId,
    String? reference,
    PhotoUpload? proof,
  }) async {
    await _latency();
    if (amount <= 0 || amount > 10000) throw AppError.from('HMY_INVALID_AMOUNT');
    final list = _topups.putIfAbsent(_me.id, () => []);
    if (list.where((t) => t.status == TopupStatus.pending).length >= 3) throw AppError.from('HMY_TOO_MANY_PENDING');
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
    final proId = _me.id;
    final id = list.first.id;
    if (proof != null) _topupProofs[id] = proof.bytes;
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
        if (a.password.isNotEmpty || a.id.startsWith('demo-') || _pros.containsKey(a.id))
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
    return [
      for (final c in DemoData.categories)
        CatalogItem(id: c.id, name: c.name, subtitle: c.description, isActive: !_inactiveCategories.contains(c.id)),
    ];
  }

  @override
  Future<void> setCategoryActive(int id, bool active) async {
    await _latency();
    _admin();
    active ? _inactiveCategories.remove(id) : _inactiveCategories.add(id);
    _log('service_categories.update', 'service_categories', '$id', {'is_active': active});
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
}

class _Account {
  _Account({required this.id, required this.email, required this.password, required this.fullName, this.cityId});

  final String id;
  final String email;
  String password;
  String fullName;
  String? phone;
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
