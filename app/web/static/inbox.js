// zortex serve: the inbox capture box (#inbox-form, on the home page and on
// /offline), which keeps working without a connection.
//
// A capture that can't reach the server (offline, the network failed, or a
// proxy answered 502/503/504 for a server that is down) is kept in this
// browser's localStorage and sent when the connection is back: on load, on
// the "online" event, when the tab is shown again, and every 30 seconds while
// anything is waiting. The server appends each one to the bottom of
// inbox.zortex, in the order they were captured. Each capture carries an id,
// so one whose answer was lost and is sent again is added once (edit.go).
(function () {
  "use strict";
  var base = document.body.dataset.base || "";
  var KEY = "zortex-inbox-queue:" + (base || "/");
  var form = document.getElementById("inbox-form");
  var status = document.getElementById("inbox-status");

  function esc(s) {
    return String(s).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }

  // the queue: [{id, text, kind, at}], oldest first. Storage can be missing
  // or throw (private windows, blocked site data): then nothing is kept and
  // a failed capture stays in the box with an error instead.
  function load() {
    try {
      var q = JSON.parse(localStorage.getItem(KEY) || "[]");
      return Array.isArray(q) ? q : [];
    } catch (e) { return []; }
  }
  function save(q) {
    try {
      if (q.length) localStorage.setItem(KEY, JSON.stringify(q));
      else localStorage.removeItem(KEY);
      return true;
    } catch (e) { return false; }
  }
  function newID() {
    if (window.crypto && crypto.randomUUID) return crypto.randomUUID();
    return Date.now().toString(36) + "-" + Math.random().toString(36).slice(2, 10);
  }

  function say(html, cls) {
    if (!status) return;
    status.innerHTML = html;
    status.className = "small" + (cls ? " " + cls : "");
  }
  function sayWaiting() {
    var n = load().length;
    if (n) say(n + (n === 1 ? " capture" : " captures") + " saved offline; added to the inbox when you're back online", "dim");
  }

  // send one capture. Resolves to "ok", "retry" (unreachable: keep it) or
  // "drop" (the server refused it for good, e.g. empty text), with the
  // server's answer.
  function send(item) {
    return fetch(base + "/api/inbox", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ text: item.text, kind: item.kind, id: item.id }),
      credentials: "same-origin",
    }).then(function (r) {
      return r.json().catch(function () { return {}; }).then(function (x) {
        if (r.ok) return { result: "ok", x: x };
        // a proxy in front of a server that is down; a login that expired
        if (r.status >= 502 && r.status <= 504) return { result: "retry", x: x };
        if (r.status === 401 || r.status === 403 || r.status === 408 || r.status === 429 || r.status >= 500) return { result: "retry", x: x, error: x.error };
        return { result: "drop", x: x, error: x.error || "refused (" + r.status + ")" };
      });
    }, function () { return { result: "retry" }; });
  }

  var flushing = false;
  function flush() {
    if (flushing || !load().length || navigator.onLine === false) return Promise.resolve();
    flushing = true;
    var added = 0, last = null, dropped = [];
    function next() {
      var q = load();
      if (!q.length) return Promise.resolve();
      var item = q[0];
      return send(item).then(function (res) {
        if (res.result === "retry") {
          if (res.error) say("Couldn't add the saved captures yet: " + esc(res.error), "bad");
          return;
        }
        // take it off the front (another tab may have changed the queue)
        save(load().filter(function (x) { return x.id !== item.id; }));
        if (res.result === "ok") { added++; last = res.x; } else dropped.push(item.text + " (" + res.error + ")");
        return next();
      });
    }
    return next().then(function () {
      flushing = false;
      if (dropped.length) say("Not added: " + esc(dropped.join("; ")), "bad");
      else if (added && !load().length) {
        say("Added " + added + " saved " + (added === 1 ? "capture" : "captures") + " to the " +
          (last && last.url ? '<a href="' + esc(last.url) + '">inbox</a>' : "inbox"));
      } else sayWaiting();
    }, function () { flushing = false; });
  }

  if (form) {
    form.addEventListener("submit", function (ev) {
      ev.preventDefault();
      var text = form.elements.text.value.trim();
      if (!text) return;
      var checked = form.querySelector("input[name=kind]:checked");
      var item = { id: newID(), text: text, kind: checked ? checked.value : "note", at: new Date().toISOString() };
      var keep = function () {
        var q = load();
        q.push(item);
        if (!save(q)) { say("Offline, and this browser can't keep it: try again when you're back online", "bad"); return; }
        form.elements.text.value = "";
        sayWaiting();
      };
      // anything already waiting goes first, so the inbox keeps their order
      if (navigator.onLine === false || load().length) { keep(); flush(); return; }
      say("Adding…", "dim");
      send(item).then(function (res) {
        if (res.result === "ok") {
          form.elements.text.value = "";
          say('Added to <a href="' + esc(res.x.url) + '">inbox</a>');
        } else if (res.result === "retry" && !res.error) keep();
        else say(esc(res.error || "Couldn't add"), "bad");
      });
    });
    // the "Add to inbox" shortcut of the installed app (pwa.go)
    if (location.hash === "#inbox") form.elements.text.focus();
  }

  window.addEventListener("online", flush);
  document.addEventListener("visibilitychange", function () { if (!document.hidden) flush(); });
  document.addEventListener("zortex:resync", flush);
  setInterval(function () { if (!document.hidden && load().length) flush(); }, 30000);
  sayWaiting();
  flush();
})();
