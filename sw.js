// Eli M. Nails — Service Worker
// Red primero; cache como respaldo. Precarga el shell para que la app abra
// sin conexión y para no devolver nunca "undefined" en respondWith (iOS muestra
// "no se puede abrir la página" en ese caso).
const CACHE = 'eli-nails-v4';
const SHELL = [
    './',
    'index.html',
    'manifest.json',
    'icon-192.png',
    'icon-512.png',
    'apple-touch-icon.png',
    'favicon-32.png'
];

// I50: permite que la pagina pida activar la version nueva
self.addEventListener('message', function (evento) {
    if (evento.data && evento.data.tipo === 'SKIP_WAITING') self.skipWaiting();
});

self.addEventListener('install', function(evento) {
    evento.waitUntil(
        caches.open(CACHE).then(function(cache) {
            return Promise.all(SHELL.map(function(ruta) {
                return cache.add(new Request(ruta, { cache: 'reload' })).catch(function() { /* seguimos */ });
            }));
        }).then(function() { return self.skipWaiting(); })
    );
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
    const peticion = evento.request;
    if (peticion.method !== 'GET') return;
    if (peticion.url.indexOf(self.location.origin) !== 0) return;

    evento.respondWith(
        fetch(peticion).then(function(respuesta) {
            if (respuesta && respuesta.ok) {
                const copia = respuesta.clone();
                caches.open(CACHE).then(function(cache) {
                    cache.put(peticion, copia).catch(function() {});
                });
            }
            return respuesta;
        }).catch(function() {
            return caches.match(peticion).then(function(cacheada) {
                if (cacheada) return cacheada;
                if (peticion.mode === 'navigate') {
                    return caches.match('./').then(function(shell) {
                        if (shell) return shell;
                        return new Response(
                            '<!doctype html><meta charset="utf-8"><title>Sin conexión</title>' +
                            '<body style="font-family:system-ui;padding:2rem;text-align:center">' +
                            '<h1>Sin conexión</h1><p>Abrí la app con internet al menos una vez.</p></body>',
                            { headers: { 'Content-Type': 'text/html; charset=utf-8' } }
                        );
                    });
                }
                return Response.error();
            });
        })
    );
});