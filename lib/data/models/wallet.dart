double _d(Object? v) => v == null ? 0 : (v as num).toDouble();

class Wallet {
  const Wallet({
    required this.available,
    required this.reserved,
    this.commissionsCollected = 0,
    this.commissionPending = 0,
    this.extrasAwaitingFunds = 0,
  });

  final double available;
  final double reserved;

  /// Saldo total: lo disponible más lo reservado en trabajos acordados.
  double get total => available + reserved;

  /// Comisiones cobradas, según el libro de movimientos.
  final double commissionsCollected;

  /// Comisiones anteriores a 0062 que no se pudieron cobrar.
  final double commissionPending;

  /// Montos aparte aprobados que esperan saldo para su comisión.
  final int extrasAwaitingFunds;

  factory Wallet.fromMap(Map<String, dynamic> m) => Wallet(
    available: _d(m['available']),
    reserved: _d(m['reserved']),
    commissionsCollected: _d(m['commissions_collected']),
    commissionPending: _d(m['commission_pending']),
    extrasAwaitingFunds: (m['extras_awaiting_funds'] as num?)?.toInt() ?? 0,
  );
}

enum LedgerType {
  topup('topup', 'Recarga'),
  commissionReserve('commission_reserve', 'Comisión reservada'),
  commissionRelease('commission_release', 'Reserva liberada'),
  commissionCapture('commission_capture', 'Comisión cobrada'),
  adjustment('adjustment', 'Ajuste'),
  refund('refund', 'Devolución');

  const LedgerType(this.key, this.label);
  final String key;
  final String label;

  static LedgerType parse(String v) => LedgerType.values.firstWhere((t) => t.key == v, orElse: () => adjustment);
}

class LedgerEntry {
  const LedgerEntry({
    required this.id,
    required this.type,
    required this.availableDelta,
    required this.reservedDelta,
    required this.availableAfter,
    this.note,
    required this.createdAt,
  });

  final int id;
  final LedgerType type;
  final double availableDelta;
  final double reservedDelta;
  final double availableAfter;
  final String? note;
  final DateTime createdAt;

  factory LedgerEntry.fromMap(Map<String, dynamic> m) => LedgerEntry(
    id: (m['id'] as num).toInt(),
    type: LedgerType.parse(m['entry_type'] as String),
    availableDelta: _d(m['available_delta']),
    reservedDelta: _d(m['reserved_delta']),
    availableAfter: _d(m['available_after']),
    note: m['note'] as String?,
    createdAt: DateTime.parse(m['created_at'] as String),
  );
}

class TopupMethod {
  const TopupMethod({required this.id, required this.name, required this.instructions});

  final int id;
  final String name;
  final String instructions;

  factory TopupMethod.fromMap(Map<String, dynamic> m) =>
      TopupMethod(id: (m['id'] as num).toInt(), name: m['name'] as String, instructions: m['instructions'] as String);
}

enum TopupStatus {
  pending('pending', 'En revisión'),
  approved('approved', 'Acreditada'),
  rejected('rejected', 'Rechazada'),
  cancelled('cancelled', 'Cancelada');

  const TopupStatus(this.key, this.label);
  final String key;
  final String label;

  static TopupStatus parse(String v) => TopupStatus.values.firstWhere((s) => s.key == v, orElse: () => pending);
}

class TopupRequest {
  const TopupRequest({
    required this.id,
    required this.amount,
    required this.status,
    this.reference,
    this.reviewNote,
    required this.createdAt,
  });

  final int id;
  final double amount;
  final TopupStatus status;
  final String? reference;
  final String? reviewNote;
  final DateTime createdAt;

  factory TopupRequest.fromMap(Map<String, dynamic> m) => TopupRequest(
    id: (m['id'] as num).toInt(),
    amount: _d(m['amount']),
    status: TopupStatus.parse(m['status'] as String),
    reference: m['reference'] as String?,
    reviewNote: m['review_note'] as String?,
    createdAt: DateTime.parse(m['created_at'] as String),
  );
}

