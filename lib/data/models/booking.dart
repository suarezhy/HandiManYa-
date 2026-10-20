import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/theme/tokens.dart';

double? _dn(Object? v) => v == null ? null : (v as num).toDouble();
DateTime? _dt(Object? v) => v == null ? null : DateTime.parse(v as String);

enum BookingMode {
  now('now', 'Lo necesito ahora'),
  scheduled('scheduled', 'Programado');

  const BookingMode(this.key, this.label);
  final String key;
  final String label;

  static BookingMode parse(String? v) => v == 'scheduled' ? scheduled : now;
}

enum PaymentMethod {
  cash('cash', 'Efectivo', Icons.payments_outlined),
  qr('qr', 'Pago por QR', Icons.qr_code_2);

  const PaymentMethod(this.key, this.label, this.icon);
  final String key;
  final String label;
  final IconData icon;

  static PaymentMethod? parse(String? v) => v == null ? null : PaymentMethod.values.firstWhere((p) => p.key == v);
}

enum StatusTone { neutral, info, warning, success, danger, brand }

/// Estados de una solicitud. El identificador interno coincide con el enum
/// `booking_status` de la base de datos; la etiqueta es la que ve el usuario.
enum BookingStatus {
  draft('draft', 'Borrador', StatusTone.neutral),
  requested('requested', 'Solicitado', StatusTone.info),
  awaitingResponse('awaiting_response', 'Buscando profesional', StatusTone.brand),
  quoteSent('quote_sent', 'Cotización enviada', StatusTone.warning),
  awaitingConfirmation('awaiting_confirmation', 'Esperando confirmación', StatusTone.warning),
  confirmed('confirmed', 'Confirmado', StatusTone.success),
  onTheWay('on_the_way', 'En camino', StatusTone.brand),
  inProgress('in_progress', 'En progreso', StatusTone.brand),
  workFinished('work_finished', 'Trabajo terminado', StatusTone.warning),
  completed('completed', 'Completado', StatusTone.success),
  cancelled('cancelled', 'Cancelado', StatusTone.neutral),
  disputed('disputed', 'En disputa', StatusTone.danger);

  const BookingStatus(this.key, this.label, this.tone);
  final String key;
  final String label;
  final StatusTone tone;

  static BookingStatus parse(String? v) =>
      BookingStatus.values.firstWhere((s) => s.key == v, orElse: () => BookingStatus.draft);

  bool get isOpen => this == requested || this == awaitingResponse || this == quoteSent || this == awaitingConfirmation;
  bool get isActive => this == confirmed || this == onTheWay || this == inProgress || this == workFinished;
  bool get isClosed => this == completed || this == cancelled;
  bool get chatOpen => isActive || this == completed || this == disputed;

  /// Texto de ayuda que explica qué pasa ahora, para el cliente.
  String customerHint() => switch (this) {
    requested => 'Esperando que el profesional responda.',
    awaitingResponse => 'Estamos avisando a profesionales disponibles cerca de ti.',
    quoteSent => 'El profesional te envió una cotización. Revísala para continuar.',
    awaitingConfirmation => 'Falta tu confirmación.',
    confirmed => 'El profesional aceptó tu solicitud.',
    onTheWay => 'El profesional va en camino.',
    inProgress => 'El trabajo está en progreso.',
    workFinished => 'El profesional marcó el trabajo como terminado. Confírmalo o reporta un problema.',
    completed => 'Trabajo completado. ¡Gracias por usar HandiMan ¡Ya!!',
    cancelled => 'Esta solicitud fue cancelada.',
    disputed => 'Nuestro equipo está revisando este caso.',
    draft => '',
  };

  String professionalHint() => switch (this) {
    requested => 'Nueva solicitud. Acéptala, envía una cotización o recházala.',
    awaitingResponse => 'Pedido ¡Ya! cerca de ti. El primero que acepta se queda con el trabajo.',
    quoteSent => 'Esperando que el cliente acepte tu cotización.',
    confirmed => 'Trabajo confirmado. Avisa cuando vayas en camino.',
    onTheWay => 'Vas en camino. Marca "Empecé el trabajo" al llegar.',
    inProgress => 'Trabajo en progreso. Márcalo terminado al finalizar.',
    workFinished => 'Esperando que el cliente confirme.',
    completed => 'Trabajo completado.',
    cancelled => 'Esta solicitud fue cancelada.',
    disputed => 'Nuestro equipo está revisando este caso.',
    awaitingConfirmation || draft => '',
  };
}

