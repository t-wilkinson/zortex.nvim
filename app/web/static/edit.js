// zortex serve -writable: edit a note from the browser.
//   checkbox            toggle the task (open <-> done), as Neovim does it
//   Edit                tap a line for: To-do · Done · Plain · Edit text · Add below · Delete
// Every request names the line it expects; if the note changed elsewhere the
// server refuses and sends the current note, which replaces the page's copy.
(function () {
  "use strict";
  var body = document.getElementById("note-body");
  var srcEl = document.getElementById("note-src");
  if (!body || !srcEl) return;
  var base = document.body.dataset.base || "";
  var rel = body.dataset.rel;
  var src = [];
  try { src = JSON.parse(srcEl.textContent || "[]"); } catch (e) { src = []; }
  var toggleBtn = document.getElementById("edit-toggle");
  var statusEl = document.getElementById("edit-status");
  var editing = false, bar = null, busy = false;

  function say(msg, bad) {
    if (!statusEl) return;
    statusEl.textContent = msg || "";
    statusEl.hidden = !msg;
    statusEl.classList.toggle("bad", !!bad);
    if (msg && !bad) setTimeout(function () { if (statusEl.textContent === msg) say(""); }, 2500);
  }

  function lineEl(n) { return document.getElementById("L" + n); }
  function lnumOf(el) {
    var ln = el && el.closest("[id^='L']");
    if (!ln || !body.contains(ln)) return 0;
    var n = parseInt(ln.id.slice(1), 10);
    return isNaN(n) ? 0 : n;
  }
  function info(n) { return src[n - 1]; }
  function isTask(t) { return /^\s*(?:[-*+]\s+)?(?:[A-Za-z0-9_]+:\s*)?\[.\]/.test(t); }
  function isDone(t) { return /^\s*(?:[-*+]\s+)?(?:[A-Za-z0-9_]+:\s*)?\[[xX]\]/.test(t); }
  function isStructural(t) { return /^#+\s|^\*\*.*:\*\*\s*$|^@/.test(t); }

  function apply(res, lnum) {
    if (res.body != null) body.innerHTML = res.body;
    if (res.src) src = res.src;
    closeBar();
    if (editing) markEditable();
    var el = lnum && lineEl(lnum);
    if (el) {
      el.classList.add("flash");
      setTimeout(function () { el.classList.remove("flash"); }, 1200);
    }
  }

  function send(payload) {
    if (busy) return Promise.resolve();
    busy = true;
    payload.rel = rel;
    return fetch(base + "/api/edit", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    }).then(function (r) {
      return r.json().then(function (res) {
        if (r.ok) { apply(res, res.lnum); say("Saved"); }
        else if (r.status === 409) { apply(res, 0); say("The note changed elsewhere; this is the latest version. Try again.", true); }
        else say(res.error || "Couldn't save", true);
      });
    }).catch(function () { say("Server unreachable; nothing was changed", true); })
      .then(function () { busy = false; });
  }

  function edit(n, op, extra) {
    var i = info(n);
    if (!i) return;
    var p = { lnum: n, expect: i.t, op: op };
    for (var k in extra || {}) p[k] = extra[k];
    return send(p);
  }

  // Checkboxes work in and out of edit mode
  body.addEventListener("click", function (ev) {
    var box = ev.target.closest(".box");
    if (box && body.contains(box)) {
      var n = lnumOf(box);
      if (n && info(n) && info(n).e) { ev.preventDefault(); edit(n, "toggle"); }
      return;
    }
    if (!editing || ev.target.closest(".line-bar")) return;
    var n2 = lnumOf(ev.target);
    if (!n2 || !info(n2) || !info(n2).e) return;
    ev.preventDefault(); // links don't navigate while editing
    openBar(n2);
  });
  body.addEventListener("keydown", function (ev) {
    if (!editing || ev.key !== "Enter" || ev.target.closest(".line-bar")) return;
    var n = lnumOf(ev.target);
    if (n && info(n) && info(n).e) { ev.preventDefault(); openBar(n); }
  });

  function markEditable() {
    body.querySelectorAll("[id^='L']").forEach(function (el) {
      var i = info(lnumOf(el));
      if (i && i.e && el.classList.contains("ln")) el.setAttribute("tabindex", "0");
    });
  }
  function unmarkEditable() {
    body.querySelectorAll("[tabindex='0']").forEach(function (el) { el.removeAttribute("tabindex"); });
  }

  if (toggleBtn) {
    toggleBtn.addEventListener("click", function () {
      editing = !editing;
      body.classList.toggle("editing", editing);
      toggleBtn.setAttribute("aria-pressed", String(editing));
      toggleBtn.textContent = editing ? "Done editing" : "Edit";
      if (editing) { markEditable(); say("Tap a line to change it"); }
      else { unmarkEditable(); closeBar(); say(""); }
    });
  }

  function closeBar() {
    if (bar) { bar.remove(); bar = null; }
    body.querySelectorAll(".ln.selected").forEach(function (el) { el.classList.remove("selected"); });
  }

  function button(label, title, fn, cls) {
    var b = document.createElement("button");
    b.type = "button";
    b.textContent = label;
    if (title) b.title = title;
    if (cls) b.className = cls;
    b.addEventListener("click", fn);
    return b;
  }

  function openBar(n) {
    closeBar();
    var el = lineEl(n), i = info(n);
    if (!el || !i) return;
    el.classList.add("selected");
    bar = document.createElement("div");
    bar.className = "line-bar";
    bar.setAttribute("role", "toolbar");
    bar.setAttribute("aria-label", "Line " + n);
    var t = i.t, blank = !t.trim(), structural = isStructural(t);
    if (!blank && !structural) {
      if (!isTask(t) || isDone(t)) bar.appendChild(button("☐ To-do", "An open task", function () { edit(n, "open"); }));
      if (!isDone(t)) bar.appendChild(button("☑ Done", "Completed today", function () { edit(n, "done"); }));
      if (isTask(t)) bar.appendChild(button("¶ Plain", "Remove the checkbox", function () { edit(n, "text"); }));
    }
    if (!blank) bar.appendChild(button("✎ Edit", "Change the text", function () { editText(n); }));
    bar.appendChild(button("＋ Add below", "A new line after this one", function () { addBelow(n); }));
    bar.appendChild(button("Delete", "Remove the line", function () {
      if (blank || window.confirm("Delete this line?\n\n" + t.trim())) edit(n, "delete");
    }, "danger"));
    bar.appendChild(button("✕", "Close", closeBar, "close"));
    el.insertAdjacentElement("afterend", bar);
    var first = bar.querySelector("button");
    if (first) first.focus();
  }

  function inputRow(value, placeholder, kinds, onSave) {
    bar.innerHTML = "";
    var form = document.createElement("form");
    form.className = "line-form";
    var input = document.createElement("input");
    input.type = "text"; input.value = value; input.placeholder = placeholder;
    input.setAttribute("aria-label", placeholder);
    form.appendChild(input);
    var kind = null;
    if (kinds) {
      kind = document.createElement("select");
      kind.setAttribute("aria-label", "Kind");
      kinds.forEach(function (k) { var o = document.createElement("option"); o.value = k[0]; o.textContent = k[1]; kind.appendChild(o); });
      form.appendChild(kind);
    }
    var save = document.createElement("button"); save.type = "submit"; save.textContent = "Save"; save.className = "primary";
    form.appendChild(save);
    form.appendChild(button("Cancel", "", closeBar));
    form.addEventListener("submit", function (ev) {
      ev.preventDefault();
      if (!input.value.trim()) { input.focus(); return; }
      onSave(input.value, kind && kind.value);
    });
    input.addEventListener("keydown", function (ev) { if (ev.key === "Escape") closeBar(); });
    bar.appendChild(form);
    input.focus();
    input.setSelectionRange(input.value.length, input.value.length);
  }

  function editText(n) {
    var i = info(n);
    // @id and @done are kept by the server; don't make them editable
    var text = i.t.slice(i.c).replace(/\s*@(?:id|done)\([^)]*\)/g, "").replace(/\s+$/, "");
    inputRow(text, "Text", null, function (v) { edit(n, "set", { text: v }); });
  }

  function addBelow(n) {
    inputRow("", "New line", [["task", "Task"], ["note", "Note"], ["text", "Text"]], function (v, kind) {
      edit(n, "insert", { text: v, kind: kind });
    });
  }

  document.addEventListener("keydown", function (ev) { if (ev.key === "Escape" && bar) closeBar(); });
})();
