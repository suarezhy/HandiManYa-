#!/usr/bin/env python3
"""Genera la lista de municipios de Bolivia (supabase/data/bolivia_municipios.csv).

Fuente: límites oficiales de GeoBolivia (2015, dominio público), publicados por
geoBoundaries (gbOpen BOL ADM1/ADM2/ADM3, versión "simplified"):
https://github.com/wmgeolab/geoBoundaries/tree/main/releaseData/gbOpen/BOL

Uso: python3 build_bolivia_locations.py ADM1.geojson ADM2.geojson ADM3.geojson > bolivia_municipios.csv

A cada municipio se le asigna el departamento y la provincia que contienen un
punto interior suyo. Las capitales usan la coordenada de la ciudad.
"""
import csv
import json
import re
import sys
import unicodedata

DEPARTMENTS = {  # mismos id que public.departments
    'Chuquisaca': 1, 'La Paz': 2, 'Cochabamba': 3, 'Oruro': 4, 'Potosí': 5,
    'Tarija': 6, 'Santa Cruz': 7, 'Beni': 8, 'Pando': 9,
}
CODES = {1: 'ch', 2: 'lp', 3: 'cb', 4: 'or', 5: 'pt', 6: 'tj', 7: 'sc', 8: 'be', 9: 'pd'}

# Ciudades que ya existían (se conservan su nombre, slug y orden) y capitales.
KNOWN = {
    'Santa Cruz de la Sierra': ('Santa Cruz de la Sierra', 'santa-cruz', -17.783300, -63.182100, 1),
    'Cochabamba': ('Cochabamba', 'cochabamba', -17.389500, -66.156800, 2),
    'Nuestra Señora de La Paz': ('La Paz', 'la-paz', -16.500000, -68.150000, 3),
    'El Alto': ('El Alto', 'el-alto', -16.504700, -68.163300, 4),
    'Sucre': ('Sucre', 'sucre', -19.033300, -65.262700, 5),
    'Oruro': ('Oruro', 'oruro', -17.966700, -67.116700, 6),
    'Potosí': ('Potosí', 'potosi', -19.583600, -65.753100, 7),
    'Tarija': ('Tarija', 'tarija', -21.535500, -64.729600, 8),
    'Trinidad': ('Trinidad', 'trinidad', -14.833300, -64.900000, 9),
    'Cobija': ('Cobija', 'cobija', -11.026700, -68.769200, 10),
}


def slugify(s):
    s = unicodedata.normalize('NFKD', s).encode('ascii', 'ignore').decode()
    return re.sub(r'[^a-z0-9]+', '-', s.lower()).strip('-')


def polygons(geom):
    return [geom['coordinates']] if geom['type'] == 'Polygon' else geom['coordinates']


def in_ring(x, y, ring):
    inside = False
    j = len(ring) - 1
    for i in range(len(ring)):
        xi, yi = ring[i][:2]
        xj, yj = ring[j][:2]
        if (yi > y) != (yj > y) and x < (xj - xi) * (y - yi) / (yj - yi) + xi:
            inside = not inside
        j = i
    return inside


def in_geom(x, y, geom):
    return any(in_ring(x, y, p[0]) and not any(in_ring(x, y, h) for h in p[1:]) for p in polygons(geom))


def ring_area_centroid(ring):
    a = cx = cy = 0.0
    for i in range(len(ring) - 1):
        x0, y0 = ring[i][:2]
        x1, y1 = ring[i + 1][:2]
        f = x0 * y1 - x1 * y0
        a += f
        cx += (x0 + x1) * f
        cy += (y0 + y1) * f
    a /= 2
    return abs(a), (cx / (6 * a), cy / (6 * a)) if a else ring[0][:2]


def interior_point(geom):
    outer = max((p[0] for p in polygons(geom)), key=lambda r: ring_area_centroid(r)[0])
    _, (cx, cy) = ring_area_centroid(outer)
    if in_geom(cx, cy, geom):
        return cx, cy
    xs = [p[0] for p in outer]
    ys = [p[1] for p in outer]
    best = None
    n = 60
    for i in range(1, n):
        for j in range(1, n):
            x = min(xs) + (max(xs) - min(xs)) * i / n
            y = min(ys) + (max(ys) - min(ys)) * j / n
            if in_geom(x, y, geom):
                d = (x - cx) ** 2 + (y - cy) ** 2
                if best is None or d < best[0]:
                    best = (d, x, y)
    return best[1], best[2]


def containing(x, y, features):
    for f in features:
        if in_geom(x, y, f['geometry']):
            return f['properties']['shapeName']
    # Puntos en el borde: el más cercano por centroide.
    return min(features, key=lambda f: sum((a - b) ** 2 for a, b in zip(interior_point(f['geometry']), (x, y))))[
        'properties']['shapeName']


def main(adm1, adm2, adm3):
    deps = json.load(open(adm1))['features']
    provs = json.load(open(adm2))['features']
    munis = json.load(open(adm3))['features']
    rows = []
    for f in munis:
        name = f['properties']['shapeName'].strip()
        x, y = interior_point(f['geometry'])
        dep = DEPARTMENTS[containing(x, y, deps)]
        prov = containing(x, y, provs)
        if name in KNOWN:
            label, slug, lat, lng, order = KNOWN[name]
        else:
            label, slug, lat, lng, order = name, f'{slugify(name)}-{CODES[dep]}', round(y, 6), round(x, 6), 100
        rows.append((order, dep, slugify(label), label, prov, slug, lat, lng))
    rows.sort()
    assert len({r[5] for r in rows}) == len(rows), 'slug repetido'
    w = csv.writer(sys.stdout, lineterminator='\n')
    w.writerow(['department_id', 'province', 'name', 'slug', 'latitude', 'longitude', 'sort_order'])
    for order, dep, _, label, prov, slug, lat, lng in rows:
        w.writerow([dep, prov, label, slug, f'{lat:.6f}', f'{lng:.6f}', order])


if __name__ == '__main__':
    main(*sys.argv[1:4])
