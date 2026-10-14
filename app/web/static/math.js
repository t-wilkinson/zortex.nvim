// zortex serve: typeset $inline$, $$display$$ and $$ blocks with KaTeX
// (vendored in /static/katex, loaded only on pages that have math). Notes
// redraw in place (live updates, edits), so new math is typeset as it
// appears; "zortex:math" tells the page when some was.
(function () {
  "use strict";
  var me = document.currentScript;
  var jsURL = me && me.dataset.katex, cssURL = me && me.dataset.katexCss;
  if (!jsURL) return;
  var loading = false, queued = false;

  function pending() {
    return document.querySelectorAll("span.math:not(.tex), pre.math-block:not(.tex)");
  }

  function typeset() {
    queued = false;
    var els = pending();
    if (!els.length) return;
    if (!window.katex) return load();
    var done = 0;
    Array.prototype.forEach.call(els, function (el) {
      if (el.closest(".katex")) return;
      var block = el.tagName === "PRE";
      var src = block ? (el.querySelector("code") || el).textContent : el.textContent;
      var out = el;
      if (block) {
        // keep the source lines (they carry the line anchors), hidden
        out = document.createElement("div");
        out.className = "tex-out";
        el.appendChild(out);
      }
      el.classList.add("tex");
      try {
        window.katex.render(src.trim(), out, {
          displayMode: block || el.classList.contains("display"),
          throwOnError: false,
          output: "htmlAndMathml",
        });
        el.title = src.trim();
      } catch (e) {
        el.classList.add("tex-error");
      }
      done++;
    });
    if (done) document.dispatchEvent(new CustomEvent("zortex:math"));
  }

  function load() {
    if (loading) return;
    loading = true;
    if (cssURL) {
      var link = document.createElement("link");
      link.rel = "stylesheet";
      link.href = cssURL;
      document.head.appendChild(link);
    }
    var s = document.createElement("script");
    s.src = jsURL;
    s.onload = typeset;
    document.head.appendChild(s);
  }

  function schedule() {
    if (queued) return;
    queued = true;
    requestAnimationFrame(typeset);
  }

  new MutationObserver(function (records) {
    for (var i = 0; i < records.length; i++) {
      if (records[i].addedNodes.length) return schedule();
    }
  }).observe(document.body, { childList: true, subtree: true });
  typeset();
})();