class ProDashboard {
  const ProDashboard({
    required this.isAvailable,
    required this.ratingAvg,
    required this.ratingCount,
    required this.completedJobs,
    required this.walletAvailable,
    required this.walletReserved,
    required this.incoming,
    required this.active,
    required this.upcoming,
    required this.earningsMonth,
  });

  final bool isAvailable;
  final double ratingAvg;
  final int ratingCount;
  final int completedJobs;
  final double walletAvailable;
  final double walletReserved;
  final int incoming;
  final int active;
  final int upcoming;
  final double earningsMonth;

  factory ProDashboard.fromMap(Map<String, dynamic> m) => ProDashboard(
    isAvailable: m['is_available'] as bool? ?? false,
    ratingAvg: _d(m['rating_avg']),
    ratingCount: (m['rating_count'] as num?)?.toInt() ?? 0,
    completedJobs: (m['completed_jobs'] as num?)?.toInt() ?? 0,
    walletAvailable: _d(m['wallet_available']),
    walletReserved: _d(m['wallet_reserved']),
    incoming: (m['incoming'] as num?)?.toInt() ?? 0,
    active: (m['active'] as num?)?.toInt() ?? 0,
    upcoming: (m['upcoming'] as num?)?.toInt() ?? 0,
    earningsMonth: _d(m['earnings_month']),
  );
}

/// Lo que verá el profesional antes de aceptar (commission_preview, 0043).
class CommissionPreview {
  const CommissionPreview({
    required this.hasRule,
    required this.expected,
    required this.reserve,
    required this.minBalance,
    this.ratePercent,
    this.fixedFee,
    this.available,
    this.pendingDebt = 0,
  });

  final bool hasRule;
  final double? ratePercent;
  final double? fixedFee;

  /// Comisión esperada con el precio que se conoce ahora.
  final double expected;

  /// Lo que se reserva al aceptar (la comisión completa o la reserva mínima).
  final double reserve;
  final double minBalance;
  final double? available;
  final double pendingDebt;

  /// Saldo que necesita para aceptar.
  double get needed => reserve > minBalance ? reserve : minBalance;

  bool get canAccept => pendingDebt <= 0 && (available ?? 0) >= needed;

  factory CommissionPreview.fromMap(Map<String, dynamic> m) {
    double? d(String k) => (m[k] as num?)?.toDouble();
    return CommissionPreview(
      hasRule: m['has_rule'] == true,
      ratePercent: d('rate_percent'),
      fixedFee: d('fixed_fee'),
      expected: d('expected') ?? 0,
      reserve: d('reserve') ?? 0,
      minBalance: d('min_balance') ?? 0,
      available: d('available'),
      pendingDebt: d('pending_debt') ?? 0,
    );
  }
}

/// Estado de una recarga por QR (0065), como lo devuelve el servidor.
enum QrRechargeStatus {
  pendingPayment('pending_payment', 'Pendiente de pago'),
  verifying('verifying', 'Pago en verificación'),
  credited('credited', 'Acreditada'),
  rejected('rejected', 'Rechazada'),
  expired('expired', 'Vencida'),
  reversed('reversed', 'Revertida');

  const QrRechargeStatus(this.key, this.label);
  final String key;
  final String label;

  bool get isFinal => this != pendingPayment && this != verifying;

  static QrRechargeStatus parse(String? v) =>
      QrRechargeStatus.values.firstWhere((s) => s.key == v, orElse: () => pendingPayment);
}

/// Una recarga por QR. El saldo se acredita solo con el aviso del proveedor
/// verificado en el servidor; la app solo muestra el estado.
class QrRecharge {
  const QrRecharge({
    required this.id,
    required this.reference,
    required this.amount,
    required this.status,
    required this.simulated,
    this.qrPayload,
    required this.createdAt,
    required this.expiresAt,
    this.paidAmount,
    this.creditedAmount,
    this.reviewReason,
    this.professionalName,
    this.reviewNote,
    this.reversalReason,
  });

