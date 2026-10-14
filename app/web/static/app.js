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
  form.addEventListener("change", update);
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
