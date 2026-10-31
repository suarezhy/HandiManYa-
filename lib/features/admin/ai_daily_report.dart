import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/config/country.dart';
import '../../core/theme/tokens.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/buttons.dart';
import '../../core/widgets/common.dart';
import '../../data/models/ai_control.dart';
import '../../data/models/booking.dart';
import '../../data/providers.dart';
import 'ai_control_center_page.dart' show dailyReportsProvider;

/// Hora de Miami (America/New_York) sin una base de zonas horarias: horario
/// de verano de EE. UU., del segundo domingo de marzo al primer domingo de
/// noviembre, a las 2:00 locales.
DateTime miamiTime(DateTime instant) {
  final utc = instant.toUtc();
  DateTime nthSunday(int year, int month, int n) {
    final first = DateTime.utc(year, month);
    final offset = (DateTime.sunday - first.weekday) % 7;
    return DateTime.utc(year, month, 1 + offset + 7 * (n - 1));
  }

  final start = nthSunday(utc.year, 3, 2).add(const Duration(hours: 7)); // 2:00 EST = 7:00 UTC
  final end = nthSunday(utc.year, 11, 1).add(const Duration(hours: 6)); // 2:00 EDT = 6:00 UTC
  final dst = !utc.isBefore(start) && utc.isBefore(end);
  final local = utc.subtract(Duration(hours: dst ? 4 : 5));
  // Mismos números, sin zona: para mostrar.
  return DateTime(local.year, local.month, local.day, local.hour, local.minute);
}

/// El reporte más nuevo que debería existir: el de ayer (hora de Miami), que
/// se genera a las 6:00. Antes de las 7:00 todavía vale el de anteayer.
DateTime expectedReportDate(DateTime now) {
  final m = miamiTime(now);
  final today = DateTime(m.year, m.month, m.day);
  return today.subtract(Duration(days: m.hour >= 7 ? 1 : 2));
}

String _longDate(DateTime d) {
  final s = DateFormat("EEEE d 'de' MMMM 'de' y", 'es').format(d);
  return s[0].toUpperCase() + s.substring(1);
}

/// Reportes guardados antes de 0040 tenían las prioridades y "lo que no se
/// mide" en inglés: se muestran en español.
String reportTextEs(String t) {
  final rules = <RegExp, String Function(Match)>{
    RegExp(r'^Resolve (\d+) critical alert\(s\) in Centro de Control IA\.$'): (m) =>
        'Resolver ${m[1]} alerta(s) crítica(s) en el Centro de Control IA.',
    RegExp(r'^Review (\d+) open security or fraud alert\(s\)\.$'): (m) =>
        'Revisar ${m[1]} alerta(s) abierta(s) de seguridad o fraude.',
    RegExp(r'^Resolve (\d+) open dispute\(s\)\.$'): (m) => 'Resolver ${m[1]} disputa(s) abierta(s).',
    RegExp(r'^Verify (\d+) pending recharge\(s\)(?: \(Bs ([\d.,]+)\))?\.$'): (m) =>
        'Verificar ${m[1]} recarga(s) pendiente(s)${m[2] == null ? '' : ' (Bs ${m[2]})'}.',
    RegExp(r'^Review (\d+) professional application\(s\)\.$'): (m) =>
        'Revisar ${m[1]} postulación(es) de profesionales.',
    RegExp(r'^Decide (\d+) item\(s\) waiting for your approval\.$'): (m) =>
        'Decidir ${m[1]} pedido(s) que esperan tu aprobación.',
    RegExp(r'^Decide the items waiting for your approval\.$'): (_) => 'Decidir los pedidos que esperan tu aprobación.',
    RegExp(r'^Answer (\d+) open complaint\(s\) or ticket\(s\)\.$'): (m) =>
        'Responder ${m[1]} reclamo(s) o consulta(s) abierta(s).',
    RegExp(r'^Follow up (\d+) booking\(s\) still waiting for a response\.$'): (m) =>
        'Dar seguimiento a ${m[1]} pedido(s) que esperan respuesta.',
    RegExp(r'^Operating expenses'): (_) => 'Gastos operativos: todavía no se registran',
    RegExp(r'^Punctuality'): (_) => 'Puntualidad: se mide con el código de llegada, pero aún no sale en este reporte',
    RegExp(r'^App crashes'): (_) => 'Cierres inesperados de la app: el reporte de fallas no está configurado',
    RegExp(r'^Supabase uptime'): (_) =>
        'Disponibilidad de Supabase y errores de la API: el monitoreo no está conectado',
    RegExp(r'^Demo mode'): (_) => 'Modo demostración: datos de ejemplo',
  };
  for (final r in rules.entries) {
    final m = r.key.firstMatch(t.trim());
    if (m != null) return r.value(m);
  }
  return t;
}

/// Una métrica del reporte: clave en el JSON y cómo se lee.
typedef _Metric = (String key, String label, {bool money, bool usd});

