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
  var calWritable = false;
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
      var cls = "event-item" + (past ? " past" : "") + (e.done ? " done" : "") + (e.moved ? " moved" : "") + (e.virtual ? " virtual" : "") + (i === current ? " current" : "");
      var time = e.time ? esc(e.time) + (e.end ? '<span class="end">–' + esc(e.end) + "</span>" : "") : "";
      var box = "";
      // a line without a checkbox that stands for a task (e.ref) toggles that task
      var refCls = e.ref ? " ref" : "", refTitle = e.ref ? ' title="the task in ' + esc(e.ref) + '"' : "";
      // a project block's next tasks: the project's own lines, shown here
      if (e.virtual) { refCls = " ref"; refTitle = ' title="the project\'s next task (' + esc(e.rel || "") + ')"'; }
      if (e.moved) {
        box = '<span class="box moved" title="carried to a later day" aria-label="carried to a later day">&gt;</span>';
      } else if (e.task && e.src && calWritable) {
        box = '<button type="button" class="box ' + (e.done ? "done" : "open") + refCls + '" data-day="' + esc(key) + '" data-i="' + i +
          '" aria-pressed="' + (e.done ? "true" : "false") + '" aria-label="' + (e.done ? "Done; mark open" : "Mark done") + '"' + refTitle + '></button>';
      } else if (e.task) {
        box = '<span class="box ' + (e.done ? "done" : "open") + '" aria-label="' + (e.done ? "done" : "open task") + '"></span>';
      }
      var bell = e.notify ? '<span class="bell" title="notifies (@n)" aria-label="notifies">🔔</span>' : "";
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
      // the dot: the day has an @event (something fixed to plan around)
      var key = dayKey(new Date(y, m, d)), busy = (cal.days[key] || []).some(function (e) { return e.event; });
      var cls = ["day-cell", busy && "has-events", key === sel && "active", key === today && "today"].filter(Boolean).join(" ");
      html += '<button type="button" class="' + cls + '" data-day="' + d + '" aria-label="' + key + (busy ? ", has events" : "") + '">' + d + "</button>";
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
        calWritable = !!data.writable;
        cal.carry = data.carry || 0;
        cal.notifications = data.notifications || [];
        cal.next = data.next_time ? { time: data.next_time, text: data.next_event } : null;
        var stats = $("cal-stats");
        if (stats && data.notes_enabled) {
          stats.textContent = data.count + " pending notification" + (data.count === 1 ? "" : "s") +
            " · next: " + data.next_event + (data.ntfy ? " · via ntfy" : " · ntfy off");
        }
      });
    })).then(function () { renderDay(); renderMonth(); renderPomodoro(); renderCarry(); });
  }

  // -writable: open tasks of the days before, copied to today (same @id) and
  // marked [>] where they were
  function renderCarry() {
    var head = document.querySelector(".cal-head");
    if (!head) return;
    var btn = head.querySelector("button.carry");
    if (!calWritable || !cal.carry) { if (btn) btn.remove(); return; }
    if (!btn) {
      btn = document.createElement("button");
      btn.type = "button";
      btn.className = "link-btn carry";
      btn.addEventListener("click", function () {
        btn.disabled = true;
        fetch(base + "/api/calendar/carry", { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" })
          .then(function (r) { if (!r.ok) return r.json().then(function (x) { window.alert(x.error || "Couldn't carry"); }); })
          .catch(function () { window.alert("Server unreachable; nothing was changed"); })
          .then(function () { btn.disabled = false; cal.loaded = {}; return loadCalendar(true); });
      });
      head.appendChild(btn);
    }
    btn.textContent = "Carry " + cal.carry + " open task" + (cal.carry === 1 ? "" : "s") + " to today";
    btn.title = "Copy the open tasks of the days before to today; the old lines are marked [>]";
  }

  // -writable: check off calendar tasks here
  var eventList = $("event-list");
  if (eventList) {
    eventList.addEventListener("click", function (ev) {
      var b = ev.target.closest("button.box[data-i]");
      if (!b) return;
      var e = (cal.days[b.dataset.day] || [])[Number(b.dataset.i)];
      if (!e || !e.src) return;
      b.disabled = true;
      fetch(base + "/api/edit", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ rel: e.rel, lnum: e.lnum, expect: e.src, op: "toggle" }),
      }).then(function (r) {
        if (r.status === 409) window.alert("The calendar changed elsewhere; showing the latest. Try again.");
        else if (!r.ok) return r.json().then(function (x) { window.alert(x.error || "Couldn't save"); });
      }).catch(function () { window.alert("Server unreachable; nothing was changed"); })
        .then(function () { cal.loaded = {}; return loadCalendar(true); }).then(loadXP);
    });
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
    renderNow();
    $("pomo-today").textContent = pomo.today + " session" + (pomo.today === 1 ? "" : "s") + (pomo.today ? " " + "🍅".repeat(Math.min(pomo.today, 12)) : "");
    $("pomo-main").textContent = pomo.running ? "Pause" : paused ? "Resume" : waiting ? "Start " + (phase === "work" ? "work" : "break") : "Start";
    $("pomo-skip").disabled = phase === "idle" || (waiting && phase === "work");
    $("pomo-stop").disabled = phase === "idle";
    $("pomo-channel").textContent = pomo.ntfy ? "alerts via ntfy" : "ntfy off: no alerts";
    var meta = $("tab-pomo-meta");
    if (meta) meta.textContent = pomo.running ? fmt(rem) : paused ? "paused" : "";
    document.title = (pomo.running ? fmt(rem) + " " + pomo.phase_name + " · " : "") + document.title.replace(/^\d+:\d\d(:\d\d)? [^·]+ · /, "");
  }

  // the calendar entry "now" falls in (today's last timed entry that has
  // started and, when it has an end time, hasn't ended), with its links
  function currentEntry() {
    var t = new Date(now()), nowMin = t.getHours() * 60 + t.getMinutes();
    var entries = cal.days[dayKey(t)] || [], cur = null, next = null;
    entries.forEach(function (e) {
      var m = minutes(e.time);
      if (m === null) return;
      if (m <= nowMin) cur = e;
      else if (!next) next = e;
    });
    if (cur && cur.end) {
      var end = minutes(cur.end);
      if (end !== null && end > minutes(cur.time) && nowMin >= end) cur = null;
    }
    return { cur: cur, next: next };
  }
  var nowShown = "";
  function renderNow() {
    var el = $("pomo-cal");
    if (!el) return;
    var c = currentEntry(), html;
    if (c.cur) {
      html = '<a class="now-time" href="' + esc(c.cur.url) + '">' + esc(c.cur.time) + (c.cur.end ? "–" + esc(c.cur.end) : "") + "</a> " + c.cur.html;
    } else if (c.next) {
      html = '<span class="dim">free until</span> <a class="now-time" href="' + esc(c.next.url) + '">' + esc(c.next.time) + "</a> " + c.next.html;
    } else {
      html = '<span class="dim">nothing scheduled</span>';
    }
    if (html !== nowShown) { el.innerHTML = html; nowShown = html; }
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
  // XP (summary published by Neovim; the ledger lives there)
  // ===========================================================================

  var SVGNS = "http://www.w3.org/2000/svg";
  var list = function (x) { return Array.isArray(x) ? x : []; };
  var num = function (n) { return Math.round(n || 0).toLocaleString(); };
  var noteHref = function (rel, lnum) {
    return base + "/n/" + rel.split("/").map(encodeURIComponent).join("/") + (lnum ? "#L" + lnum : "");
  };

  function ago(iso) {
    var t = Date.parse(iso);
    if (!t) return "";
    var m = Math.round((now() - t) / 60000);
    if (m < 1) return "just now";
    if (m < 60) return m + " min ago";
    if (m < 48 * 60) return Math.round(m / 60) + " h ago";
    return Math.round(m / 1440) + " days ago";
  }

  // 14 columns, one per day; today's value labelled on its cap. Hover (or
  // focus) any column for its date and XP.
  function renderChart(days) {
    var wrap = $("xp-chart");
    wrap.textContent = "";
    var W = 308, H = 104, top = 18, bottom = 18, slot = W / Math.max(days.length, 1);
    var bw = Math.min(16, slot - 4), max = 0;
    days.forEach(function (d) { max = Math.max(max, d.xp); });
    var scale = max > 0 ? (H - top - bottom) / max : 0;
    var svg = document.createElementNS(SVGNS, "svg");
    svg.setAttribute("viewBox", "0 0 " + W + " " + H);
    svg.setAttribute("role", "img");
    svg.setAttribute("aria-label", "XP per day for the last " + days.length + " days; the table below has the values");
    var base_y = H - bottom;
    var axis = document.createElementNS(SVGNS, "line");
    axis.setAttribute("x1", 0); axis.setAttribute("x2", W);
    axis.setAttribute("y1", base_y + 0.5); axis.setAttribute("y2", base_y + 0.5);
    axis.setAttribute("class", "axis");
    svg.appendChild(axis);
    days.forEach(function (d, i) {
      var h = d.xp * scale, x = i * slot + (slot - bw) / 2, isToday = i === days.length - 1;
      var g = document.createElementNS(SVGNS, "g");
      g.setAttribute("class", "col" + (isToday ? " today" : ""));
      g.setAttribute("tabindex", "0");
      g.setAttribute("aria-label", d.date + ": " + num(d.xp) + " XP");
      g.dataset.date = d.date; g.dataset.xp = d.xp;
      var hit = document.createElementNS(SVGNS, "rect"); // the whole slot is the target
      hit.setAttribute("x", i * slot); hit.setAttribute("y", 0);
      hit.setAttribute("width", slot); hit.setAttribute("height", H);
      hit.setAttribute("class", "hit");
      g.appendChild(hit);
      if (h > 0) {
        h = Math.max(h, 2);
        var r = Math.min(4, bw / 2, h), y = base_y - h;
        // rounded data end, square at the baseline
        var path = document.createElementNS(SVGNS, "path");
        path.setAttribute("d", "M" + x + "," + base_y + "V" + (y + r) + "Q" + x + "," + y + " " + (x + r) + "," + y +
          "H" + (x + bw - r) + "Q" + (x + bw) + "," + y + " " + (x + bw) + "," + (y + r) + "V" + base_y + "Z");
        path.setAttribute("class", "bar");
        g.appendChild(path);
      }
      if (isToday && d.xp > 0) {
        var label = document.createElementNS(SVGNS, "text");
        label.setAttribute("x", x + bw / 2); label.setAttribute("y", base_y - h - 5);
        label.setAttribute("text-anchor", "middle");
        label.setAttribute("class", "value");
        label.textContent = num(d.xp);
        g.appendChild(label);
      }
      if (i === 0 || isToday || i === Math.floor(days.length / 2)) {
        var tick = document.createElementNS(SVGNS, "text");
        tick.setAttribute("x", x + bw / 2); tick.setAttribute("y", H - 3);
        tick.setAttribute("text-anchor", "middle");
        tick.setAttribute("class", "tick");
        tick.textContent = isToday ? "today" : d.date.slice(5).replace("-", "/");
        g.appendChild(tick);
      }
      svg.appendChild(g);
    });
    wrap.appendChild(svg);
    if (max === 0) {
      var empty = document.createElement("p");
      empty.className = "chart-empty dim small";
      empty.textContent = "No XP in the last 14 days";
      wrap.appendChild(empty);
    }

    var tip = $("xp-tip");
    function show(g) {
      var d = new Date(g.dataset.date + "T12:00:00");
      tip.innerHTML = "<span class='tip-date'>" + esc(d.toLocaleDateString(undefined, { weekday: "short", month: "short", day: "numeric" })) +
        "</span> <strong>" + esc(num(Number(g.dataset.xp))) + " Mastery XP</strong>";
      tip.hidden = false;
      var box = wrap.getBoundingClientRect(), r = g.querySelector(".hit").getBoundingClientRect();
      var left = r.left - box.left + r.width / 2;
      tip.style.left = Math.max(60, Math.min(box.width - 60, left)) + "px";
      svg.querySelectorAll(".col.hover").forEach(function (c) { c.classList.remove("hover"); });
      g.classList.add("hover");
    }
    function hide() {
      tip.hidden = true;
      svg.querySelectorAll(".col.hover").forEach(function (c) { c.classList.remove("hover"); });
    }
    svg.querySelectorAll(".col").forEach(function (g) {
      g.addEventListener("pointerenter", function () { show(g); });
      g.addEventListener("focus", function () { show(g); });
      g.addEventListener("blur", hide);
    });
    svg.addEventListener("pointerleave", hide);

    var tbody = $("xp-table").querySelector("tbody");
    tbody.innerHTML = days.map(function (d) { return "<tr><td>" + esc(d.date) + "</td><td>" + esc(num(d.xp)) + "</td></tr>"; }).join("");
  }

  // XP is estimated work: xp_per_hour XP (10 by default) is an hour of it
  function xpPerHour(x) { return (x && x.calibration && x.calibration.xp_per_hour) || 10; }
  function hoursText(h) {
    if (h > 0 && h < 1) return Math.round(h * 60) + "m";
    return (Math.round(h * 10) / 10) + "h";
  }
  function workHours(xp, x) { return hoursText(xp / xpPerHour(x)); }

  function renderXP(x) {
    var panel = $("xp");
    if (!panel) return;
    if (!x || x.available === false || !x.version) { panel.hidden = true; return; }
    panel.hidden = false;
    var s = x.season;
    var objs = $("xp-objectives");
    if (s && x.version >= 2) {
      // the season is progress on its objectives; tiers are thresholds on it
      $("xp-title").textContent = s.name;
      $("xp-meta").textContent = (s.auto ? "quarter" : "season") +
        (s.days_left != null ? " · " + Math.max(0, s.days_left) + " days left" : "") +
        (s.start_date ? " · since " + s.start_date : "");
      var pct = Math.round((s.progress || 0) * 100);
      var objectives = list(s.objectives);
      $("xp-level").textContent = objectives.length ? pct + "% of objectives" : "No objectives";
      $("xp-tier").textContent = s.tier || "";
      $("xp-tier").hidden = !s.tier;
      $("xp-meter").hidden = false;
      $("xp-meter").setAttribute("aria-valuenow", pct);
      $("xp-meter-fill").style.width = pct + "%";
      $("xp-marks").innerHTML = list(s.tiers).filter(function (t) { return t.at > 0 && t.at < 1; }).map(function (t) {
        return '<span style="left:' + (t.at * 100) + '%" title="' + esc(t.name) + " at " + Math.round(t.at * 100) + '%"></span>';
      }).join("");
      $("xp-next").textContent = !objectives.length ? "No objective in this season's window: add a 3M-YYYY-Qn objective to OKRs" :
        s.next_tier ? s.next_tier + " at " + Math.round(s.next_at * 100) + "%" : "Every objective done";
      $("xp-season").textContent = pct + "%";
      objs.innerHTML = objectives.map(function (o) {
        var p = Math.round((o.progress || 0) * 100);
        var title = esc(o.title || "");
        if (o.rel) title = '<a href="' + esc(noteHref(o.rel, o.lnum)) + '">' + title + "</a>";
        return '<li><div class="area-row"><span class="area-name">' + title + "</span>" +
          '<span class="area-level">' + p + "% · " + Math.round((o.share || 0) * 100) + "% of season</span></div>" +
          '<div class="meter thin" role="progressbar" aria-label="' + esc(o.title || "") + ' progress" aria-valuemin="0" aria-valuemax="100" aria-valuenow="' + p + '">' +
          '<div class="meter-fill" style="width:' + p + '%"></div></div></li>';
      }).join("");
    } else {
      $("xp-title").textContent = "XP";
      $("xp-meta").textContent = s ? "update Neovim's zortex to see the season" : "no season running · :ZortexSeasonStart";
      $("xp-level").textContent = "No season";
      $("xp-tier").hidden = true;
      $("xp-meter").hidden = true;
      $("xp-next").textContent = "";
      $("xp-season").textContent = "–";
      objs.innerHTML = "";
    }
    $("xp-today").textContent = (x.today > 0 ? "+" : "") + num(x.today);
    $("xp-week").textContent = (x.week > 0 ? "+" : "") + num(x.week);
    renderChart(list(x.daily));

    var areas = list(x.areas);
    $("xp-areas").innerHTML = areas.length ? areas.map(function (a) {
      var pct = Math.round((a.progress || 0) * 100);
      return '<li><div class="area-row"><span class="area-name" title="' + esc(a.key) + '">' + esc(a.name) + "</span>" +
        '<span class="area-level">Lvl ' + esc(a.level || 1) + " · " + esc(num(a.xp)) + " Mastery XP</span></div>" +
        '<div class="meter thin" role="progressbar" aria-label="' + esc(a.name) + ' progress to the next level" aria-valuemin="0" aria-valuemax="100" aria-valuenow="' + pct + '">' +
        '<div class="meter-fill" style="width:' + pct + '%"></div></div></li>';
    }).join("") : '<li class="dim">No Mastery XP yet: give objectives areas with @a(...) and link projects to key results</li>';

    var awards = list(x.awards);
    $("xp-awards").innerHTML = awards.length ? awards.map(function (e) {
      var title = esc(e.title || "");
      if (e.rel) title = '<a href="' + esc(noteHref(e.rel, e.lnum)) + '">' + title + "</a>";
      var kind = e.source === "objective" ? " · objective" : e.source === "project_done" ? " · project done" : "";
      var award = e.xp > 0 ? "+" + num(e.xp) : "·";
      var effort = e.effort != null ? e.effort : e.xp;
      return '<li><span class="award-xp" title="+' + esc(num(e.xp)) + " Mastery XP for " + esc(num(effort)) + " XP (" + esc(workHours(effort, x)) + ') of estimated work">' + esc(award) + "</span>" +
        '<span class="award-title">' + title + '<span class="dim small"> ' + esc(e.date ? e.date.slice(5).replace("-", "/") : "") + " · " + esc(workHours(effort, x)) + esc(kind) + "</span></span></li>";
    }).join("") : '<li class="dim">Nothing completed in the last 30 days</li>';

    $("xp-updated").textContent = (x.generated ? "Updated in Neovim " + ago(x.generated) + " · " : "") +
      num(xpPerHour(x)) + " XP = 1 hour of estimated work";
  }

  function renderPending(x) {
    var el = $("web-pending");
    if (!el) return;
    var n = (x && x.pending_web) || 0;
    el.hidden = n === 0;
    if (!n) return;
    var tasks = list(x.pending_tasks);
    var titles = tasks.length ? tasks.map(function (t) { return esc(t.title) + " ~" + num(t.xp) + " XP (" + (t.hours ? hoursText(t.hours) : workHours(t.xp, x)) + ")"; }).join(", ") :
      list(x.pending_titles).map(esc).join(", ");
    var xp = x.pending_xp ? " · ~" + num(x.pending_xp) + " XP (" + (x.pending_hours ? hoursText(x.pending_hours) : workHours(x.pending_xp, x)) + " of estimated work) pending" : "";
    el.innerHTML = "<strong>" + n + " task" + (n === 1 ? "" : "s") + " completed here" + esc(xp) + "</strong> " +
      "<span class='dim'>· an estimate from " + (n === 1 ? "its" : "their") + " sizes; Neovim counts the real XP next time it runs" +
      (titles ? " (" + titles + (n > 5 ? ", …" : "") + ")" : "") + "</span>";
  }

  function loadXP() {
    if (!$("xp")) return Promise.resolve();
    return api("/api/xp").then(function (res) { if (res.ok) { renderXP(res.body); renderPending(res.body); } }).catch(function () {});
  }

  // -writable: add to inbox.zortex
  var inbox = $("inbox-form");
  if (inbox) {
    inbox.addEventListener("submit", function (ev) {
      ev.preventDefault();
      var text = inbox.elements.text.value.trim();
      if (!text) return;
      var kind = inbox.querySelector("input[name=kind]:checked").value;
      var st = $("inbox-status");
      st.textContent = "Adding…"; st.className = "small dim";
      fetch(base + "/api/inbox", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ text: text, kind: kind }),
      }).then(function (r) { return r.json().then(function (x) { return { ok: r.ok, x: x }; }); })
        .then(function (res) {
          if (res.ok) {
            inbox.elements.text.value = "";
            st.innerHTML = 'Added to <a href="' + esc(res.x.url) + '">inbox</a>';
            st.className = "small";
          } else { st.textContent = res.x.error || "Couldn't add"; st.className = "small bad"; }
        }).catch(function () { st.textContent = "Server unreachable"; st.className = "small bad"; });
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
  setInterval(function () { if (!document.hidden) { loadCalendar(true); loadXP(); } }, 60000);
  document.addEventListener("visibilitychange", function () {
    if (!document.hidden) { loadPomodoro(); loadCalendar(true); loadXP(); }
  });
  // live updates (live.js): redraw as soon as the server says something changed
  var notesTimer = null;
  document.addEventListener("zortex:notes", function () {
    clearTimeout(notesTimer);
    notesTimer = setTimeout(function () { loadCalendar(true); loadXP(); }, 250);
  });
  document.addEventListener("zortex:xp", loadXP);
  document.addEventListener("zortex:pomodoro", loadPomodoro);
  document.addEventListener("zortex:resync", function () { loadPomodoro(); loadCalendar(true); loadXP(); });

  loadPomodoro();
  loadCalendar(false);
  loadXP();
})();
