import 'dart:math' as math;

/// Un punto en el mapa.
class GeoPoint {
  const GeoPoint(this.latitude, this.longitude);

  final double latitude;
  final double longitude;
}

/// Base y radio de trabajo de un profesional. Solo la ve el propio profesional.
class ServiceLocation {
  const ServiceLocation({required this.latitude, required this.longitude, required this.radiusKm});

  final double latitude;
  final double longitude;
  final int radiusKm;
}

/// Distancia en línea recta, en km (fórmula del haversine).
double distanceKm(double lat1, double lng1, double lat2, double lng2) {
  const r = 6371.0;
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(lat2 - lat1);
  final dLng = rad(lng2 - lng1);
  final a =
      math.pow(math.sin(dLat / 2), 2) + math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.pow(math.sin(dLng / 2), 2);
  return r * 2 * math.asin(math.sqrt(a));
}
