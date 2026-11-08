// Eli M. Nails — Service Worker mínimo
// Estrategia: red primero (siempre fresca), cache como respaldo sin conexión.
const CACHE = 'eli-nails-v1';

self.addEventListener('install', function(evento) {
    self.skipWaiting();
});

self.addEventListener('activate', function(evento) {
    evento.waitUntil(
        caches.keys().then(function(claves) {
            return Promise.all(claves.map(function(clave) {
                if (clave !== CACHE) return caches.delete(clave);
            }));
        }).then(function() { return self.clients.claim(); })
    );
});

self.addEventListener('fetch', function(evento) {
    if (evento.request.method !== 'GET') return;
    if (evento.request.url.indexOf(self.location.origin) !== 0) return;

    evento.respondWith(
        fetch(evento.request).then(function(respuesta) {
            if (respuesta && respuesta.ok) {
                const copia = respuesta.clone();
                caches.open(CACHE).then(function(cache) {
                    cache.put(evento.request, copia).catch(function() {});
                });
            }
            return respuesta;
        }).catch(function() {
            return caches.match(evento.request).then(function(cacheada) {
                return cacheada || caches.match('./');
            });
        })
    );
});