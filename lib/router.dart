import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'data/models/booking.dart';
import 'data/models/user.dart';
import 'data/providers.dart';
import 'features/auth/access_page.dart';
import 'features/auth/forgot_password_page.dart';
import 'features/auth/login_page.dart';
import 'features/auth/register_page.dart';
import 'features/auth/verify_email_page.dart';
import 'features/booking/booking_detail_page.dart';
import 'features/booking/my_requests_page.dart';
import 'features/booking/request_flow_page.dart';
import 'features/home/all_categories_page.dart';
import 'features/home/customer_home_page.dart';
import 'features/messages/chat_page.dart';
import 'features/messages/conversations_page.dart';
import 'features/notifications/notifications_page.dart';
import 'features/onboarding/onboarding_page.dart';
import 'features/pro_mode/application_page.dart';
import 'features/pro_mode/pro_home_page.dart';
import 'features/pro_mode/pro_jobs_page.dart';
import 'features/pro_mode/wallet_page.dart';
import 'features/professional/professional_profile_page.dart';
import 'features/profile/edit_profile_page.dart';
import 'features/profile/profile_page.dart';
import 'features/profile/support_page.dart';
import 'features/search/search_page.dart';
import 'features/shell/app_shell.dart';
import 'features/shell/splash_page.dart';

abstract final class Routes {
  static const splash = '/';
  static const onboarding = '/bienvenida';
  static const access = '/acceso';
  static const login = '/ingresar';
  static const register = '/registro';
  static const verify = '/verificar';
  static const forgot = '/recuperar';

  static const home = '/inicio';
  static const search = '/buscar';
  static const requests = '/solicitudes';
  static const messages = '/mensajes';
  static const profile = '/perfil';

  static const proHome = '/pro/inicio';
  static const proRequests = '/pro/solicitudes';
  static const proJobs = '/pro/trabajos';
  static const proMessages = '/pro/mensajes';
  static const proProfile = '/pro/perfil';

  static const ya = '/ya';
  static const categories = '/categorias';
  static const notifications = '/notificaciones';
  static const editProfile = '/perfil/editar';
  static const apply = '/postular';
  static const wallet = '/billetera';
  static const support = '/ayuda';

  static String professional(String id) => '/profesional/$id';
  static String requestPro(String id, BookingMode mode) => '/profesional/$id/solicitar?modo=${mode.key}';
  static String category(int id) => '/buscar?categoria=$id';
  static String booking(String id) => '/solicitud/$id';
  static String chat(String id) => '/chat/$id';

  static const publicRoutes = {onboarding, access, login, register, forgot};
}