extension StatusToneColors on StatusTone {
  Color get foreground => switch (this) {
    StatusTone.neutral => HyColors.textSecondary,
    StatusTone.info => HyColors.info,
    StatusTone.warning => HyColors.warning,
    StatusTone.success => HyColors.success,
    StatusTone.danger => HyColors.danger,
    StatusTone.brand => HyColors.primaryDark,
  };

  Color get background => switch (this) {
    StatusTone.neutral => HyColors.surfaceMuted,
    StatusTone.info => HyColors.infoSoft,
    StatusTone.warning => HyColors.warningSoft,
    StatusTone.success => HyColors.successSoft,
    StatusTone.danger => HyColors.dangerSoft,
    StatusTone.brand => HyColors.primarySoft,
  };
}

/// Fila de la lista "Mis solicitudes" / "Trabajos".
class BookingSummary {
  const BookingSummary({
    required this.id,
    required this.code,
    required this.status,
    required this.mode,
    required this.categoryId,
    required this.category,
    required this.city,
    this.zone,
    required this.description,
    this.scheduledStart,
    required this.createdAt,
    this.otherUserId,
    this.otherName,
    this.otherPhotoUrl,
    this.quoteAmount,
    this.finalAmount,
    this.hasReview = false,
    this.isOffer = false,
    this.distanceKm,
    this.problems = const [],
  });

  final String id;
  final String code;
  final BookingStatus status;
  final BookingMode mode;
  final int categoryId;
  final String category;
  final String city;
  final String? zone;
  final String description;
  final DateTime? scheduledStart;
  final DateTime createdAt;

  /// Lo que eligió el cliente en "¿Qué necesitas solucionar?".
  final List<String> problems;

  /// Distancia aproximada (km) del pedido a la base del profesional.
  final double? distanceKm;
  final String? otherUserId;
  final String? otherName;
  final String? otherPhotoUrl;
  final double? quoteAmount;
  final double? finalAmount;
  final bool hasReview;
  final bool isOffer;

  factory BookingSummary.fromMap(Map<String, dynamic> m, {String? Function(String?)? photo}) => BookingSummary(
    id: m['id'] as String,
    code: m['code'] as String,
    status: BookingStatus.parse(m['status'] as String?),
    mode: BookingMode.parse(m['mode'] as String?),
    categoryId: (m['category_id'] as num).toInt(),
    category: m['category'] as String,
    city: m['city'] as String,
    zone: m['zone'] as String?,
    description: m['description'] as String,
    scheduledStart: _dt(m['scheduled_start']),
    createdAt: DateTime.parse(m['created_at'] as String),
    otherUserId: m['other_user_id'] as String?,
    otherName: m['other_name'] as String?,
    otherPhotoUrl: photo?.call(m['other_photo_path'] as String?),
    quoteAmount: _dn(m['quote_amount']),
    finalAmount: _dn(m['final_amount']),
    hasReview: m['has_review'] as bool? ?? false,
    isOffer: m['is_offer'] as bool? ?? false,
    distanceKm: _dn(m['distance_km']),
    problems: [for (final p in (m['problems'] as List? ?? const [])) p as String],
  );
}

class BookingEvent {
  const BookingEvent({required this.status, this.note, required this.at});

  final BookingStatus status;
  final String? note;
  final DateTime at;

  factory BookingEvent.fromMap(Map<String, dynamic> m) => BookingEvent(
    status: BookingStatus.parse(m['status'] as String?),
    note: m['note'] as String?,
    at: DateTime.parse(m['at'] as String),
  );
}

class BookingAddress {
  const BookingAddress({required this.line, this.reference, this.latitude, this.longitude});

  final String line;
  final String? reference;
  final double? latitude;
  final double? longitude;

  /// Enlace para abrir la ruta en Google Maps (o el navegador).
  Uri get directionsUrl => latitude != null && longitude != null
      ? Uri.https('www.google.com', '/maps/dir/', {'api': '1', 'destination': '$latitude,$longitude'})
      : Uri.https('www.google.com', '/maps/search/', {'api': '1', 'query': line});
}

/// Foto ya guardada: URL firmada (Supabase) o bytes (modo demostración).
class BookingPhoto {
  const BookingPhoto({this.url, this.bytes, this.kind = 'problem'});

  final String? url;
  final Uint8List? bytes;
  final String kind;
}

/// Foto elegida en el teléfono, lista para subir.
class PhotoUpload {
  const PhotoUpload({required this.bytes, required this.fileName});

  final Uint8List bytes;
  final String fileName;

  String get contentType => switch (fileName.split('.').last.toLowerCase()) {
    'png' => 'image/png',
    'webp' => 'image/webp',
    _ => 'image/jpeg',
  };
}

