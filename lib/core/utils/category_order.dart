/// Orden único de los servicios para el cliente: lo usan el inicio, la lista
/// completa de servicios y el paso 1 de "Pedir ¡Ya!", así la experiencia es
/// la misma en todas partes. Se ordena en la app (comparando slug o nombre
/// normalizado), sin tocar `sort_order` en la base de datos.
library;

/// Servicios del hogar a pedido, primero y en este orden.
const priorityCategoryKeys = [
  'plomeria',
  'electricidad',
  'limpieza',
  'albanileria',
  'pintura',
  'reparaciones-hogar',
  'cerrajeria',
  'jardineria',
  'aire-acondicionado',
];

/// Después, por grupos: otros servicios del hogar y el vehículo; cuidado
/// personal y de la familia; clases, eventos y trámites. Lo que no esté en
/// ninguna lista (una categoría nueva del administrador) va al final,
/// en el orden de la base de datos.
const _groupKeys = [
  ['carpinteria', 'mecanica'],
  ['belleza', 'manicure', 'ninera', 'mascotas'],
  ['clases', 'eventos', 'asesoria-legal', 'notario'],
];

/// Nombres alternativos que también identifican a un servicio prioritario.
const _aliases = {
  'reparaciones-hogar': ['reparaciones', 'reparaciones del hogar'],
  'aire-acondicionado': ['aire acondicionado'],
};

/// Texto en minúsculas y sin tildes, para comparar slugs y nombres.
String normalizeCategoryKey(String s) {
  const from = 'áàäâéèëêíìïîóòöôúùüûñ';
  const to = 'aaaaeeeeiiiioooouuuun';
  final buf = StringBuffer();
  for (final ch in s.trim().toLowerCase().split('')) {
    final i = from.indexOf(ch);
    buf.write(i < 0 ? ch : to[i]);
  }
  return buf.toString();
}

bool _matches(String key, String slug, String name) {
  final s = normalizeCategoryKey(slug);
  final n = normalizeCategoryKey(name);
  final names = [key, key.replaceAll('-', ' '), ...?_aliases[key]];
  return s == key || names.contains(n);
}

/// Rango de orden: 0..8 prioritarios, luego los grupos, luego el resto.
int categoryRank({required String slug, required String name}) {
  for (var i = 0; i < priorityCategoryKeys.length; i++) {
    if (_matches(priorityCategoryKeys[i], slug, name)) return i;
  }
  var base = priorityCategoryKeys.length;
  for (final group in _groupKeys) {
    for (var i = 0; i < group.length; i++) {
      if (_matches(group[i], slug, name)) return base + i;
    }
    base += group.length;
  }
  return base;
}

/// Orden estable: empates conservan el orden recibido (el `sort_order`).
List<T> orderCategories<T>(Iterable<T> items, {required String Function(T) slug, required String Function(T) name}) {
  final list = items.toList();
  final indexed = [
    for (var i = 0; i < list.length; i++) (i, categoryRank(slug: slug(list[i]), name: name(list[i])), list[i]),
  ];
  indexed.sort((a, b) {
    final r = a.$2.compareTo(b.$2);
    return r != 0 ? r : a.$1.compareTo(b.$1);
  });
  return [for (final e in indexed) e.$3];
}

/// Búsqueda de servicios sin importar tildes ni mayúsculas.
bool categoryMatchesQuery(String query, List<String?> fields) {
  final q = normalizeCategoryKey(query);
  if (q.isEmpty) return true;
  return fields.any((f) => f != null && normalizeCategoryKey(f).contains(q));
}

/// Orden de "¿Qué necesitas solucionar?" por servicio (solo para mostrar):
/// primero lo urgente. Lo que no está en la lista sigue en su orden de la base
/// de datos, y "Otro problema" va siempre al final.
const _problemPriority = {
  'plomeria': [
    'fuga de agua',
    'destapar caneria',
    'sin agua',
    'problema con la ducha',
    'reparar inodoro',
    'reparar o instalar grifo',
    'instalar tuberias',
  ],
};

List<T> orderProblems<T>(
  Iterable<T> items, {
  required String categorySlug,
  required String Function(T) name,
  required bool Function(T) isOther,
}) {
  final priority = _problemPriority[normalizeCategoryKey(categorySlug)] ?? const <String>[];
  final list = items.toList();
  int rank(T p) {
    if (isOther(p)) return 1 << 20;
    final i = priority.indexOf(normalizeCategoryKey(name(p)));
    return i < 0 ? priority.length : i;
  }

  final indexed = [for (var i = 0; i < list.length; i++) (i, rank(list[i]), list[i])];
  indexed.sort((a, b) {
    final r = a.$2.compareTo(b.$2);
    return r != 0 ? r : a.$1.compareTo(b.$1);
  });
  return [for (final e in indexed) e.$3];
}
