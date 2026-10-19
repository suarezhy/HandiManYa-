import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import '../../core/utils/app_error.dart';
import '../models/booking.dart';
import '../models/catalog.dart';
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
        ProRepository {
  DemoBackend({this.simulateDelays = true}) {
    _seed();
  }

  /// En las pruebas automáticas se apaga para que todo sea inmediato.
  final bool simulateDelays;

  static const demoPassword = 'Demo1234';
  static const demoCode = '123456';
  static const customerEmail = 'cliente@demo.bo';
  static const professionalEmail = 'profesional@demo.bo';

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
  Future<List<City>> cities() async => DemoData.cities;

  @override
  Future<List<Zone>> zones(int cityId) async => DemoData.zones.where((z) => z.cityId == cityId).toList();

  @override
  Future<List<ServiceCategory>> categories() async => DemoData.categories;

  @override
  Future<List<Promotion>> promotions(int? cityId) async => DemoData.promotions;

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

  Iterable<_Pro> _eligible(int categoryId, int cityId, int? zoneId, String customerId) => _pros.values.where(
    (p) =>
        p.status == VerificationStatus.approved &&
        p.available &&
        p.id != customerId &&
        p.cityId == cityId &&
        p.primaryCategoryId == categoryId &&
        (zoneId == null || p.zoneIds.isEmpty || p.zoneIds.contains(zoneId)),
  );

  @override
  Future<int> countYaAvailable({required int categoryId, required int cityId, int? zoneId}) async {
    await _latency(150);
    return _eligible(categoryId, cityId, zoneId, _session?.id ?? '').length;
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
    if (d.professionalId == me.id) throw AppError.from('HMY_CANNOT_BOOK_SELF');
    final b = _Booking(
      id: _id('b'),
      code: List.generate(6, (_) => 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'[_rng.nextInt(31)]).join(),
      customerId: me.id,
      professionalId: d.professionalId,
      draft: d,
      createdAt: DateTime.now(),
    );

    if (d.isYa) {
      final eligible = _eligible(d.categoryId, d.cityId, d.zoneId, me.id).toList();
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
      address: addressVisible ? BookingAddress(line: b.draft.address, reference: b.draft.addressReference) : null,
      conversationId: b.conversationId,
      hasReview: b.hasReview,
      offersSent: isCustomer ? b.offersCount : null,
      events: List.of(b.events),
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
  }

  @override
  Future<void> submitApplication() async {
    await _latency();
    final p = _pros[_me.id];
    if (p == null) throw AppError.from('HMY_NO_APPLICATION');
    if (p.documentCount == 0) throw AppError.from('HMY_DOCUMENTS_REQUIRED');
    if (p.displayName.length < 3) throw AppError.from('HMY_APPLICATION_INCOMPLETE');
    p.status = VerificationStatus.submitted;
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
  Future<void> requestTopup({required double amount, required int methodId, String? reference}) async {
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
    // Demostración: la recarga se acredita sola a los pocos segundos.
    final proId = _me.id;
    final id = list.first.id;
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
  });

  final String id;
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
