// zortex serve -writable: edit a note from the browser.
//   checkbox            toggle the task (open <-> done), as Neovim does it
//   Edit                tap a line for: To-do · Done · Plain · Edit text · Add below ·
//                       Move up/down · Delete; drag ⠿ to move a line (and the
//                       lines indented under it) anywhere in the note
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
  var toggles = Array.prototype.slice.call(document.querySelectorAll(".edit-toggle"));
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
    if (res.mod != null) body.dataset.mod = String(res.mod);
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
    return fetch(base + "/api/n/" + String(rel).split("/").map(encodeURIComponent).join("/"), {
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
      .then(function () { busy = false; idleSoon(); });
  }

  // live.js redraws the note when it changes elsewhere, but not under the
  // user's hands: only while no toolbar is open, nothing is dragged or saved
  function idle() { return !busy && !bar && !drag; }
  function idleSoon() {
    setTimeout(function () { if (idle()) document.dispatchEvent(new CustomEvent("zortex:editor-idle")); }, 0);
  }
  window.zortexEditor = {
    idle: idle,
    replace: function (res) { apply(res, 0); say("Updated: the note changed elsewhere"); },
  };

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
    if (!editing || ev.target.closest(".line-bar") || ev.target.closest(".grip")) return;
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
      var n = lnumOf(el), i = info(n);
      if (!i || !i.e || !el.classList.contains("ln")) return;
      el.setAttribute("tabindex", "0");
      if (movable(n) && !el.querySelector(":scope > .grip")) {
        var g = document.createElement("span");
        g.className = "grip";
        g.setAttribute("aria-hidden", "true");
        g.title = "Drag to move";
        g.textContent = "⠿";
        el.insertBefore(g, el.firstChild);
      }
    });
  }
  function unmarkEditable() {
    body.querySelectorAll("[tabindex='0']").forEach(function (el) { el.removeAttribute("tabindex"); });
    body.querySelectorAll(".grip").forEach(function (el) { el.remove(); });
  }

  // ---------------------------------------------------------------------------
  // Moving lines (the server's moveBlock decides; this mirrors it for display)
  // ---------------------------------------------------------------------------

  function width(t) {
    var w = 0;
    for (var k = 0; k < t.length && (t[k] === " " || t[k] === "\t"); k++) w += t[k] === "\t" ? 4 : 1;
    return w;
  }
  function blank(t) { return !t || !t.trim(); }
  function movable(n) {
    var i = info(n);
    return !!(i && i.e && !blank(i.t) && !isStructural(i.t.trim()));
  }
  // last line of the block starting at n: n plus the deeper-indented lines below
  function blockEnd(n) {
    var w = width(info(n).t), end = n;
    for (var k = n + 1; k <= src.length; k++) {
      var t = src[k - 1].t;
      if (blank(t)) continue;
      if (width(t) <= w) break;
      end = k;
    }
    return end;
  }
  // the line before which the block can't be dropped without changing nothing
  function noop(from, to) { return to >= from && to <= blockEnd(from) + 1; }

  function move(from, to) {
    if (noop(from, to)) return Promise.resolve();
    var i = info(from);
    return send({ lnum: from, expect: i.t, op: "move", to: to, expectTo: to <= src.length ? info(to).t : "" });
  }

  // previous / next sibling, for the toolbar's ↑ ↓ (and keyboard users)
  function upTarget(n) {
    var w = width(info(n).t);
    for (var k = n - 1; k >= 1; k--) {
      var t = info(k).t;
      if (!info(k).e) return 0;
      if (blank(t)) continue;
      if (isStructural(t.trim())) return k; // above the heading: end of the section before
      var kw = width(t);
      if (kw > w) continue;
      return kw === w && movable(k) ? k : 0;
    }
    return 0;
  }
  function downTarget(n) {
    var w = width(info(n).t);
    for (var k = blockEnd(n) + 1; k <= src.length; k++) {
      var t = info(k).t;
      if (blank(t)) continue;
      if (!info(k).e) return 0;
      if (isStructural(t.trim())) return k + 1; // first in the next section
      var kw = width(t);
      return kw === w && movable(k) ? blockEnd(k) + 1 : 0;
    }
    return 0;
  }

  var drag = null;

  function dropTargets(from) {
    // gaps a block may land in: before an editable line, or the end
    var end = blockEnd(from), out = [];
    for (var k = 1; k <= src.length + 1; k++) {
      if (k <= src.length && !info(k).e) continue;
      if (k > from && k <= end) continue;
      var el = k <= src.length ? lineEl(k) : null;
      var y;
      if (el) {
        if (!el.classList.contains("ln") || !el.getClientRects().length) continue;
        y = el.getBoundingClientRect().top + window.scrollY;
      } else {
        var last = body.lastElementChild;
        if (!last) continue;
        y = last.getBoundingClientRect().bottom + window.scrollY;
      }
      out.push({ to: k, y: y });
    }
    return out;
  }

  function startDrag(ev, n) {
    if (busy || !movable(n)) return;
    ev.preventDefault();
    closeBar();
    var end = blockEnd(n);
    drag = { from: n, end: end, targets: dropTargets(n), to: 0, y: ev.clientY, raf: 0, el: ev.target };
    try { ev.target.setPointerCapture(ev.pointerId); } catch (e) { /* not supported */ }
    for (var k = n; k <= end; k++) { var el = lineEl(k); if (el) el.classList.add("moving"); }
    drag.line = document.createElement("div");
    drag.line.className = "drop-line";
    drag.line.hidden = true;
    body.appendChild(drag.line);
    body.classList.add("dragging");
    tick();
  }

  function place() {
    var y = drag.y + window.scrollY, best = null;
    drag.targets.forEach(function (t) {
      if (!best || Math.abs(t.y - y) < Math.abs(best.y - y)) best = t;
    });
    drag.to = best && !noop(drag.from, best.to) ? best.to : 0;
    if (!drag.to) { drag.line.hidden = true; return; }
    var top = best.y - (body.getBoundingClientRect().top + window.scrollY);
    drag.line.style.top = top + "px";
    drag.line.hidden = false;
  }

  function tick() {
    if (!drag) return;
    // scroll when near the top or bottom of the window
    var edge = 56, dy = 0;
    if (drag.y < edge + (parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--top-h")) || 0)) dy = -12;
    else if (drag.y > window.innerHeight - edge) dy = 12;
    if (dy) window.scrollBy(0, dy);
    place();
    drag.raf = requestAnimationFrame(tick);
  }

  function endDrag(commit) {
    if (!drag) return;
    var d = drag;
    drag = null;
    cancelAnimationFrame(d.raf);
    d.line.remove();
    body.classList.remove("dragging");
    body.querySelectorAll(".moving").forEach(function (el) { el.classList.remove("moving"); });
    if (commit && d.to) move(d.from, d.to);
    else idleSoon();
  }

  body.addEventListener("pointerdown", function (ev) {
    var g = ev.target.closest(".grip");
    if (!editing || !g || !body.contains(g) || ev.button > 0) return;
    startDrag(ev, lnumOf(g));
  });
  body.addEventListener("pointermove", function (ev) { if (drag) { drag.y = ev.clientY; ev.preventDefault(); } });
  body.addEventListener("pointerup", function () { endDrag(true); });
  body.addEventListener("pointercancel", function () { endDrag(false); });
  document.addEventListener("keydown", function (ev) { if (drag && ev.key === "Escape") endDrag(false); });

  toggles.forEach(function (btn) {
    btn.addEventListener("click", function () {
      editing = !editing;
      body.classList.toggle("editing", editing);
      toggles.forEach(function (b) {
        b.setAttribute("aria-pressed", String(editing));
        b.textContent = editing ? "Done editing" : "Edit";
      });
      if (editing) { markEditable(); say("Tap a line to change it, drag ⠿ to move it"); }
      else { unmarkEditable(); closeBar(); say(""); }
    });
  });

  function closeBar() {
    if (bar) { bar.remove(); bar = null; idleSoon(); }
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
    if (!blank && !structural && body.dataset.track) {
      bar.appendChild(button("⏱ Track", "Count the clocks' time on this line (home page)", function () { track(n); }));
    }
    bar.appendChild(button("＋ Add below", "A new line after this one", function () { addBelow(n); }));
    if (movable(n)) {
      var up = upTarget(n), down = downTarget(n);
      var ub = button("↑", "Move up (with the lines under it)", function () { move(n, up); });
      var db = button("↓", "Move down (with the lines under it)", function () { move(n, down); });
      ub.disabled = !up; db.disabled = !down;
      ub.setAttribute("aria-label", "Move up"); db.setAttribute("aria-label", "Move down");
      bar.appendChild(ub); bar.appendChild(db);
    }
    bar.appendChild(button("Delete", "Remove the line", function () {
      if (blank || window.confirm("Delete this line?\n\n" + t.trim())) edit(n, "delete");
    }, "danger"));
    bar.appendChild(button("✕", "Close", closeBar, "close"));
    el.insertAdjacentElement("afterend", bar);
    var first = bar.querySelector("button");
    if (first) first.focus();
  }

  // time tracking: the home page's clocks count on this line from now on
  function track(n) {
    var i = info(n);
    fetch(base + "/api/track/pin", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ rel: rel, lnum: n, expect: i.t }),
    }).then(function (r) {
      return r.json().then(function (res) {
        if (r.ok && !res.error) { closeBar(); say("Tracking time on this line"); }
        else say(res.error || "Couldn't track this line", true);
      });
    }).catch(function () { say("Server unreachable", true); });
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
    form.appendChild(attrChips(input));
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

  // Attributes a tap away: each chip puts "@due()" (or "@p1") at the
  // cursor, the cursor inside its parentheses; its title says what it means
  // (static/attributes.json, the plugin's attributes_help). "@ help" opens
  // the whole list (/attributes) in a new tab, the edit kept.
  var CHIPS = ["due", "area", "size", "p", "project", "notify", "dur"];
  var helpData = null;
  function loadHelp() {
    if (helpData) return Promise.resolve(helpData);
    return fetch(base + "/static/attributes.json", { credentials: "same-origin" })
      .then(function (r) { return r.ok ? r.json() : { attributes: [] }; })
      .then(function (d) { helpData = {}; (d.attributes || []).forEach(function (a) { helpData[a.key] = a; }); return helpData; })
      .catch(function () { helpData = {}; return helpData; });
  }
  function attrChips(input) {
    var row = document.createElement("div");
    row.className = "attr-chips";
    loadHelp().then(function (help) {
      CHIPS.forEach(function (key) {
        var a = help[key] || { insert: "@" + key + "(", formats: [] };
        var b = document.createElement("button");
        b.type = "button"; b.className = "chip";
        b.textContent = a.insert.slice(-1) === "(" ? a.insert + "…)" : (key === "p" ? "@p1" : a.insert);
        b.title = (a.formats || []).join("  ") + (a.desc ? "\n" + a.desc : "");
        b.addEventListener("click", function () {
          var ins = a.insert.slice(-1) === "(" ? a.insert + ")" : (key === "p" ? "@p1" : a.insert);
          var v = input.value, at = input.selectionStart == null ? v.length : input.selectionStart;
          var pre = v.slice(0, at), post = v.slice(at);
          if (pre && !/\s$/.test(pre)) pre += " ";
          input.value = pre + ins + (post && !/^\s/.test(post) ? " " : "") + post;
          var cur = pre.length + (ins.slice(-1) === ")" ? ins.length - 1 : ins.length);
          input.focus();
          input.setSelectionRange(cur, cur);
        });
        row.appendChild(b);
      });
      var more = document.createElement("a");
      more.href = base + "/attributes"; more.target = "_blank"; more.rel = "noopener";
      more.className = "dim small"; more.textContent = "@ help";
      more.title = "Every attribute and how it is written";
      row.appendChild(more);
    });
    return row;
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
