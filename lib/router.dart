import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'data/models/booking.dart';
import 'data/models/staff.dart';
import 'data/models/user.dart';
import 'data/providers.dart';
import 'features/auth/complete_profile_page.dart';
import 'features/auth/phone_auth_page.dart';
import 'features/auth/recover_account_page.dart';
import 'features/admin/admin_applications_page.dart';
import 'features/admin/admin_cases_pages.dart';
import 'features/admin/admin_catalog_audit_pages.dart';
import 'features/admin/admin_costs_page.dart';
import 'features/admin/admin_services_pages.dart';
import 'features/admin/admin_home_page.dart';
import 'features/admin/admin_money_pages.dart';
import 'features/admin/admin_users_page.dart';
import 'features/admin/ai_control_center_page.dart';
import 'features/booking/booking_detail_page.dart';
import 'features/booking/live_trip.dart';
import 'features/booking/my_requests_page.dart';
import 'features/booking/choose_professional_page.dart';
import 'features/booking/request_flow_page.dart';
import 'features/home/all_categories_page.dart';
import 'features/management/cases_pages.dart';
import 'features/management/management_common.dart';
import 'features/management/management_shell.dart';
import 'features/management/panel_pages.dart';
import 'features/management/team_page.dart';
import 'features/home/customer_home_page.dart';
import 'features/messages/chat_page.dart';
import 'features/messages/conversations_page.dart';
import 'features/notifications/notifications_page.dart';
import 'features/onboarding/onboarding_page.dart';
import 'features/pro_mode/application_page.dart';
import 'features/pro_mode/pro_home_page.dart';
import 'features/pro_mode/pro_jobs_page.dart';
import 'features/pro_mode/service_area_page.dart';
import 'features/pro_mode/wallet_page.dart';
import 'features/professional/professional_profile_page.dart';
import 'features/profile/edit_profile_page.dart';
import 'features/profile/profile_page.dart';
import 'features/profile/support_page.dart';
import 'features/safety/emergency_guide_page.dart';
import 'features/search/search_page.dart';
import 'features/security/security_page.dart';
import 'features/shell/app_shell.dart';
import 'features/shell/splash_page.dart';

abstract final class Routes {
  static const splash = '/';
  static const onboarding = '/bienvenida';
  static const access = '/acceso';
  static const recover = '/recuperar';
  static const completeProfile = '/completa-tu-perfil';

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
  static const security = '/perfil/seguridad';
  static const emergencyGuide = '/perfil/emergencia';
  static const apply = '/postular';
  static const wallet = '/billetera';
  static const support = '/ayuda';
  static const serviceArea = '/zona-de-trabajo';

  static const admin = '/admin';
  static const adminApplications = '/admin/postulaciones';
  static const adminTopups = '/admin/recargas';
  static const adminReports = '/admin/reportes';
  static const adminDisputes = '/admin/disputas';
  static const adminTickets = '/admin/soporte';
  static const adminUsers = '/admin/usuarios';
  static const adminCommissions = '/admin/comisiones';
  static const adminCatalog = '/admin/catalogo';
  static const adminAudit = '/admin/auditoria';
  static const adminAi = '/admin/centro-ia';
  static const adminCosts = '/admin/costos';
  static const ownerManage = '/admin/gestion';
  static const ownerTeam = '/admin/equipo';
  static const ownerProfile = '/admin/perfil';
  static String adminApplication(String id) => '/admin/postulaciones/$id';

  static const manager = '/gerente';
  static const managerCases = '/gerente/casos';
  static const managerApplications = '/gerente/postulaciones';
  static const managerTeam = '/gerente/equipo';
  static const managerProfile = '/gerente/perfil';

  static const employee = '/empleado';
  static const employeeActivity = '/empleado/actividad';
  static const employeeProfile = '/empleado/perfil';

  static const staffCases = '/gestion/casos';
  static String staffCase(int id) => '/gestion/caso/$id';

  static String panelHome(StaffRole role) => switch (role) {
    StaffRole.owner => admin,
    StaffRole.manager => manager,
    StaffRole.employee => employee,
  };
  static String adminProblems(int categoryId) => '/admin/catalogo/$categoryId/opciones';

  static String professional(String id) => '/profesional/$id';
  static String requestPro(String id, BookingMode mode) => '/profesional/$id/solicitar?modo=${mode.key}';
  static String category(int id) => '/buscar?categoria=$id';

  /// "¿Qué necesitas solucionar?" de una categoría. Al tocar una categoría
  /// siempre se llega aquí, nunca directo a la lista de profesionales.
  static String service(int id) => '/servicio/$id';
  static const chooseProfessional = '/elegir-profesional';
  static String booking(String id) => '/solicitud/$id';
  static String chat(String id) => '/chat/$id';

