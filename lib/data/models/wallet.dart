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
