import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import '../../data/models/geo.dart';
import '../config/env.dart';
import '../utils/app_error.dart';

/// Ubicación del teléfono. Se reemplaza en las pruebas.
abstract interface class LocationService {
  /// Pide permiso (si hace falta) y devuelve la ubicación actual.
  Future<GeoPoint> current();
}

class DeviceLocationService implements LocationService {
  const DeviceLocationService();

  @override
  Future<GeoPoint> current() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw const AppError('Activa la ubicación (GPS) de tu teléfono e inténtalo de nuevo.', code: 'HMY_GPS_OFF');
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
    if (permission == LocationPermission.denied) {
      throw const AppError(
        'No nos diste permiso para usar tu ubicación. Puedes escribir la dirección a mano.',
        code: 'HMY_GPS_DENIED',
      );
    }
    if (permission == LocationPermission.deniedForever) {
      throw const AppError(
        'El permiso de ubicación está bloqueado. Puedes activarlo en Ajustes del teléfono o escribir la dirección a mano.',
        code: 'HMY_GPS_BLOCKED',
      );
    }
    final pos = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 20)),
    );
    if (pos.latitude < -23.5 || pos.latitude > -9 || pos.longitude < -70 || pos.longitude > -57) {
      // Solo en la app de desarrollo: para probar fuera de Bolivia se usa un
      // punto fijo del centro de Santa Cruz. Nunca en producción.
      if (Env.isDevProject) return devSimulatedLocation;
      throw const AppError(
        'Tu ubicación parece estar fuera de Bolivia. Escribe la dirección a mano.',
        code: 'HMY_INVALID_LOCATION',
      );
    }
    return GeoPoint(pos.latitude, pos.longitude);
  }
}

/// Ubicación simulada de la app de desarrollo (Plaza 24 de Septiembre, Santa Cruz).
const devSimulatedLocation = GeoPoint(-17.7834, -63.1821);

final locationServiceProvider = Provider<LocationService>((ref) => const DeviceLocationService());

/// Explica para qué usamos la ubicación antes de que el teléfono pida el permiso.
Future<bool> explainLocationUse(BuildContext context, {required bool professional}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      icon: const Icon(Icons.my_location_rounded, size: 40),
      title: const Text('Usar tu ubicación'),
      content: Text(
        professional
            ? 'La usamos para mandarte pedidos cercanos y calcular a qué distancia están. '
                  'Los clientes no ven tu ubicación exacta. Solo la tomamos cuando tocas este botón.'
            : 'La usamos para encontrar profesionales cerca de ti. '
                  'Tu ubicación exacta solo la verá el profesional que acepte tu pedido. '
                  'Solo la tomamos cuando tocas este botón; no te seguimos en segundo plano.',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Ahora no')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Continuar')),
      ],
    ),
  );
  return ok ?? false;
}
