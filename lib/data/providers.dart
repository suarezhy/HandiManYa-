import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show Supabase;

import '../core/config/env.dart';
import 'demo/demo_backend.dart';
import 'models/booking.dart';
import 'models/catalog.dart';
import 'models/messaging.dart';
import 'models/professional.dart';
import 'models/user.dart';
import 'models/wallet.dart';
import 'repositories/repositories.dart';
import 'supabase/supabase_backend.dart';

/// Backend único que implementa todos los repositorios. En `main` se elige
/// Supabase o el modo demostración; en las pruebas se reemplaza.
abstract interface class AppBackend
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
        AiControlRepository,
        FinanceRepository {}

class _SupabaseAppBackend extends SupabaseBackend implements AppBackend {
  _SupabaseAppBackend(super.db);
}

class DemoAppBackend extends DemoBackend implements AppBackend {
  DemoAppBackend({super.simulateDelays, super.codeCooldown});
}

AppBackend createBackend() => Env.hasBackend ? _SupabaseAppBackend(Supabase.instance.client) : DemoAppBackend();

final backendProvider = Provider<AppBackend>((ref) => throw UnimplementedError('backendProvider sin configurar'));
final isDemoProvider = Provider<bool>((ref) => ref.watch(backendProvider) is DemoAppBackend);
final prefsProvider = Provider<SharedPreferences>((ref) => throw UnimplementedError('prefsProvider sin configurar'));

// ----------------------------------------------------------------- Sesión
final authUserProvider = StreamProvider<AuthUser?>((ref) async* {
  final backend = ref.watch(backendProvider);
  yield backend.currentUser;
  yield* backend.authChanges();
});

/// Cuenta del usuario (roles y estado vienen de la base de datos).
final accountProvider = FutureProvider<UserProfile?>((ref) async {
  final user = ref.watch(authUserProvider).value;
  if (user == null) return null;
  // Se recarga con los avisos en tiempo real (por ejemplo, cuando aprueban el perfil).
  ref.watch(bookingChangesProvider);
  return ref.watch(backendProvider).myAccount();
});

// ----------------------------------------------------------------- Preferencias locales
class OnboardingSeen extends Notifier<bool> {
  static const _key = 'onboarding_seen_v1';

  @override
  bool build() => ref.watch(prefsProvider).getBool(_key) ?? false;

  Future<void> markSeen() async {
    state = true;
    await ref.read(prefsProvider).setBool(_key, true);
  }
}

final onboardingSeenProvider = NotifierProvider<OnboardingSeen, bool>(OnboardingSeen.new);

/// Ciudad elegida en el encabezado. Empieza con la ciudad del perfil; si el
/// usuario la cambia, se recuerda en el dispositivo.
class SelectedCity extends Notifier<int?> {
  static const _key = 'selected_city_v1';

  @override
  int? build() {
    final saved = ref.watch(prefsProvider).getInt(_key);
    if (saved != null) return saved;
    return ref.watch(accountProvider).value?.cityId;
  }

  Future<void> select(int cityId) async {
    state = cityId;
    await ref.read(prefsProvider).setInt(_key, cityId);
  }
}

final selectedCityProvider = NotifierProvider<SelectedCity, int?>(SelectedCity.new);

/// Lo que la persona eligió en la pantalla de bienvenida ("Necesito un
/// servicio" o "Soy profesional"). Solo guía la interfaz; los permisos los
/// decide el servidor.
class EntryIntent extends Notifier<AppRole> {
  static const _key = 'entry_intent_v1';

  @override
  AppRole build() => AppRole.parse(ref.watch(prefsProvider).getString(_key));

  Future<void> set(AppRole role) async {
    state = role;
    await ref.read(prefsProvider).setString(_key, role.key);
  }
}

final entryIntentProvider = NotifierProvider<EntryIntent, AppRole>(EntryIntent.new);

// ----------------------------------------------------------------- Catálogo
final citiesProvider = FutureProvider<List<City>>((ref) => ref.watch(backendProvider).cities());
final categoriesProvider = FutureProvider<List<ServiceCategory>>((ref) => ref.watch(backendProvider).categories());
final problemsProvider = FutureProvider.family<List<ServiceProblem>, int>(
  (ref, categoryId) => ref.watch(backendProvider).problems(categoryId),
);
final zonesProvider = FutureProvider.family<List<Zone>, int>((ref, cityId) => ref.watch(backendProvider).zones(cityId));
final promotionsProvider = FutureProvider<List<Promotion>>(
  (ref) => ref.watch(backendProvider).promotions(ref.watch(selectedCityProvider)),
);

