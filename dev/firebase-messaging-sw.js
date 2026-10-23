// Avisos push en la web (Firebase Cloud Messaging). La app lo registra junto
// a sí misma con la configuración pública del proyecto en la dirección
// (firebase-messaging-sw.js?apiKey=...&projectId=...). Sin configuración no
// hace nada. Al tocar un aviso se abre la app.
const params = new URL(self.location.href).searchParams;
const config = {
  apiKey: params.get('apiKey'),
  projectId: params.get('projectId'),
  messagingSenderId: params.get('messagingSenderId'),
  appId: params.get('appId'),
};

if (config.apiKey && config.projectId && config.messagingSenderId && config.appId) {
  // La misma versión del SDK de Firebase que usa FlutterFire (firebase_core_web).
  importScripts('https://www.gstatic.com/firebasejs/13.1.0/firebase-app-compat.js');
  importScripts('https://www.gstatic.com/firebasejs/13.1.0/firebase-messaging-compat.js');
  firebase.initializeApp(config);
  // Los mensajes con "notification" los muestra Firebase solo.
  firebase.messaging();
}

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const url = new URL('./', self.location.href).href;
  event.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((list) => {
      for (const c of list) {
        if (c.url.startsWith(url) && 'focus' in c) return c.focus();
      }
      return self.clients.openWindow(url);
    }),
  );
});