class BookingProfessional {
  const BookingProfessional({
    required this.id,
    required this.displayName,
    this.photoUrl,
    this.ratingAvg = 0,
    this.ratingCount = 0,
    this.isVerified = false,
  });

  final String id;
  final String displayName;
  final String? photoUrl;
  final double ratingAvg;
  final int ratingCount;
  final bool isVerified;
}

class BookingDetail {
  const BookingDetail({
    required this.id,
    required this.code,
    required this.status,
    required this.mode,
    required this.categoryId,
    required this.category,
    required this.city,
    this.zone,
    required this.description,
    this.scheduledStart,
    this.responseDeadline,
    this.quoteAmount,
    this.quoteNote,
    this.finalAmount,
    this.paymentMethod,
    this.customerPaidAck = false,
    this.professionalPaidAck = false,
    required this.createdAt,
    this.cancelReason,
    required this.viewerIsCustomer,
    this.isOffer = false,
    required this.customerId,
    required this.customerFirstName,
    this.professional,
    this.address,
    this.conversationId,
    this.hasReview = false,
    this.offersSent,
    this.events = const [],
    this.distanceKm,
    this.photoPaths = const [],
    this.photos = const [],
    this.problems = const [],
    this.safetyNote,
  });

  final String id;
  final String code;
  final BookingStatus status;
  final BookingMode mode;
  final int categoryId;
  final String category;
  final String city;
  final String? zone;
  final String description;
  final DateTime? scheduledStart;
  final DateTime? responseDeadline;
  final double? quoteAmount;
  final String? quoteNote;
  final double? finalAmount;
  final PaymentMethod? paymentMethod;
  final bool customerPaidAck;
  final bool professionalPaidAck;
  final DateTime createdAt;
  final String? cancelReason;
  final bool viewerIsCustomer;
  final bool isOffer;
  final String customerId;
  final String customerFirstName;
  final BookingProfessional? professional;
  final BookingAddress? address;
  final String? conversationId;
  final bool hasReview;
  final int? offersSent;
  final List<BookingEvent> events;
  final double? distanceKm;

  /// Rutas en el almacenamiento; [photos] trae las fotos listas para mostrar.
  final List<String> photoPaths;
  final List<BookingPhoto> photos;

  /// Lo que eligió el cliente en "¿Qué necesitas solucionar?".
  final List<String> problems;

  /// Regla de seguridad de la categoría (servicios sensibles).
  final String? safetyNote;

  String get areaLabel => zone == null ? city : '$zone, ${city.replaceAll(' de la Sierra', '')}';

  factory BookingDetail.fromMap(
    Map<String, dynamic> m, {
    String? Function(String?)? photo,
    List<BookingPhoto> photos = const [],
  }) {
    final pro = m['professional'] as Map<String, dynamic>?;
    final addr = m['address'] as Map<String, dynamic>?;
    return BookingDetail(
      id: m['id'] as String,
      code: m['code'] as String,
      status: BookingStatus.parse(m['status'] as String?),
      mode: BookingMode.parse(m['mode'] as String?),
      categoryId: (m['category_id'] as num).toInt(),
      category: m['category'] as String,
      city: m['city'] as String,
      zone: m['zone'] as String?,
      description: m['description'] as String,
      scheduledStart: _dt(m['scheduled_start']),
      responseDeadline: _dt(m['response_deadline']),
      quoteAmount: _dn(m['quote_amount']),
      quoteNote: m['quote_note'] as String?,
      finalAmount: _dn(m['final_amount']),
      paymentMethod: PaymentMethod.parse(m['payment_method'] as String?),
      customerPaidAck: m['customer_paid_ack'] as bool? ?? false,
      professionalPaidAck: m['professional_paid_ack'] as bool? ?? false,
      createdAt: DateTime.parse(m['created_at'] as String),
      cancelReason: m['cancel_reason'] as String?,
      viewerIsCustomer: m['viewer_role'] == 'customer',
      isOffer: m['is_offer'] as bool? ?? false,
      customerId: m['customer_id'] as String,
      customerFirstName: m['customer_first_name'] as String? ?? 'Cliente',
      professional: pro == null
          ? null
          : BookingProfessional(
              id: pro['id'] as String,
              displayName: pro['display_name'] as String,
              photoUrl: photo?.call(pro['photo_path'] as String?),
              ratingAvg: _dn(pro['rating_avg']) ?? 0,
              ratingCount: (pro['rating_count'] as num?)?.toInt() ?? 0,
              isVerified: pro['is_verified'] as bool? ?? false,
            ),
      address: addr == null
          ? null
          : BookingAddress(
              line: addr['line'] as String,
              reference: addr['reference'] as String?,
              latitude: _dn(addr['latitude']),
              longitude: _dn(addr['longitude']),
            ),
      conversationId: m['conversation_id'] as String?,
      hasReview: m['has_review'] as bool? ?? false,
      offersSent: (m['offers_sent'] as num?)?.toInt(),
      events: [
        for (final e in (m['events'] as List? ?? const [])) BookingEvent.fromMap(Map<String, dynamic>.from(e as Map)),
      ],
      distanceKm: _dn(m['distance_km']),
      photoPaths: [for (final p in (m['photos'] as List? ?? const [])) (p as Map)['path'] as String],
      photos: photos,
      problems: [for (final p in (m['problems'] as List? ?? const [])) p as String],
      safetyNote: m['safety_note'] as String?,
    );
  }
}