/// Avisa a GoRouter cuando cambia la sesión, la cuenta o la bienvenida.
class _RouterRefresh extends ChangeNotifier {
  void ping() => notifyListeners();
}

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = _RouterRefresh();
  ref
    ..listen(authUserProvider, (_, _) => refresh.ping())
    ..listen(accountProvider, (_, _) => refresh.ping())
    ..listen(onboardingSeenProvider, (_, _) => refresh.ping())
    ..onDispose(refresh.dispose);

  String? redirect(BuildContext context, GoRouterState state) {
    final loc = state.matchedLocation;
    final onboardingSeen = ref.read(onboardingSeenProvider);
    final authAsync = ref.read(authUserProvider);
    final user = authAsync.value;

    if (!onboardingSeen) return loc == Routes.onboarding ? null : Routes.onboarding;
    if (authAsync.isLoading && !authAsync.hasValue) return loc == Routes.splash ? null : Routes.splash;

    if (user == null) {
      if (Routes.publicRoutes.contains(loc)) return null;
      return Routes.access;
    }
    if (!user.emailConfirmed) return loc == Routes.verify ? null : Routes.verify;

    final accountAsync = ref.read(accountProvider);
    final account = accountAsync.value;
    if (account == null) {
      // Cargando la cuenta (o error): pantalla de espera con reintento.
      return loc == Routes.splash ? null : Routes.splash;
    }

    final homeForRole = account.isProfessionalMode ? Routes.proHome : Routes.home;
    final atEntry = loc == Routes.splash || loc == Routes.verify || Routes.publicRoutes.contains(loc);
    if (atEntry) {
      final wantsPro = ref.read(entryIntentProvider) == AppRole.professional;
      if (wantsPro && !account.isApprovedProfessional && account.professionalStatus.canEdit) return Routes.apply;
      return homeForRole;
    }
    if (loc.startsWith('/pro/') && !account.isProfessionalMode) return Routes.home;
    if (!loc.startsWith('/pro/') && account.isProfessionalMode && _customerTabs.contains(loc)) {
      return homeForRole;
    }
    return null;
  }

  return GoRouter(
    initialLocation: Routes.splash,
    refreshListenable: refresh,
    redirect: redirect,
    routes: [
      GoRoute(path: Routes.splash, builder: (_, _) => const SplashPage()),
      GoRoute(path: Routes.onboarding, builder: (_, _) => const OnboardingPage()),
      GoRoute(path: Routes.access, builder: (_, _) => const AccessPage()),
      GoRoute(
        path: Routes.login,
        builder: (_, s) => LoginPage(asProfessional: s.uri.queryParameters['rol'] == 'pro'),
      ),
      GoRoute(
        path: Routes.register,
        builder: (_, s) => RegisterPage(asProfessional: s.uri.queryParameters['rol'] == 'pro'),
      ),
      GoRoute(
        path: Routes.verify,
        builder: (_, s) => VerifyEmailPage(email: s.uri.queryParameters['correo']),
      ),
      GoRoute(path: Routes.forgot, builder: (_, _) => const ForgotPasswordPage()),

      // Cliente
      StatefulShellRoute.indexedStack(
        builder: (_, _, shell) => AppShell(shell: shell, professional: false),
        branches: [
          StatefulShellBranch(
            routes: [GoRoute(path: Routes.home, builder: (_, _) => const CustomerHomePage())],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: Routes.search,
                builder: (_, s) => SearchPage(
                  key: ValueKey(s.uri.toString()),
                  initialCategoryId: int.tryParse(s.uri.queryParameters['categoria'] ?? ''),
                  initialQuery: s.uri.queryParameters['q'],
                  initialAvailableNow: s.uri.queryParameters['ahora'] == '1',
                ),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [GoRoute(path: Routes.requests, builder: (_, _) => const MyRequestsPage(asProfessional: false))],
          ),
          StatefulShellBranch(
            routes: [GoRoute(path: Routes.messages, builder: (_, _) => const ConversationsPage())],
          ),
          StatefulShellBranch(
            routes: [GoRoute(path: Routes.profile, builder: (_, _) => const ProfilePage())],
          ),
        ],
      ),

      // Profesional
      StatefulShellRoute.indexedStack(
        builder: (_, _, shell) => AppShell(shell: shell, professional: true),
        branches: [
          StatefulShellBranch(
            routes: [GoRoute(path: Routes.proHome, builder: (_, _) => const ProHomePage())],
          ),
          StatefulShellBranch(
            routes: [GoRoute(path: Routes.proRequests, builder: (_, _) => const ProJobsPage(incoming: true))],
          ),
          StatefulShellBranch(
            routes: [GoRoute(path: Routes.proJobs, builder: (_, _) => const ProJobsPage(incoming: false))],
          ),
          StatefulShellBranch(
            routes: [GoRoute(path: Routes.proMessages, builder: (_, _) => const ConversationsPage())],
          ),
          StatefulShellBranch(
            routes: [GoRoute(path: Routes.proProfile, builder: (_, _) => const ProfilePage())],
          ),
        ],
      ),

      // Pantallas completas
      GoRoute(
        path: Routes.ya,
        builder: (_, s) => RequestFlowPage(initialCategoryId: int.tryParse(s.uri.queryParameters['categoria'] ?? '')),
      ),
      GoRoute(
        path: '/profesional/:id',
        builder: (_, s) => ProfessionalProfilePage(id: s.pathParameters['id']!),
        routes: [
          GoRoute(
            path: 'solicitar',
            builder: (_, s) => RequestFlowPage(
              professionalId: s.pathParameters['id'],
              initialMode: BookingMode.parse(s.uri.queryParameters['modo']),
              initialCategoryId: int.tryParse(s.uri.queryParameters['categoria'] ?? ''),
            ),
          ),
        ],
      ),
      GoRoute(path: Routes.categories, builder: (_, _) => const AllCategoriesPage()),
      GoRoute(
        path: '/solicitud/:id',
        builder: (_, s) => BookingDetailPage(id: s.pathParameters['id']!),
      ),
      GoRoute(
        path: '/chat/:id',
        builder: (_, s) => ChatPage(conversationId: s.pathParameters['id']!),
      ),
      GoRoute(path: Routes.notifications, builder: (_, _) => const NotificationsPage()),
      GoRoute(path: Routes.editProfile, builder: (_, _) => const EditProfilePage()),
      GoRoute(path: Routes.apply, builder: (_, _) => const ApplicationPage()),
      GoRoute(path: Routes.wallet, builder: (_, _) => const WalletPage()),
      GoRoute(path: Routes.support, builder: (_, _) => const SupportPage()),
    ],
  );
});

const _customerTabs = {Routes.home, Routes.requests, Routes.messages, Routes.profile};