const _sections = <(String, IconData, List<_Metric>, List<_Metric>)>[
  (
    'Operaciones',
    Icons.handyman_outlined,
    [
      ('bookings_created', 'Pedidos nuevos', money: false, usd: false),
      ('bookings_completed', 'Servicios completados', money: false, usd: false),
      ('bookings_cancelled', 'Pedidos cancelados', money: false, usd: false),
      ('disputes_opened', 'Disputas nuevas', money: false, usd: false),
    ],
    [
      ('bookings_pending', 'Pedidos esperando respuesta', money: false, usd: false),
      ('bookings_in_progress', 'Trabajos en curso', money: false, usd: false),
      ('disputes_open', 'Disputas abiertas', money: false, usd: false),
    ],
  ),
  (
    'Finanzas',
    Icons.account_balance_outlined,
    [
      ('commission_revenue_bs', 'Comisiones cobradas', money: true, usd: false),
      ('commissions_captured', 'Trabajos con comisión cobrada', money: false, usd: false),
      ('recharges_requested', 'Recargas pedidas', money: false, usd: false),
      ('recharges_requested_bs', 'Monto de recargas pedidas', money: true, usd: false),
      ('recharges_approved', 'Recargas acreditadas', money: false, usd: false),
      ('recharges_approved_bs', 'Monto de recargas acreditadas', money: true, usd: false),
    ],
    [
      ('recharges_pending', 'Recargas por revisar', money: false, usd: false),
      ('recharges_pending_bs', 'Monto por revisar', money: true, usd: false),
    ],
  ),
  (
    'Seguridad',
    Icons.shield_outlined,
    [],
    [
      ('security_alerts_open', 'Alertas de seguridad o fraude abiertas', money: false, usd: false),
      ('alerts_critical', 'Alertas críticas', money: false, usd: false),
      ('alerts_open', 'Alertas abiertas', money: false, usd: false),
    ],
  ),
  (
    'Profesionales y clientes',
    Icons.groups_outlined,
    [
      ('new_customers', 'Cuentas nuevas', money: false, usd: false),
      ('new_applications', 'Postulaciones nuevas', money: false, usd: false),
      ('professionals_approved', 'Profesionales aprobados', money: false, usd: false),
      ('complaints', 'Reportes y consultas nuevas', money: false, usd: false),
      ('poor_reviews', 'Calificaciones de 1 o 2 estrellas', money: false, usd: false),
    ],
    [
      ('verifications_pending', 'Postulaciones por revisar', money: false, usd: false),
      ('complaints_open', 'Reportes y consultas abiertas', money: false, usd: false),
      ('quality_alerts_open', 'Alertas de calidad abiertas', money: false, usd: false),
    ],
  ),
  (
    'Rendimiento de IA',
    Icons.smart_toy_outlined,
    [],
    [
      ('decisions_pending', 'Pedidos que esperan tu decisión', money: false, usd: false),
      ('agent_runs_ok', 'Revisiones correctas del día', money: false, usd: false),
      ('agent_runs_failed', 'Revisiones fallidas del día', money: false, usd: false),
      ('ai_cost_usd', 'Gasto de IA del día', money: false, usd: true),
      ('database_size_mb', 'Tamaño de la base (MB)', money: false, usd: false),
    ],
  ),
];