/// Lo que el cliente llena para pedir un servicio.
class BookingDraft {
  const BookingDraft({
    required this.categoryId,
    required this.cityId,
    required this.mode,
    required this.description,
    required this.address,
    this.addressReference,
    this.zoneId,
    this.professionalId,
    this.scheduledStart,
    this.durationMinutes = 120,
    this.paymentMethod,
    this.latitude,
    this.longitude,
    this.problemIds = const [],
    this.otherText,
  });

  final int categoryId;
  final int cityId;
  final BookingMode mode;
  final String description;
  final String address;
  final String? addressReference;
  final int? zoneId;

  /// Vacío en un pedido ¡Ya! (se envía a todos los disponibles).
  final String? professionalId;
  final DateTime? scheduledStart;
  final int durationMinutes;
  final PaymentMethod? paymentMethod;

  /// Punto exacto (GPS). Solo lo ve el profesional asignado.
  final double? latitude;
  final double? longitude;

  /// Opciones elegidas en "¿Qué necesitas solucionar?" y el texto de "Otro".
  final List<int> problemIds;
  final String? otherText;

  bool get isYa => mode == BookingMode.now && professionalId == null;

  /// La misma solicitud dirigida a un profesional elegido, para otro momento.
  BookingDraft scheduledWith({required String professionalId, required DateTime start, required int durationMinutes}) =>
      BookingDraft(
        categoryId: categoryId,
        cityId: cityId,
        mode: BookingMode.scheduled,
        description: description,
        address: address,
        addressReference: addressReference,
        zoneId: zoneId,
        professionalId: professionalId,
        scheduledStart: start,
        durationMinutes: durationMinutes,
        paymentMethod: paymentMethod,
        latitude: latitude,
        longitude: longitude,
        problemIds: problemIds,
        otherText: otherText,
      );
}

/// Código de llegada: el profesional marca "He llegado" y el cliente escribe
/// el código que le dicta. Recién con la llegada verificada empieza el trabajo.
enum ArrivalStage {
  /// Todavía no marcó "He llegado".
  none('none'),

  /// Marcó "He llegado", pero no hay un código vigente (venció o se bloqueó).
  arrived('arrived'),
  waitingPin('waiting_pin'),
  verified('verified');

  const ArrivalStage(this.key);
  final String key;

  static ArrivalStage fromKey(String? k) => values.firstWhere((s) => s.key == k, orElse: () => ArrivalStage.none);
}

class BookingArrival {
  const BookingArrival({
    this.stage = ArrivalStage.none,
    this.arrivedAt,
    this.pinExpiresAt,
    this.attemptsLeft,
    this.pinsLeft = 3,
    this.verifiedAt,
    this.byTeam = false,
    this.delayMinutes,
  });

  final ArrivalStage stage;
  final DateTime? arrivedAt;
  final DateTime? pinExpiresAt;
  final int? attemptsLeft;
  final int pinsLeft;
  final DateTime? verifiedAt;

  /// Verificada por el equipo (excepción con motivo), no con el código.
  final bool byTeam;

  /// Minutos de atraso respecto de la hora acordada (solo programados).
  final int? delayMinutes;

  bool get verified => stage == ArrivalStage.verified;

  factory BookingArrival.fromMap(Map<String, dynamic> m) => BookingArrival(
    stage: ArrivalStage.fromKey(m['state'] as String?),
    arrivedAt: _dt(m['arrived_at']),
    pinExpiresAt: _dt(m['pin_expires_at']),
    attemptsLeft: (m['attempts_left'] as num?)?.toInt(),
    pinsLeft: (m['pins_left'] as num?)?.toInt() ?? 3,
    verifiedAt: _dt(m['verified_at']),
    byTeam: m['method'] == 'admin',
    delayMinutes: (m['delay_minutes'] as num?)?.toInt(),
  );
}

