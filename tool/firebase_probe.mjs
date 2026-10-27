// Prueba la configuración de Firebase de la app Android sin un teléfono: crea
// una instalación de Firebase (lo primero que hace el teléfono antes de pedir
// el token de avisos) con la misma clave de API, el mismo ID de app, el mismo
// paquete y la misma huella SHA-1 que el APK de prueba, y la borra al final.
// Solo muestra códigos HTTP y mensajes de error de Google; nunca la clave ni
// tokens. Es gratis: Firebase Installations no tiene costo.
//
// Variables: FIREBASE_API_KEY, FIREBASE_PROJECT_ID, FIREBASE_APP_ID_ANDROID,
// ANDROID_PACKAGE, ANDROID_CERT_SHA1 (40 hex, sin ":").
// Uso: node tool/firebase_probe.mjs
import { randomBytes } from 'node:crypto';

const key = process.env.FIREBASE_API_KEY ?? '';
const project = process.env.FIREBASE_PROJECT_ID ?? '';
const appId = process.env.FIREBASE_APP_ID_ANDROID ?? '';
const pkg = process.env.ANDROID_PACKAGE ?? '';
const cert = (process.env.ANDROID_CERT_SHA1 ?? '').replace(/:/g, '').toLowerCase();
const hide = (s) => String(s).split(key).join('***');

// Un FID como los de Android: 22 caracteres base64url que empiezan con c, d, e o f.
function fid() {
  const b = randomBytes(17);
  b[0] = 0x70 | (b[0] & 0x0f);
  return b.toString('base64url').slice(0, 22);
}

async function call(label, headers) {
  const res = await fetch(`https://firebaseinstallations.googleapis.com/v1/projects/${project}/installations`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'x-goog-api-key': key, ...headers },
    body: JSON.stringify({ fid: fid(), appId, authVersion: 'FIS_v2', sdkVersion: 'a:18.0.0' }),
  });
  const body = await res.json().catch(() => ({}));
  const err = body.error ? `${body.error.status ?? ''} ${body.error.message ?? ''}`.trim() : '';
  console.log(`${label}: HTTP ${res.status}${err ? ` · ${hide(err)}` : ' · instalación creada'}`);
  if (res.ok && body.authToken?.token) {
    const del = await fetch(
      `https://firebaseinstallations.googleapis.com/v1/projects/${project}/installations/${body.fid}`,
      { method: 'DELETE', headers: { 'x-goog-api-key': key, Authorization: `FIS_v2 ${body.authToken.token}`, ...headers } },
    );
    console.log(`  borrada: HTTP ${del.status}`);
  }
  return res.status;
}

console.log(`Proyecto ${project}, app …${appId.slice(-6)}, paquete ${pkg}, SHA-1 …${cert.slice(-6)}`);
const asPhone = await call('Como el APK de prueba (paquete + SHA-1)', {
  'x-android-package': pkg,
  'x-android-cert': cert,
});
const bare = await call('Sin datos de Android', {});
if (asPhone === 200) {
  console.log('Resultado: la configuración de Firebase es correcta para este APK.');
} else if (bare === 200) {
  console.log('Resultado: la clave funciona, pero está restringida a otra app Android (paquete o SHA-1 distintos).');
  process.exitCode = 1;
} else {
  console.log('Resultado: Firebase rechaza la clave o el ID de la app (ver el mensaje de arriba).');
  process.exitCode = 1;
}
