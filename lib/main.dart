import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'core/config/env.dart';
import 'core/services/secure_session_storage.dart';
import 'data/providers.dart';
import 'features/shell/startup_error_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _start();
}

// Supabase se prepara una sola vez, aunque se reintente el arranque.
var _supabaseReady = false;

/// Prepara la app y la abre. Si algo falla (por ejemplo, no se puede leer la
/// sesión guardada), muestra el error con "Reintentar" en vez de quedar en blanco.
Future<void> _start() async {
  try {
    // Pantallas pensadas para el teléfono en vertical (igual que en iPhone).
    final (_, _, prefs) = await (
      SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]),
      initializeDateFormatting('es'),
      SharedPreferences.getInstance(),
    ).wait;
    if (Env.hasBackend && !_supabaseReady) {
      await Supabase.initialize(
        url: Env.supabaseUrl,
        publishableKey: Env.supabaseAnonKey,
        // La sesión queda cifrada en el teléfono (llavero de iOS, Keystore de Android).
        authOptions: secureAuthOptions(Env.supabaseUrl, prefs),
      );
      _supabaseReady = true;
    }

    runApp(
      ProviderScope(
        overrides: [prefsProvider.overrideWithValue(prefs), backendProvider.overrideWithValue(createBackend())],
        child: const HandiManYaApp(),
      ),
    );
  } catch (e) {
    runApp(StartupErrorApp(error: e, onRetry: _start));
  }
}
