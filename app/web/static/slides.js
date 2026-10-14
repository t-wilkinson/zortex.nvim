// zortex serve: a note as slides (/n/<rel>?view=slides).
//
// The URL's hash is the position: #3 is slide 3, #3.2 its second step, and
// #L42 the slide holding line 42 (links to a line, :ZortexPresent). Windows
// showing the same deck (the presenter window, "s") follow each other over a
// BroadcastChannel; the deck redraws in place when the note changes.
(function () {
  "use strict";
  var body = document.body;
  var deck = document.getElementById("deck");
  var stage = document.getElementById("stage");
  if (!deck) return;
  var rel = body.dataset.rel;
  var params = new URLSearchParams(location.search);
  var presenting = params.has("presenter");
  var slides = [];
  var cur = 0, step = 0;

  var $ = function (id) { return document.getElementById(id); };
  var count = $("deck-count");

  function index() { slides = Array.prototype.slice.call(deck.querySelectorAll(":scope > .slide")); }
  function stepsOf(i) { return parseInt(slides[i].dataset.steps, 10) || 0; }

  // ---------------------------------------------------------------------------
  // Scale and fit
  // ---------------------------------------------------------------------------
  function scaleTo(el, w, h) {
    var k = Math.min(w / 1280, h / 720);
    el.style.setProperty("--k", String(k));
  }
  function layout() {
    var r = stage.getBoundingClientRect();
    var pad = presenting ? 24 : 0;
    slides.forEach(function (s) { scaleTo(s, r.width - pad, r.height - pad); });
    var next = $("pp-next");
    if (presenting && next) {
      var nr = next.getBoundingClientRect();
      Array.prototype.forEach.call(next.querySelectorAll(".slide"), function (s) { scaleTo(s, nr.width, nr.height); });
    }
  }
  // shrink the text of a slide whose content doesn't fit, down to 55%
  function fit(s) {
    var inner = s.querySelector(".slide-inner");
    if (!inner || s.dataset.fitted) return;
    var shown = s.classList.contains("current") || s.closest(".overview, .pp-next-frame");
    if (!shown) return;
    var f = 1;
    inner.style.setProperty("--fit", "1");
    while (inner.scrollHeight > inner.clientHeight + 1 && f > 0.55) {
      f -= 0.05;
      inner.style.setProperty("--fit", f.toFixed(2));
    }
    s.dataset.fitted = "1";
  }

  // ---------------------------------------------------------------------------
  // Position
  // ---------------------------------------------------------------------------
  function show(i, st, from) {
    if (!slides.length) return;
    i = Math.max(0, Math.min(slides.length - 1, i));
    st = Math.max(0, Math.min(stepsOf(i), st));
    if (slides[cur]) {
      slides[cur].classList.remove("current");
      if (i !== cur) Array.prototype.forEach.call(slides[cur].querySelectorAll("video"), function (v) { v.pause(); });
    }
    cur = i; step = st;
    var s = slides[cur];
    s.classList.add("current");
    Array.prototype.forEach.call(s.querySelectorAll("[data-step]"), function (el) {
      el.classList.toggle("pending", parseInt(el.dataset.step, 10) > step);
    });
    fit(s);
    count.textContent = (cur + 1) + " / " + slides.length;
    var hash = "#" + (cur + 1) + (step ? "." + step : "");
    if (location.hash !== hash) history.replaceState(null, "", hash);
    if (presenting) presenterView();
    if (from !== "remote") send();
    if (deck.classList.contains("overview")) s.scrollIntoView({ block: "nearest" });
  }
  function next() {
    if (step < stepsOf(cur)) show(cur, step + 1);
    else if (cur < slides.length - 1) show(cur + 1, 0);
  }
  function prev() {
    if (step > 0) show(cur, step - 1);
    else if (cur > 0) show(cur - 1, stepsOf(cur - 1));
  }
  // the slide holding line lnum
  function slideOfLine(lnum) {
    for (var i = slides.length - 1; i >= 0; i--) {
      if (parseInt(slides[i].dataset.lnum, 10) <= lnum) return i;
    }
    return 0;
  }
  function fromHash() {
    var h = location.hash.slice(1);
    var m = /^L(\d+)$/.exec(h);
    if (m) return show(slideOfLine(parseInt(m[1], 10)), 0);
    m = /^(\d+)(?:\.(\d+))?$/.exec(h);
    if (m) return show(parseInt(m[1], 10) - 1, parseInt(m[2] || "0", 10));
    show(0, 0);
  }

  // ---------------------------------------------------------------------------
  // Other windows of this deck
  // ---------------------------------------------------------------------------
  var channel = window.BroadcastChannel ? new BroadcastChannel("zortex-slides:" + rel) : null;
  function send() { if (channel) channel.postMessage({ slide: cur, step: step }); }
  if (channel) {
    channel.onmessage = function (ev) {
      var d = ev.data || {};
      if (d.hello) return send();
      if (typeof d.slide === "number") show(d.slide, d.step || 0, "remote");
    };
  }
  function openPresenter() {
    var u = new URL(location.href);
    u.searchParams.set("presenter", "1");
    window.open(u.toString(), "zortex-presenter:" + rel, "width=1200,height=760");
  }

  // ---------------------------------------------------------------------------
  // Presenter window
  // ---------------------------------------------------------------------------
  var started = 0, elapsed = 0, timer = null;
  function fmt(ms) {
    var t = Math.floor(ms / 1000), h = Math.floor(t / 3600), m = Math.floor(t / 60) % 60, s = t % 60;
    return (h ? h + ":" + (m < 10 ? "0" : "") : "") + m + ":" + (s < 10 ? "0" : "") + s;
  }
  function tick() {
    var ms = elapsed + (started ? Date.now() - started : 0);
    $("pp-timer").textContent = fmt(ms);
    $("pp-clock").textContent = new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
  }
  function presenterView() {
    $("pp-count").textContent = "Slide " + (cur + 1) + " of " + slides.length + (stepsOf(cur) ? " · step " + step + "/" + stepsOf(cur) : "");
    var notes = slides[cur].querySelector(".notes");
    $("pp-notes").innerHTML = notes ? notes.innerHTML : '<p class="dim">No notes for this slide.</p>';
    var frame = $("pp-next");
    frame.innerHTML = "";
    if (cur + 1 < slides.length) {
      var copy = slides[cur + 1].cloneNode(true);
      copy.classList.remove("current");
      delete copy.dataset.fitted;
      frame.appendChild(copy);
      var r = frame.getBoundingClientRect();
      scaleTo(copy, r.width, r.height);
      fit(copy);
    } else {
      frame.innerHTML = '<div class="end">End of the deck</div>';
    }
  }
  if (presenting) {
    body.classList.add("presenting");
    $("presenter").hidden = false;
    started = Date.now();
    timer = setInterval(tick, 500);
    tick();
    var tb = $("pp-timer");
    tb.addEventListener("click", function () {
      if (started) { elapsed += Date.now() - started; started = 0; } else started = Date.now();
      tb.classList.toggle("paused", !started);
      tick();
    });
    tb.addEventListener("dblclick", function () {
      elapsed = 0; started = Date.now();
      tb.classList.remove("paused");
      tick();
    });
  }

  // ---------------------------------------------------------------------------
  // Overview, help, black screen, fullscreen
  // ---------------------------------------------------------------------------
  function overview(on) {
    if (on === undefined) on = !deck.classList.contains("overview");
    deck.classList.toggle("overview", on);
    if (on) {
      slides.forEach(fit);
      slides[cur].scrollIntoView({ block: "center" });
    } else {
      layout();
    }
  }
  function help(on) {
    var h = $("deck-help");
    h.hidden = on === undefined ? !h.hidden : !on;
  }
  function black(on) { stage.classList.toggle("black", on === undefined ? !stage.classList.contains("black") : on); }
  function fullscreen() {
    if (document.fullscreenElement) document.exitFullscreen();
    else if (document.documentElement.requestFullscreen) document.documentElement.requestFullscreen();
  }

  // ---------------------------------------------------------------------------
  // Input
  // ---------------------------------------------------------------------------
  var typed = "";
  document.addEventListener("keydown", function (e) {
    if (e.ctrlKey || e.metaKey || e.altKey) return;
    var t = e.target;
    if (t && (t.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName))) return;
    var k = e.key;
    if (k === " " && t && t.tagName === "VIDEO") return; // play/pause, not next
    if (/^[0-9]$/.test(k)) { typed += k; return; }
    if (k === "Enter" && typed) { show(parseInt(typed, 10) - 1, 0); typed = ""; e.preventDefault(); return; }
    typed = "";
    var inOverview = deck.classList.contains("overview");
    switch (k) {
      case "ArrowRight": case "ArrowDown": case "PageDown": case "l": case "j": case "n":
        if (inOverview) show(cur + 1, 0); else next(); break;
      case " ":
        if (e.shiftKey) prev(); else next(); break;
      case "ArrowLeft": case "ArrowUp": case "PageUp": case "Backspace": case "h": case "k": case "p":
        if (inOverview) show(cur - 1, 0); else prev(); break;
      case "Home": show(0, 0); break;
      case "End": show(slides.length - 1, 0); break;
      case "Enter": if (inOverview) overview(false); else next(); break;
      case "o": overview(); break;
      case "s": openPresenter(); break;
      case "f": fullscreen(); break;
      case "b": case ".": black(); break;
      case "?": help(); break;
      case "Escape":
        if (!$("deck-help").hidden) help(false);
        else if (inOverview) overview(false);
        else if (stage.classList.contains("black")) black(false);
        else return;
        break;
      default: return;
    }
    e.preventDefault();
  });

  document.querySelector(".deck-bar").addEventListener("click", function (e) {
    var b = e.target.closest("button[data-act]");
    if (!b) return;
    ({ prev: prev, next: next, overview: function () { overview(); }, presenter: openPresenter,
      fullscreen: fullscreen, help: function () { help(); } })[b.dataset.act]();
    b.blur();
  });

  deck.addEventListener("click", function (e) {
    // a link to a line of this note goes to its slide
    var a = e.target.closest("a[href]");
    if (a) {
      var u = new URL(a.href, location.href);
      var m = /^#L(\d+)$/.exec(u.hash);
      if (m && u.pathname === location.pathname) {
        e.preventDefault();
        if (deck.classList.contains("overview")) overview(false);
        show(slideOfLine(parseInt(m[1], 10)), 0);
      }
      return;
    }
    if (deck.classList.contains("overview")) {
      var s = e.target.closest(".slide");
      if (s) { show(slides.indexOf(s), 0); overview(false); }
    }
  });

  // swipe on touch screens
  var x0 = null, y0 = 0;
  stage.addEventListener("touchstart", function (e) {
    if (e.touches.length === 1) { x0 = e.touches[0].clientX; y0 = e.touches[0].clientY; }
  }, { passive: true });
  stage.addEventListener("touchend", function (e) {
    if (x0 === null || deck.classList.contains("overview")) return;
    var dx = e.changedTouches[0].clientX - x0, dy = e.changedTouches[0].clientY - y0;
    x0 = null;
    if (Math.abs(dx) > 50 && Math.abs(dx) > Math.abs(dy)) { if (dx < 0) next(); else prev(); }
  });

  // hide the bar and the cursor while the mouse rests
  var idle = null;
  function wake() {
    body.classList.remove("idle");
    clearTimeout(idle);
    idle = setTimeout(function () { if (!presenting) body.classList.add("idle"); }, 2500);
  }
  document.addEventListener("mousemove", wake);
  wake();

  window.addEventListener("resize", function () { layout(); if (presenting) presenterView(); });
  window.addEventListener("hashchange", fromHash);

  // ---------------------------------------------------------------------------
  // Live: the note changed (Neovim saved it, an edit elsewhere)
  // ---------------------------------------------------------------------------
  var loading = false;
  function reload() {
    if (loading) return;
    loading = true;
    var anchor = slides[cur] ? parseInt(slides[cur].dataset.lnum, 10) : 1, keepStep = step;
    var u = new URL(location.href);
    u.hash = "";
    fetch(u.toString(), { cache: "no-store" })
      .then(function (r) { return r.ok ? r.text() : null; })
      .then(function (html) {
        if (!html) return;
        var doc = new DOMParser().parseFromString(html, "text/html");
        var fresh = doc.getElementById("deck");
        if (!fresh || doc.body.dataset.mod === body.dataset.mod) return;
        body.dataset.mod = doc.body.dataset.mod;
        var wasOverview = deck.classList.contains("overview");
        deck.innerHTML = fresh.innerHTML;
        index();
        layout();
        cur = 0;
        show(slideOfLine(anchor), keepStep, "remote");
        if (wasOverview) slides.forEach(fit);
      })
      .catch(function () {})
      .then(function () { loading = false; });
  }
  document.addEventListener("zortex:notes", function (ev) {
    var rels = (ev.detail && ev.detail.rels) || [];
    if (rels.indexOf(rel) >= 0) reload();
  });
  document.addEventListener("zortex:resync", reload);

  // math typesets after the first fit: fit again once it has
  document.addEventListener("zortex:math", function () {
    slides.forEach(function (s) { delete s.dataset.fitted; });
    if (slides[cur]) fit(slides[cur]);
    if (presenting) presenterView();
  });

  index();
  layout();
  fromHash();
  if (channel && presenting) channel.postMessage({ hello: true });
})();
