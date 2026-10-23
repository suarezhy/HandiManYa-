import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handimanya/core/theme/tokens.dart';
import 'package:handimanya/data/models/user.dart';
import 'package:handimanya/data/providers.dart';
import 'package:handimanya/features/shell/splash_page.dart';

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

    test('Android 12+ muestra el logo completo, no el ícono sobre blanco', () {
      for (final dir in ['values-v31', 'values-night-v31']) {
        final s = read('$dir/styles.xml');
        expect(s, contains('windowSplashScreenBackground">@color/splash_background'));
        expect(s, contains('windowSplashScreenAnimatedIcon">@drawable/splash_icon'));
      }
      for (final f in ['drawable/launch_background.xml', 'drawable-v21/launch_background.xml']) {
        expect(read(f), allOf(contains('@color/splash_background'), contains('@drawable/splash_logo')));
      }
    });

    test('las imágenes miden lo mismo en dp en todas las densidades', () {
      for (final (bucket, scale) in [('mdpi', 1.0), ('hdpi', 1.5), ('xhdpi', 2.0), ('xxhdpi', 3.0), ('xxxhdpi', 4.0)]) {
        final logo = _pngSize('$res/drawable-$bucket/splash_logo.png');
        expect(logo.width, closeTo(SplashPage.logoSize.width * scale, 1), reason: bucket);
        expect(logo.height, closeTo(SplashPage.logoSize.height * scale, 1), reason: bucket);
        final icon = _pngSize('$res/drawable-$bucket/splash_icon.png');
        expect(icon.width, closeTo(288 * scale, 1), reason: 'lienzo de 288 dp ($bucket)');
      }
      // El logo entero cabe en el círculo de 192 dp que Android deja ver.
      final half = SplashPage.logoSize / 2;
      expect(half.width * half.width + half.height * half.height, lessThan(96 * 96));
      expect(_pngSize('assets/brand/4.0x/splash_logo.png').width, closeTo(SplashPage.logoSize.width * 4, 1));
    });
  });
}

Size _pngSize(String path) {
  final b = File(path).readAsBytesSync();
  int u32(int o) => (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];
  return Size(u32(16).toDouble(), u32(20).toDouble());
}
