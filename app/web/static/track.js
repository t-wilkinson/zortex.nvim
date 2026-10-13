// zortex serve home page: "Working on", the task the clocks' time goes to
// (/api/track). The server counts while a clock runs and adds the time to
// the task's @spent(...) when the clocks stop or the task changes.
(function () {
  "use strict";
  var base = document.body.dataset.base || "";
  var $ = function (id) { return document.getElementById(id); };
  var box = $("track");
  if (!box) return;
  var esc = function (s) { return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;"); };
  var pad = function (n) { return String(n).padStart(2, "0"); };

  var st = null, at = 0;

  function hm(min) {
    min = Math.round(min);
    var h = Math.floor(min / 60), m = min % 60;
    return h ? h + "h" + (m ? " " + m + "m" : "") : m + "m";
  }
  function clock(ms) {
    var s = Math.max(0, Math.floor(ms / 1000)), h = Math.floor(s / 3600), m = Math.floor(s % 3600 / 60);
    return (h ? h + ":" + pad(m) : String(m)) + ":" + pad(s % 60);
  }

  function api(path, body) {
    var opts = body === undefined ? { cache: "no-store" } :
      { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body || {}) };
    return fetch(base + path, opts).then(function (r) { return r.json(); });
  }

  function set(state) {
    st = state;
    at = Date.now();
    render();
  }
  function load() { return api("/api/track").then(set).catch(function () {}); }

  function taskHTML(t) {
    var text = t.html || esc(t.text);
    return '<a class="track-link" href="' + esc(t.url) + '">' + (t.done ? "☑ " : "") + text + "</a>";
  }

  function counted() {
    if (!st) return 0;
    return st.counted_ms + (st.counting ? Date.now() - at : 0);
  }

  function render() {
    if (!st || !st.enabled) { box.hidden = true; return; }
    box.hidden = false;
    var t = st.task;
    $("track-task").innerHTML = t ? taskHTML(t) :
      st.mode === "off" ? '<span class="dim">nothing: time isn\'t tracked</span>' :
      '<span class="dim">no calendar entry now</span>';
    var note = [];
    if (t) {
      note.push(st.mode === "calendar" ? "from the calendar" : "picked");
      if (t.where) note.push(esc(t.where));
      if (t.spent_min) note.push(hm(t.spent_min) + " logged");
    }
    if (st.mode !== "calendar" && st.calendar) note.push('calendar: ' + esc(st.calendar.text));
    if (st.error) note.push('<span class="bad">' + esc(st.error) + "</span>");
    $("track-note").innerHTML = note.join(" · ");
    tick();
  }

  function tick() {
    if (!st || !st.enabled) return;
    var ms = counted(), el = $("track-time");
    if (!st.task) { el.textContent = ""; return; }
    if (st.counting) {
      el.textContent = "+" + clock(ms);
      el.className = "track-time on";
      el.title = "Counting while a clock runs";
    } else if (ms > 0) {
      el.textContent = "+" + clock(ms) + " paused";
      el.className = "track-time";
      el.title = ms < st.min_write * 1000 ? "Under a minute: logged once it reaches one" : "Logged when the clocks stop";
    } else {
      el.textContent = "";
      el.className = "track-time";
    }
  }

  // ---------------------------------------------------------------------------
  // Picker
  // ---------------------------------------------------------------------------
  var picker = $("track-picker"), q = $("track-q"), results = $("track-results"), btn = $("track-change");
  var seq = 0, timer = null;

  function open(on) {
    picker.hidden = !on;
    btn.setAttribute("aria-expanded", String(on));
    btn.textContent = on ? "Close" : "Change";
    if (on) { q.value = ""; search(); q.focus(); }
  }
  btn.addEventListener("click", function () { open(picker.hidden); });

  function search() {
    var mine = ++seq;
    api("/api/track/tasks?q=" + encodeURIComponent(q.value)).then(function (res) {
      if (mine !== seq) return;
      var html = "";
      if (st && st.mode !== "calendar") {
        html += '<li><button type="button" data-mode="follow"><span class="what">Follow the calendar</span>' +
          (st.calendar ? '<span class="small dim">now: ' + esc(st.calendar.text) + "</span>" : '<span class="small dim">no entry right now</span>') + "</button></li>";
      }
      if (st && st.mode !== "off") {
        html += '<li><button type="button" data-mode="off"><span class="what">Don\'t track</span><span class="small dim">time goes nowhere</span></button></li>';
      }
      (res.tasks || []).forEach(function (t) {
        html += '<li><button type="button" data-rel="' + esc(t.rel) + '" data-lnum="' + t.lnum + '"' + (t.current ? ' aria-current="true"' : "") + ">" +
          '<span class="what">' + esc(t.text) + "</span>" +
          '<span class="small dim">' + esc(t.where) + (t.spent_min ? " · " + hm(t.spent_min) : "") + "</span></button></li>";
      });
      if (!res.tasks || !res.tasks.length) html += '<li class="empty dim">No open tasks match.</li>';
      else if (res.more) html += '<li class="empty dim small">More match: type more words.</li>';
      results.innerHTML = html;
    }).catch(function () {});
  }
  q.addEventListener("input", function () { clearTimeout(timer); timer = setTimeout(search, 150); });
  q.addEventListener("keydown", function (ev) {
    if (ev.key === "Escape") { open(false); btn.focus(); }
    if (ev.key === "ArrowDown") { var first = results.querySelector("button"); if (first) { ev.preventDefault(); first.focus(); } }
  });
  results.addEventListener("keydown", function (ev) {
    var b = ev.target.closest("button");
    if (!b) return;
    var all = Array.prototype.slice.call(results.querySelectorAll("button")), i = all.indexOf(b);
    if (ev.key === "ArrowDown" && all[i + 1]) { ev.preventDefault(); all[i + 1].focus(); }
    if (ev.key === "ArrowUp") { ev.preventDefault(); (all[i - 1] || q).focus(); }
    if (ev.key === "Escape") { open(false); btn.focus(); }
  });
  results.addEventListener("click", function (ev) {
    var b = ev.target.closest("button");
    if (!b) return;
    var req = b.dataset.mode ? api("/api/track/" + b.dataset.mode, {}) :
      api("/api/track/pin", { rel: b.dataset.rel, lnum: Number(b.dataset.lnum) });
    req.then(function (res) { set(res); open(false); }).catch(function () {});
  });

  setInterval(function () { if (!document.hidden) tick(); }, 500);
  setInterval(function () { if (!document.hidden) load(); }, 60000);
  ["zortex:track", "zortex:resync", "zortex:pomodoro", "zortex:clocks"].forEach(function (name) {
    document.addEventListener(name, load);
  });
  load();
})();