/// Reporte diario del dueño, en español. Solo datos reales: lo que no se
/// midió dice "Sin dato", nunca un cero inventado.
class DailyReportTab extends ConsumerWidget {
  const DailyReportTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reports = ref.watch(dailyReportsProvider);
    return RefreshIndicator(
      onRefresh: () => ref.refresh(dailyReportsProvider.future),
      child: ListView(
        padding: bottomSafePadding(context),
        children: [
          PageBody(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: HySpacing.sm),
                const Text(
                  'Se genera solo todos los días a las 6:00 (Hora de Miami) con el día anterior completo. '
                  'Solo datos reales de la base.',
                  style: TextStyle(color: HyColors.textSecondary),
                ),
                const SizedBox(height: HySpacing.sm),
                SecondaryButton(
                  label: 'Generar el de ayer ahora',
                  icon: Icons.summarize_outlined,
                  onPressed: () async {
                    final ok = await runGuarded(
                      context,
                      () => ref.read(backendProvider).generateDailyReport(),
                      success: 'Reporte de ayer generado con los datos de este momento.',
                    );
                    if (ok) ref.invalidate(dailyReportsProvider);
                  },
                ),
                const SizedBox(height: HySpacing.md),
                ...switch (reports) {
                  AsyncData(:final value) when value.isEmpty => [
                    const EmptyState(
                      icon: Icons.article_outlined,
                      title: 'Todavía no hay reportes',
                      message: 'El primero se genera a las 6:00 (Hora de Miami) o al tocar "Generar".',
                    ),
                  ],
                  AsyncData(:final value) => [DailyReportView(report: value.first, now: DateTime.now())],
                  AsyncError(:final error) => [
                    ErrorView(error: error, onRetry: () => ref.invalidate(dailyReportsProvider)),
                  ],
                  _ => [const LoadingView()],
                },
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class DailyReportView extends StatelessWidget {
  const DailyReportView({super.key, required this.report, required this.now});

  final DailyReport report;
  final DateTime now;

  String _tzLabel() =>
      (report.data['timezone_label'] as String?) ??
      switch (report.timezone) {
        'America/New_York' => 'Hora de Miami',
        final tz => Country.all.where((c) => c.timezone == tz).firstOrNull?.timezoneLabel ?? tz,
      };

  String _value(_Metric m, Object? v) {
    if (v is! num) return 'Sin dato';
    if (m.money) return Fmt.bs(v);
    if (m.usd) return 'US\$ ${v.toStringAsFixed(2)}';
    return NumberFormat.decimalPattern(kCountry.locale).format(v);
  }

  @override
  Widget build(BuildContext context) {
    final r = report;
    final day = DateTime(r.date.year, r.date.month, r.date.day);
    final expected = expectedReportDate(now);
    final stale = day.isBefore(expected);
    final miami = r.timezone == 'America/New_York';
    final generated = miami ? miamiTime(r.generatedAt) : r.generatedAt.toLocal();
    final snapshotRaw = DateTime.tryParse('${r.data['snapshot_at']}');
    final snapshot = snapshotRaw == null ? generated : (miami ? miamiTime(snapshotRaw) : snapshotRaw.toLocal());
    final tz = _tzLabel();
    const note = TextStyle(color: HyColors.textSecondary);

    Widget metricRow(_Metric m, Map<String, dynamic> data, {Map<String, dynamic>? previous}) {
      final prev = previous?[m.$1];
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: Text(m.$2)),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  _value(m, data[m.$1]),
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: data[m.$1] is num ? HyColors.text : HyColors.textMuted,
                  ),
                ),
                if (prev is num)
                  Text('antes: ${_value(m, prev)}', style: const TextStyle(color: HyColors.textMuted, fontSize: 12)),
              ],
            ),
          ],
        ),
      );
    }

    return Column(
      key: const Key('daily-report'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Reporte del ${_longDate(day)}',
          key: const Key('daily-report-date'),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        Text('Periodo: ese día completo, de 00:00 a 24:00 ($tz).', style: note),
        Text(
          'Generado: ${Fmt.dateTime(generated)} (${miami ? 'Hora de Miami' : 'hora de este teléfono'}).',
          key: const Key('daily-report-generated'),
          style: note,
        ),
        if (stale) ...[
          const SizedBox(height: HySpacing.sm),
          InfoBanner(
            key: const Key('daily-report-stale'),
            icon: Icons.history_toggle_off,
            tone: StatusTone.warning,
            text:
                'Este no es el reporte de ayer: es del ${_longDate(day)}. '
                'El del ${_longDate(expected)} no se generó todavía. Revisa que el reporte automático esté '
                'activado o toca "Generar el de ayer ahora".',
          ),
        ],
        const SizedBox(height: HySpacing.sm),
        AppCard(
          color: HyColors.primarySoft,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Prioridades del día', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
              if (r.priorities.isEmpty) const Text('Nada urgente.'),
              for (var i = 0; i < r.priorities.length; i++) Text('${i + 1}. ${reportTextEs(r.priorities[i])}'),
            ],
          ),
        ),
        for (final (title, icon, dayMetrics, nowMetrics) in _sections) ...[
          const SizedBox(height: HySpacing.sm),
          AppCard(
            key: Key('daily-report-$title'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(icon, color: HyColors.primaryDark),
                    const SizedBox(width: HySpacing.xs),
                    Expanded(
                      child: Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                    ),
                  ],
                ),
                if (dayMetrics.isNotEmpty) ...[
                  const SizedBox(height: HySpacing.xs),
                  Text(
                    '${stale ? 'Ese día' : 'Ayer'} (${DateFormat('d MMM', 'es').format(day)}), comparado con el día anterior',
                    style: const TextStyle(fontWeight: FontWeight.w700, color: HyColors.textSecondary),
                  ),
                  for (final m in dayMetrics) metricRow(m, r.today, previous: r.previousDay),
                ],
                const SizedBox(height: HySpacing.xs),
                Text(
                  'Estado actual (al ${Fmt.dateTime(snapshot)})',
                  style: const TextStyle(fontWeight: FontWeight.w700, color: HyColors.textSecondary),
                ),
                for (final m in nowMetrics) metricRow(m, r.current),
                if (title == 'Seguridad')
                  const Padding(
                    padding: EdgeInsets.only(top: 4),
                    child: Text(
                      'Los reportes de seguridad de los clientes van a Casos del equipo y no se cierran sin revisión.',
                      style: TextStyle(color: HyColors.textMuted, fontSize: 13),
                    ),
                  ),
              ],
            ),
          ),
        ],
        const SizedBox(height: HySpacing.sm),
        if (r.unavailable.isNotEmpty)
          AppCard(
            key: const Key('daily-report-pending'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Todavía no se mide', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                for (final u in r.unavailable) Text('• ${reportTextEs(u)}'),
              ],
            ),
          ),
      ],
    );
  }
}
