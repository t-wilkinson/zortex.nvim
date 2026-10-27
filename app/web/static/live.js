// zortex serve: live updates. /api/events tells open pages what changed
// (a note synced from Neovim, an edit in another tab, a new XP summary, the
// pomodoro clock); pages listen for "zortex:<kind>" events on document.
// A note page redraws its note in place, keeping the scroll position.
(function () {
  "use strict";
  var base = document.body.dataset.base || "";

  function emit(kind, detail) {
    document.dispatchEvent(new CustomEvent("zortex:" + kind, { detail: detail || {} }));
  }

  // One id per tab, so the server can send a page from Neovim to the tab
  // focused last (open.go) instead of Neovim opening a new one.
  var clientId = (function () {
    var id = "";
    try { id = sessionStorage.getItem("zortex-client") || ""; } catch (e) { /* private mode */ }
    if (!id) {
      id = Math.random().toString(36).slice(2) + Date.now().toString(36);
      try { sessionStorage.setItem("zortex-client", id); } catch (e) { /* ignore */ }
    }
    return id;
  })();
  function post(path, body) {
    return fetch(base + path, {
      method: "POST", keepalive: true,
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    }).catch(function () {});
  }
  function presence() { post("/api/presence", { client: clientId }); }
  window.addEventListener("focus", presence);

  // Neovim asked this tab to show a page: answer, then go there (or, on
  // this page already, to the line or tag index chip)
  function openFromNeovim(data) {
    if (!data || typeof data.path !== "string" || data.path.charAt(0) !== "/" || data.path.charAt(1) === "/") return;
    post("/api/open/ack", { token: data.token }).then(function () {
      var target = new URL(base + data.path, location.href);
      if (target.origin !== location.origin) return;
      try { window.focus(); } catch (e) { /* browsers mostly ignore this */ }
      if (target.pathname === location.pathname && target.search === location.search) {
        if (target.hash && target.hash !== location.hash) location.hash = target.hash;
        else if (target.hash) {
          var el = document.getElementById(decodeURIComponent(target.hash.slice(1)));
          if (el) el.scrollIntoView({ block: "start" });
        }
        return;
      }
      location.assign(target.href);
    });
  }

  var es = null, failures = 0, wasOpen = false;
  function connect() {
    if (!window.EventSource) return;
    es = new EventSource(base + "/api/events?client=" + encodeURIComponent(clientId));
    es.onopen = function () {
      // after a dropped connection, anything may have changed meanwhile
      if (wasOpen || failures) emit("resync");
      wasOpen = true;
      failures = 0;
      if (document.hasFocus()) presence();
    };
    es.addEventListener("open", function (ev) {
      var data = null;
      try { data = JSON.parse(ev.data || "null"); } catch (e) { /* ignore */ }
      openFromNeovim(data);
    });
    es.onerror = function () {
      failures++;
      // the browser retries on its own; give up on a proxy that won't stream
      if (failures > 20) { es.close(); es = null; }
    };
    ["notes", "xp", "pomodoro", "clocks", "track"].forEach(function (kind) {
      es.addEventListener(kind, function (ev) {
        var data = {};
        try { data = JSON.parse(ev.data || "{}"); } catch (e) { /* ignore */ }
        emit(kind, data);
      });
    });
  }
  connect();
  document.addEventListener("visibilitychange", function () {
    if (document.visibilityState !== "visible") return;
    presence();
    if (!es) connect();
    emit("resync");
  });
  window.addEventListener("pagehide", function () { if (es) es.close(); });

  // ---------------------------------------------------------------------------
  // The note on this page
  // ---------------------------------------------------------------------------
  var body = document.getElementById("note-body");
  if (!body || !body.dataset.rel) return;
  var rel = body.dataset.rel;
  var waiting = false, checking = false;

  function editor() { return window.zortexEditor; }

  function check() {
    var ed = editor();
    if (ed && !ed.idle()) { waiting = true; return; }
    if (checking) { waiting = true; return; }
    checking = true; waiting = false;
    fetch(base + "/api/n/" + String(rel).split("/").map(encodeURIComponent).join("/"), { cache: "no-store" })
      .then(function (r) { return r.ok ? r.json() : null; })
      .then(function (res) {
        if (!res || String(res.mod) === body.dataset.mod) return;
        var ed2 = editor();
        if (ed2) {
          if (!ed2.idle()) { waiting = true; return; }
          ed2.replace(res);
        } else {
          body.innerHTML = res.body;
          body.dataset.mod = String(res.mod);
        }
        emit("note-updated", { rel: rel });
      })
      .catch(function () {})
      .then(function () {
        checking = false;
        if (waiting) setTimeout(check, 800);
      });
  }

  document.addEventListener("zortex:notes", function (ev) {
    var rels = (ev.detail && ev.detail.rels) || [];
    if (rels.indexOf(rel) >= 0) check();
  });
  document.addEventListener("zortex:resync", check);
  // the editor says it's idle again (toolbar closed, drag ended, saved)
  document.addEventListener("zortex:editor-idle", function () { if (waiting) check(); });
})();
