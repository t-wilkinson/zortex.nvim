// zortex serve: "/" focuses search, live results on the search page,
// arrow keys + Enter move through results.
(function () {
  "use strict";
  var base = document.body.dataset.base || "";

  document.addEventListener("keydown", function (e) {
    var el = document.activeElement;
    var typing = el && (el.tagName === "INPUT" || el.tagName === "TEXTAREA");
    if (e.key === "/" && !typing) {
      var box = document.getElementById("search-input") || document.getElementById("quick");
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
