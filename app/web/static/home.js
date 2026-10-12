// zortex serve, home page: the calendar (days of calendar.zortex plus the
// notifications scheduled from it) and the pomodoro clock shared with Neovim.
(function () {
  "use strict";
  var base = document.body.dataset.base || "";
  var $ = function (id) { return document.getElementById(id); };
  var esc = function (s) { return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;"); };
  var pad = function (n) { return String(n).padStart(2, "0"); };
  var dayKey = function (d) { return d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate()); };
  var hhmm = function (d) { return pad(d.getHours()) + ":" + pad(d.getMinutes()); };
  var offset = 0; // server clock - local clock (ms)
  var now = function () { return Date.now() + offset; };

  function api(path, opts) {
    return fetch(base + path, opts).then(function (r) {
      return r.json().then(function (body) { return { ok: r.ok, body: body }; });
    });
  }

  // ===========================================================================
  // Calendar
  // ===========================================================================

  var cal = { days: {}, loaded: {}, notifications: [], next: null };
  var shown = new Date(), selected = new Date();
  shown.setDate(1);

  function minutes(t) {
    var m = /^(\d{1,2}):(\d{2})/.exec(t || "");
    return m ? Number(m[1]) * 60 + Number(m[2]) : null;
  }

  function renderDay() {
    var list = $("event-list");
    if (!list) return;
    var key = dayKey(selected), isToday = key === dayKey(new Date(now()));
    $("day-header").textContent = isToday ? "Today" :
      selected.toLocaleDateString(undefined, { weekday: "long", month: "short", day: "numeric" });
    var entries = cal.days[key] || [];
    if (!entries.length) { list.innerHTML = '<div class="empty-day">Nothing scheduled.</div>'; return; }
    var t = new Date(now()), nowMin = t.getHours() * 60 + t.getMinutes();
    // the entry "now" falls in: the last timed one that has started
    var current = -1;
    if (isToday) entries.forEach(function (e, i) { var m = minutes(e.time); if (m !== null && m <= nowMin) current = i; });
    var html = "";
    entries.forEach(function (e, i) {
      var m = minutes(e.time);
      var past = isToday && m !== null && i < current;
      var cls = "event-item" + (past ? " past" : "") + (e.done ? " done" : "") + (i === current ? " current" : "");
      var time = e.time ? esc(e.time) + (e.end ? '<span class="end">–' + esc(e.end) + "</span>" : "") : "";
      var box = e.task ? '<span class="box ' + (e.done ? "done" : "open") + '" aria-label="' + (e.done ? "done" : "open task") + '"></span>' : "";
      var bell = e.notify ? '<span class="bell" title="notification scheduled" aria-label="notification">🔔</span>' : "";
      html += '<div class="' + cls + '" style="--depth:' + (e.depth || 0) + '">' +
        '<a class="event-time" href="' + esc(e.url) + '">' + time + "</a>" +
        '<span class="event-title">' + box + e.html + bell + "</span></div>";
      if (i === current) {
        var nextTimed = null;
        for (var j = i + 1; j < entries.length; j++) { if (minutes(entries[j].time) !== null) { nextTimed = minutes(entries[j].time); break; } }
        if (nextTimed !== null && nextTimed > m) {
          var pct = Math.max(0, Math.min(100, (nowMin - m) / (nextTimed - m) * 100));
          html += '<div class="now-row"><div class="now-track"><div class="now-fill" style="height:' + pct + '%"></div></div>' +
            '<span class="now-label">◀ ' + esc(hhmm(t)) + "</span></div>";
        }
      }
    });
    list.innerHTML = html;
  }

  function renderMonth() {
    var grid = $("calendar-days");
    if (!grid) return;
    var y = shown.getFullYear(), m = shown.getMonth();
    $("month-label").textContent = shown.toLocaleDateString(undefined, { month: "long", year: "numeric" });
    var first = new Date(y, m, 1).getDay(), count = new Date(y, m + 1, 0).getDate();
    var sel = dayKey(selected), today = dayKey(new Date(now()));
    var html = '<span class="day-cell blank"></span>'.repeat(first);
    for (var d = 1; d <= count; d++) {
      var key = dayKey(new Date(y, m, d)), busy = (cal.days[key] || []).length > 0;
      var cls = ["day-cell", busy && "has-events", key === sel && "active", key === today && "today"].filter(Boolean).join(" ");
      html += '<button type="button" class="' + cls + '" data-day="' + d + '" aria-label="' + key + (busy ? ", has entries" : "") + '">' + d + "</button>";
    }
    grid.innerHTML = html;
  }

  function monthRange(d) {
    var from = new Date(d.getFullYear(), d.getMonth(), 1), to = new Date(d.getFullYear(), d.getMonth() + 1, 0);
    return { key: dayKey(from).slice(0, 7), from: dayKey(from), to: dayKey(to) };
  }

  function loadCalendar(force) {
    if (!$("calendar-days")) return Promise.resolve();
    var r = monthRange(shown);
    var extra = monthRange(selected); // the selected day may sit in another month
    var ranges = [r];
    if (extra.key !== r.key) ranges.push(extra);
    return Promise.all(ranges.map(function (rg) {
      if (cal.loaded[rg.key] && !force) return null;
      return api("/api/calendar?from=" + rg.from + "&to=" + rg.to).then(function (res) {
        if (!res.ok) return;
        var data = res.body;
        // replace that month's days
        Object.keys(cal.days).forEach(function (k) { if (k.slice(0, 7) === rg.key) delete cal.days[k]; });
        Object.keys(data.days || {}).forEach(function (k) { cal.days[k] = data.days[k]; });
        cal.loaded[rg.key] = true;
        cal.notifications = data.notifications || [];
        cal.next = data.next_time ? { time: data.next_time, text: data.next_event } : null;
        var stats = $("cal-stats");
        if (stats && data.notes_enabled) {
          stats.textContent = data.count + " pending notification" + (data.count === 1 ? "" : "s") +
            " · next: " + data.next_event + (data.ntfy ? " · via ntfy" : " · ntfy off");
        }
      });
    })).then(function () { renderDay(); renderMonth(); renderPomodoro(); });
  }

  var days = $("calendar-days");
  if (days) {
    days.addEventListener("click", function (ev) {
      var b = ev.target.closest("button[data-day]");
      if (!b) return;
      selected = new Date(shown.getFullYear(), shown.getMonth(), Number(b.dataset.day));
      renderDay(); renderMonth();
    });
    document.querySelectorAll("[data-month]").forEach(function (b) {
      b.addEventListener("click", function () {
        shown.setMonth(shown.getMonth() + Number(b.dataset.month));
        renderMonth();
        loadCalendar(false);
      });
    });
    $("cal-today").addEventListener("click", function () {
      selected = new Date(now()); shown = new Date(now()); shown.setDate(1);
      loadCalendar(false);
    });
  }

  // ===========================================================================
  // Pomodoro
  // ===========================================================================

  var pomo = null; // last state from the server
  var pomoAt = 0;  // local time it arrived

  function fmt(sec) {
    sec = Math.max(0, Math.round(sec));
    var h = Math.floor(sec / 3600), m = Math.floor(sec % 3600 / 60), s = sec % 60;
    return (h ? h + ":" + pad(m) : pad(m)) + ":" + pad(s);
  }

  function remaining() {
    if (!pomo) return 0;
    if (!pomo.running) return pomo.remaining;
    return Math.max(0, (Date.parse(pomo.ends_at) - now()) / 1000);
  }

  function renderPomodoro() {
    if (!$("pomo") || !pomo) return;
    var phase = pomo.phase, rem = remaining();
    var waiting = phase !== "idle" && !pomo.started;
    var paused = phase !== "idle" && pomo.started && !pomo.running;
    var label = phase === "idle" ? "Idle" : pomo.phase_name + (paused ? " · paused" : waiting ? " · ready" : "");
    var pill = $("pomo-phase");
    pill.textContent = label;
    pill.dataset.phase = phase;
    $("pomo-time").textContent = phase === "idle" ? fmt(pomo.settings.work * 60) : fmt(rem);
    var frac = phase === "idle" || !pomo.duration ? 0 : 1 - rem / pomo.duration;
    $("pomo-ring").setAttribute("stroke-dashoffset", String(100 - frac * 100));
    $("pomo-ring").dataset.phase = phase;
    var n = pomo.settings.long_break_after, done = pomo.completed;
    var dots = "";
    for (var i = 0; i < n; i++) dots += i < done ? "●" : "○";
    $("pomo-session").textContent = phase === "idle" ? "Not running" :
      (phase === "work" ? "Work " + pomo.session + " of " + n : "After work " + done + " of " + n) + "  " + dots;
    $("pomo-next").textContent = pomo.running ? hhmm(new Date(Date.parse(pomo.ends_at))) + " · " +
      (phase === "work" ? (done + 1 >= n ? "long break" : "short break") : "back to work") :
      paused ? "paused (" + fmt(rem) + " left)" : waiting ? "press Start" : "–";
    $("pomo-cal").textContent = cal.next ? cal.next.text : "–";
    $("pomo-today").textContent = pomo.today + " session" + (pomo.today === 1 ? "" : "s") + (pomo.today ? " " + "🍅".repeat(Math.min(pomo.today, 12)) : "");
    $("pomo-main").textContent = pomo.running ? "Pause" : paused ? "Resume" : waiting ? "Start " + (phase === "work" ? "work" : "break") : "Start";
    $("pomo-skip").disabled = phase === "idle" || (waiting && phase === "work");
    $("pomo-stop").disabled = phase === "idle";
    $("pomo-channel").textContent = pomo.ntfy ? "alerts via ntfy" : "ntfy off: no alerts";
    document.title = (pomo.running ? fmt(rem) + " " + pomo.phase_name + " · " : "") + document.title.replace(/^\d+:\d\d(:\d\d)? [^·]+ · /, "");
  }

  function setPomodoro(st) {
    if (!st || st.enabled === false) return;
    pomo = st;
    pomoAt = Date.now();
    if (st.now) offset = Date.parse(st.now) - pomoAt;
    renderPomodoro();
  }

  function loadPomodoro() {
    if (!$("pomo")) return Promise.resolve();
    return api("/api/pomodoro").then(function (res) { if (res.ok) setPomodoro(res.body); }).catch(function () {});
  }

  function showError(msg) {
    var el = $("pomo-error");
    el.textContent = msg || "";
    el.hidden = !msg;
  }

  function act(action, body) {
    showError("");
    return api("/api/pomodoro/" + action, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body || {}),
    }).then(function (res) {
      if (res.body && (res.body.state || res.body.phase)) setPomodoro(res.body.state || res.body);
      if (!res.ok) showError(res.body.error || "request failed");
      return res;
    }).catch(function () { showError("server unreachable"); });
  }

  if ($("pomo")) {
    document.querySelectorAll("[data-pomo]").forEach(function (b) {
      b.addEventListener("click", function () { act(b.dataset.pomo); });
    });
    var form = $("pomo-settings"), btn = $("pomo-settings-btn");
    var closeForm = function () { form.hidden = true; btn.setAttribute("aria-expanded", "false"); };
    btn.addEventListener("click", function () {
      if (!form.hidden) { closeForm(); return; }
      var st = (pomo && pomo.settings) || {};
      ["work", "short_break", "long_break", "long_break_after"].forEach(function (k) { form.elements[k].value = st[k]; });
      form.elements.auto_start_break.checked = !!st.auto_start_break;
      form.elements.auto_start_work.checked = !!st.auto_start_work;
      form.hidden = false;
      btn.setAttribute("aria-expanded", "true");
      form.elements.work.focus();
    });
    $("pomo-settings-cancel").addEventListener("click", closeForm);
    form.addEventListener("submit", function (ev) {
      ev.preventDefault();
      var body = {};
      ["work", "short_break", "long_break", "long_break_after"].forEach(function (k) { body[k] = Number(form.elements[k].value); });
      body.auto_start_break = form.elements.auto_start_break.checked;
      body.auto_start_work = form.elements.auto_start_work.checked;
      act("settings", body).then(function (res) { if (res && res.ok) closeForm(); });
    });
  }

  // ===========================================================================
  // Refresh
  // ===========================================================================

  var lastSecond = -1;
  setInterval(function () {
    // tick the clock locally; poll the server when the phase should have ended
    if (pomo && pomo.running && remaining() <= 0 && Date.now() - pomoAt > 1500) loadPomodoro();
    var s = Math.floor(now() / 1000);
    if (s !== lastSecond) { lastSecond = s; renderPomodoro(); }
  }, 250);
  setInterval(function () { if (!document.hidden) loadPomodoro(); }, 5000);
  setInterval(function () { if (!document.hidden) loadCalendar(true); }, 60000);
  document.addEventListener("visibilitychange", function () {
    if (!document.hidden) { loadPomodoro(); loadCalendar(true); }
  });

  loadPomodoro();
  loadCalendar(false);
})();
