import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handimanya/core/theme/tokens.dart';
import 'package:handimanya/data/models/user.dart';
import 'package:handimanya/data/providers.dart';
import 'package:handimanya/features/shell/splash_page.dart';
import 'package:handimanya/features/shell/startup_error_app.dart';

/// Arranque de una sola pantalla: la nativa de Android y la de Flutter
/// muestran el mismo logo, fondo y tamaño (Build 13 mostraba primero el ícono
/// sobre blanco y después el logo con la ruedita).
void main() {
  Future<void> pump(WidgetTester tester, Future<UserProfile?> Function() account) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [accountProvider.overrideWith((ref) => account())],
        child: const MaterialApp(home: SplashPage()),
      ),
    );
  }

  testWidgets('el logo va centrado y la ruedita sale solo si la carga tarda', (tester) async {
    final never = Completer<UserProfile?>();
    await pump(tester, () => never.future);
    final logo = find.byKey(const Key('splash-logo'));
    expect(logo, findsOneWidget);
    expect(tester.getSize(logo), SplashPage.logoSize);
    final screen = tester.getSize(find.byType(Scaffold));
    expect(tester.getCenter(logo), Offset(screen.width / 2, screen.height / 2), reason: 'como el ícono nativo');
    expect(find.byKey(const Key('splash-loading')), findsNothing, reason: 'sin ruedita al abrir');
    await tester.pump(SplashPage.spinnerDelay + const Duration(milliseconds: 50));
    expect(find.byKey(const Key('splash-loading')), findsOneWidget);
    expect(tester.getCenter(logo), Offset(screen.width / 2, screen.height / 2), reason: 'el logo no se mueve');
  });

  testWidgets('un error al cargar se explica con Reintentar, sin mover el logo', (tester) async {
    await pump(tester, () async => throw Exception('x'));
    await tester.pump();
    expect(find.text('Reintentar'), findsOneWidget);
    final screen = tester.getSize(find.byType(Scaffold));
    expect(tester.getCenter(find.byKey(const Key('splash-logo'))).dy, screen.height / 2);
  });

  testWidgets('arranque rápido (menos de 1 s): nunca aparece la ruedita', (tester) async {
    final slow = Completer<UserProfile?>();
    await pump(tester, () => slow.future);
    await tester.pump(const Duration(milliseconds: 900));
    expect(find.byKey(const Key('splash-loading')), findsNothing);
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.byKey(const Key('splash-loading')), findsOneWidget, reason: 'pasado 1 s, sí');
  });

  testWidgets('sin internet: lo dice claro y Reintentar vuelve a cargar', (tester) async {
    var calls = 0;
    await pump(tester, () async {
      calls++;
      if (calls == 1) throw Exception('SocketException: Failed host lookup (network)');
      return null;
    });
    await tester.pump();
    expect(find.textContaining('No hay conexión a internet'), findsOneWidget);
    await tester.tap(find.text('Reintentar'));
    await tester.pump();
    expect(calls, 2);
    expect(find.text('Reintentar'), findsNothing, reason: 'al reintentar ya no muestra el error viejo');
  });

  testWidgets('si la app no logra arrancar, muestra el error con Reintentar', (tester) async {
    var retried = 0;
    await tester.pumpWidget(StartupErrorApp(error: Exception('network down'), onRetry: () async => retried++));
    await tester.pump();
    expect(find.byKey(const Key('startup-error')), findsOneWidget);
    final screen = tester.getSize(find.byType(Scaffold));
    expect(tester.getCenter(find.byType(Image)).dy, screen.height / 2, reason: 'el logo en el mismo lugar');
    await tester.tap(find.text('Reintentar'));
    await tester.pump();
    expect(retried, 1);
  });

  group('pantalla nativa de Android', () {
    const res = 'android/app/src/main/res';
    String read(String p) => File('$res/$p').readAsStringSync();

    test('mismo fondo que la app, con y sin modo oscuro', () {
      final hex = HyColors.background.toARGB32().toRadixString(16).substring(2).toUpperCase();
      expect(read('values/colors.xml'), contains('#$hex'));
      for (final dir in ['values', 'values-night', 'values-v31', 'values-night-v31']) {
        final s = read('$dir/styles.xml');
        expect(s, contains('Theme.AppCompat.Light.NoActionBar'), reason: dir);
        expect(s, isNot(contains('colorBackground')), reason: '$dir: nada de fondo del sistema');
      }
    });

    test('Android 12+ (prueba): el logo chico entra entero en el círculo y crece hasta el de Flutter', () {
      // Lienzo de 288 dp; Android deja ver un círculo de 192 dp.
      final small = Size(SplashPage.logoSize.width * 36 / 46, 36);
      expect(small.width * small.width / 4 + small.height * small.height / 4, lessThan(96 * 96));
      for (final dir in ['values-v31', 'values-night-v31']) {
        final s = read('$dir/styles.xml');
        expect(s, contains('windowSplashScreenBackground">@color/splash_background'));
        expect(s, contains('windowSplashScreenAnimatedIcon">@drawable/splash_icon'));
      }
      for (final (bucket, scale) in [('mdpi', 1.0), ('hdpi', 1.5), ('xhdpi', 2.0), ('xxhdpi', 3.0), ('xxxhdpi', 4.0)]) {
        expect(_pngSize('$res/drawable-$bucket/splash_icon.png').width, closeTo(288 * scale, 1), reason: bucket);
      }
      // MainActivity agranda 46/36: el mismo alto que el logo de SplashPage.
      final activity = File('android/app/src/main/kotlin/bo/handimanya/handimanya/MainActivity.kt').readAsStringSync();
      expect(activity, contains('LOGO_GROWTH = 46f / 36f'));
      expect(SplashPage.logoSize.height, 46);
      expect(activity, contains('view.remove()'));
      for (final f in ['drawable/launch_background.xml', 'drawable-v21/launch_background.xml']) {
        expect(read(f), allOf(contains('@color/splash_background'), contains('@drawable/splash_logo')));
      }
    });

    test('cada @color y @drawable que usan los recursos de Android existe', () {
      // Build 14: cambiar colors.xml borró ic_launcher_background y la
      // compilación de Android falló recién en GitHub.
      final res = Directory('android/app/src/main/res');
      final files = res.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.xml')).toList();
      final colors = {
        for (final f in files.where((f) => f.path.contains('${Platform.pathSeparator}values')))
          for (final m in RegExp(r'<color name="([^"]+)"').allMatches(f.readAsStringSync())) m.group(1)!,
      };
      final drawables = {
        for (final f in res.listSync(recursive: true).whereType<File>())
          if (RegExp(r'[/\\](drawable|mipmap)[^/\\]*[/\\]').hasMatch(f.path)) f.uri.pathSegments.last.split('.').first,
      };
      for (final f in files) {
        final text = f.readAsStringSync();
        for (final m in RegExp(r'@color/(\w+)').allMatches(text)) {
          expect(colors, contains(m.group(1)), reason: f.path);
        }
        for (final m in RegExp(r'@(?:drawable|mipmap)/(\w+)').allMatches(text)) {
          expect(drawables, contains(m.group(1)), reason: f.path);
        }
      }
    });

    test('las imágenes miden lo mismo en dp en todas las densidades', () {
      for (final (bucket, scale) in [('mdpi', 1.0), ('hdpi', 1.5), ('xhdpi', 2.0), ('xxhdpi', 3.0), ('xxxhdpi', 4.0)]) {
        final logo = _pngSize('$res/drawable-$bucket/splash_logo.png');
        expect(logo.width, closeTo(SplashPage.logoSize.width * scale, 1), reason: bucket);
        expect(logo.height, closeTo(SplashPage.logoSize.height * scale, 1), reason: bucket);
      }
      // Issue #13: 30-40 % más grande que el de Build 15 (175 x 34 dp), sin deformarse.
      expect(SplashPage.logoSize.width / 175, inInclusiveRange(1.3, 1.4));
      expect(SplashPage.logoSize.width / SplashPage.logoSize.height, closeTo(175 / 34, 0.05));
      expect(_pngSize('assets/brand/4.0x/splash_logo.png').width, closeTo(SplashPage.logoSize.width * 4, 1));
    });
  });
}

Size _pngSize(String path) {
  final b = File(path).readAsBytesSync();
  int u32(int o) => (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];
  return Size(u32(16).toDouble(), u32(20).toDouble());
}
