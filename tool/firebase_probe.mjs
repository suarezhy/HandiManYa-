// Diagnostica la clave de API de Firebase de la app Android sin un teléfono.
//
// 1. Revisa la forma de la clave (largo, prefijo AIza, espacios o saltos de
//    línea) sin mostrarla: solo dice sus 4 últimos caracteres.
// 2. Hace lo primero que hace el teléfono antes de pedir el token de avisos:
//    crea una instalación de Firebase con el mismo proyecto, ID de app,
//    paquete y huella SHA-1 que el APK de prueba, y la borra al final.
// 3. Muestra el motivo exacto que da Google (clave inválida, bloqueada para
//    Android o para este servicio, API desactivada, ID de app equivocado) y,
//    cuando Google lo dice, el número del proyecto al que pertenece la clave.
//
// Nunca muestra la clave completa ni tokens. Es gratis: Firebase
// Installations no cobra. No cambia nada en Firebase ni en Supabase (la
// instalación de prueba se borra).
//
// Variables: FIREBASE_API_KEY, FIREBASE_PROJECT_ID, FIREBASE_SENDER_ID,
// FIREBASE_APP_ID_ANDROID, ANDROID_PACKAGE, ANDROID_CERT_SHA1 y, opcional,
// FIREBASE_API_KEY_NEW (una clave nueva para comparar).
// Uso: node tool/firebase_probe.mjs
import { randomBytes } from 'node:crypto';

const project = process.env.FIREBASE_PROJECT_ID ?? '';
const sender = process.env.FIREBASE_SENDER_ID ?? '';
const appId = process.env.FIREBASE_APP_ID_ANDROID ?? '';
const pkg = process.env.ANDROID_PACKAGE ?? '';
const cert = (process.env.ANDROID_CERT_SHA1 ?? '').replace(/:/g, '').toLowerCase();
const secrets = [process.env.FIREBASE_API_KEY ?? '', process.env.FIREBASE_API_KEY_NEW ?? ''].filter(Boolean);
const hide = (s) => secrets.reduce((t, k) => t.split(k).join('***'), String(s));

// Un FID como los de Android: 22 caracteres base64url que empiezan con c, d, e o f.
function fid() {
  const b = randomBytes(17);
  b[0] = 0x70 | (b[0] & 0x0f);
  return b.toString('base64url').slice(0, 22);
}

function shape(label, key) {
  const trimmed = key.trim();
  const problems = [];
  if (key !== trimmed) problems.push('tiene espacios o saltos de línea al principio o al final');
  if (/\s/.test(trimmed)) problems.push('tiene espacios dentro');
  if (/^["']|["']$/.test(trimmed)) problems.push('tiene comillas');
  if (!trimmed.startsWith('AIza')) problems.push('no empieza con AIza');
  if (trimmed.length !== 39) problems.push(`mide ${trimmed.length} caracteres (una clave de Google mide 39)`);
  console.log(
    `${label}: existe, termina en …${trimmed.slice(-4)}` + (problems.length ? `; PROBLEMA: ${problems.join('; ')}` : '; forma correcta'),
  );
  return trimmed;
}

// El motivo que da Google, sin el texto de la clave.
function reason(body) {
  const e = body.error ?? {};
  const info = (e.details ?? []).find((d) => d.reason) ?? {};
  const meta = info.metadata ?? {};
  return {
    googleStatus: e.status ?? '',
    reason: info.reason ?? '',
    message: hide(e.message ?? ''),
    consumer: (meta.consumer ?? '').replace('projects/', ''),
    service: meta.service ?? '',
  };
}

async function install(key, headers) {
  const res = await fetch(`https://firebaseinstallations.googleapis.com/v1/projects/${project}/installations`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'x-goog-api-key': key, ...headers },
    body: JSON.stringify({ fid: fid(), appId, authVersion: 'FIS_v2', sdkVersion: 'a:18.0.0' }),
  });
  const body = await res.json().catch(() => ({}));
  if (res.ok && body.authToken?.token) {
    const del = await fetch(
      `https://firebaseinstallations.googleapis.com/v1/projects/${project}/installations/${body.fid}`,
      // Borrar se autoriza con el refreshToken de la instalación (no con el authToken).
      { method: 'DELETE', headers: { 'x-goog-api-key': key, Authorization: `FIS_v2 ${body.refreshToken}`, ...headers } },
    );
    return { status: res.status, deleted: del.status };
  }
  return { status: res.status, ...reason(body) };
}

function explain(r) {
  if (r.status === 200) return 'VÁLIDA: Firebase aceptó la clave para esta app.';
  switch (r.reason) {
    case 'API_KEY_INVALID':
      return 'INVÁLIDA: Google no reconoce esta clave (mal copiada, borrada, o de otra cuenta).';
    case 'API_KEY_ANDROID_APP_BLOCKED':
      return 'RESTRINGIDA: la clave solo acepta otra app Android (otro paquete o SHA-1).';
    case 'API_KEY_SERVICE_BLOCKED':
      return 'RESTRINGIDA: la clave no permite la API de Firebase Installations.';
    case 'API_KEY_HTTP_REFERRER_BLOCKED':
    case 'API_KEY_IP_ADDRESS_BLOCKED':
    case 'API_KEY_IOS_APP_BLOCKED':
      return `RESTRINGIDA: la clave está limitada a otro tipo de app (${r.reason}).`;
    case 'SERVICE_DISABLED':
      return 'API DESACTIVADA: la API de Firebase Installations no está activada en el proyecto de la clave.';
    case 'CONSUMER_INVALID':
      return 'PROYECTO: la clave pertenece a un proyecto que no existe o está borrado.';
    default:
      if (r.status === 400 && /app.?id|application/i.test(r.message)) return 'ID DE APP: Firebase no reconoce el ID de la app Android.';
      if (r.status === 404) return 'PROYECTO: Firebase no encuentra el proyecto con ese ID.';
      if (r.status === 403) return 'PERMISO: la clave no tiene permiso en este proyecto.';
      return 'OTRO: ver el mensaje de Google arriba.';
  }
}

