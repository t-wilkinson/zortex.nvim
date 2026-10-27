// zortex serve: the reviews' fixes (/review, -writable). Each button or form
// carries what its POST needs (data-act, data-rel, data-lnum, data-line: the
// line as the page saw it); on success the page reloads where it was, so
// the lists show the notes as they are now. A note that changed since the
// page loaded is refused (409) and the page says to reload.
(function () {
  "use strict";
  var base = document.body.dataset.base || "";
  var page = document.querySelector(".review-page");
  if (!page) return;
  var status = document.getElementById("rv-status");
  var KEY = "zortex-review-scroll:" + location.pathname + location.search;

  // back where it was after a reload
  try {
    var y = sessionStorage.getItem(KEY);
    if (y !== null) {
      sessionStorage.removeItem(KEY);
      window.scrollTo(0, Number(y) || 0);
    }
  } catch (e) { /* storage blocked: start at the top */ }

  function say(text, bad) {
    if (!status) return;
    status.hidden = !text;
    status.textContent = text || "";
    status.className = "rv-status small" + (bad ? " bad" : "");
  }

  function post(url, body) {
    return fetch(base + url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
      credentials: "same-origin",
    }).then(function (r) {
      return r.json().catch(function () { return {}; }).then(function (x) { return { ok: r.ok, status: r.status, x: x }; });
    });
  }

  function reload(msg) {
    say(msg || "Done");
    try { sessionStorage.setItem(KEY, String(window.scrollY)); } catch (e) { /* ignore */ }
    location.reload();
  }

  function run(el, url, body, done) {
    el.setAttribute("aria-busy", "true");
    el.querySelectorAll && el.querySelectorAll("button").forEach(function (b) { b.disabled = true; });
    if (el.tagName === "BUTTON") el.disabled = true;
    say("Saving…");
    return post(url, body).then(function (res) {
      if (res.ok && !res.x.error) return reload(done ? done(res.x) : "Done");
      el.removeAttribute("aria-busy");
      if (el.tagName === "BUTTON") el.disabled = false;
      el.querySelectorAll && el.querySelectorAll("button").forEach(function (b) { b.disabled = false; });
      say(res.status === 409 ? "The note changed since this page loaded: reload it." : (res.x.error || "Couldn't save"), true);
    }, function () {
      say("Server unreachable", true);
    });
  }

  function line(el) {
    return { rel: el.dataset.rel, lnum: Number(el.dataset.lnum), expect: el.dataset.line };
  }

  page.addEventListener("click", function (ev) {
    var b = ev.target.closest("button[data-act]");
    if (!b || b.form) return;
    var act = b.dataset.act;
    var body = line(b);
    if (act === "tick") {
      run(b, "/api/n/" + String(body.rel).split("/").map(encodeURIComponent).join("/"), { lnum: body.lnum, expect: body.expect, op: "toggle" }, function () { return "Ticked"; });
    } else if (act === "tomorrow") {
      run(b, "/api/review/tomorrow", { lnum: body.lnum, expect: body.expect }, function (x) { return "On " + (x.date || "tomorrow"); });
    } else if (act === "due") {
      var due = window.prompt("Due: YYYY-MM-DD, +N days, or tomorrow", b.dataset.due || "+7");
      if (due === null || !due.trim()) return;
      body.due = due.trim();
      run(b, "/api/review/due", body, function (x) { return "Due " + x.due; });
    } else if (act === "focus") {
      run(b, "/api/review/focus", { week: b.dataset.week, rel: body.rel, lnum: body.lnum }, function (x) {
        return x.project + (x.added ? " added to the focus" : " taken out of the focus");
      });
    } else if (act === "finish") {
      run(b, "/api/review/finish", { date: b.dataset.date }, function (x) {
        return (x.stamped ? x.stamped + " given @a(" + x.area + "), " : "") + x.date + " reviewed";
      });
    }
  });

  page.addEventListener("submit", function (ev) {
    var f = ev.target.closest("form[data-act]");
    if (!f) return;
    ev.preventDefault();
    var act = f.dataset.act;
    var body = line(f);
    if (act === "move") {
      if (!f.elements.to.value) { f.elements.to.focus(); return; }
      body.to = f.elements.to.value;
      run(f, "/api/review/move", body, function (x) { return "Moved to " + x.project; });
    } else if (act === "area") {
      if (!f.elements.area.value) { f.elements.area.focus(); return; }
      body.area = f.elements.area.value;
      run(f, "/api/review/area", body, function (x) { return "@a(" + x.area + ")"; });
    } else if (act === "note") {
      var text = f.elements.text.value.trim();
      if (!text) { f.elements.text.focus(); return; }
      run(f, "/api/review/note", { week: f.dataset.week, date: f.dataset.date, label: f.elements.label.value, text: text },
        function () { return "Written in reviews.zortex"; });
    }
  });
})();
