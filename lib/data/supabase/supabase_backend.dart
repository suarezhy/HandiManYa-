import 'dart:async';
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart' hide AuthUser;

import '../../core/services/push_tokens.dart';
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

/// Fecha como la espera Postgres ('2026-10-01').
String _day(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

List<Map<String, dynamic>> _rows(dynamic data) => [
  for (final r in (data as List? ?? const [])) Map<String, dynamic>.from(r as Map),
];

/// Implementación real sobre Supabase. Toda escritura importante pasa por
/// funciones RPC del servidor, que validan permisos y estados.
class SupabaseBackend
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
  SupabaseBackend(this._db);

  final SupabaseClient _db;

  String get _uid {
    final id = _db.auth.currentUser?.id;
    if (id == null) throw const AuthException('HMY_AUTH_REQUIRED');
    return id;
  }

  String? _publicPhoto(String? path) =>
      (path == null || path.isEmpty) ? null : _db.storage.from('avatars').getPublicUrl(path);

  // ---------------------------------------------------------------- Auth
  AuthUser? _map(User? u) => u == null
      ? null
      : AuthUser(
          id: u.id,
          // Supabase guarda el número sin "+".
          phone: (u.phone ?? '').isEmpty ? null : '+${u.phone!.replaceFirst('+', '')}',
          email: (u.email ?? '').isEmpty ? null : u.email,
        );

  @override
  AuthUser? get currentUser => _map(_db.auth.currentUser);

  @override
  Stream<AuthUser?> authChanges() => _db.auth.onAuthStateChange.map((s) => _map(s.session?.user));

  static OtpChannel _channel(CodeChannel c) => c == CodeChannel.whatsapp ? OtpChannel.whatsapp : OtpChannel.sms;

  // Supabase no le pasa el canal al servicio de envío: se guarda antes.
  Future<void> _chooseChannel(String phone, CodeChannel channel) =>
      _db.rpc('choose_code_channel', params: {'p_phone': phone, 'p_channel': channel.key});

  @override
  Future<void> sendPhoneCode({required String phone, required CodeChannel channel}) async {
    await _chooseChannel(phone, channel);
    await _db.auth.signInWithOtp(phone: phone, channel: _channel(channel), shouldCreateUser: true);
  }

  @override
  Future<void> verifyPhoneCode({required String phone, required String code}) =>
      _db.auth.verifyOTP(type: OtpType.sms, phone: phone, token: code.trim());

  @override
  Future<void> sendEmailLoginCode(String email) =>
      _db.auth.signInWithOtp(email: email.trim().toLowerCase(), shouldCreateUser: false);

  @override
  Future<void> verifyEmailLoginCode({required String email, required String code}) =>
      _db.auth.verifyOTP(type: OtpType.email, email: email.trim().toLowerCase(), token: code.trim());

  @override
  Future<void> signOut() async {
    // Primero se suelta el teléfono: la cuenta que sale deja de recibir avisos push aquí.
    final token = PushTokens.current;
    if (token != null) {
      try {
        await unregisterPushDevice(token);
      } catch (_) {
        // Sin conexión o sin la migración 0045: igual se cierra la sesión.
      }
      PushTokens.current = null;
    }
    await _db.auth.signOut();
  }

  // ---------------------------------------------------------------- Cuenta
  @override
  Future<UserProfile> myAccount() async {
    // Las cuatro consultas a la vez: al abrir la app se espera una sola vuelta.
    final results = await Future.wait<dynamic>([
      _db.rpc('my_account'),
      _db.rpc('my_status'),
      _db.from('profiles').select('avatar_path').eq('id', _uid).maybeSingle(),
      _myStaffAccess(),
    ]);
    final m = Map<String, dynamic>.from(results[0] as Map);
    final st = Map<String, dynamic>.from(results[1] as Map? ?? const {});
    final avatar = (results[2] as Map?)?['avatar_path'] as String?;
    final staff = results[3] as StaffAccess;
    return UserProfile(
      id: m['id'] as String,
      email: m['email'] as String? ?? '',
      fullName: m['full_name'] as String? ?? '',
      phone: m['phone'] as String?,
      phoneVerified: m['phone_verified'] as bool? ?? false,
      emailConfirmed: m['email_confirmed'] as bool? ?? false,
      emailPending: m['email_pending'] as String?,
      staffRole: staff.role == StaffRole.owner ? null : staff.role,
      staffStatus: staff.status,
      profileComplete: m['profile_complete'] as bool? ?? false,
      cityId: (m['city_id'] as num?)?.toInt(),
      activeRole: AppRole.parse(m['active_role'] as String?),
      roles: {for (final r in (m['roles'] as List? ?? const [])) AppRole.parse(r as String)},
      professionalStatus: VerificationStatus.parse(m['professional_status'] as String?),
      onboardingCompleted: m['onboarding_completed'] as bool? ?? false,
      deletionRequested: m['deletion_requested'] as bool? ?? false,
      isSuspended: st['suspended_at'] != null,
      suspensionReason: st['suspension_reason'] as String?,
      blockedIds: {for (final id in (st['blocked'] as List? ?? const [])) id as String},
      photoUrl: _publicPhoto(avatar),
    );
  }

  @override
  Future<void> setProfilePhoto({required Uint8List bytes, required String fileName}) async {
    final photo = PhotoUpload(bytes: bytes, fileName: fileName);
    final old = (await _db.from('profiles').select('avatar_path').eq('id', _uid).maybeSingle())?['avatar_path'];
    // Ruta nueva en cada cambio: así nadie ve la foto anterior guardada en caché.
    final ext = photo.contentType.split('/').last.replaceAll('jpeg', 'jpg');
    final path = '$_uid/perfil-${DateTime.now().millisecondsSinceEpoch}.$ext';
    await _db.storage
        .from('avatars')
        .uploadBinary(path, bytes, fileOptions: FileOptions(contentType: photo.contentType, upsert: false));
    await _db.from('profiles').update({'avatar_path': path}).eq('id', _uid);
    // La misma foto en el perfil público de profesional, si lo tiene.
    await _db.from('professional_profiles').update({'photo_path': path}).eq('user_id', _uid);
    if (old is String && old.isNotEmpty && old != path) await _removeAvatarFile(old);
  }

  @override
  Future<void> removeProfilePhoto() async {
    final old = (await _db.from('profiles').select('avatar_path').eq('id', _uid).maybeSingle())?['avatar_path'];
    await _db.from('profiles').update({'avatar_path': null}).eq('id', _uid);
    await _db.from('professional_profiles').update({'photo_path': null}).eq('user_id', _uid);
    if (old is String && old.isNotEmpty) await _removeAvatarFile(old);
  }

  /// Borra un archivo propio de `avatars`. Si falla, la foto ya no se muestra
  /// igual (la ruta se quitó del perfil), así que no se interrumpe al usuario.
  Future<void> _removeAvatarFile(String path) async {
    if (!path.startsWith('$_uid/')) return;
    try {
      await _db.storage.from('avatars').remove([path]);
    } catch (_) {}
  }

  @override
  Future<void> completeSignup({required String fullName, required int cityId, required bool acceptTerms}) => _db.rpc(
    'complete_signup',
    params: {'p_full_name': fullName.trim(), 'p_city_id': cityId, 'p_accept_terms': acceptTerms},
  );

  @override
  Future<void> updateProfile({required String fullName, int? cityId}) async {
    await _db.from('profiles').update({'full_name': fullName.trim(), 'city_id': cityId}).eq('id', _uid);
  }

  // El número y el correo los cambia Supabase Auth, después de un código.
  @override
  Future<void> requestPhoneChange({required String phone, required CodeChannel channel}) async {
    await _chooseChannel(phone, channel);
    await _db.auth.updateUser(UserAttributes(phone: phone));
  }

  @override
  Future<void> verifyPhoneChange({required String phone, required String code}) =>
      _db.auth.verifyOTP(type: OtpType.phoneChange, phone: phone, token: code.trim());

  @override
  Future<void> requestEmailChange(String email) =>
      _db.auth.updateUser(UserAttributes(email: email.trim().toLowerCase()));

  @override
  Future<void> verifyEmailChange({required String email, required String code}) =>
      _db.auth.verifyOTP(type: OtpType.emailChange, email: email.trim().toLowerCase(), token: code.trim());

  @override
  Future<void> removeEmail() async {
    await _db.rpc('remove_my_email');
    // La sesión guarda una copia del usuario: se actualiza para que el
    // correo quitado no siga apareciendo.
    await _db.auth.refreshSession();
  }

  @override
  Future<void> setActiveRole(AppRole role) => _db.rpc('set_active_role', params: {'p_role': role.key});

  @override
  Future<void> completeOnboarding() => _db.rpc('complete_onboarding');

  @override
  Future<void> requestAccountDeletion() => _db.rpc('request_account_deletion');

  // ---------------------------------------------------------------- Catálogo
  @override
  Future<List<City>> cities() async => _rows(
    await _db
        .from('cities')
        .select('id, name, slug, department_id, province, latitude, longitude')
        .eq('is_active', true)
        .order('sort_order')
        .order('name'),
  ).map(City.fromMap).toList();

  @override
  Future<List<Zone>> zones(int cityId) async => _rows(
    await _db
        .from('service_zones')
        .select('id, city_id, name')
        .eq('city_id', cityId)
        .eq('is_active', true)
        .order('sort_order'),
  ).map(Zone.fromMap).toList();

  @override
  Future<List<ServiceCategory>> categories() async => _rows(
    await _db
        .from('service_categories')
        .select('id, slug, name, icon, description, allows_ya, required_doc, safety_note, pro_note, sort_order')
        .eq('is_active', true)
        .order('sort_order'),
  ).map(ServiceCategory.fromMap).toList();

  @override
  Future<List<ServiceProblem>> problems(int categoryId) async => _rows(
    await _db
        .from('service_problems')
        .select('id, category_id, name, icon, is_other, sort_order, opens_category_id')
        .eq('category_id', categoryId)
        .eq('is_active', true)
        .order('sort_order')
        .order('id'),
  ).map(ServiceProblem.fromMap).toList();

  @override
  Future<List<Promotion>> promotions(int? cityId) async {
    final rows = _rows(await _db.from('promotions').select().eq('is_active', true).order('sort_order'));
    return rows
        .where((r) => r['city_id'] == null || (r['city_id'] as num).toInt() == cityId)
        .map(Promotion.fromMap)
        .toList();
  }

  // ---------------------------------------------------------------- Profesionales
  @override
  Future<List<ProfessionalSummary>> search(SearchFilters f, {int limit = 20, int offset = 0}) async {
    final data = await _db.rpc(
      'search_professionals',
      params: {
        'p_city_id': f.cityId,
        'p_category_id': f.categoryId,
        'p_zone_id': f.zoneId,
        'p_query': f.query.trim().isEmpty ? null : f.query.trim(),
        'p_available_now': f.availableNow,
        'p_min_rating': f.minRating,
        'p_sort': f.sort.key,
        'p_limit': limit,
        'p_offset': offset,
      },
    );
    return _rows(data).map((m) => ProfessionalSummary.fromMap(m, photo: _publicPhoto)).toList();
  }

  @override
  Future<ProfessionalDetail?> professionalDetail(String id) async {
    final rows = _rows(await _db.rpc('get_professional_public', params: {'p_id': id}));
    if (rows.isEmpty) return null;
    final m = rows.first;
    return ProfessionalDetail(
      summary: ProfessionalSummary.fromMap(m, photo: _publicPhoto),
      bio: m['bio'] as String?,
      yearsExperience: (m['years_experience'] as num?)?.toInt(),
      priceNote: m['price_note'] as String?,
      services: _rows(m['services']).map(ProService.fromMap).toList(),
      portfolioUrls: [
        for (final p in _rows(m['portfolio'])) _db.storage.from('portfolio').getPublicUrl(p['path'] as String),
      ],
      availability: _rows(m['weekly_availability']).map(AvailabilitySlot.fromMap).toList(),
    );
  }

  @override
  Future<List<Review>> reviews(String professionalId) async =>
      _rows(await _db.rpc('professional_reviews', params: {'p_professional': professionalId}))
          .map(Review.fromMap)
          .toList();

  @override
  Future<HomeMapData> homeMap(int cityId) async {
    final m = Map<String, dynamic>.from(await _db.rpc('home_map_professionals', params: {'p_city': cityId}) as Map);
    final city = Map<String, dynamic>.from(m['city'] as Map);
    return HomeMapData(
      cityName: city['name'] as String? ?? '',
      cityLatitude: (city['latitude'] as num?)?.toDouble(),
      cityLongitude: (city['longitude'] as num?)?.toDouble(),
      professionals: [
        for (final p in (m['professionals'] as List? ?? const []))
          MapProfessional.fromMap(Map<String, dynamic>.from(p as Map), photo: _publicPhoto),
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
  }) async => (await _db.rpc(
    'count_ya_available',
    params: {
      'p_category': categoryId,
      'p_city': cityId,
      'p_zone': zoneId,
      'p_latitude': latitude,
      'p_longitude': longitude,
    },
  ) as num).toInt();

  // ---------------------------------------------------------------- Solicitudes
  DateTime? _expiredAt;

  // Cierra los pedidos de esta persona que vencieron sin respuesta (0046),
  // a lo más cada 20 s. Si falla, no pasa nada: el servidor igual rechaza
  // aceptar un pedido vencido.
  Future<void> _expireOverdue() async {
    final now = DateTime.now();
    if (_expiredAt != null && now.difference(_expiredAt!) < const Duration(seconds: 20)) return;
    _expiredAt = now;
    try {
      await _db.rpc('expire_my_overdue_bookings');
    } on PostgrestException {
      // Sin la migración 0046 (PGRST202) o un bloqueo pasajero: se sigue.
    }
  }

  @override
  Future<String> create(BookingDraft d) async {
    // Lo vencido no cuenta para el máximo de pedidos abiertos.
    _expiredAt = null;
    await _expireOverdue();
    if (d.isYa) {
      return await _db.rpc(
        'create_ya_request',
        params: {
          'p_category': d.categoryId,
          'p_city': d.cityId,
          'p_description': d.description,
          'p_address': d.address,
          'p_address_reference': d.addressReference,
          'p_zone_id': d.zoneId,
          'p_payment_method': d.paymentMethod?.key,
          'p_latitude': d.latitude,
          'p_longitude': d.longitude,
          'p_problem_ids': d.problemIds.isEmpty ? null : d.problemIds,
          'p_other_text': d.otherText,
          'p_destination': d.destination,
        },
      ) as String;
    }
    // Programada sin profesional elegido: queda "Pendiente de profesional".
    if (d.mode == BookingMode.scheduled && d.professionalId == null) {
      return await _db.rpc(
        'create_scheduled_request',
        params: {
          'p_category': d.categoryId,
          'p_city': d.cityId,
          'p_description': d.description,
          'p_address': d.address,
          'p_scheduled_start': d.scheduledStart?.toUtc().toIso8601String(),
          'p_duration_minutes': d.durationMinutes,
          'p_address_reference': d.addressReference,
          'p_zone_id': d.zoneId,
          'p_payment_method': d.paymentMethod?.key,
          'p_latitude': d.latitude,
          'p_longitude': d.longitude,
          'p_problem_ids': d.problemIds.isEmpty ? null : d.problemIds,
          'p_other_text': d.otherText,
          'p_destination': d.destination,
        },
      ) as String;
    }
    return await _db.rpc(
      'create_booking',
      params: {
        'p_professional': d.professionalId,
        'p_category': d.categoryId,
        'p_mode': d.mode.key,
        'p_description': d.description,
        'p_address': d.address,
        'p_address_reference': d.addressReference,
        'p_zone_id': d.zoneId,
        'p_scheduled_start': d.scheduledStart?.toUtc().toIso8601String(),
        'p_duration_minutes': d.durationMinutes,
        'p_payment_method': d.paymentMethod?.key,
        'p_latitude': d.latitude,
        'p_longitude': d.longitude,
        'p_problem_ids': d.problemIds.isEmpty ? null : d.problemIds,
        'p_other_text': d.otherText,
        'p_destination': d.destination,
      },
    ) as String;
  }

  @override
  Future<List<BookingSummary>> myBookings({required bool asProfessional}) async {
    await _expireOverdue();
    return _rows(await _db.rpc('my_bookings', params: {'p_as': asProfessional ? 'professional' : 'customer'}))
        .map((m) => BookingSummary.fromMap(m, photo: _publicPhoto))
        .toList();
  }

  @override
  Future<BookingDetail> detail(String bookingId) async {
    await _expireOverdue();
    final m = Map<String, dynamic>.from(await _db.rpc('booking_detail', params: {'p_booking': bookingId}) as Map);
    // Las fotos están en un depósito privado: se firman por una hora.
    final paths = [for (final p in (m['photos'] as List? ?? const [])) (p as Map)['path'] as String];
    var photos = const <BookingPhoto>[];
    if (paths.isNotEmpty) {
      try {
        final signed = await _db.storage.from('booking-photos').createSignedUrlsResult(paths, 3600);
        photos = [
          for (final u in signed)
            if (u is SignedUrlSuccess) BookingPhoto(url: u.signedUrl),
        ];
      } catch (_) {
        // Sin permiso para ver las fotos: se muestra la solicitud sin ellas.
      }
    }
    return BookingDetail.fromMap(m, photo: _publicPhoto, photos: photos);
  }

  @override
  Future<void> addPhotos(String bookingId, List<PhotoUpload> photos) async {
    final uid = _uid;
    for (final p in photos) {
      final ext = p.contentType.split('/').last.replaceAll('jpeg', 'jpg');
      final path = '$bookingId/${uid}_${DateTime.now().microsecondsSinceEpoch}.$ext';
      await _db.storage
          .from('booking-photos')
          .uploadBinary(path, p.bytes, fileOptions: FileOptions(contentType: p.contentType));
      await _db.from('booking_photos').insert({
        'booking_id': bookingId,
        'kind': 'problem',
        'storage_path': path,
        'uploaded_by': uid,
      });
    }
  }

  @override
  Stream<void> changes() {
    final controller = StreamController<void>.broadcast();
    final channel = _db
        .channel('bookings-${DateTime.now().microsecondsSinceEpoch}')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'bookings',
          callback: (_) => controller.add(null),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'notifications',
          callback: (_) => controller.add(null),
        )
        .subscribe();
    controller.onCancel = () => _db.removeChannel(channel);
    return controller.stream;
  }

  @override
  Future<void> accept(String bookingId, {required bool isOffer}) => _closingIfExpired(
    () => _db.rpc(isOffer ? 'claim_ya_request' : 'accept_booking', params: {'p_booking': bookingId}),
  );

  // Si el pedido ya venció, se cierra enseguida para que la pantalla deje de
  // ofrecer "Aceptar".
  Future<void> _closingIfExpired(Future<dynamic> Function() call) async {
    try {
      await call();
    } on PostgrestException catch (e) {
      if (e.message.contains('HMY_REQUEST_EXPIRED')) {
        _expiredAt = null;
        await _expireOverdue();
      }
      rethrow;
    }
  }

  @override
  Future<void> decline(String bookingId, {required bool isOffer, String? reason}) => isOffer
      ? _db.rpc('decline_ya_offer', params: {'p_booking': bookingId})
      : _db.rpc('decline_booking', params: {'p_booking': bookingId, 'p_reason': reason});

  @override
  Future<void> sendQuote(String bookingId, double amount, String? note) => _closingIfExpired(
    () => _db.rpc('send_quote', params: {'p_booking': bookingId, 'p_amount': amount, 'p_note': note}),
  );

  @override
  Future<void> updateProgress(String bookingId, BookingStatus to, {double? finalAmount}) =>
      _db.rpc('update_job_progress', params: {'p_booking': bookingId, 'p_to': to.key, 'p_final_amount': finalAmount});

  @override
  Future<ArrivalPin> markArrived(String bookingId) async => ArrivalPin.fromMap(
    Map<String, dynamic>.from(await _db.rpc('mark_arrived', params: {'p_booking': bookingId}) as Map),
  );

  @override
  Future<ArrivalCheck> verifyArrivalPin(String bookingId, String pin) async => ArrivalCheck.fromMap(
    Map<String, dynamic>.from(
      await _db.rpc('verify_arrival_pin', params: {'p_booking': bookingId, 'p_pin': pin}) as Map,
    ),
  );

  @override
  Future<BookingArrival> arrival(String bookingId) async => BookingArrival.fromMap(
    Map<String, dynamic>.from(await _db.rpc('booking_arrival', params: {'p_booking': bookingId}) as Map),
  );

  @override
  Future<bool> shareTripLocation(String bookingId, GeoPoint point, {int? accuracyM}) async =>
      await _db.rpc(
        'share_trip_location',
        params: {
          'p_booking': bookingId,
          'p_latitude': point.latitude,
          'p_longitude': point.longitude,
          'p_accuracy_m': accuracyM,
        },
      ) ==
      true;

  @override
  Future<void> stopTripLocation(String bookingId) => _db.rpc('stop_trip_location', params: {'p_booking': bookingId});

  @override
  Future<TripLocation> tripLocation(String bookingId) async => TripLocation.fromMap(
    Map<String, dynamic>.from(await _db.rpc('trip_location', params: {'p_booking': bookingId}) as Map),
  );

  @override
  Future<String> createTripShare(String bookingId, {String? contactName}) async {
    final r = await _db.rpc('create_trip_share', params: {'p_booking': bookingId, 'p_contact_name': contactName});
    return (r as Map)['token'] as String;
  }

  @override
  Future<List<TripShare>> tripShares(String bookingId) async {
    final r = await _db.rpc('my_trip_shares', params: {'p_booking': bookingId}) as List;
    return [for (final m in r) TripShare.fromMap(Map<String, dynamic>.from(m as Map))];
  }

  @override
  Future<void> revokeTripShare(int shareId) => _db.rpc('revoke_trip_share', params: {'p_share': shareId});

  @override
  Future<SharedTrip> sharedTrip(String token) async => SharedTrip.fromMap(
    Map<String, dynamic>.from(await _db.rpc('trip_share_view', params: {'p_token': token}) as Map),
  );

  @override
  Future<void> respondQuote(String bookingId, {required bool accept}) =>
      _db.rpc('respond_quote', params: {'p_booking': bookingId, 'p_accept': accept});

  @override
  Future<void> confirmCompletion(String bookingId) => _db.rpc('confirm_completion', params: {'p_booking': bookingId});

  @override
  Future<void> submitReview(String bookingId, int rating, String? comment) =>
      _db.rpc('submit_review', params: {'p_booking': bookingId, 'p_rating': rating, 'p_comment': comment});

  @override
  Future<void> cancel(String bookingId, String reason) =>
      _db.rpc('cancel_booking', params: {'p_booking': bookingId, 'p_reason': reason});

  @override
  Future<void> openDispute(String bookingId, String reason) =>
      _db.rpc('open_dispute', params: {'p_booking': bookingId, 'p_reason': reason});

  @override
  Future<void> acknowledgePayment(String bookingId, PaymentMethod method) =>
      _db.rpc('acknowledge_payment', params: {'p_booking': bookingId, 'p_method': method.key});

  // ---------------------------------------------------------------- Mensajes
  @override
  Future<List<Conversation>> conversations() async =>
      _rows(await _db.rpc('my_conversations')).map(Conversation.fromMap).toList();

  @override
  Stream<List<ChatMessage>> watchMessages(String conversationId) => _db
      .from('messages')
      .stream(primaryKey: ['id'])
      .eq('conversation_id', conversationId)
      .order('created_at')
      .map((rows) => rows.map(ChatMessage.fromMap).toList());

  @override
  Future<void> send(String conversationId, String body) =>
      _db.rpc('send_message', params: {'p_conversation': conversationId, 'p_body': body});

  @override
  Future<void> markRead(String conversationId) =>
      _db.rpc('mark_conversation_read', params: {'p_conversation': conversationId});

  // ---------------------------------------------------------------- Notificaciones
  @override
  Future<List<AppNotification>> list() async =>
      _rows(await _db.from('notifications').select().order('created_at', ascending: false).limit(50))
          .map(AppNotification.fromMap)
          .toList();

  @override
  Stream<int> unreadCount() => _db
      .from('notifications')
      .stream(primaryKey: ['id'])
      .eq('user_id', _uid)
      .map((rows) => rows.where((r) => r['read_at'] == null).length);

  @override
  Future<void> markAllRead() => _db.rpc('mark_notifications_read');

  @override
  Future<void> registerPushDevice(String token, String platform) =>
      _db.rpc('register_push_device', params: {'p_token': token, 'p_platform': platform});

  @override
  Future<void> unregisterPushDevice(String token) => _db.rpc('unregister_push_device', params: {'p_token': token});

  // Sin la migración 0045 (PGRST202) el servidor no tiene avisos push.
  @override
  Future<PushStatus?> pushStatus() async {
    try {
      return PushStatus.fromMap(Map<String, dynamic>.from(await _db.rpc('my_push_status') as Map));
    } on PostgrestException catch (e) {
      if (e.code == 'PGRST202') return null;
      rethrow;
    }
  }

  @override
  Future<int> sendTestPush() async => ((await _db.rpc('send_test_push')) as num).toInt();

  // ---------------------------------------------------------------- Profesional
  @override
  Future<ProDashboard> dashboard() async =>
      ProDashboard.fromMap(Map<String, dynamic>.from(await _db.rpc('pro_dashboard') as Map));

  @override
  Future<void> setAvailability(bool available) => _db.rpc('set_availability', params: {'p_available': available});

  @override
  Future<ProfessionalApplication> application() async {
    final p = await _db.from('professional_profiles').select().eq('user_id', _uid).maybeSingle();
    if (p == null) return const ProfessionalApplication();
    final services = _rows(await _db.from('professional_services').select('category_id').eq('professional_id', _uid));
    final zones = _rows(await _db.from('professional_zones').select('zone_id').eq('professional_id', _uid));
    final docs = _rows(await _db.from('professional_documents').select('id').eq('professional_id', _uid));
    return ProfessionalApplication(
      status: VerificationStatus.parse(p['status'] as String?),
      displayName: p['display_name'] as String? ?? '',
      primaryCategoryId: (p['primary_category_id'] as num?)?.toInt(),
      bio: p['bio'] as String? ?? '',
      yearsExperience: (p['years_experience'] as num?)?.toInt(),
      cityId: (p['city_id'] as num?)?.toInt(),
      priceNote: p['price_note'] as String? ?? '',
      categoryIds: {for (final s in services) (s['category_id'] as num).toInt()},
      zoneIds: {for (final z in zones) (z['zone_id'] as num).toInt()},
      documentCount: docs.length,
      reviewNote: p['review_note'] as String?,
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
    final uid = _uid;
    await _db.rpc('start_professional_application');
    await _db
        .from('professional_profiles')
        .update({
          'display_name': displayName.trim(),
          'primary_category_id': primaryCategoryId,
          'city_id': cityId,
          'bio': bio.trim(),
          'years_experience': yearsExperience,
          'price_note': (priceNote ?? '').trim().isEmpty ? null : priceNote!.trim(),
        })
        .eq('user_id', uid);

    final cats = {...categoryIds, primaryCategoryId};
    await _db
        .from('professional_services')
        .delete()
        .eq('professional_id', uid)
        .not('category_id', 'in', '(${cats.join(',')})');
    await _db
        .from('professional_services')
        .upsert(
          [
            for (final c in cats) {'professional_id': uid, 'category_id': c},
          ],
          onConflict: 'professional_id,category_id',
          ignoreDuplicates: true,
        );
    await _db.from('professional_zones').delete().eq('professional_id', uid);
    if (zoneIds.isNotEmpty) {
      await _db.from('professional_zones').insert([
        for (final z in zoneIds) {'professional_id': uid, 'zone_id': z},
      ]);
    }
  }

  @override
  Future<void> uploadDocument({required String docType, required Uint8List bytes, required String fileName}) async {
    final uid = _uid;
    final ext = fileName.contains('.') ? fileName.split('.').last.toLowerCase() : 'jpg';
    final path = '$uid/${docType}_${DateTime.now().millisecondsSinceEpoch}.$ext';
    await _db.storage
        .from('professional-documents')
        .uploadBinary(
          path,
          bytes,
          fileOptions: FileOptions(contentType: ext == 'pdf' ? 'application/pdf' : 'image/$ext'),
        );
    await _db.from('professional_documents').insert({
      'professional_id': uid,
      'doc_type': docType,
      'storage_path': path,
    });
  }

  @override
  Future<void> submitApplication() => _db.rpc('submit_professional_application');

  @override
  Future<Wallet> wallet() async {
    final w = await _db.from('wallets').select('available, reserved').eq('professional_id', _uid).maybeSingle();
    return w == null ? const Wallet(available: 0, reserved: 0) : Wallet.fromMap(w);
  }

  @override
  Future<List<LedgerEntry>> ledger() async => _rows(
    await _db
        .from('wallet_ledger')
        .select()
        .eq('professional_id', _uid)
        .order('created_at', ascending: false)
        .limit(50),
  ).map(LedgerEntry.fromMap).toList();

  @override
  Future<List<TopupMethod>> topupMethods() async =>
      _rows(await _db.from('topup_methods').select().eq('is_active', true).order('sort_order'))
          .map(TopupMethod.fromMap)
          .toList();

  @override
  Future<List<TopupRequest>> topups() async => _rows(
    await _db
        .from('topup_requests')
        .select()
        .eq('professional_id', _uid)
        .order('created_at', ascending: false)
        .limit(20),
  ).map(TopupRequest.fromMap).toList();

  @override
  Future<int> requestTopup({
    required double amount,
    required int methodId,
    String? reference,
    PhotoUpload? proof,
    required String authMethod,
    required String clientKey,
  }) async {
    String? proofPath;
    if (proof != null) {
      final ext = proof.contentType.split('/').last.replaceAll('jpeg', 'jpg');
      proofPath = '$_uid/recarga_${DateTime.now().millisecondsSinceEpoch}.$ext';
      await _db.storage
          .from('topup-proofs')
          .uploadBinary(proofPath, proof.bytes, fileOptions: FileOptions(contentType: proof.contentType));
    }
    final id = await _db.rpc(
      'request_topup',
      params: {
        'p_amount': amount,
        'p_method': methodId,
        'p_reference': reference,
        'p_proof_path': proofPath,
        'p_auth_method': authMethod,
        'p_client_key': clientKey,
      },
    );
    return (id as num).toInt();
  }

  @override
  Future<bool> biometricEnabled() async {
    final m = await _db.from('security_settings').select('biometric_enabled').eq('user_id', _uid).maybeSingle();
    return m?['biometric_enabled'] as bool? ?? false;
  }

  @override
  Future<void> setBiometricEnabled(bool enabled, {String authMethod = 'otp'}) =>
      _db.rpc('set_biometric_enabled', params: {'p_enabled': enabled, 'p_auth_method': authMethod});

  @override
  Future<ServiceLocation?> serviceLocation() async {
    final m = await _db
        .from('professional_locations')
        .select('base_latitude, base_longitude, service_radius_km')
        .eq('professional_id', _uid)
        .maybeSingle();
    if (m == null) return null;
    return ServiceLocation(
      latitude: (m['base_latitude'] as num).toDouble(),
      longitude: (m['base_longitude'] as num).toDouble(),
      radiusKm: (m['service_radius_km'] as num).toInt(),
    );
  }

  @override
  Future<void> setServiceLocation({required double latitude, required double longitude, required int radiusKm}) => _db
      .rpc('set_service_location', params: {'p_latitude': latitude, 'p_longitude': longitude, 'p_radius_km': radiusKm});

  @override
  Future<IdentityCheck> identityCheck() async =>
      IdentityCheck.fromMap(Map<String, dynamic>.from(await _db.rpc('my_identity_check') as Map));

  @override
  Future<({String url, bool sandbox})> startIdentityCheck() async {
    final res = await _db.functions.invoke('identity-check');
    final m = Map<String, dynamic>.from(res.data as Map);
    return (url: m['verification_url'] as String, sandbox: m['sandbox'] as bool? ?? true);
  }

  // ---------------------------------------------------------------- Seguridad
  @override
  Future<void> reportUser({required String userId, required ReportReason reason, String? details, String? bookingId}) =>
      _db.rpc(
        'report_user',
        params: {'p_user': userId, 'p_reason': reason.key, 'p_details': details, 'p_booking': bookingId},
      );

  @override
  Future<void> blockUser(String userId) => _db.rpc('block_user', params: {'p_user': userId});

  @override
  Future<void> unblockUser(String userId) => _db.rpc('unblock_user', params: {'p_user': userId});

  @override
  Future<void> recordConsent(String document, String version) =>
      _db.rpc('record_consent', params: {'p_document': document, 'p_version': version});

  @override
  Future<void> contactSupport({required String subject, required String body, String? bookingId}) => _db
      .from('support_tickets')
      .insert({'user_id': _uid, 'subject': subject.trim(), 'body': body.trim(), 'booking_id': bookingId});

  // ---------------------------------------------------------------- Administración
  Future<String?> _signed(String bucket, String? path) async {
    if (path == null || path.isEmpty) return null;
    try {
      return await _db.storage.from(bucket).createSignedUrl(path, 3600);
    } catch (_) {
      return null;
    }
  }

  /// Rol de gestión. Si el proyecto todavía no tiene la migración de roles,
  /// la cuenta sigue funcionando como antes (sin Gerente ni Empleado).
  @override
  Future<StaffAccess> myStaffAccess() => _myStaffAccess();

  Future<StaffAccess> _myStaffAccess() async {
    try {
      return StaffAccess.fromMap(Map<String, dynamic>.from(await _db.rpc('my_staff_role') as Map));
    } catch (_) {
      return StaffAccess.none;
    }
  }

  // ------------------------------------------------------------ Equipo
  List<Map<String, dynamic>> _list(Object? v) => [
    for (final e in (v as List? ?? const [])) Map<String, dynamic>.from(e as Map),
  ];

  @override
  Future<OpsDashboard> opsDashboard() async =>
      OpsDashboard(Map<String, dynamic>.from(await _db.rpc('ops_dashboard') as Map));

  @override
  Future<List<OpsCase>> opsCases({String scope = 'mine', bool includeResolved = false}) async => [
    for (final m in _list(
      await _db.rpc('ops_cases_list', params: {'p_scope': scope, 'p_include_resolved': includeResolved}),
    ))
      OpsCase.fromMap(m),
  ].where(_inScope(scope)).toList();

  // Un servidor sin 0041 trata 'urgent' y 'escalated_owner' como 'all': la app
  // filtra igual, para no mostrar casos que no corresponden a la tarjeta.
  static bool Function(OpsCase) _inScope(String scope) => switch (scope) {
    'urgent' => (c) => c.priority == 'urgent',
    'escalated_owner' => (c) => c.status == OpsCaseStatus.escalated && c.escalatedTo == 'owner',
    _ => (_) => true,
  };

  @override
  Future<OpsCaseDetail> opsCaseDetail(int caseId) async => OpsCaseDetail.fromMap(
    Map<String, dynamic>.from(await _db.rpc('ops_case_detail', params: {'p_case': caseId}) as Map),
  );

  @override
  Future<void> assignCase(int caseId, String? userId) =>
      _db.rpc('ops_assign_case', params: {'p_case': caseId, 'p_user': userId});

  @override
  Future<void> setCaseStatus(int caseId, OpsCaseStatus status, {String? note}) =>
      _db.rpc('ops_set_case_status', params: {'p_case': caseId, 'p_status': status.key, 'p_note': note});

  @override
  Future<void> addCaseNote(int caseId, String body) =>
      _db.rpc('ops_add_note', params: {'p_case': caseId, 'p_body': body});

  @override
  Future<void> replyCase(int caseId, String message) =>
      _db.rpc('ops_reply', params: {'p_case': caseId, 'p_message': message});

  @override
  Future<void> escalateCase(int caseId, String reason, {String? category}) =>
      _db.rpc('ops_escalate', params: {'p_case': caseId, 'p_reason': reason, 'p_category': category});

  @override
  Future<void> flagDocument(int documentId, String note) =>
      _db.rpc('ops_flag_document', params: {'p_document': documentId, 'p_note': note});

  @override
  Future<List<StaffMember>> staffOverview() async => [
    for (final m in _list(await _db.rpc('ops_staff_overview'))) StaffMember.fromMap(m),
  ];

  @override
  Future<List<StaffActivity>> myStaffActivity() async => [
    for (final m in _list(await _db.rpc('ops_my_activity'))) StaffActivity.fromMap(m),
  ];

  // Sin la migración 0039 el servidor no tiene owner_staff_candidates ni la
  // versión con confirmación de owner_grant_staff (PGRST202): se usa la de
  // antes, que el servidor sigue autorizando solo para el propietario.
  @override
  Future<List<StaffCandidate>> staffCandidates(String query) async {
    try {
      return [
        for (final m in _rows(await _db.rpc('owner_staff_candidates', params: {'p_query': query})))
          StaffCandidate.fromMap(m),
      ];
    } on PostgrestException catch (e) {
      if (e.code != 'PGRST202') rethrow;
      final me = _db.auth.currentUser?.id;
      return [
        for (final u in await adminUsers(query))
          StaffCandidate(
            id: u.id,
            fullName: u.fullName,
            phoneMasked: maskPhone(u.phone),
            cityName: u.cityName,
            eligible: u.id != me && !u.isAdmin && !u.isSuspended && u.phone != null,
            reason: u.id == me
                ? 'self'
                : u.isAdmin
                ? 'owner'
                : u.isSuspended
                ? 'suspended'
                : u.phone == null
                ? 'phone_unconfirmed'
                : null,
          ),
      ];
    }
  }

  @override
  Future<void> grantStaff(String userId, StaffRole role, {required String authMethod}) async {
    try {
      await _db.rpc('owner_grant_staff', params: {'p_user': userId, 'p_role': role.key, 'p_auth_method': authMethod});
    } on PostgrestException catch (e) {
      if (e.code != 'PGRST202') rethrow;
      await _db.rpc('owner_grant_staff', params: {'p_user': userId, 'p_role': role.key});
    }
  }

  @override
  Future<void> setStaffStatus(String userId, String status, {String? reason, String? authMethod}) async {
    final params = {'p_user': userId, 'p_status': status, 'p_reason': reason};
    try {
      await _db.rpc('owner_set_staff_status', params: {...params, 'p_auth_method': authMethod});
    } on PostgrestException catch (e) {
      if (e.code != 'PGRST202') rethrow;
      await _db.rpc('owner_set_staff_status', params: params);
    }
  }

  @override
  Future<AdminDashboard> adminDashboard() async {
    try {
      return AdminDashboard(Map<String, dynamic>.from(await _db.rpc('owner_dashboard') as Map));
    } on PostgrestException catch (e) {
      // Sin la migración 0037 el servidor no tiene owner_dashboard: se usan los
      // números de siempre y el panel dice "Sin datos" en el resto.
      if (e.code != 'PGRST202') rethrow;
      return AdminDashboard(Map<String, dynamic>.from(await _db.rpc('admin_dashboard') as Map));
    }
  }

  @override
  Future<List<AdminApplication>> adminApplications({String status = 'pending'}) async =>
      _rows(await _db.rpc('admin_applications', params: {'p_status': status})).map(AdminApplication.fromMap).toList();

  @override
  Future<AdminApplicationDetail> adminApplicationDetail(String professionalId) async {
    final m = Map<String, dynamic>.from(
      await _db.rpc('admin_application_detail', params: {'p_professional': professionalId}) as Map,
    );
    final docs = _rows(m['documents']);
    return AdminApplicationDetail(
      summary: AdminApplication.fromMap({...m, 'documents': docs.length}),
      bio: m['bio'] as String?,
      yearsExperience: (m['years_experience'] as num?)?.toInt(),
      reviewNote: m['review_note'] as String?,
      zones: [for (final z in (m['zones'] as List? ?? const [])) z as String],
      categories: [for (final c in (m['categories'] as List? ?? const [])) c as String],
      documents: [
        for (final d in docs)
          AdminDocument(
            id: (d['id'] as num).toInt(),
            docType: d['doc_type'] as String,
            status: DocumentStatus.parse(d['status'] as String?),
            reviewNote: d['review_note'] as String?,
            url: await _signed('professional-documents', d['storage_path'] as String?),
          ),
      ],
      history: [
        for (final e in _rows(m['history']))
          (
            status: VerificationStatus.parse(e['to_status'] as String?),
            note: e['note'] as String?,
            at: DateTime.parse(e['created_at'] as String),
          ),
      ],
      identityChecks: _rows(m['identity_checks']).map(IdentityCheck.fromMap).toList(),
      identityCheckRequired: m['identity_check_required'] as bool? ?? false,
    );
  }

  @override
  Future<void> reviewApplication(String professionalId, VerificationStatus decision, {String? note}) => _db.rpc(
    'review_professional_application',
    params: {'p_professional': professionalId, 'p_decision': decision.key, 'p_note': note},
  );

  @override
  Future<void> reviewDocument(int documentId, DocumentStatus status, {String? note}) =>
      _db.rpc('admin_review_document', params: {'p_document': documentId, 'p_status': status.key, 'p_note': note});

  @override
  Future<List<AdminTopup>> adminTopups({String status = 'pending'}) async {
    final rows = _rows(await _db.rpc('admin_topups', params: {'p_status': status}));
    return [
      for (final r in rows) AdminTopup.fromMap(r, proofUrl: await _signed('topup-proofs', r['proof_path'] as String?)),
    ];
  }

  @override
  Future<void> reviewTopup(int topupId, {required bool approve, String? note}) =>
      _db.rpc('review_topup', params: {'p_topup': topupId, 'p_approve': approve, 'p_note': note});

  @override
  Future<void> adminVerifyArrival(String bookingCode, String reason) =>
      _db.rpc('admin_verify_arrival', params: {'p_code': bookingCode, 'p_reason': reason});

  @override
  Future<void> adjustWallet(String professionalId, double amount, String reason) => _db.rpc(
    'admin_wallet_adjustment',
    params: {
      'p_professional': professionalId,
      'p_amount': amount,
      'p_reason': reason,
      'p_key': '${DateTime.now().microsecondsSinceEpoch}',
    },
  );

  @override
  Future<List<AdminReport>> adminReports({String status = 'open'}) async =>
      _rows(await _db.rpc('admin_reports', params: {'p_status': status})).map(AdminReport.fromMap).toList();

  @override
  Future<void> reviewReport(int reportId, CaseStatus status, {String? resolution}) => _db.rpc(
    'admin_review_report',
    params: {'p_report': reportId, 'p_status': status.key, 'p_resolution': resolution},
  );

  @override
  Future<List<AdminDispute>> adminDisputes({String status = 'open'}) async =>
      _rows(await _db.rpc('admin_disputes', params: {'p_status': status})).map(AdminDispute.fromMap).toList();

  @override
  Future<void> resolveDispute(String bookingId, DisputeOutcome outcome, String resolution) => _db.rpc(
    'resolve_dispute',
    params: {'p_booking': bookingId, 'p_outcome': outcome.status.key, 'p_resolution': resolution},
  );

  @override
  Future<List<AdminTicket>> adminTickets({String status = 'open'}) async =>
      _rows(await _db.rpc('admin_tickets', params: {'p_status': status})).map(AdminTicket.fromMap).toList();

  @override
  Future<void> updateTicket(int ticketId, TicketStatus status, {String? note}) =>
      _db.rpc('admin_update_ticket', params: {'p_ticket': ticketId, 'p_status': status.key, 'p_note': note});

  @override
  Future<List<AdminUser>> adminUsers(String query) async =>
      _rows(await _db.rpc('admin_users', params: {'p_query': query})).map(AdminUser.fromMap).toList();

  @override
  Future<void> setSuspension(String userId, {required bool suspend, String? reason}) =>
      _db.rpc('admin_set_suspension', params: {'p_user': userId, 'p_suspend': suspend, 'p_reason': reason});

  @override
  Future<List<CommissionRule>> commissionRules() async =>
      _rows(await _db.from('commission_rules').select().order('id')).map(CommissionRule.fromMap).toList();

  @override
  Future<void> saveCommissionRule(CommissionRule r) => _db.rpc(
    'admin_save_commission_rule',
    params: {
      'p_id': r.id,
      'p_name': r.name,
      'p_category': r.categoryId,
      'p_city': r.cityId,
      'p_rate_percent': r.ratePercent,
      'p_fixed_fee': r.fixedFee,
      'p_reserve_amount': r.reserveAmount,
      'p_min_balance': r.minBalance,
      'p_capture_at': r.captureAt.key,
      'p_active': r.isActive,
    },
  );

  List<CatalogItem> _items(dynamic rows, {String? Function(Map<String, dynamic>)? subtitle}) => [
    for (final r in _rows(rows))
      CatalogItem(
        id: (r['id'] as num).toInt(),
        name: (r['name'] ?? r['title']) as String,
        subtitle: subtitle?.call(r),
        isActive: r['is_active'] as bool? ?? true,
      ),
  ];

  @override
  Future<List<CatalogItem>> adminCategories() async => _items(
    await _db.from('service_categories').select('id, name, is_active, description').order('sort_order'),
    subtitle: (r) => r['description'] as String?,
  );

  @override
  Future<void> setCategoryActive(int id, bool active) =>
      _db.from('service_categories').update({'is_active': active}).eq('id', id);

  @override
  Future<List<ServiceCategory>> adminServiceCategories() async =>
      _rows(await _db.from('service_categories').select().order('sort_order').order('id'))
          .map(ServiceCategory.fromMap)
          .toList();

  @override
  Future<void> saveCategory(ServiceCategory c) async {
    if (c.id == 0) {
      await _db.from('service_categories').insert(c.toMap());
    } else {
      await _db.from('service_categories').update(c.toMap()..remove('slug')).eq('id', c.id);
    }
  }

  @override
  Future<void> reorderCategories(List<int> orderedIds) async {
    for (var i = 0; i < orderedIds.length; i++) {
      await _db.from('service_categories').update({'sort_order': (i + 1) * 10}).eq('id', orderedIds[i]);
    }
  }

  @override
  Future<List<ServiceProblem>> adminProblems(int categoryId) async =>
      _rows(await _db.from('service_problems').select().eq('category_id', categoryId).order('sort_order').order('id'))
          .map(ServiceProblem.fromMap)
          .toList();

  @override
  Future<void> saveProblem(ServiceProblem p) async {
    if (p.id == 0) {
      await _db.from('service_problems').insert(p.toMap());
    } else {
      await _db.from('service_problems').update(p.toMap()).eq('id', p.id);
    }
  }

  @override
  Future<void> reorderProblems(List<int> orderedIds) async {
    for (var i = 0; i < orderedIds.length; i++) {
      await _db.from('service_problems').update({'sort_order': (i + 1) * 10}).eq('id', orderedIds[i]);
    }
  }

  @override
  Future<List<CatalogItem>> adminCities() async =>
      _items(await _db.from('cities').select('id, name, is_active').order('name'));

  @override
  Future<void> setCityActive(int id, bool active) => _db.from('cities').update({'is_active': active}).eq('id', id);

  @override
  Future<List<CatalogItem>> adminPromotions() async => _items(
    await _db.from('promotions').select('id, title, subtitle, is_active').order('sort_order'),
    subtitle: (r) => r['subtitle'] as String?,
  );

  @override
  Future<void> setPromotionActive(int id, bool active) =>
      _db.from('promotions').update({'is_active': active}).eq('id', id);

  @override
  Future<void> createPromotion({required String title, String? subtitle, int? cityId}) =>
      _db.from('promotions').insert({'title': title.trim(), 'subtitle': subtitle, 'city_id': cityId});

  @override
  Future<List<AuditEntry>> auditLog() async =>
      _rows(await _db.rpc('admin_audit_entries', params: {'p_limit': 200})).map(AuditEntry.fromMap).toList();

  @override
  Future<CostDashboard> costDashboard() async =>
      CostDashboard.fromMap(Map<String, dynamic>.from(await _db.rpc('admin_cost_dashboard') as Map));

  @override
  Future<void> setVendor(String key, VendorStatus status, {double monthlyCapUsd = 0, String? authMethod}) => _db.rpc(
    'admin_set_vendor',
    params: {'p_key': key, 'p_status': status.key, 'p_monthly_cap_usd': monthlyCapUsd, 'p_auth_method': authMethod},
  );

  @override
  Future<int> runCostMonitors() async => ((await _db.rpc('admin_run_cost_monitors')) as num).toInt();

  @override
  Future<void> setIdentityCheckRequired(bool required, {String? authMethod}) => _db.rpc(
    'admin_set_setting',
    params: {
      'p_key': 'identity_check',
      'p_value': {'required': required},
      'p_auth_method': authMethod,
    },
  );

  // ------------------------------------------------------- Centro de Control IA
  @override
  Future<AiOverview> aiOverview() async =>
      AiOverview.fromMap(Map<String, dynamic>.from(await _db.rpc('admin_ai_overview') as Map));

  @override
  Future<List<AiAgent>> aiAgents() async => [
    for (final m in (await _db.rpc('admin_ai_agents') as List?) ?? const [])
      AiAgent.fromMap(Map<String, dynamic>.from(m as Map)),
  ];

  @override
  Future<AiItemDetail> aiItemDetail(int itemId) async => AiItemDetail.fromMap(
    Map<String, dynamic>.from(await _db.rpc('admin_ai_item_detail', params: {'p_item': itemId}) as Map),
  );

  @override
  Future<List<AiItem>> aiItems({List<String> statuses = const []}) async {
    var q = _db.from('ai_items').select();
    if (statuses.isNotEmpty) q = q.inFilter('status', statuses);
    return _rows(await q.order('created_at', ascending: false).limit(100)).map(AiItem.fromMap).toList();
  }

  @override
  Future<Listed<AiItem>> aiCardItems(AiCard card) async {
    // Las mismas condiciones que admin_ai_overview (20261022003600).
    final since = DateTime.now().toUtc().subtract(AiCard.window).toIso8601String();
    var q = _db.from('ai_items').select();
    q = switch (card) {
      AiCard.approval => q.eq('status', 'pending_approval'),
      AiCard.open => q.inFilter('status', ['open', 'more_info']),
      AiCard.critical => q.inFilter('status', AiCard.pendingStatuses).eq('severity', 'critical'),
      AiCard.high => q.inFilter('status', AiCard.pendingStatuses).eq('severity', 'high'),
      AiCard.aiRecommendations => q.eq('source', 'ai').inFilter('status', ['open', 'more_info']),
      AiCard.completed7d => q.eq('status', 'completed').gt('completed_at', since),
      AiCard.failed7d => q.eq('status', 'failed').gt('updated_at', since),
    };
    final r = await q.order('created_at', ascending: false).limit(100).count(CountOption.exact);
    return Listed([for (final m in r.data) AiItem.fromMap(Map<String, dynamic>.from(m))], r.count);
  }

  @override
  Future<AiRuns> aiRuns({required String status, Duration window = const Duration(hours: 24)}) async {
    final to = DateTime.now().toUtc();
    final from = to.subtract(window);
    final r = await _db
        .from('ai_agent_runs')
        .select()
        .eq('status', status)
        .gt('started_at', from.toIso8601String())
        .order('started_at', ascending: false)
        .limit(AiRuns.limit)
        .count(CountOption.exact);
    final paid = await _db
        .from('ai_agent_runs')
        .select('id')
        .eq('status', status)
        .gt('started_at', from.toIso8601String())
        .not('model', 'is', null)
        .limit(1)
        .count(CountOption.exact);
    return AiRuns(
      items: [for (final m in r.data) AiRun.fromMap(Map<String, dynamic>.from(m))],
      total: r.count,
      withAiModel: paid.count,
      from: from,
      to: to,
    );
  }

  @override
  Future<void> decideAiItem(int itemId, AiDecision decision, {String? note, String? authMethod}) => _db.rpc(
    'admin_decide_ai_item',
    params: {'p_item': itemId, 'p_decision': decision.key, 'p_note': note, 'p_auth_method': authMethod},
  );

  @override
  Future<List<DailyReport>> dailyReports() async =>
      _rows(await _db.from('daily_reports').select().order('report_date', ascending: false).limit(30))
          .map(DailyReport.fromMap)
          .toList();

  @override
  Future<DailyReport> generateDailyReport() async {
    await _db.rpc('admin_generate_daily_report');
    return (await dailyReports()).first;
  }

  @override
  Future<AiCheckResult> runAllChecks() async =>
      AiCheckResult.fromMap(Map<String, dynamic>.from(await _db.rpc('admin_run_all_checks') as Map));

  // ---------------------------------------------------------------- Detalle del panel
  Map<String, dynamic> _obj(Object? v) => Map<String, dynamic>.from(v as Map);

  Listed<T> _listed<T>(Object? v, T Function(Map<String, dynamic>) f) {
    final m = _obj(v);
    final items = [for (final x in (m['items'] as List? ?? const [])) f(Map<String, dynamic>.from(x as Map))];
    return Listed(items, (m['total'] as num?)?.toInt() ?? items.length);
  }

  @override
  Future<DemandBookings?> demandBookings(DemandKind kind, String name, {String? department}) async {
    try {
      final v = await _db.rpc(
        'owner_demand_bookings',
        params: {'p_kind': kind.key, 'p_name': name, 'p_department': department},
      );
      return DemandBookings(_listed(v, OpsBooking.fromMap), professionals: (_obj(v)['professionals'] as num?)?.toInt());
    } on PostgrestException catch (e) {
      if (e.code != 'PGRST202') rethrow;
      return null;
    }
  }

  @override
  Future<Listed<OpsBooking>> opsBookings(BookingFilter filter, {String query = ''}) async => _listed(
    await _db.rpc('ops_bookings', params: {'p_filter': filter.key, 'p_query': query.trim().isEmpty ? null : query}),
    OpsBooking.fromMap,
  );

  @override
  Future<OpsBookingDetail> opsBookingDetail(String bookingId) async =>
      OpsBookingDetail.fromMap(_obj(await _db.rpc('ops_booking_detail', params: {'p_booking': bookingId})));

  @override
  Future<int> openBookingCase(String bookingId, String reason, {String category = 'routine'}) async => (await _db.rpc(
    'ops_open_booking_case',
    params: {'p_booking': bookingId, 'p_reason': reason, 'p_category': category},
  ) as num).toInt();

  @override
  Future<Listed<PersonRow>> adminPeople(PeopleFilter filter, {String query = ''}) async {
    try {
      return _listed(
        await _db.rpc('admin_people', params: {'p_filter': filter.key, 'p_query': query.trim().isEmpty ? null : query}),
        PersonRow.fromMap,
      );
    } on PostgrestException catch (e) {
      // Sin 0041, "Todos" sigue funcionando con la búsqueda de siempre.
      if (e.code != 'PGRST202' || filter != PeopleFilter.all) rethrow;
      final users = await adminUsers(query);
      return Listed([for (final u in users) PersonRow(user: u)], users.length);
    }
  }

  @override
  Future<Listed<RiskItem>> riskItems(RiskKind kind) async =>
      _listed(await _db.rpc('ops_risk_items', params: {'p_kind': kind.key}), RiskItem.fromMap);

  @override
  Future<WalletList> ownerWallets({String query = '', WalletSort sort = WalletSort.available}) async =>
      WalletList.fromMap(
        _obj(
          await _db.rpc('owner_wallets', params: {'p_query': query.trim().isEmpty ? null : query, 'p_sort': sort.key}),
        ),
      );

  // ---------------------------------------------------------------- Finanzas y Bancos
  @override
  Future<FinanceSummary> financeSummary({DateTime? month}) async => FinanceSummary.fromMap(
    Map<String, dynamic>.from(
      await _db.rpc(
        'owner_finance_summary',
        params: {'p_month': month == null ? null : _day(DateTime(month.year, month.month))},
      ) as Map,
    ),
  );

  @override
  Future<List<FinanceTransaction>> financeTransactions({
    String? kind,
    int? before,
    int limit = 50,
    String? professionalId,
  }) async => [
    for (final m in _rows(
      await _db.rpc(
        'owner_finance_transactions',
        params: {'p_kind': kind, 'p_before': before, 'p_limit': limit, 'p_professional': professionalId},
      ),
    ))
      FinanceTransaction.fromMap(m),
  ];

  @override
  Future<List<ReconcileTopup>> topupsForReconciliation(String bankStatus) async => [
    for (final m in _rows(await _db.rpc('owner_topups_reconciliation', params: {'p_bank_status': bankStatus})))
      ReconcileTopup.fromMap(m),
  ];

  @override
  Future<FinanceList<CommissionDebt>?> commissionDebts() async {
    try {
      final m = _obj(await _db.rpc('owner_commission_debts'));
      return FinanceList(
        [
          for (final r in (m['items'] as List? ?? const []))
            CommissionDebt.fromMap(Map<String, dynamic>.from(r as Map)),
        ],
        total: (m['total'] as num?)?.toInt() ?? 0,
        sumBs: (m['sum_bs'] as num?)?.toDouble() ?? 0,
      );
    } on PostgrestException catch (e) {
      if (e.code != 'PGRST202') rethrow;
      return null;
    }
  }

  @override
  Future<CommissionPreview?> commissionPreview(String bookingId) async {
    try {
      return CommissionPreview.fromMap(_obj(await _db.rpc('commission_preview', params: {'p_booking': bookingId})));
    } on PostgrestException catch (e) {
      if (e.code != 'PGRST202') rethrow;
      return null;
    }
  }

  @override
  Future<FinanceList<FinanceTransaction>> financeLedger({
    String? kind,
    DateTime? month,
    String query = '',
    String? professionalId,
  }) async {
    try {
      final m = _obj(
        await _db.rpc(
          'owner_finance_ledger',
          params: {
            'p_kind': kind,
            'p_month': month == null ? null : _day(DateTime(month.year, month.month)),
            'p_query': query,
            'p_professional': professionalId,
          },
        ),
      );
      return FinanceList(
        [for (final r in (m['items'] as List? ?? const [])) FinanceTransaction.fromMap(r as Map<String, dynamic>)],
        total: (m['total'] as num?)?.toInt() ?? 0,
        sumBs: (m['sum_bs'] as num?)?.toDouble() ?? 0,
      );
    } on PostgrestException catch (e) {
      // Sin 0042: los últimos 200 movimientos, filtrados aquí (lista parcial).
      if (e.code != 'PGRST202') rethrow;
      final rows = (await financeTransactions(kind: kind, limit: 200, professionalId: professionalId))
          .where((t) => month == null || (t.createdAt.year == month.year && t.createdAt.month == month.month))
          .where((t) => _matches(query, [t.professionalName, t.bookingCode, t.reference, t.note]))
          .toList();
      return FinanceList(
        rows,
        total: rows.length,
        sumBs: rows.fold(
          0.0,
          (s, t) => s + (t.entryType == 'commission_capture' ? t.platformRevenue : t.availableDelta),
        ),
        isPartial: true,
      );
    }
  }

  @override
  Future<FinanceList<ReconcileTopup>> financeTopups(TopupFilter filter, {DateTime? month, String query = ''}) async {
    try {
      final m = _obj(
        await _db.rpc(
          'owner_finance_topups',
          params: {
            'p_status': filter.key,
            'p_month': month == null ? null : _day(DateTime(month.year, month.month)),
            'p_query': query,
          },
        ),
      );
      return FinanceList(
        [for (final r in (m['items'] as List? ?? const [])) ReconcileTopup.fromMap(r as Map<String, dynamic>)],
        total: (m['total'] as num?)?.toInt() ?? 0,
        sumBs: (m['sum_bs'] as num?)?.toDouble() ?? 0,
      );
    } on PostgrestException catch (e) {
      if (e.code != 'PGRST202') rethrow;
      final rows = (await topupsForReconciliation(filter == TopupFilter.credited ? 'todas' : filter.key))
          .where(filter.matches)
          .where((t) {
            final at = t.isCredited ? (t.reviewedAt ?? t.createdAt) : t.createdAt;
            return month == null || (at.year == month.year && at.month == month.month);
          })
          .where((t) => _matches(query, [t.professionalName, t.reference, t.bankReference, '${t.id}']))
          .toList();
      return FinanceList(rows, total: rows.length, sumBs: rows.fold(0.0, (s, t) => s + t.amount), isPartial: true);
    }
  }

  static bool _matches(String query, List<String?> fields) {
    final q = query.trim().toLowerCase();
    return q.isEmpty || fields.whereType<String>().any((f) => f.toLowerCase().contains(q));
  }

  @override
  Future<void> reconcileTopup(
    int topupId,
    BankStatus status, {
    String? bankReference,
    int? accountId,
    required String authMethod,
  }) => _db.rpc(
    'owner_reconcile_topup',
    params: {
      'p_topup': topupId,
      'p_bank_status': status.key,
      'p_bank_reference': bankReference,
      'p_account': accountId,
      'p_auth_method': authMethod,
    },
  );

  @override
  Future<List<ReceivingAccount>> receivingAccounts() async => [
    for (final m in _rows(await _db.rpc('owner_receiving_accounts'))) ReceivingAccount.fromMap(m),
  ];

  @override
  Future<int> saveReceivingAccount(ReceivingAccountDraft d, {required String authMethod}) async {
    final id = await _db.rpc(
      'owner_save_receiving_account',
      params: {
        'p_id': d.id,
        'p_label': d.label,
        'p_account_type': d.type.key,
        'p_bank_name': d.bankName,
        'p_holder_name': d.holderName,
        'p_account_number': d.accountNumber,
        'p_currency': d.currency,
        'p_qr_path': d.qrPath,
        'p_notes': d.notes,
        'p_auth_method': authMethod,
      },
    );
    return (id as num).toInt();
  }

  @override
  Future<void> setReceivingAccount(
    int id, {
    required bool active,
    required bool verified,
    required String authMethod,
  }) => _db.rpc(
    'owner_set_receiving_account',
    params: {
      'p_id': id,
      'p_active': active,
      'p_verification': verified ? 'verificada' : 'sin_verificar',
      'p_auth_method': authMethod,
    },
  );

  @override
  Future<String> uploadReceivingQr(PhotoUpload image) async {
    final ext = image.contentType.split('/').last.replaceAll('jpeg', 'jpg');
    final path = '$_uid/cobro_${DateTime.now().millisecondsSinceEpoch}.$ext';
    await _db.storage
        .from('payment-qr')
        .uploadBinary(path, image.bytes, fileOptions: FileOptions(contentType: image.contentType, upsert: false));
    return path;
  }

  @override
  Future<String?> receivingQrUrl(String path) => _signed('payment-qr', path);

  @override
  Future<List<FinanceAuditEntry>> financeAudit({int limit = 100}) async => [
    for (final m in _rows(await _db.rpc('owner_finance_audit', params: {'p_limit': limit})))
      FinanceAuditEntry.fromMap(m),
  ];

  // ---------------------------------------------------------------- Publicidad
  String? _adImage(String? path) => (path == null || path.isEmpty) ? null : _db.storage.from('ads').getPublicUrl(path);

  @override
  Future<HomeAd?> homeAd(int cityId) async {
    final m = await _db.rpc('home_ad', params: {'p_city': cityId});
    if (m == null) return null;
    return HomeAd.fromMap(Map<String, dynamic>.from(m as Map), image: _adImage);
  }

  @override
  Future<String?> adClick(int id) async => await _db.rpc('ad_click', params: {'p_id': id}) as String?;

  @override
  Future<List<OwnerAd>> ownerAds() async => [
    for (final m in _rows(await _db.rpc('owner_ads'))) OwnerAd.fromMap(m, image: _adImage),
  ];

  @override
  Future<int> saveAd(AdDraft d) async => (await _db.rpc(
    'owner_save_ad',
    params: {
      'p_id': d.id,
      'p_advertiser': d.advertiser,
      'p_title': d.title,
      'p_body': d.body,
      'p_logo_path': d.logoPath,
      'p_image_path': d.imagePath,
      'p_link_url': d.linkUrl,
      'p_label': d.label,
      'p_city': d.cityId,
      'p_starts_at': d.startsAt?.toUtc().toIso8601String(),
      'p_ends_at': d.endsAt?.toUtc().toIso8601String(),
    },
  ) as num).toInt();

  @override
  Future<void> setAdStatus(int id, AdAction action) =>
      _db.rpc('owner_set_ad_status', params: {'p_id': id, 'p_action': action.key});

  @override
  Future<String> uploadAdImage(PhotoUpload image) async {
    final ext = image.contentType.split('/').last.replaceAll('jpeg', 'jpg');
    final path = '$_uid/anuncio_${DateTime.now().millisecondsSinceEpoch}.$ext';
    await _db.storage
        .from('ads')
        .uploadBinary(path, image.bytes, fileOptions: FileOptions(contentType: image.contentType, upsert: false));
    return path;
  }
}
