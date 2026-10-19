import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// Ícono por categoría. El nombre viene de la base de datos (columna `icon`),
/// así el administrador puede agregar categorías sin cambiar la app.
IconData categoryIcon(String name) => switch (name) {
  'plumbing' => Icons.plumbing,
  'electrical_services' => Icons.electrical_services,
  'cleaning_services' => Icons.cleaning_services,
  'format_paint' => Icons.format_paint,
  'construction' => Icons.construction,
  'carpenter' => Icons.carpenter,
  'yard' => Icons.yard,
  'home_repair_service' => Icons.home_repair_service,
  'directions_car' => Icons.directions_car,
  'ac_unit' => Icons.ac_unit,
  'key' => Icons.key,
  'content_cut' => Icons.content_cut,
  'spa' => Icons.spa,
  'child_care' => Icons.child_care,
  'pets' => Icons.pets,
  'school' => Icons.school,
  'celebration' => Icons.celebration,
  'gavel' => Icons.gavel,
  'more' => Icons.more_horiz_rounded,
  _ => Icons.handyman,
};

/// Colores de los íconos de categoría, en la línea de la marca.
(Color, Color) categoryColors(String name) => switch (name) {
  'plumbing' || 'ac_unit' => (const Color(0xFF1F6FC5), const Color(0xFFE8F1FB)),
  'electrical_services' || 'key' => (const Color(0xFFB37400), const Color(0xFFFFF5DC)),
  'yard' || 'format_paint' || 'pets' => (HyColors.greenDark, HyColors.greenSoft),
  'directions_car' || 'construction' || 'carpenter' => (HyColors.primaryDark, HyColors.primarySoft),
  'cleaning_services' || 'content_cut' || 'spa' || 'gavel' => (const Color(0xFF6B3FA0), const Color(0xFFF2ECFA)),
  _ => (HyColors.navy, HyColors.surfaceMuted),
};
