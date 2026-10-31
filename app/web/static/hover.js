// Hover cards: what a link points at, before you follow it (hover.go).
//   a note or a heading   its title, path, header tags, first lines and how
//                         many links point at it (/api/hover)
//   an image file         the image
//   a link to a website   its domain and URL (nothing is fetched)
// Only where a pointer can hover; a touch opens the link as before.
(function () {
  "use strict";
  if (!window.matchMedia || !window.matchMedia("(hover: hover)").matches) return;
  var base = document.body.dataset.base || "";
  var IMAGE = /\.(png|jpe?g|gif|webp|svg|avif|bmp)$/i;
  var cache = {}, card = null, timer = null, hideTimer = null, current = null;

  function esc(s) {
    return String(s).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }

  // what a link points at: { kind: "note", rel, lnum } | { kind: "image", src }
  // | { kind: "web", url } | null
  function target(a) {
    var href = a.getAttribute("href") || "";
    if (!href || href.charAt(0) === "#") return null;
    if (/^https?:\/\//i.test(href)) {
      if (href.indexOf(location.origin + "/") === 0) href = href.slice(location.origin.length);
      else return IMAGE.test(href.split(/[?#]/)[0]) ? { kind: "image", src: href } : { kind: "web", url: href };
    }
    if (href.indexOf(base + "/n/") === 0) {
      var rest = href.slice(base.length + 3), hash = rest.indexOf("#");
      var rel = decodeURIComponent(hash < 0 ? rest : rest.slice(0, hash));
      var m = hash < 0 ? null : /^#L(\d+)$/.exec(rest.slice(hash));
      return { kind: "note", rel: rel, lnum: m ? Number(m[1]) : 0 };
    }
    if (href.indexOf(base + "/f/") === 0 && IMAGE.test(href.split(/[?#]/)[0])) {
      return { kind: "image", src: base + "/raw/" + href.slice(base.length + 3) };
    }
    // a Markdown document a link names (/f/z/markdown/a.md#L12): its card,
    // as a note's
    if (href.indexOf(base + "/f/") === 0 && /\.(md|markdown)$/i.test(href.split(/[?#]/)[0])) {
      var drest = href.slice(base.length + 3), dh = drest.indexOf("#");
      var dm = dh < 0 ? null : /^#L(\d+)$/.exec(drest.slice(dh));
      return { kind: "note", rel: decodeURIComponent(drest.split(/[?#]/)[0]), lnum: dm ? Number(dm[1]) : 0 };
    }
    return null;
  }

  function render(t, data) {
    if (t.kind === "image") {
      return '<img class="hc-img" src="' + esc(t.src) + '" alt="">';
    }
    if (t.kind === "web") {
      var u;
      try { u = new URL(t.url); } catch (e) { return null; }
      return '<div class="hc-title">' + esc(u.hostname.replace(/^www\./, "")) + '</div><div class="hc-url">' + esc(t.url) + "</div>";
    }
    if (!data) return '<div class="hc-dim">…</div>';
    if (data.error) return '<div class="hc-dim">' + esc(data.error) + "</div>";
    var html = '<div class="hc-title">' + esc(data.section || data.title) + "</div>";
    html += '<div class="hc-path">' + esc(data.rel) + (data.section ? " · " + esc(data.title) : "") + "</div>";
    if (data.tags && data.tags.length) {
      html += '<div class="hc-tags">' + data.tags.map(function (t) { return '<span class="tag">@' + esc(t) + "</span>"; }).join(" ") + "</div>";
    }
    if (data.lines && data.lines.length) {
      html += '<ul class="hc-lines">' + data.lines.map(function (l) { return "<li>" + esc(l) + "</li>"; }).join("") + "</ul>";
    }
    html += '<div class="hc-dim">' + (data.backlinks === 1 ? "1 link points here" : data.backlinks + " links point here") + "</div>";
    return html;
  }

  function place(a) {
    var r = a.getBoundingClientRect(), w = card.offsetWidth, h = card.offsetHeight;
    var x = Math.max(8, Math.min(r.left, window.innerWidth - w - 8));
    var y = r.bottom + 6;
    if (y + h > window.innerHeight - 8 && r.top - h - 6 > 8) y = r.top - h - 6;
    card.style.left = x + window.scrollX + "px";
    card.style.top = y + window.scrollY + "px";
  }

  function show(a, t) {
    if (!card) {
      card = document.createElement("div");
      card.className = "hover-card";
      card.setAttribute("role", "tooltip");
      card.addEventListener("mouseenter", function () { clearTimeout(hideTimer); });
      card.addEventListener("mouseleave", hide);
      document.body.appendChild(card);
    }
    var key = t.kind === "note" ? t.rel + ":" + t.lnum : (t.src || t.url);
    var html = render(t, cache[key]);
    if (html === null) return;
    card.innerHTML = html;
    card.hidden = false;
    current = a;
    place(a);
    var img = card.querySelector("img");
    if (img) img.addEventListener("load", function () { if (current === a) place(a); });
    if (t.kind === "note" && !cache[key]) {
      fetch(base + "/api/hover?rel=" + encodeURIComponent(t.rel) + "&lnum=" + t.lnum, { headers: { Accept: "application/json" } })
        .then(function (r) { return r.json(); })
        .then(function (data) {
          cache[key] = data;
          if (current === a && !card.hidden) { card.innerHTML = render(t, data); place(a); }
        })
        .catch(function () {});
    }
  }

  function hide() {
    clearTimeout(timer);
    hideTimer = setTimeout(function () {
      if (card) card.hidden = true;
      if (current && current.dataset.title) { current.title = current.dataset.title; }
      current = null;
    }, 120);
  }

  document.addEventListener("mouseover", function (ev) {
    var a = ev.target.closest && ev.target.closest("main a[href]");
    if (!a || a === current || a.closest(".hover-card") || a.closest(".top")) return;
    var t = target(a);
    if (!t) return;
    clearTimeout(timer); clearTimeout(hideTimer);
    timer = setTimeout(function () {
      // the card replaces the browser's own tooltip
      if (a.title) { a.dataset.title = a.title; a.removeAttribute("title"); }
      show(a, t);
    }, 350);
    a.addEventListener("mouseleave", hide, { once: true });
  });
  document.addEventListener("keydown", function (ev) { if (ev.key === "Escape" && card) card.hidden = true; });
})();
