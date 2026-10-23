// Finanzas y Bancos (solo el Propietario). Los números vienen de la base
// (owner_finance_summary y compañía); la app no calcula saldos ni inventa
// movimientos del banco.

double _d(Object? v) => v == null ? 0 : (v is num ? v.toDouble() : double.tryParse('$v') ?? 0);
int _i(Object? v) => v == null ? 0 : (v is num ? v.toInt() : int.tryParse('$v') ?? 0);
DateTime? _t(Object? v) => v == null ? null : DateTime.tryParse('$v');

/// Estado bancario de una recarga: si el dinero llegó a la cuenta de la
/// plataforma, según el Propietario con su extracto. Un comprobante subido no
/// lo prueba.
enum BankStatus {
  unverified('sin_verificar', 'Sin verificar'),
  reconciled('conciliada', 'Conciliada con el banco'),
  notFound('no_encontrada', 'No aparece en el banco');

  const BankStatus(this.key, this.label);
  final String key;
  final String label;

  static BankStatus parse(String? v) => values.firstWhere((s) => s.key == v, orElse: () => unverified);
}

class FinanceMonth {
  const FinanceMonth({required this.month, required this.walletFundsBs, required this.commissionBs});

  /// 'YYYY-MM'.
  final String month;
  final double walletFundsBs;
  final double commissionBs;

  factory FinanceMonth.fromMap(Map<String, dynamic> m) => FinanceMonth(
    month: m['month'] as String,
    walletFundsBs: _d(m['wallet_funds_bs']),
    commissionBs: _d(m['commission_bs']),
  );
}

class FinanceSummary {
  const FinanceSummary({
    required this.month,
    required this.timezone,
    required this.generatedAt,
    required this.commissionEarnedBs,
    required this.commissionsCount,
    required this.commissionRefundedBs,
    required this.walletFundsReceivedBs,
    required this.walletFundsReceivedCount,
    required this.walletFundsReconciledBs,
    required this.walletFundsUnverifiedBs,
    required this.walletFundsNotFoundBs,
    required this.manualAdjustmentsBs,
    required this.topupsPending,
    required this.topupsPendingBs,
    required this.topupsUnverifiedTotal,
    required this.topupsUnverifiedTotalBs,
    required this.walletsAvailableBs,
    required this.walletsReservedBs,
    required this.walletsCount,
    required this.receivingAccountsActive,
    required this.receivingAccountsVerified,
    required this.bankIntegration,
    required this.months,
  });

  /// 'YYYY-MM' del mes que resume (hora de Bolivia).
  final String month;
  final String timezone;
  final DateTime? generatedAt;

  /// Ingreso real de la plataforma: comisiones cobradas de las billeteras.
  final double commissionEarnedBs;
  final int commissionsCount;
  final double commissionRefundedBs;

  /// Recargas acreditadas: plata de los profesionales, no un ingreso.
  final double walletFundsReceivedBs;
  final int walletFundsReceivedCount;
  final double walletFundsReconciledBs;
  final double walletFundsUnverifiedBs;
  final double walletFundsNotFoundBs;
  final double manualAdjustmentsBs;

  final int topupsPending;
  final double topupsPendingBs;

  /// Todas las recargas acreditadas que nadie concilió todavía (todos los meses).
  final int topupsUnverifiedTotal;
  final double topupsUnverifiedTotalBs;

  final double walletsAvailableBs;
  final double walletsReservedBs;
  final int walletsCount;
  final int receivingAccountsActive;
  final int receivingAccountsVerified;

  /// 'pendiente_configuracion' mientras no haya conexión con un banco.
  final String bankIntegration;
  final List<FinanceMonth> months;

  bool get bankConnected => bankIntegration != 'pendiente_configuracion';

