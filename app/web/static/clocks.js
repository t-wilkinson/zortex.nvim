// zortex serve home page: the clock box's tabs (Pomodoro · Timer · Alarm ·
// Stopwatch). The pomodoro is home.js; timers, alarms and the stopwatch live
// in the server (/api/clocks) so every device shows the same ones, and
// timers and alarms reach ntfy with no page open.
(function () {
  "use strict";
  var base = document.body.dataset.base || "";
  var $ = function (id) { return document.getElementById(id); };
  var box = $("pomo");
  if (!box || !$("clock-timer")) return;

  var esc = function (s) { return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;"); };
  var pad = function (n) { return String(n).padStart(2, "0"); };
  function hms(sec) {
    sec = Math.max(0, Math.ceil(sec));
    var h = Math.floor(sec / 3600), m = Math.floor(sec % 3600 / 60), s = sec % 60;
    return (h ? h + ":" + pad(m) : String(m)) + ":" + pad(s);
  }
  function stopwatchText(ms) {
    ms = Math.max(0, ms);
    var tenths = Math.floor(ms / 100) % 10, sec = Math.floor(ms / 1000);
    return hms(sec) + "." + tenths;
  }

  // ---------------------------------------------------------------------------
  // Tabs: the pomodoro is the default; arrow keys move between tabs
  // ---------------------------------------------------------------------------
  var tabs = Array.prototype.slice.call(box.querySelectorAll("[role=tab]"));
  function select(tab, focus) {
    tabs.forEach(function (t) {
      var on = t === tab;
      t.setAttribute("aria-selected", String(on));
      t.tabIndex = on ? 0 : -1;
      $(t.getAttribute("aria-controls")).hidden = !on;
    });
    if (focus) tab.focus();
  }
  tabs.forEach(function (t, i) {
    t.addEventListener("click", function () { select(t, false); });
    t.addEventListener("keydown", function (ev) {
      var k = ev.key, next = null;
      if (k === "ArrowDown" || k === "ArrowRight") next = tabs[(i + 1) % tabs.length];
      else if (k === "ArrowUp" || k === "ArrowLeft") next = tabs[(i - 1 + tabs.length) % tabs.length];
      else if (k === "Home") next = tabs[0];
      else if (k === "End") next = tabs[tabs.length - 1];
      if (next) { ev.preventDefault(); select(next, true); }
    });
  });

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------
  var st = null, offset = 0, at = 0;
  var now = function () { return Date.now() + offset; };

  function api(path, body) {
    var opts = body === undefined ? { cache: "no-store" } :
      { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body || {}) };
    return fetch(base + path, opts).then(function (r) {
      return r.json().then(function (x) { return { ok: r.ok, body: x }; });
    });
  }

  function set(state) {
    if (!state || !state.timers) return;
    st = state;
    at = Date.now();
    if (state.now) offset = Date.parse(state.now) - at;
    render();
  }

  function load() {
    return api("/api/clocks").then(function (res) { if (res.ok) set(res.body); }).catch(function () {});
  }

  function errorIn(id, msg) {
    var el = $(id);
    if (!el) return;
    el.textContent = msg || "";
    el.hidden = !msg;
  }

  function post(path, body, errId) {
    return api(path, body).then(function (res) {
      if (res.ok) { errorIn(errId, ""); set(res.body); }
      else { errorIn(errId, res.body.error || "Couldn't save"); if (res.body.state) set(res.body.state); }
      return res;
    }).catch(function () { errorIn(errId, "Server unreachable"); });
  }

  // ---------------------------------------------------------------------------
  // Timers
  // ---------------------------------------------------------------------------

  // "10" minutes, "1:30" m:ss, "1:02:03" h:mm:ss, "1h30m", "90s", "1.5h"
  function parseDuration(s) {
    s = String(s || "").trim().toLowerCase().replace(/\s+/g, "");
    if (!s) return 0;
    if (/^\d+(\.\d+)?$/.test(s)) return Math.round(parseFloat(s) * 60);
    var m = /^(\d+):(\d{1,2})(?::(\d{1,2}))?$/.exec(s);
    if (m) return m[3] !== undefined ? +m[1] * 3600 + +m[2] * 60 + +m[3] : +m[1] * 60 + +m[2];
    var total = 0, rest = s.replace(/(\d+(?:\.\d+)?)(h|hr|hrs|hours?|m|min|mins|minutes?|s|sec|secs|seconds?)/g, function (_, n, u) {
      total += parseFloat(n) * (u[0] === "h" ? 3600 : u[0] === "m" ? 60 : 1);
      return "";
    });
    return rest ? 0 : Math.round(total);
  }

  function timerLeft(t) {
    if (!t.running) return t.left;
    return Math.max(0, (Date.parse(t.ends_at) - now()) / 1000);
  }

  function startTimer(seconds, label) {
    return post("/api/clocks/timers", { seconds: seconds, label: label || "" }, "timer-error");
  }

  $("timer-form").addEventListener("submit", function (ev) {
    ev.preventDefault();
    var sec = parseDuration(this.elements.duration.value);
    if (!sec) { errorIn("timer-error", "Duration: 10 (minutes), 1:30, 1h15m or 90s"); this.elements.duration.focus(); return; }
    var form = this;
    startTimer(sec, form.elements.label.value).then(function (res) {
      if (res && res.ok) { form.elements.duration.value = ""; form.elements.label.value = ""; }
    });
  });
  box.querySelectorAll("[data-preset]").forEach(function (b) {
    b.addEventListener("click", function () {
      var label = $("timer-label");
      startTimer(+b.dataset.preset, label.value).then(function (res) { if (res && res.ok) label.value = ""; });
    });
  });

  function renderTimers() {
    var list = $("timer-list");
    if (!st.timers.length) { list.innerHTML = '<li class="empty">No timers. Pick a preset or type a duration.</li>'; return; }
    list.innerHTML = st.timers.map(function (t) {
      var cls = t.done ? "done" : t.running ? "running" : "paused";
      var sub = t.done ? "done at " + new Date(Date.parse(t.done_at)).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }) :
        t.running ? "of " + hms(t.duration) : "paused · of " + hms(t.duration);
      var acts = t.done ?
        '<button type="button" data-timer="restart">Restart</button><button type="button" data-timer="remove">Dismiss</button>' :
        (t.running ? '<button type="button" data-timer="pause">Pause</button>' : '<button type="button" class="primary" data-timer="resume">Resume</button>') +
        '<button type="button" data-timer="restart">Restart</button><button type="button" data-timer="remove" aria-label="Remove timer">Remove</button>';
      return '<li class="' + cls + '" data-id="' + esc(t.id) + '">' +
        '<span class="big" data-left>' + (t.done ? "0:00" : hms(timerLeft(t))) + "</span>" +
        '<span class="what">' + (t.label ? esc(t.label) : '<span class="dim">Timer</span>') + '<span class="small dim">' + esc(sub) + "</span></span>" +
        '<span class="acts">' + acts + "</span>" +
        '<span class="bar" aria-hidden="true"><span data-bar style="width:0"></span></span></li>';
    }).join("");
  }

  $("timer-list").addEventListener("click", function (ev) {
    var b = ev.target.closest("[data-timer]");
    if (!b) return;
    var id = b.closest("li").dataset.id;
    post("/api/clocks/timers/" + encodeURIComponent(id) + "/" + b.dataset.timer, {}, "timer-error");
  });

  // ---------------------------------------------------------------------------
  // Alarms (times are the server's clock)
  // ---------------------------------------------------------------------------

  function serverOffset() {
    var m = /([+-])(\d\d):(\d\d)$/.exec(st && st.now || "");
    if (!m) return /Z$/.test(st && st.now || "") ? 0 : null;
    return (m[1] === "-" ? -1 : 1) * (+m[2] * 60 + +m[3]);
  }

  // a day as the server's wall clock sees it
  function serverDay(ms) {
    var off = serverOffset();
    if (off === null) off = -new Date().getTimezoneOffset();
    var d = new Date(ms + off * 60000);
    return { key: d.getUTCFullYear() + "-" + d.getUTCMonth() + "-" + d.getUTCDate(), date: d };
  }
  function dayWord(iso) {
    var d = serverDay(Date.parse(iso)), t = now();
    if (d.key === serverDay(t).key) return "today";
    if (d.key === serverDay(t + 86400000).key) return "tomorrow";
    return d.date.toLocaleDateString([], { timeZone: "UTC", weekday: "short", month: "short", day: "numeric" });
  }

  function untilText(iso) {
    var sec = (Date.parse(iso) - now()) / 1000;
    if (sec < 60) return "in under a minute";
    var h = Math.floor(sec / 3600), m = Math.floor(sec % 3600 / 60);
    return "in " + (h ? h + " h " : "") + m + " min";
  }

  $("alarm-form").addEventListener("submit", function (ev) {
    ev.preventDefault();
    var f = this;
    post("/api/clocks/alarms", { time: f.elements.time.value, label: f.elements.label.value, repeat: f.elements.repeat.value }, "alarm-error")
      .then(function (res) { if (res && res.ok) { f.elements.label.value = ""; } });
  });

  function renderAlarms() {
    var list = $("alarm-list");
    var tz = $("alarm-tz"), off = serverOffset();
    if (off !== null && off !== -new Date().getTimezoneOffset()) {
      var sign = off < 0 ? "−" : "+", a = Math.abs(off);
      tz.textContent = "Alarm times are the server's clock (UTC" + sign + pad(Math.floor(a / 60)) + ":" + pad(a % 60) + ").";
      tz.hidden = false;
    } else tz.hidden = true;
    if (!st.alarms.length) { list.innerHTML = '<li class="empty">No alarms. They ring through ntfy, once or every day.</li>'; return; }
    list.innerHTML = st.alarms.map(function (a) {
      var when = a.enabled ? "rings " + dayWord(a.next) + " · " + untilText(a.next) : "off";
      return '<li class="' + (a.enabled ? "on" : "off") + '" data-id="' + esc(a.id) + '">' +
        '<span class="big">' + esc(a.time) + "</span>" +
        '<span class="what">' + (a.label ? esc(a.label) : '<span class="dim">Alarm</span>') +
        '<span class="small dim">' + (a.repeat === "daily" ? "every day" : "once") + " · " + esc(when) + "</span></span>" +
        '<span class="acts"><button type="button" class="switch" data-alarm="' + (a.enabled ? "disable" : "enable") + '" aria-pressed="' + a.enabled + '">' + (a.enabled ? "On" : "Off") + "</button>" +
        '<button type="button" data-alarm="remove">Remove</button></span></li>';
    }).join("");
  }

  $("alarm-list").addEventListener("click", function (ev) {
    var b = ev.target.closest("[data-alarm]");
    if (!b) return;
    var id = b.closest("li").dataset.id;
    post("/api/clocks/alarms/" + encodeURIComponent(id) + "/" + b.dataset.alarm, {}, "alarm-error");
  });

  // ---------------------------------------------------------------------------
  // Stopwatch
  // ---------------------------------------------------------------------------

  function swElapsed() {
    var sw = st.stopwatch;
    return sw.running ? sw.elapsed_ms + (Date.now() - at) : sw.elapsed_ms;
  }

  box.querySelectorAll("[data-sw]").forEach(function (b) {
    b.addEventListener("click", function () { post("/api/clocks/stopwatch/" + b.dataset.sw, {}, "sw-error"); });
  });

  function renderStopwatch() {
    var sw = st.stopwatch, laps = sw.laps_ms || [];
    $("sw-main").textContent = sw.running ? "Pause" : sw.elapsed_ms > 0 ? "Resume" : "Start";
    $("sw-lap").disabled = !sw.running;
    $("sw-reset").disabled = !sw.running && !sw.elapsed_ms;
    var html = "";
    for (var i = laps.length - 1; i >= 0; i--) {
      var split = laps[i] - (i ? laps[i - 1] : 0);
      html += "<li><span>Lap " + (i + 1) + "</span><span>" + stopwatchText(split) + '</span><span class="dim">' + stopwatchText(laps[i]) + "</span></li>";
    }
    $("sw-laps").innerHTML = html;
  }

  // ---------------------------------------------------------------------------
  // Drawing
  // ---------------------------------------------------------------------------

  var channelShown = null;
  function render() {
    if (!st) return;
    if (channelShown !== st.ntfy) {
      channelShown = st.ntfy;
      box.querySelectorAll(".clocks-channel").forEach(function (el) {
        el.textContent = st.ntfy ? "rings through ntfy" : "ntfy off: no alerts";
      });
    }
    renderTimers();
    renderAlarms();
    renderStopwatch();
    tick();
  }

  var due = false;
  function tick() {
    if (!st) return;
    var soonest = null;
    st.timers.forEach(function (t) {
      var li = $("timer-list").querySelector('[data-id="' + t.id + '"]');
      var left = t.done ? 0 : timerLeft(t);
      if (li) {
        li.querySelector("[data-left]").textContent = hms(left);
        li.querySelector("[data-bar]").style.width = (t.done ? 100 : 100 * (1 - left / t.duration)) + "%";
      }
      if (t.running && (soonest === null || left < soonest)) soonest = left;
      if (t.running && left <= 0 && !due) { due = true; setTimeout(function () { due = false; load(); }, 1200); }
    });
    $("tab-timer-meta").textContent = soonest !== null ? hms(soonest) : st.timers.some(function (t) { return t.done; }) ? "done" : "";
    var next = null;
    st.alarms.forEach(function (a) { if (a.enabled && (!next || a.next < next.next)) next = a; });
    $("tab-alarm-meta").textContent = next ? next.time : "";
    var el = swElapsed();
    $("sw-time").textContent = stopwatchText(el);
    $("tab-stopwatch-meta").textContent = st.stopwatch.running || el ? hms(Math.floor(el / 1000)) : "";
  }

  // a timer ending or an alarm ringing while the page is open: a short chime
  function chime() {
    try {
      var Ctx = window.AudioContext || window.webkitAudioContext;
      if (!Ctx || document.hidden) return;
      var ctx = new Ctx(), t0 = ctx.currentTime;
      [0, 0.25, 0.5].forEach(function (d, i) {
        var o = ctx.createOscillator(), g = ctx.createGain();
        o.frequency.value = [880, 988, 1175][i];
        g.gain.setValueAtTime(0.0001, t0 + d);
        g.gain.exponentialRampToValueAtTime(0.2, t0 + d + 0.02);
        g.gain.exponentialRampToValueAtTime(0.0001, t0 + d + 0.22);
        o.connect(g); g.connect(ctx.destination);
        o.start(t0 + d); o.stop(t0 + d + 0.25);
      });
      setTimeout(function () { ctx.close(); }, 1200);
    } catch (e) { /* no audio */ }
  }

  setInterval(function () { if (!document.hidden) tick(); }, 200);
  setInterval(function () { if (!document.hidden) load(); }, 30000);
  setInterval(function () { if (!document.hidden && st) renderAlarms(); }, 30000);
  document.addEventListener("zortex:clocks", function (ev) {
    if (ev.detail && (ev.detail.event === "timer" || ev.detail.event === "alarm")) chime();
    load();
  });
  document.addEventListener("zortex:resync", load);
  load();
})();