async function check(label, key) {
  const k = shape(label, key);
  const asPhone = await install(k, { 'x-android-package': pkg, 'x-android-cert': cert });
  const bare = await install(k, {});
  for (const [what, r] of [
    ['como el APK de prueba (paquete + SHA-1)', asPhone],
    ['sin datos de Android', bare],
  ]) {
    const extra = r.status === 200 ? `instalación de prueba creada y borrada (HTTP ${r.deleted})` : [r.googleStatus, r.reason, r.message].filter(Boolean).join(' · ');
    console.log(`  ${what}: HTTP ${r.status} · ${extra}`);
    if (r.consumer) {
      console.log(
        `  la clave pertenece al proyecto número ${r.consumer}: ${r.consumer === sender ? 'el mismo que la app' : `DISTINTO (la app es ${sender})`}`,
      );
    }
  }
  const verdict = asPhone.status === 200 ? explain(asPhone) : bare.status === 200 ? explain({ reason: 'API_KEY_ANDROID_APP_BLOCKED' }) : explain(asPhone);
  console.log(`  RESULTADO ${label}: ${verdict}`);
  return asPhone.status === 200;
}

// La configuración pública que usa la app: proyecto, app y paquete coinciden entre sí.
console.log(`Proyecto ${project} (número ${sender}), app Android …${appId.slice(-6)}, paquete ${pkg}, SHA-1 …${cert.slice(-6)}`);
const appSender = appId.split(':')[1];
console.log(
  `El ID de la app es del proyecto número ${appSender}: ${appSender === sender ? 'coincide' : 'NO coincide'} con el de la configuración.`,
);
console.log(`El ID de la app es de Android: ${appId.includes(':android:') ? 'sí' : 'NO'}.`);

let ok = await check('FIREBASE_API_KEY (la guardada)', process.env.FIREBASE_API_KEY ?? '');
// Otra forma de preguntar, para descartar que la prueba esté mal hecha: la
// clave en la dirección (?key=) en vez del encabezado, y una API distinta.
// Con una clave que existe, Google responde otra cosa que API_KEY_INVALID
// (por ejemplo, API_KEY_SERVICE_BLOCKED si la API no está en su lista).
async function crossCheck(label, key) {
  const k = key.trim();
  const viaQuery = await fetch(
    `https://firebaseinstallations.googleapis.com/v1/projects/${project}/installations?key=${encodeURIComponent(k)}`,
    { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ fid: fid(), appId, authVersion: 'FIS_v2', sdkVersion: 'a:18.0.0' }) },
  );
  const qBody = await viaQuery.json().catch(() => ({}));
  const q = viaQuery.ok ? { status: 200 } : { status: viaQuery.status, ...reason(qBody) };
  if (viaQuery.ok && qBody.refreshToken) {
    await fetch(`https://firebaseinstallations.googleapis.com/v1/projects/${project}/installations/${qBody.fid}`, {
      method: 'DELETE',
      headers: { 'x-goog-api-key': k, Authorization: `FIS_v2 ${qBody.refreshToken}` },
    });
  }
  console.log(`  ${label}, clave en la dirección: HTTP ${q.status} ${q.reason ?? ''}`.trimEnd());
  const other = await fetch(`https://identitytoolkit.googleapis.com/v1/projects?key=${encodeURIComponent(k)}`);
  const o = other.ok ? { status: 200 } : { status: other.status, ...reason(await other.json().catch(() => ({}))) };
  console.log(
    `  ${label}, otra API de Google (Identity Toolkit): HTTP ${o.status} ${o.reason ?? ''}` +
      (o.reason === 'API_KEY_INVALID' ? ' → Google tampoco reconoce la clave ahí' : ' → Google sí reconoce la clave'),
  );
}

await crossCheck('FIREBASE_API_KEY (la guardada)', process.env.FIREBASE_API_KEY ?? '');

if (process.env.FIREBASE_API_KEY_NEW) {
  const a = (process.env.FIREBASE_API_KEY ?? '').trim();
  const b = process.env.FIREBASE_API_KEY_NEW.trim();
  const same = a === b;
  console.log(`FIREBASE_API_KEY_NEW es ${same ? 'IGUAL' : 'DISTINTA'} a la guardada.`);
  if (!same) {
    // Dónde difieren, sin mostrar ningún carácter.
    const diff = [...Array(Math.max(a.length, b.length)).keys()].filter((i) => a[i] !== b[i]);
    const sameIgnoringCase = a.toLowerCase() === b.toLowerCase();
    console.log(
      `  largo guardada ${a.length}, nueva ${b.length}; ${diff.length} posiciones distintas, la primera es la ${diff[0] + 1}` +
        (sameIgnoringCase ? '; solo cambian mayúsculas y minúsculas' : ''),
    );
  }
  await crossCheck('FIREBASE_API_KEY_NEW (la nueva)', b);
  ok = (await check('FIREBASE_API_KEY_NEW (la nueva)', process.env.FIREBASE_API_KEY_NEW)) || ok;
}
if (!ok) process.exitCode = 1;
