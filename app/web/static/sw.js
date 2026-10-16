// zortex serve: the service worker (pwa.go). Served at the app's root, so
// its scope is the whole app; registered by app.js as sw.js?v=<build>.
//
//   static files   this build's, from the cache first (their URLs carry the
//                  build, so a new build fetches new ones)
//   pages          from the network; the last MAX_PAGES you opened are kept,
//                  so they open offline as a saved copy; a page never opened
//                  shows /offline, which lists the saved ones
//   anything else  the network only: the API, live updates, edits, files
"use strict";

var VERSION = new URL(self.location.href).searchParams.get("v") || "dev";
var BASE = new URL(self.registration.scope).pathname.replace(/\/$/, "");
var STATIC = "zortex-static-" + VERSION;
var PAGES = "zortex-pages-" + VERSION;
var MAX_PAGES = 60;
var OFFLINE = BASE + "/offline";
// pages that are never kept: the API and everything that changes notes or
// streams (the network only)
var NETWORK_ONLY = /^\/(api|f|raw|notify|pending|test|sw\.js|manifest\.webmanifest)(\/|$)/;

self.addEventListener("install", function (event) {
  var core = ["style.css", "app.js", "hover.js", "live.js", "tables.js", "math.js", "icon.svg"].map(function (f) {
    return BASE + "/static/" + f + "?v=" + VERSION;
  });
  event.waitUntil(
    Promise.all([
      caches.open(STATIC).then(function (c) { return c.addAll(core); }),
      caches.open(PAGES).then(function (c) { return c.add(OFFLINE); }),
    ]).then(function () { return self.skipWaiting(); })
  );
});

self.addEventListener("activate", function (event) {
  event.waitUntil(
    caches.keys().then(function (names) {
      return Promise.all(names.map(function (n) {
        if (n.indexOf("zortex-") === 0 && n !== STATIC && n !== PAGES) return caches.delete(n);
      }));
    }).then(function () { return self.clients.claim(); })
  );
});

// Keep the newest MAX_PAGES pages (the offline page always stays).
function trim(cache) {
  return cache.keys().then(function (keys) {
    var pages = keys.filter(function (k) { return new URL(k.url).pathname !== OFFLINE; });
    var extra = pages.length - MAX_PAGES;
    return Promise.all(pages.slice(0, Math.max(0, extra)).map(function (k) { return cache.delete(k); }));
  });
}

// A saved page, marked as one: <body data-saved="when it was saved">, so the
// page can say it is a copy (app.js)
function saved(response) {
  var when = response.headers.get("X-Zortex-Saved") || "";
  return response.text().then(function (html) {
    html = html.replace("<body ", '<body data-saved="' + when.replace(/[^0-9TZ:.\-]/g, "") + '" ');
    return new Response(html, { status: 200, headers: { "Content-Type": "text/html; charset=utf-8" } });
  });
}

function fallback(request) {
  return caches.open(PAGES).then(function (cache) {
    return cache.match(request.url).then(function (hit) {
      return hit ? saved(hit) : cache.match(OFFLINE);
    });
  });
}

function page(request) {
  return fetch(request).then(function (response) {
    // behind a reverse proxy a server that is down is a 502 / 503 / 504
    if (response.status >= 502 && response.status <= 504) {
      return caches.open(PAGES).then(function (cache) { return cache.match(request.url); })
        .then(function (hit) { return hit ? saved(hit) : response; });
    }
    if (response.ok && response.type === "basic" && !/no-store/.test(response.headers.get("Cache-Control") || "")) {
      var copy = response.clone();
      caches.open(PAGES).then(function (cache) {
        return copy.blob().then(function (body) {
          var headers = new Headers(copy.headers);
          headers.set("X-Zortex-Saved", new Date().toISOString());
          // re-adding moves it to the end: newest last
          return cache.delete(request.url).then(function () {
            return cache.put(request.url, new Response(body, { status: copy.status, headers: headers }));
          });
        }).then(function () { return trim(cache); });
      });
    }
    return response;
  }).catch(function () {
    return fallback(request);
  });
}

function asset(request) {
  return caches.open(STATIC).then(function (cache) {
    return cache.match(request).then(function (hit) {
      return hit || fetch(request).then(function (response) {
        if (response.ok) cache.put(request, response.clone());
        return response;
      });
    });
  });
}

self.addEventListener("fetch", function (event) {
  var request = event.request;
  if (request.method !== "GET") return;
  var url = new URL(request.url);
  if (url.origin !== self.location.origin || url.pathname.indexOf(BASE + "/") !== 0) return;
  var path = url.pathname.slice(BASE.length);
  if (NETWORK_ONLY.test(path)) return;
  if (path.indexOf("/static/") === 0) {
    event.respondWith(asset(request));
  } else if (request.mode === "navigate") {
    event.respondWith(page(request));
  }
});
