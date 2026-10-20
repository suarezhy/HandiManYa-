import 'dart:async';
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart' hide AuthUser;

import '../../core/config/env.dart';
import '../models/booking.dart';
import '../models/catalog.dart';
import '../models/geo.dart';
import '../models/messaging.dart';
import '../models/professional.dart';
import '../models/user.dart';
import '../models/wallet.dart';
import '../repositories/repositories.dart';

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
        ProRepository {
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
  AuthUser? _map(User? u) =>
      u == null ? null : AuthUser(id: u.id, email: u.email ?? '', emailConfirmed: u.emailConfirmedAt != null);

  @override
  AuthUser? get currentUser => _map(_db.auth.currentUser);

  @override
  Stream<AuthUser?> authChanges() => _db.auth.onAuthStateChange.map((s) => _map(s.session?.user));

  @override
  Future<void> signUp({
    required String email,
    required String password,
    required String fullName,
    required String phone,
    required int cityId,
    required bool wantsToBeProfessional,
  }) async {
    await _db.auth.signUp(
      email: email.trim(),
      password: password,
      emailRedirectTo: Env.authRedirectUrl,
      data: {
        'full_name': fullName.trim(),
        'phone': phone,
        'city_id': '$cityId',
        'terms_accepted': 'true',
        'wants_professional': wantsToBeProfessional ? 'true' : 'false',
      },
    );
  }

  @override
  Future<void> verifyEmailCode({required String email, required String code}) =>
      _db.auth.verifyOTP(type: OtpType.signup, email: email.trim(), token: code.trim());

  @override
  Future<void> resendEmailCode(String email) => _db.auth.resend(type: OtpType.signup, email: email.trim());

  @override
  Future<void> signIn({required String email, required String password}) =>
      _db.auth.signInWithPassword(email: email.trim(), password: password);

  @override
  Future<void> sendPasswordReset(String email) =>
      _db.auth.resetPasswordForEmail(email.trim(), redirectTo: Env.authRedirectUrl);

  @override
  Future<void> verifyRecoveryCode({required String email, required String code}) =>
      _db.auth.verifyOTP(type: OtpType.recovery, email: email.trim(), token: code.trim());

  @override
  Future<void> updatePassword(String newPassword) => _db.auth.updateUser(UserAttributes(password: newPassword));

  @override
  Future<void> signOut() => _db.auth.signOut();

  // ---------------------------------------------------------------- Cuenta
  @override
  Future<UserProfile> myAccount() async {
    final m = Map<String, dynamic>.from(await _db.rpc('my_account') as Map);
    return UserProfile(
      id: m['id'] as String,
      email: m['email'] as String? ?? '',
      fullName: m['full_name'] as String? ?? '',
      phone: m['phone'] as String?,
      cityId: (m['city_id'] as num?)?.toInt(),
      activeRole: AppRole.parse(m['active_role'] as String?),
      roles: {for (final r in (m['roles'] as List? ?? const [])) AppRole.parse(r as String)},
      professionalStatus: VerificationStatus.parse(m['professional_status'] as String?),
      onboardingCompleted: m['onboarding_completed'] as bool? ?? false,
      deletionRequested: m['deletion_requested'] as bool? ?? false,
    );
  }

  @override
  Future<void> updateProfile({required String fullName, String? phone, int? cityId}) async {
    await _db.from('profiles').update({'full_name': fullName.trim(), 'phone': phone, 'city_id': cityId}).eq('id', _uid);
  }

  @override
  Future<void> setActiveRole(AppRole role) => _db.rpc('set_active_role', params: {'p_role': role.key});

  @override
  Future<void> completeOnboarding() => _db.rpc('complete_onboarding');

  @override
  Future<void> requestAccountDeletion() => _db.rpc('request_account_deletion');

  // ---------------------------------------------------------------- Catálogo
  @override
  Future<List<City>> cities() async =>
      _rows(await _db.from('cities').select('id, name, slug').eq('is_active', true).order('sort_order'))
          .map(City.fromMap)
          .toList();

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
        .select('id, slug, name, icon, description')
        .eq('is_active', true)
        .order('sort_order'),
  ).map(ServiceCategory.fromMap).toList();

  @override
  Future<List<Promotion>> promotions(int? cityId) async {
    final rows = _rows(await _db.from('promotions').select().order('sort_order'));
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
  @override
  Future<String> create(BookingDraft d) async {
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
      },
    ) as String;
  }

  @override
  Future<List<BookingSummary>> myBookings({required bool asProfessional}) async =>
      _rows(await _db.rpc('my_bookings', params: {'p_as': asProfessional ? 'professional' : 'customer'}))
          .map((m) => BookingSummary.fromMap(m, photo: _publicPhoto))
          .toList();

  @override
  Future<BookingDetail> detail(String bookingId) async {
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
  Future<void> accept(String bookingId, {required bool isOffer}) =>
      _db.rpc(isOffer ? 'claim_ya_request' : 'accept_booking', params: {'p_booking': bookingId});

  @override
  Future<void> decline(String bookingId, {required bool isOffer, String? reason}) => isOffer
      ? _db.rpc('decline_ya_offer', params: {'p_booking': bookingId})
      : _db.rpc('decline_booking', params: {'p_booking': bookingId, 'p_reason': reason});

  @override
  Future<void> sendQuote(String bookingId, double amount, String? note) =>
      _db.rpc('send_quote', params: {'p_booking': bookingId, 'p_amount': amount, 'p_note': note});

  @override
  Future<void> updateProgress(String bookingId, BookingStatus to, {double? finalAmount}) =>
      _db.rpc('update_job_progress', params: {'p_booking': bookingId, 'p_to': to.key, 'p_final_amount': finalAmount});

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
  Future<void> requestTopup({
    required double amount,
    required int methodId,
    String? reference,
    PhotoUpload? proof,
  }) async {
    String? proofPath;
    if (proof != null) {
      final ext = proof.contentType.split('/').last.replaceAll('jpeg', 'jpg');
      proofPath = '$_uid/recarga_${DateTime.now().millisecondsSinceEpoch}.$ext';
      await _db.storage
          .from('topup-proofs')
          .uploadBinary(proofPath, proof.bytes, fileOptions: FileOptions(contentType: proof.contentType));
    }
    await _db.rpc(
      'request_topup',
      params: {'p_amount': amount, 'p_method': methodId, 'p_reference': reference, 'p_proof_path': proofPath},
    );
  }

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
}
