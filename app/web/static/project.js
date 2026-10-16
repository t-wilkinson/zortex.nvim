// zortex serve project page (-writable): tick tasks (POST /api/edit, which
// keeps calendar copies in step) and add a line to the project's log
// (POST /api/project/log); the page reloads with the result.
(function () {
  "use strict";
  var base = document.body.dataset.base || "";
  var page = document.querySelector(".project-page");
  if (!page) return;
  var rel = page.dataset.rel;

  function post(path, body) {
    return fetch(base + path, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    }).then(function (r) {
      return r.json().then(function (b) { return { ok: r.ok, body: b }; });
    });
  }

  page.addEventListener("click", function (ev) {
    var btn = ev.target.closest("button.pcheck");
    if (!btn) return;
    btn.disabled = true;
    post("/api/edit", { rel: rel, lnum: Number(btn.dataset.lnum), expect: btn.dataset.expect, op: "toggle" })
      .then(function (res) {
        if (!res.ok) { alert(res.body.error || "Could not change the task"); }
        location.reload();
      })
      .catch(function () { btn.disabled = false; });
  });

  var form = document.getElementById("log-form");
  if (form) {
    form.addEventListener("submit", function (ev) {
      ev.preventDefault();
      var text = form.elements.text.value.trim();
      if (!text) return;
      var status = document.getElementById("log-status");
      post("/api/project/log", { rel: rel, lnum: Number(page.dataset.lnum), expect: page.dataset.expect, text: text })
        .then(function (res) {
          if (res.ok) { location.reload(); return; }
          status.textContent = res.body.error || "Could not add it";
        })
        .catch(function () { status.textContent = "Could not reach the server"; });
    });
  }
})();