  factory FinanceSummary.fromMap(Map<String, dynamic> m) => FinanceSummary(
    month: m['month'] as String,
    timezone: m['timezone'] as String? ?? 'America/La_Paz',
    generatedAt: _t(m['generated_at']),
    commissionEarnedBs: _d(m['commission_earned_bs']),
    commissionsCount: _i(m['commissions_count']),
    commissionRefundedBs: _d(m['commission_refunded_bs']),
    walletFundsReceivedBs: _d(m['wallet_funds_received_bs']),
    walletFundsReceivedCount: _i(m['wallet_funds_received_count']),
    walletFundsReconciledBs: _d(m['wallet_funds_reconciled_bs']),
    walletFundsUnverifiedBs: _d(m['wallet_funds_unverified_bs']),
    walletFundsNotFoundBs: _d(m['wallet_funds_not_found_bs']),
    manualAdjustmentsBs: _d(m['manual_adjustments_bs']),
    topupsPending: _i(m['topups_pending']),
    topupsPendingBs: _d(m['topups_pending_bs']),
    topupsUnverifiedTotal: _i(m['topups_unverified_total']),
    topupsUnverifiedTotalBs: _d(m['topups_unverified_total_bs']),
    walletsAvailableBs: _d(m['wallets_available_bs']),
    walletsReservedBs: _d(m['wallets_reserved_bs']),
    walletsCount: _i(m['wallets_count']),
    receivingAccountsActive: _i(m['receiving_accounts_active']),
    receivingAccountsVerified: _i(m['receiving_accounts_verified']),
    bankIntegration: m['bank_integration'] as String? ?? 'pendiente_configuracion',
    months: [
      for (final x in (m['months'] as List?) ?? const []) FinanceMonth.fromMap(Map<String, dynamic>.from(x as Map)),
    ],
  );
}

/// Un movimiento del libro de las billeteras.
class FinanceTransaction {
  const FinanceTransaction({
    required this.id,
    required this.professionalId,
    this.professionalName,
    required this.entryType,
    required this.availableDelta,
    required this.reservedDelta,
    this.bookingCode,
    this.bookingId,
    this.bookingStatus,
    this.categoryName,
    this.topupId,
    this.topupBankStatus,
    this.reference,
    this.note,
    required this.createdAt,
  });

  final int id;
  final String professionalId;
  final String? professionalName;
  final String entryType;
  final double availableDelta;
  final double reservedDelta;
  final String? bookingCode;

  /// El pedido del movimiento (comisiones), para abrir su detalle.
  final String? bookingId;
  final String? bookingStatus;
  final String? categoryName;
  final int? topupId;
  final BankStatus? topupBankStatus;
  final String? reference;
  final String? note;
  final DateTime createdAt;

  /// Lo que la plataforma ganó con este movimiento (solo comisión cobrada).
  double get platformRevenue => entryType == 'commission_capture' ? -(availableDelta + reservedDelta) : 0;

  String get label => switch (entryType) {
    'topup' => 'Recarga acreditada',
    'commission_reserve' => 'Comisión reservada',
    'commission_release' => 'Reserva liberada',
    'commission_capture' => 'Comisión cobrada',
    'adjustment' => 'Ajuste manual',
    'refund' => 'Devolución',
    _ => entryType,
  };

  factory FinanceTransaction.fromMap(Map<String, dynamic> m) => FinanceTransaction(
    id: _i(m['id']),
    professionalId: m['professional_id'] as String,
    professionalName: m['professional_name'] as String?,
    entryType: m['entry_type'] as String,
    availableDelta: _d(m['available_delta']),
    reservedDelta: _d(m['reserved_delta']),
    bookingCode: m['booking_code'] as String?,
    bookingId: m['booking_id'] as String?,
    bookingStatus: m['booking_status'] as String?,
    categoryName: m['category_name'] as String?,
    topupId: m['topup_id'] == null ? null : _i(m['topup_id']),
    topupBankStatus: m['topup_bank_status'] == null ? null : BankStatus.parse(m['topup_bank_status'] as String),
    reference: m['reference'] as String?,
    note: m['note'] as String?,
    createdAt: _t(m['created_at']) ?? DateTime.now(),
  );
}

/// Una recarga, con su estado en la app y en el banco.
class ReconcileTopup {
  const ReconcileTopup({
    required this.id,
    required this.professionalId,
    this.professionalName,
    required this.amount,
    this.methodName,
    this.reference,
    required this.hasProof,
    required this.status,
    required this.bankStatus,
    this.bankReference,
    this.bankAccountId,
    this.bankAccountLabel,
    this.bankCheckedAt,
    this.reviewedAt,
    required this.createdAt,
  });

