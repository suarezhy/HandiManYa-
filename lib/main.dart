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

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Pantallas pensadas para el teléfono en vertical (igual que en iPhone).
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  await initializeDateFormatting('es');
  final prefs = await SharedPreferences.getInstance();
  if (Env.hasBackend) {
    await Supabase.initialize(
      url: Env.supabaseUrl,
      publishableKey: Env.supabaseAnonKey,
      // La sesión queda cifrada en el teléfono (llavero de iOS, Keystore de Android).
      authOptions: secureAuthOptions(Env.supabaseUrl, prefs),
    );
  }

  runApp(
    ProviderScope(
      overrides: [prefsProvider.overrideWithValue(prefs), backendProvider.overrideWithValue(createBackend())],
      child: const HandiManYaApp(),
    ),
  );
}
