// zortex serve: "/" focuses search, live results on the search page,
// arrow keys + Enter move through results.
(function () {
  "use strict";
  var base = document.body.dataset.base || "";

  // Anchored lines must clear the sticky top bar, whose height changes when
  // it wraps (narrow windows, phones): publish it as --top-h, which sets the
  // page's scroll-padding-top, and re-land on the target once it's known.
  var bar = document.querySelector("header.top");
  if (bar) {
    var setTop = function () {
      document.documentElement.style.setProperty("--top-h", bar.getBoundingClientRect().height + "px");
    };
    setTop();
    if (window.ResizeObserver) new ResizeObserver(setTop).observe(bar);
    var reland = function () {
      var id = decodeURIComponent(location.hash.slice(1));
      var el = id && document.getElementById(id);
      if (el) el.scrollIntoView({ block: "start" });
    };
    if (location.hash) {
      reland();
      window.addEventListener("load", reland, { once: true }); // after images/fonts move things
    }
  }

  document.addEventListener("keydown", function (e) {
    var el = document.activeElement;
    var typing = el && (el.tagName === "INPUT" || el.tagName === "TEXTAREA");
    if (e.key === "/" && !typing) {
      var box = document.getElementById("search-input") || document.querySelector("[data-slash]") || document.getElementById("quick");
      if (box) { e.preventDefault(); box.focus(); box.select(); }
    }
  });

  // The installable app (pwa.go, sw.js): the service worker keeps this
  // build's files and the pages you opened, for reading offline. Browsers
  // allow it on HTTPS and localhost only.
  if ("serviceWorker" in navigator && window.isSecureContext && document.body.dataset.sw) {
    navigator.serviceWorker.register(document.body.dataset.sw, { scope: base + "/" }).catch(function () {});
  }
  // A saved copy (the server or the network was unreachable), or offline:
  // say so
  var savedAt = document.body.dataset.saved;
  var offlineBanner = function () {
    var bannerEl = document.getElementById("offline-banner");
    if (navigator.onLine && !savedAt) { if (bannerEl) bannerEl.remove(); return; }
    if (bannerEl || !document.querySelector("main")) return;
    bannerEl = document.createElement("p");
    bannerEl.id = "offline-banner";
    bannerEl.className = "offline-banner";
    bannerEl.setAttribute("role", "status");
    var when = savedAt ? new Date(savedAt) : null;
    bannerEl.textContent = (navigator.onLine ? "The server can't be reached" : "Offline") +
      (when && !isNaN(when) ? ": a copy saved " + when.toLocaleString([], { dateStyle: "medium", timeStyle: "short" }) : ": a saved copy") +
      ". Editing works again once it's back.";
    document.querySelector("main").prepend(bannerEl);
  };
  window.addEventListener("online", offlineBanner);
  window.addEventListener("offline", offlineBanner);
  offlineBanner();
  // /offline: the pages saved for reading offline, newest first
  var savedList = document.getElementById("offline-list");
  if (savedList && window.caches) {
    caches.keys().then(function (names) {
      var name = names.filter(function (n) { return n.indexOf("zortex-pages-") === 0; })[0];
      return name ? caches.open(name) : null;
    }).then(function (cache) {
      if (!cache) return [];
      return cache.keys().then(function (keys) {
        return Promise.all(keys.reverse().map(function (k) {
          return cache.match(k).then(function (res) { return res.text(); }).then(function (html) {
            var m = /<title>([^<]*)<\/title>/.exec(html);
            var t = document.createElement("textarea");
            t.innerHTML = m ? m[1] : "";
            return { url: k.url, title: t.value };
          });
        }));
      });
    }).then(function (pages) {
      pages = pages.filter(function (p) { return new URL(p.url).pathname !== base + "/offline"; });
      // "Projects · Zortex" -> "Projects"; the home page is "Zortex"
      var site = document.title.split(" · ").pop();
      pages.forEach(function (p) {
        var t = p.title;
        if (t.slice(-(site.length + 3)) === " · " + site) t = t.slice(0, -(site.length + 3));
        p.title = new URL(p.url).pathname === base + "/" ? "Home" : t;
      });
      savedList.innerHTML = "";
      if (!pages.length) {
        savedList.innerHTML = '<li class="dim">None yet: pages are saved as you open them.</li>';
        return;
      }
      pages.forEach(function (p) {
        var li = document.createElement("li"), a = document.createElement("a");
        a.href = p.url;
        a.textContent = p.title || decodeURIComponent(new URL(p.url).pathname.slice(base.length));
        li.appendChild(a);
        savedList.appendChild(li);
      });
    }).catch(function () { savedList.innerHTML = '<li class="dim">The saved pages can\'t be read here.</li>'; });
  }

  // The header's search box: the notes whose name matches, as you type
  // (article search, /api/search?mode=article). Arrows move, Enter opens the
  // marked note (or, with none marked, the full search page), Escape closes.
  var quick = document.getElementById("quick");
  if (quick && !document.getElementById("search-input")) {
    var qform = quick.form, qlist = document.createElement("ul"), qtimer = null, qseq = 0, qsel = -1;
    qlist.className = "quick-results";
    qlist.id = "quick-results";
    qlist.setAttribute("role", "listbox");
    qlist.hidden = true;
    qform.appendChild(qlist);
    quick.setAttribute("aria-controls", "quick-results");
    quick.setAttribute("aria-autocomplete", "list");
    var qclose = function () { qlist.hidden = true; qsel = -1; };
    var qmark = function (i) {
      var items = qlist.querySelectorAll("a");
      if (!items.length) return;
      if (qsel >= 0 && items[qsel]) items[qsel].classList.remove("sel");
      qsel = Math.max(-1, Math.min(i, items.length - 1));
      if (qsel >= 0) { items[qsel].classList.add("sel"); items[qsel].scrollIntoView({ block: "nearest" }); }
    };
    var qupdate = function () {
      var q = quick.value.trim(), mine = ++qseq;
      if (!q) { qclose(); qlist.innerHTML = ""; return; }
      fetch(base + "/api/search?mode=article&limit=8&q=" + encodeURIComponent(q), { headers: { "Accept": "application/json" } })
        .then(function (r) { return r.json(); })
        .then(function (list) {
          if (mine !== qseq) return;
          qlist.innerHTML = "";
          (list || []).forEach(function (x) {
            var li = document.createElement("li"), a = document.createElement("a"), name = document.createElement("span"), rel = document.createElement("span");
            li.setAttribute("role", "option");
            a.href = x.url;
            name.className = "name";
            name.textContent = x.breadcrumb || x.rel;
            rel.className = "dim";
            rel.textContent = x.rel;
            a.appendChild(name);
            a.appendChild(rel);
            li.appendChild(a);
            qlist.appendChild(li);
          });
          if (!qlist.children.length) {
            var none = document.createElement("li");
            none.className = "dim empty";
            none.textContent = "No note named so · Enter searches inside notes";
            qlist.appendChild(none);
          }
          qsel = -1;
          qlist.hidden = false;
        })
        .catch(function () {});
    };
    quick.addEventListener("input", function () { clearTimeout(qtimer); qtimer = setTimeout(qupdate, 120); });
    quick.addEventListener("focus", function () { if (quick.value.trim() && qlist.children.length) qlist.hidden = false; });
    quick.addEventListener("keydown", function (e) {
      if (e.key === "Escape") { qclose(); return; }
      if (qlist.hidden || (e.key !== "ArrowDown" && e.key !== "ArrowUp")) return;
      e.preventDefault();
      qmark(e.key === "ArrowDown" ? qsel + 1 : qsel - 1);
    });
    qform.addEventListener("submit", function (e) {
      var items = qlist.querySelectorAll("a");
      if (!qlist.hidden && qsel >= 0 && items[qsel]) { e.preventDefault(); location.href = items[qsel].href; }
    });
    document.addEventListener("click", function (e) { if (!qform.contains(e.target)) qclose(); });
  }

  var input = document.getElementById("search-input");
  var results = document.getElementById("results");
  var form = document.getElementById("search-form");
  if (!input || !results || !form) return;

  var timer = null, seq = 0;
  function params() {
    var p = new URLSearchParams(new FormData(form));
    return p;
  }
  function update() {
    var p = params();
    var mine = ++seq;
    history.replaceState(null, "", base + "/search?" + p.toString());
    p.set("partial", "1");
    fetch(base + "/search?" + p.toString(), { headers: { "Accept": "text/html" } })
      .then(function (r) { return r.text(); })
      .then(function (html) { if (mine === seq) { results.innerHTML = html; sel = -1; } })
      .catch(function () {});
  }
  input.addEventListener("input", function () {
    clearTimeout(timer);
    timer = setTimeout(update, 120);
  });
  form.addEventListener("change", function () {
    var text = (form.querySelector("input[name=mode]:checked") || {}).value === "text";
    document.querySelectorAll(".search-page .help[data-for]").forEach(function (p) {
      p.hidden = (p.getAttribute("data-for") === "text") !== text;
    });
    update();
  });
  form.addEventListener("submit", function (e) {
    var hits = results.querySelectorAll(".hit a");
    if (hits.length) { e.preventDefault(); location.href = (hits[sel >= 0 ? sel : 0]).href; }
  });

  var sel = -1;
  input.addEventListener("keydown", function (e) {
    if (e.key !== "ArrowDown" && e.key !== "ArrowUp") return;
    var hits = results.querySelectorAll(".hit a");
    if (!hits.length) return;
    e.preventDefault();
    if (sel >= 0 && hits[sel]) hits[sel].classList.remove("sel");
    sel = e.key === "ArrowDown" ? Math.min(sel + 1, hits.length - 1) : Math.max(sel - 1, 0);
    hits[sel].classList.add("sel");
    hits[sel].scrollIntoView({ block: "nearest" });
  });
})();