  final int id;
  final String professionalId;
  final String? professionalName;
  final double amount;
  final String? methodName;
  final String? reference;
  final bool hasProof;

  /// pending, approved, rejected o cancelled (en la app).
  final String status;
  final BankStatus bankStatus;
  final String? bankReference;
  final int? bankAccountId;
  final String? bankAccountLabel;
  final DateTime? bankCheckedAt;
  final DateTime? reviewedAt;
  final DateTime createdAt;

  bool get isCredited => status == 'approved';

  String get statusLabel => switch (status) {
    'pending' => 'Pendiente de revisión',
    'approved' => 'Acreditada en la billetera',
    'rejected' => 'Rechazada',
    'cancelled' => 'Cancelada',
    _ => status,
  };

  factory ReconcileTopup.fromMap(Map<String, dynamic> m) => ReconcileTopup(
    id: _i(m['id']),
    professionalId: m['professional_id'] as String,
    professionalName: m['professional_name'] as String?,
    amount: _d(m['amount']),
    methodName: m['method_name'] as String?,
    reference: m['reference'] as String?,
    hasProof: m['has_proof'] as bool? ?? false,
    status: m['status'] as String,
    bankStatus: BankStatus.parse(m['bank_status'] as String?),
    bankReference: m['bank_reference'] as String?,
    bankAccountId: m['bank_account_id'] == null ? null : _i(m['bank_account_id']),
    bankAccountLabel: m['bank_account_label'] as String?,
    bankCheckedAt: _t(m['bank_checked_at']),
    reviewedAt: _t(m['reviewed_at']),
    createdAt: _t(m['created_at']) ?? DateTime.now(),
  );
}

enum ReceivingAccountType {
  savings('caja_ahorro', 'Caja de ahorro'),
  checking('cuenta_corriente', 'Cuenta corriente'),
  qr('qr', 'Solo QR');

  const ReceivingAccountType(this.key, this.label);
  final String key;
  final String label;

  static ReceivingAccountType parse(String? v) => values.firstWhere((t) => t.key == v, orElse: () => savings);
}

/// Cuenta de la plataforma donde los profesionales depositan sus recargas.
/// Solo datos para recibir pagos: nunca contraseñas de banca por internet.
class ReceivingAccount {
  const ReceivingAccount({
    required this.id,
    required this.label,
    required this.type,
    required this.bankName,
    required this.holderName,
    this.accountNumber,
    this.accountMasked,
    this.currency = 'BOB',
    this.qrPath,
    this.notes,
    required this.verified,
    required this.isActive,
    this.updatedAt,
  });

  final int id;
  final String label;
  final ReceivingAccountType type;
  final String bankName;
  final String holderName;

  /// Completo solo para editarlo; en listas se muestra [accountMasked].
  final String? accountNumber;
  final String? accountMasked;
  final String currency;
  final String? qrPath;
  final String? notes;

  /// El Propietario confirmó con su banco que la cuenta recibe pagos.
  final bool verified;
  final bool isActive;
  final DateTime? updatedAt;

  factory ReceivingAccount.fromMap(Map<String, dynamic> m) => ReceivingAccount(
    id: _i(m['id']),
    label: m['label'] as String,
    type: ReceivingAccountType.parse(m['account_type'] as String?),
    bankName: m['bank_name'] as String,
    holderName: m['holder_name'] as String,
    accountNumber: m['account_number'] as String?,
    accountMasked: m['account_masked'] as String?,
    currency: m['currency'] as String? ?? 'BOB',
    qrPath: m['qr_path'] as String?,
    notes: m['notes'] as String?,
    verified: m['verification'] == 'verificada',
    isActive: m['is_active'] as bool? ?? true,
    updatedAt: _t(m['updated_at']),
  );
}

/// Lo que el Propietario escribe al crear o cambiar una cuenta de cobro.
class ReceivingAccountDraft {
  const ReceivingAccountDraft({
    this.id,
    required this.label,
    required this.type,
    required this.bankName,
    required this.holderName,
    this.accountNumber,
    this.currency = 'BOB',
    this.qrPath,
    this.notes,
  });

  final int? id;
  final String label;
  final ReceivingAccountType type;
  final String bankName;
  final String holderName;
  final String? accountNumber;
  final String currency;
  final String? qrPath;
  final String? notes;
}

