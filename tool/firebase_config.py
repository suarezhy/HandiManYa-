#!/usr/bin/env python3
"""Convierte los valores públicos de Firebase en config/firebase-<entorno>.json.

Uso: python3 tool/firebase_config.py dev < valores.txt

Acepta el bloque "firebaseConfig = { apiKey: ..., ... }" que muestra Firebase
para cada app, o líneas CLAVE=valor. Para Android e iOS basta su appId
("1:...:android:..." / "1:...:ios:..."); la clave Web Push va como
FIREBASE_VAPID_KEY=... . Solo valores públicos: nunca la cuenta de servicio.

Para empezar solo con Android alcanzan apiKey, projectId, messagingSenderId y
el appId de Android; iPhone y web se agregan después (sin ellos, esas
versiones siguen sin avisos push).
"""
import json
import re
import sys

PATTERNS = {
    'FIREBASE_API_KEY': r'AIza[0-9A-Za-z_-]{35}',
    'FIREBASE_PROJECT_ID': r'[a-z0-9-]{6,30}',
    'FIREBASE_SENDER_ID': r'\d{6,15}',
    'FIREBASE_APP_ID_ANDROID': r'1:\d{6,15}:android:[0-9a-f]{6,}',
    'FIREBASE_APP_ID_IOS': r'1:\d{6,15}:ios:[0-9a-f]{6,}',
    'FIREBASE_APP_ID_WEB': r'1:\d{6,15}:web:[0-9a-f]{6,}',
    'FIREBASE_VAPID_KEY': r'[A-Za-z0-9_-]{80,100}',
}


def parse(text):
    if '"private_key"' in text or 'BEGIN PRIVATE KEY' in text:
        sys.exit('Esto es la cuenta de servicio (secreta). No la pegues aquí: va solo en Supabase.')
    out = {}
    for key, value in re.findall(r'(\w+)\s*[:=]\s*["\']?([^"\',\s}]+)', text):
        k = key.upper()
        if key == 'apiKey':
            out['FIREBASE_API_KEY'] = value
        elif key == 'projectId':
            out['FIREBASE_PROJECT_ID'] = value
        elif key == 'messagingSenderId':
            out['FIREBASE_SENDER_ID'] = value
        elif key == 'appId' or k.startswith('FIREBASE_APP_ID'):
            kind = re.search(r':(android|ios|web):', value)
            if kind:
                out['FIREBASE_APP_ID_' + kind.group(1).upper()] = value
        elif k in PATTERNS:
            out[k] = value
    return out


# Sin estos no hay push en ninguna versión; los demás son de iPhone y web.
REQUIRED = ('FIREBASE_API_KEY', 'FIREBASE_PROJECT_ID', 'FIREBASE_SENDER_ID', 'FIREBASE_APP_ID_ANDROID')


def check(cfg):
    problems = [f'falta {k}' for k in REQUIRED if k not in cfg]
    for k, v in cfg.items():
        if not re.fullmatch(PATTERNS[k], v):
            problems.append(f'{k} no tiene el formato esperado')
    sender = cfg.get('FIREBASE_SENDER_ID')
    for k in ('FIREBASE_APP_ID_ANDROID', 'FIREBASE_APP_ID_IOS', 'FIREBASE_APP_ID_WEB'):
        if sender and k in cfg and cfg[k].split(':')[1] != sender:
            problems.append(f'{k} es de otro proyecto (el número no coincide con FIREBASE_SENDER_ID)')
    return problems


def main():
    env = sys.argv[1] if len(sys.argv) > 1 else 'dev'
    cfg = parse(sys.stdin.read())
    problems = check(cfg)
    if problems:
        sys.exit('No se escribió nada:\n- ' + '\n- '.join(problems))
    path = f'config/firebase-{env}.json'
    with open(path, 'w') as f:
        json.dump({k: cfg[k] for k in PATTERNS if k in cfg}, f, indent=2)
        f.write('\n')
    print(f'Listo: {path}')
    missing = [k for k in PATTERNS if k not in cfg]
    if missing:
        print('Sin push todavía en iPhone o web (faltan: ' + ', '.join(missing) + ').')


if __name__ == '__main__':
    main()