/// El código que ve solo el profesional, una vez.
class ArrivalPin {
  const ArrivalPin({required this.pin, required this.expiresAt, required this.pinsLeft});

  final String pin;
  final DateTime expiresAt;
  final int pinsLeft;

  factory ArrivalPin.fromMap(Map<String, dynamic> m) => ArrivalPin(
    pin: m['pin'] as String,
    expiresAt: DateTime.parse(m['expires_at'] as String),
    pinsLeft: (m['pins_left'] as num?)?.toInt() ?? 0,
  );
}

enum ArrivalCheckResult { verified, wrong, locked, expired }

class ArrivalCheck {
  const ArrivalCheck(this.result, {this.attemptsLeft});

  final ArrivalCheckResult result;
  final int? attemptsLeft;

  factory ArrivalCheck.fromMap(Map<String, dynamic> m) => ArrivalCheck(
    m['ok'] == true
        ? ArrivalCheckResult.verified
        : switch (m['reason']) {
            'locked' => ArrivalCheckResult.locked,
            'expired' => ArrivalCheckResult.expired,
            _ => ArrivalCheckResult.wrong,
          },
    attemptsLeft: (m['attempts_left'] as num?)?.toInt(),
  );
}

/// Ubicación en vivo del profesional mientras va en camino. Solo el último punto.
class TripLocation {
  const TripLocation({
    required this.live,
    this.latitude,
    this.longitude,
    this.updatedAt,
    this.stale = false,
    this.distanceKm,
    this.etaMinutes,
  });

  /// El pedido está en camino y la llegada todavía no se verificó.
  final bool live;
  final double? latitude;
  final double? longitude;
  final DateTime? updatedAt;

  /// Hace más de 2 minutos que no llega una posición (mala señal, app cerrada).
  final bool stale;
  final double? distanceKm;
  final int? etaMinutes;

  bool get hasPoint => latitude != null && longitude != null;

  factory TripLocation.fromMap(Map<String, dynamic> m) => TripLocation(
    live: m['live'] == true,
    latitude: (m['latitude'] as num?)?.toDouble(),
    longitude: (m['longitude'] as num?)?.toDouble(),
    updatedAt: _dt(m['updated_at']),
    stale: m['stale'] == true,
    distanceKm: (m['distance_km'] as num?)?.toDouble(),
    etaMinutes: (m['eta_minutes'] as num?)?.toInt(),
  );
}

/// Enlace de viaje compartido con un contacto de confianza.
class TripShare {
  const TripShare({
    required this.id,
    this.contactName,
    required this.createdAt,
    required this.expiresAt,
    this.viewedAt,
  });

  final int id;
  final String? contactName;
  final DateTime createdAt;
  final DateTime expiresAt;
  final DateTime? viewedAt;

  factory TripShare.fromMap(Map<String, dynamic> m) => TripShare(
    id: (m['id'] as num).toInt(),
    contactName: m['contact_name'] as String?,
    createdAt: DateTime.parse(m['created_at'] as String),
    expiresAt: DateTime.parse(m['expires_at'] as String),
    viewedAt: _dt(m['last_viewed_at']),
  );
}

/// Lo que ve el contacto de confianza con el enlace. Nunca la dirección ni teléfonos.
class SharedTrip {
  const SharedTrip({
    required this.code,
    required this.status,
    required this.customerFirstName,
    required this.professionalName,
    required this.professionalVerified,
    required this.category,
    this.arrivalVerifiedAt,
    this.trip,
  });

  final String code;
  final BookingStatus status;
  final String customerFirstName;
  final String professionalName;
  final bool professionalVerified;
  final String category;
  final DateTime? arrivalVerifiedAt;
  final TripLocation? trip;

  factory SharedTrip.fromMap(Map<String, dynamic> m) => SharedTrip(
    code: m['code'] as String,
    status: BookingStatus.parse(m['status'] as String?),
    customerFirstName: (m['customer_first_name'] as String?) ?? '',
    professionalName: (m['professional_name'] as String?) ?? '',
    professionalVerified: m['professional_verified'] == true,
    category: (m['category'] as String?) ?? '',
    arrivalVerifiedAt: _dt(m['arrival_verified_at']),
    trip: m['trip'] == null
        ? null
        : TripLocation.fromMap({...Map<String, dynamic>.from(m['trip'] as Map), 'live': true}),
  );
}