/// Un cambio de dinero en la auditoría.
class FinanceAuditEntry {
  const FinanceAuditEntry({
    required this.id,
    required this.actorName,
    required this.action,
    this.targetTable,
    this.targetId,
    this.details = const {},
    required this.createdAt,
  });

  final int id;
  final String actorName;
  final String action;
  final String? targetTable;
  final String? targetId;
  final Map<String, dynamic> details;
  final DateTime createdAt;

  String get label => switch (action) {
    'finance.reconcile' => switch (details['to']) {
      'conciliada' => 'Concilió una recarga con el banco',
      'no_encontrada' => 'Marcó una recarga como no encontrada en el banco',
      _ => 'Volvió una recarga a "sin verificar"',
    },
    'finance.account_created' => 'Agregó una cuenta de cobro',
    'finance.account_updated' => 'Cambió los datos de una cuenta de cobro',
    'finance.account_status' => 'Cambió el estado de una cuenta de cobro',
    'topup.request' => 'Pidió una recarga (comprobante subido)',
    'topup.approve' => 'Aprobó una recarga (acreditada en la billetera)',
    'topup.reject' => 'Rechazó una recarga',
    'wallet.adjust' => 'Ajustó un saldo',
    _ when action.startsWith('commission') => 'Cambió una regla de comisión',
    _ => action,
  };

  factory FinanceAuditEntry.fromMap(Map<String, dynamic> m) => FinanceAuditEntry(
    id: _i(m['id']),
    actorName: m['actor_name'] as String? ?? 'Sistema',
    action: m['action'] as String,
    targetTable: m['target_table'] as String?,
    targetId: m['target_id'] as String?,
    details: Map<String, dynamic>.from((m['details'] as Map?) ?? const {}),
    createdAt: _t(m['created_at']) ?? DateTime.now(),
  );
}

/// Una lista de Finanzas con el total y la suma de TODAS las filas (la lista
/// puede traer solo las primeras). [isPartial]: el servidor todavía no tiene
/// 0042 y la lista se armó con los últimos movimientos.
class FinanceList<T> {
  const FinanceList(this.items, {required this.total, required this.sumBs, this.isPartial = false});

  final List<T> items;
  final int total;
  final double sumBs;
  final bool isPartial;

  bool get isTruncated => items.length < total;
}

/// Qué recargas mostrar (owner_finance_topups).
enum TopupFilter {
  credited('acreditadas', 'Acreditadas'),
  unverified('sin_verificar', 'Sin verificar'),
  reconciled('conciliada', 'Conciliadas'),
  notFound('no_encontrada', 'No aparecen'),
  pending('pendiente', 'Por revisar'),
  all('todas', 'Todas');

  const TopupFilter(this.key, this.label);
  final String key;
  final String label;

  static TopupFilter parse(String? v) => values.firstWhere((f) => f.key == v, orElse: () => unverified);

  bool matches(ReconcileTopup t) => switch (this) {
    all => true,
    pending => t.status == 'pending',
    credited => t.isCredited,
    _ => t.isCredited && t.bankStatus.key == key,
  };
}

/// Comisión que faltó cobrar al completar un trabajo (0043). Se cobra sola de
/// la próxima recarga del profesional; mientras tanto no acepta trabajos.
class CommissionDebt {
  const CommissionDebt({
    required this.bookingId,
    required this.bookingCode,
    required this.professionalId,
    required this.amount,
    this.professionalName,
    this.captured,
    this.completedAt,
  });

  final String bookingId;
  final String bookingCode;
  final String professionalId;
  final String? professionalName;
  final double amount;
  final double? captured;
  final DateTime? completedAt;

  factory CommissionDebt.fromMap(Map<String, dynamic> m) => CommissionDebt(
    bookingId: m['booking_id'] as String,
    bookingCode: m['booking_code'] as String,
    professionalId: m['professional_id'] as String,
    professionalName: m['professional_name'] as String?,
    amount: (m['amount'] as num).toDouble(),
    captured: (m['captured'] as num?)?.toDouble(),
    completedAt: m['completed_at'] == null ? null : DateTime.parse(m['completed_at'] as String).toLocal(),
  );
}