final currentCityProvider = Provider<City?>((ref) {
  final id = ref.watch(selectedCityProvider);
  final cities = ref.watch(citiesProvider).value ?? const [];
  if (cities.isEmpty) return null;
  return cities.firstWhere((c) => c.id == id, orElse: () => cities.first);
});

// ----------------------------------------------------------------- Profesionales
final searchResultsProvider = FutureProvider.autoDispose.family<List<ProfessionalSummary>, SearchFilters>(
  (ref, filters) => ref.watch(backendProvider).search(filters),
);

final nearbyProfessionalsProvider = FutureProvider.autoDispose<List<ProfessionalSummary>>((ref) {
  final city = ref.watch(currentCityProvider);
  return ref.watch(backendProvider).search(SearchFilters(cityId: city?.id, sort: SortOption.recommended));
});

final professionalDetailProvider = FutureProvider.autoDispose.family<ProfessionalDetail?, String>(
  (ref, id) => ref.watch(backendProvider).professionalDetail(id),
);

final professionalReviewsProvider = FutureProvider.autoDispose.family<List<Review>, String>(
  (ref, id) => ref.watch(backendProvider).reviews(id),
);

// ----------------------------------------------------------------- Tiempo real
/// Emite cada vez que cambia algo de las solicitudes del usuario. Las listas
/// lo escuchan para refrescarse solas.
final bookingChangesProvider = StreamProvider<int>((ref) {
  var tick = 0;
  return ref.watch(backendProvider).changes().map((_) => ++tick);
});

final myBookingsProvider = FutureProvider.autoDispose.family<List<BookingSummary>, bool>((ref, asProfessional) {
  ref.watch(bookingChangesProvider);
  return ref.watch(backendProvider).myBookings(asProfessional: asProfessional);
});

final bookingDetailProvider = FutureProvider.autoDispose.family<BookingDetail, String>((ref, id) {
  ref.watch(bookingChangesProvider);
  return ref.watch(backendProvider).detail(id);
});

final conversationsProvider = FutureProvider.autoDispose<List<Conversation>>((ref) {
  ref.watch(bookingChangesProvider);
  return ref.watch(backendProvider).conversations();
});

final unreadMessagesProvider = Provider.autoDispose<int>((ref) {
  final list = ref.watch(conversationsProvider).value ?? const [];
  return list.fold(0, (sum, c) => sum + c.unreadCount);
});

final messagesProvider = StreamProvider.autoDispose.family<List<ChatMessage>, String>(
  (ref, conversationId) => ref.watch(backendProvider).watchMessages(conversationId),
);

final notificationsProvider = FutureProvider.autoDispose<List<AppNotification>>((ref) {
  ref.watch(bookingChangesProvider);
  return ref.watch(backendProvider).list();
});

final unreadNotificationsProvider = StreamProvider.autoDispose<int>((ref) {
  if (ref.watch(authUserProvider).value == null) return Stream.value(0);
  return ref.watch(backendProvider).unreadCount();
});

// ----------------------------------------------------------------- Profesional
final proDashboardProvider = FutureProvider.autoDispose<ProDashboard>((ref) {
  ref.watch(bookingChangesProvider);
  return ref.watch(backendProvider).dashboard();
});

final applicationProvider = FutureProvider.autoDispose<ProfessionalApplication>((ref) {
  ref.watch(bookingChangesProvider);
  return ref.watch(backendProvider).application();
});

final walletProvider = FutureProvider.autoDispose<Wallet>((ref) {
  ref.watch(bookingChangesProvider);
  return ref.watch(backendProvider).wallet();
});

final ledgerProvider = FutureProvider.autoDispose<List<LedgerEntry>>((ref) {
  ref.watch(bookingChangesProvider);
  return ref.watch(backendProvider).ledger();
});

final topupMethodsProvider = FutureProvider.autoDispose<List<TopupMethod>>(
  (ref) => ref.watch(backendProvider).topupMethods(),
);

final topupsProvider = FutureProvider.autoDispose<List<TopupRequest>>((ref) => ref.watch(backendProvider).topups());

/// Para depurar en consola sin exponer datos sensibles.
void logDebug(String message) {
  if (kDebugMode) debugPrint('[HMY] $message');
}

/// Evita advertencias por futuros sin esperar en callbacks de UI.
void fireAndForget(Future<void> f) => unawaited(f);