  /// Viaje compartido: página pública que abre el contacto de confianza.
  static String sharedTrip(String token) => '/viaje/$token';

  static const publicRoutes = {onboarding, access, recover};
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
    ..listen(managementCustomerModeProvider, (_, _) => refresh.ping())
    ..onDispose(refresh.dispose);

  String? redirect(BuildContext context, GoRouterState state) {
    final loc = state.matchedLocation;
    // El contacto de confianza abre el enlace sin cuenta ni bienvenida.
    if (loc.startsWith('/viaje/')) return null;
    final onboardingSeen = ref.read(onboardingSeenProvider);
    final authAsync = ref.read(authUserProvider);
    final user = authAsync.value;

    if (!onboardingSeen) return loc == Routes.onboarding ? null : Routes.onboarding;
    if (authAsync.isLoading && !authAsync.hasValue) return loc == Routes.splash ? null : Routes.splash;

    if (user == null) {
      if (Routes.publicRoutes.contains(loc)) return null;
      return Routes.access;
    }

    final accountAsync = ref.read(accountProvider);
    final account = accountAsync.value;
    if (account == null) {
      // Cargando la cuenta (o error): pantalla de espera con reintento.
      return loc == Routes.splash ? null : Routes.splash;
    }

    // Cuenta nueva: después del código, nombre, ciudad y términos.
    if (!account.profileComplete) return loc == Routes.completeProfile ? null : Routes.completeProfile;

    final staffRole = account.managementRole;
    final customerMode = ref.read(managementCustomerModeProvider);
    final homeForRole = staffRole != null
        ? Routes.panelHome(staffRole)
        : account.isProfessionalMode
        ? Routes.proHome
        : Routes.home;
    // Cada panel solo para su rol. Ocultar la pantalla no basta: el servidor
    // vuelve a revisar cada acción (hmy_can, is_admin).
    if (loc.startsWith(Routes.admin)) {
      final allowed =
          staffRole == StaffRole.owner ||
          (staffRole == StaffRole.manager && _managerAdminRoutes.any((r) => loc == r || loc.startsWith('$r/')));
      if (!allowed) return homeForRole;
    }
    if (loc.startsWith(Routes.manager) && staffRole != StaffRole.manager) return homeForRole;
    if (loc.startsWith(Routes.employee) && staffRole != StaffRole.employee) return homeForRole;
    if (loc.startsWith('/gestion/') && staffRole == null) return homeForRole;
    final atEntry = loc == Routes.splash || loc == Routes.completeProfile || Routes.publicRoutes.contains(loc);
    if (atEntry) {
      // El equipo entra directo a su panel; la intención "quiero ser
      // profesional" de la bienvenida no aplica.
      if (staffRole != null) return homeForRole;
      final wantsPro = ref.read(entryIntentProvider) == AppRole.professional;
      if (wantsPro && !account.isApprovedProfessional && account.professionalStatus.canEdit) return Routes.apply;
      return homeForRole;
    }
    // El equipo usa la app de cliente solo si eligió "Cambiar a modo cliente".
    if (staffRole != null && !customerMode && (_customerTabs.contains(loc) || loc == Routes.search)) {
      return homeForRole;
    }
    if (loc.startsWith('/pro/') && !account.isProfessionalMode) return Routes.home;
    // La billetera es solo de profesionales (el servidor tampoco muestra saldo a otros).
    if (loc == Routes.wallet && !account.isApprovedProfessional) return Routes.home;
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
      _route(path: Routes.splash, builder: (_, _) => const SplashPage()),
      _route(
        path: '/viaje/:token',
        builder: (_, s) => TripSharePage(token: s.pathParameters['token']!),
      ),
      _route(path: Routes.onboarding, builder: (_, _) => const OnboardingPage()),
      _route(path: Routes.access, builder: (_, _) => const PhoneAuthPage()),
      _route(path: Routes.recover, builder: (_, _) => const RecoverAccountPage()),
      _route(path: Routes.completeProfile, builder: (_, _) => const CompleteProfilePage()),

      // Cliente
      StatefulShellRoute.indexedStack(
        pageBuilder: (_, s, shell) => _page(s, AppShell(shell: shell, professional: false)),
        branches: [
          StatefulShellBranch(
            routes: [_route(path: Routes.home, builder: (_, _) => const CustomerHomePage())],
          ),
          StatefulShellBranch(
            routes: [
              _route(
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
            routes: [_route(path: Routes.requests, builder: (_, _) => const MyRequestsPage(asProfessional: false))],
          ),
          StatefulShellBranch(
            routes: [_route(path: Routes.messages, builder: (_, _) => const ConversationsPage())],
          ),
          StatefulShellBranch(
            routes: [_route(path: Routes.profile, builder: (_, _) => const ProfilePage())],
          ),
        ],
      ),

      // Profesional
      StatefulShellRoute.indexedStack(
        pageBuilder: (_, s, shell) => _page(s, AppShell(shell: shell, professional: true)),
        branches: [
          StatefulShellBranch(
            routes: [_route(path: Routes.proHome, builder: (_, _) => const ProHomePage())],
          ),
          StatefulShellBranch(
            routes: [_route(path: Routes.proRequests, builder: (_, _) => const ProJobsPage(incoming: true))],
          ),
          StatefulShellBranch(
            routes: [_route(path: Routes.proJobs, builder: (_, _) => const ProJobsPage(incoming: false))],
          ),
          StatefulShellBranch(
            routes: [_route(path: Routes.proMessages, builder: (_, _) => const ConversationsPage())],
          ),
          StatefulShellBranch(
            routes: [_route(path: Routes.proProfile, builder: (_, _) => const ProfilePage())],
          ),
        ],
      ),

      // Pantallas completas
      _route(
        path: Routes.ya,
        builder: (_, s) => RequestFlowPage(initialCategoryId: int.tryParse(s.uri.queryParameters['categoria'] ?? '')),
      ),
      _route(
        path: '/profesional/:id',
        builder: (_, s) => ProfessionalProfilePage(id: s.pathParameters['id']!),
        routes: [
          _route(
            path: 'solicitar',
            builder: (_, s) => RequestFlowPage(
              professionalId: s.pathParameters['id'],
              initialMode: BookingMode.parse(s.uri.queryParameters['modo']),
              initialCategoryId: int.tryParse(s.uri.queryParameters['categoria'] ?? ''),
            ),
          ),
        ],
      ),
      _route(
        path: '/servicio/:id',
        builder: (_, s) => RequestFlowPage(initialCategoryId: int.tryParse(s.pathParameters['id'] ?? '')),
      ),
      _route(
        path: Routes.chooseProfessional,
        builder: (_, s) => ChooseProfessionalPage(args: s.extra as ChooseProfessionalArgs?),
      ),
      _route(path: Routes.categories, builder: (_, _) => const AllCategoriesPage()),
      _route(
        path: '/solicitud/:id',
        builder: (_, s) => BookingDetailPage(id: s.pathParameters['id']!),
      ),
      _route(
        path: '/chat/:id',
        builder: (_, s) => ChatPage(conversationId: s.pathParameters['id']!),
      ),
      _route(path: Routes.notifications, builder: (_, _) => const NotificationsPage()),
      _route(path: Routes.editProfile, builder: (_, _) => const EditProfilePage()),
      _route(path: Routes.security, builder: (_, _) => const SecurityPage()),
      _route(path: Routes.emergencyGuide, builder: (_, _) => const EmergencyGuidePage()),
      _route(path: Routes.apply, builder: (_, _) => const ApplicationPage()),
      _route(path: Routes.wallet, builder: (_, _) => const WalletPage()),
      _route(path: Routes.support, builder: (_, _) => const SupportPage()),
      _route(path: Routes.serviceArea, builder: (_, _) => const ServiceAreaPage()),

      // Panel del Propietario
      StatefulShellRoute.indexedStack(
        pageBuilder: (_, s, shell) => _page(s, ManagementShell(role: StaffRole.owner, shell: shell)),
        branches: [
          StatefulShellBranch(
            routes: [_route(path: Routes.admin, builder: (_, _) => const AdminHomePage())],
          ),
          StatefulShellBranch(
            routes: [_route(path: Routes.ownerManage, builder: (_, _) => const OwnerManagePage())],
          ),
          StatefulShellBranch(
            routes: [_route(path: Routes.adminAi, builder: (_, _) => const AiControlCenterPage())],
          ),
          StatefulShellBranch(
            routes: [
              _route(
                path: Routes.ownerTeam,
                builder: (_, _) => const TeamPage(role: StaffRole.owner),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              _route(
                path: Routes.ownerProfile,
                builder: (_, _) => const StaffProfilePage(role: StaffRole.owner),
              ),
            ],
          ),
        ],
      ),

      // Panel del Gerente (sin dinero)
      StatefulShellRoute.indexedStack(
        pageBuilder: (_, s, shell) => _page(s, ManagementShell(role: StaffRole.manager, shell: shell)),
        branches: [
          StatefulShellBranch(
            routes: [_route(path: Routes.manager, builder: (_, _) => const ManagerHomePage())],
          ),
          StatefulShellBranch(
            routes: [
              _route(
                path: Routes.managerCases,
                builder: (_, _) => const CasesPage(role: StaffRole.manager, initialScope: 'unassigned'),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [_route(path: Routes.managerApplications, builder: (_, _) => const AdminApplicationsPage())],
          ),
          StatefulShellBranch(
            routes: [
              _route(
                path: Routes.managerTeam,
                builder: (_, _) => const TeamPage(role: StaffRole.manager),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              _route(
                path: Routes.managerProfile,
                builder: (_, _) => const StaffProfilePage(role: StaffRole.manager),
              ),
            ],
          ),
        ],
      ),

      // Panel del Empleado (solo sus casos)
      StatefulShellRoute.indexedStack(
        pageBuilder: (_, s, shell) => _page(s, ManagementShell(role: StaffRole.employee, shell: shell)),
        branches: [
          StatefulShellBranch(
            routes: [
              _route(
                path: Routes.employee,
                builder: (_, _) => const CasesPage(role: StaffRole.employee),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [_route(path: Routes.employeeActivity, builder: (_, _) => const EmployeeActivityPage())],
          ),
          StatefulShellBranch(
            routes: [
              _route(
                path: Routes.employeeProfile,
                builder: (_, _) => const StaffProfilePage(role: StaffRole.employee),
              ),
            ],
          ),
        ],
      ),

      // Casos del equipo, abiertos desde cualquier panel
      _route(
        path: Routes.staffCases,
        builder: (_, _) => CasesPage(
          role: ref.read(accountProvider).value?.managementRole ?? StaffRole.employee,
          initialScope: 'all',
          inShell: false,
        ),
      ),
      _route(
        path: '/gestion/caso/:id',
        builder: (_, s) => CaseDetailPage(caseId: int.parse(s.pathParameters['id']!)),
      ),

      // Administración
      _route(path: Routes.adminApplications, builder: (_, _) => const AdminApplicationsPage()),
      _route(
        path: '/admin/postulaciones/:id',
        builder: (_, s) => AdminApplicationDetailPage(professionalId: s.pathParameters['id']!),
      ),
      _route(path: Routes.adminTopups, builder: (_, _) => const AdminTopupsPage()),
      _route(path: Routes.adminReports, builder: (_, _) => const AdminReportsPage()),
      _route(path: Routes.adminDisputes, builder: (_, _) => const AdminDisputesPage()),
      _route(path: Routes.adminTickets, builder: (_, _) => const AdminTicketsPage()),
      _route(path: Routes.adminUsers, builder: (_, _) => const AdminUsersPage()),
      _route(path: Routes.adminCommissions, builder: (_, _) => const AdminCommissionsPage()),
      _route(path: Routes.adminCatalog, builder: (_, _) => const AdminCatalogPage()),
      _route(
        path: '/admin/catalogo/:id/opciones',
        builder: (_, s) => AdminProblemsPage(categoryId: int.parse(s.pathParameters['id']!)),
      ),
      _route(path: Routes.adminAudit, builder: (_, _) => const AdminAuditPage()),
      _route(path: Routes.adminCosts, builder: (_, _) => const AdminCostsPage()),
    ],
  );
});

/// Página Material del propio Flutter para cada ruta.
///
/// go_router 18 busca el MaterialApp del paquete material_ui y no reconoce el
/// de Flutter que usa la app: sin esto arma páginas sin transición, y en iOS
/// no se puede volver deslizando desde el borde izquierdo (ni hay animación
/// del gesto atrás predictivo en Android). Con MaterialPage se usan las
/// transiciones del tema (AppTheme: Cupertino en iOS, predictiva en Android).
Page<void> _page(GoRouterState state, Widget child) => MaterialPage<void>(
  key: state.pageKey,
  name: state.name ?? state.path,
  arguments: <String, String>{...state.pathParameters, ...state.uri.queryParameters},
  restorationId: state.pageKey.value,
  child: child,
);

/// Una ruta con [_page]: igual que GoRoute(path:, builder:).
GoRoute _route({required String path, required GoRouterWidgetBuilder builder, List<RouteBase> routes = const []}) =>
    GoRoute(path: path, pageBuilder: (context, state) => _page(state, builder(context, state)), routes: routes);

/// Lo de /admin que también usa el gerente (el resto es del propietario).
const _managerAdminRoutes = [
  Routes.adminApplications,
  Routes.adminReports,
  Routes.adminDisputes,
  Routes.adminTickets,
  Routes.adminUsers,
];

const _customerTabs = {Routes.home, Routes.requests, Routes.messages, Routes.profile};