  final String id;
  final String reference;
  final double amount;
  final QrRechargeStatus status;

  /// QR de desarrollo: no se puede pagar en ningún banco.
  final bool simulated;

  /// Contenido del QR mientras está pendiente de pago.
  final String? qrPayload;
  final DateTime createdAt;
  final DateTime expiresAt;
  final double? paidAmount;
  final double? creditedAmount;

  /// Por qué quedó en verificación: wrong_amount, wrong_currency o paid_after_expiry.
  final String? reviewReason;

  // Solo en la lista del Propietario.
  final String? professionalName;
  final String? reviewNote;
  final String? reversalReason;

  String? get reviewReasonLabel => switch (reviewReason) {
    'wrong_amount' => 'El monto pagado no coincide',
    'wrong_currency' => 'Se pagó en otra moneda',
    'paid_after_expiry' => 'Se pagó después de vencer',
    _ => null,
  };

  factory QrRecharge.fromMap(Map<String, dynamic> m) => QrRecharge(
    id: m['id'] as String,
    reference: m['reference'] as String,
    amount: _d(m['amount']),
    status: QrRechargeStatus.parse(m['status'] as String?),
    simulated: m['simulated'] as bool? ?? false,
    qrPayload: m['qr_payload'] as String?,
    createdAt: DateTime.parse(m['created_at'] as String),
    expiresAt: DateTime.parse(m['expires_at'] as String),
    paidAmount: m['paid_amount'] == null ? null : _d(m['paid_amount']),
    creditedAmount: m['credited_amount'] == null ? null : _d(m['credited_amount']),
    reviewReason: m['review_reason'] as String?,
    professionalName: m['professional'] as String?,
    reviewNote: m['review_note'] as String?,
    reversalReason: m['reversal_reason'] as String?,
  );
}

/// Cuenta oficial para la transferencia bancaria: solo las que el Propietario
/// cargó y verificó con su banco.
class RechargeBankAccount {
  const RechargeBankAccount({
    required this.id,
    required this.label,
    required this.bankName,
    required this.holderName,
    required this.accountType,
    this.accountNumber,
  });

  final int id;
  final String label;
  final String bankName;
  final String holderName;
  final String accountType;
  final String? accountNumber;

  String get accountTypeLabel => switch (accountType) {
    'caja_ahorro' => 'Caja de ahorro',
    'cuenta_corriente' => 'Cuenta corriente',
    _ => 'QR',
  };

  factory RechargeBankAccount.fromMap(Map<String, dynamic> m) => RechargeBankAccount(
    id: (m['id'] as num).toInt(),
    label: m['label'] as String,
    bankName: m['bank_name'] as String,
    holderName: m['holder_name'] as String,
    accountType: m['account_type'] as String,
    accountNumber: m['account_number'] as String?,
  );
}

/// Lista del Propietario: recargas por QR y cuántos avisos no encontraron recarga.
class QrRechargeReport {
  const QrRechargeReport({required this.items, required this.counts, required this.unmatchedEvents});

  final List<QrRecharge> items;
  final Map<QrRechargeStatus, int> counts;
  final int unmatchedEvents;

  factory QrRechargeReport.fromMap(Map<String, dynamic> m) => QrRechargeReport(
    items: [for (final i in (m['items'] as List? ?? const [])) QrRecharge.fromMap(i as Map<String, dynamic>)],
    counts: {
      for (final e in ((m['summary'] as Map<String, dynamic>?) ?? const {}).entries)
        QrRechargeStatus.parse(e.key): ((e.value as Map)['count'] as num).toInt(),
    },
    unmatchedEvents: (m['unmatched_events'] as num?)?.toInt() ?? 0,
  );
}
