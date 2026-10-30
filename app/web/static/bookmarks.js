// zortex serve: bookmarks (bookmarks.go). The top bar's ☆ keeps the page
// you're on, on the server, so every device sees it; the home page shows the
// bookmarks as cards (× removes one) and redraws them when any device
// changes them (the "bookmarks" event, live.js).
(function () {
  "use strict";
  var base = document.body.dataset.base || "";
  var star = document.getElementById("bm-toggle");
  var cards = document.getElementById("bm-cards");

  function post(path, body) {
    return fetch(base + path, {
      method: "POST",
      headers: { "Content-Type": "application/json", "Accept": "application/json" },
      body: JSON.stringify(body),
    }).then(function (r) {
      return r.json().then(function (b) {
        if (!r.ok) throw new Error(b.error || r.statusText);
        return b;
      });
    });
  }

  // the page's own title, without the site's (" · Zortex")
  function pageTitle() {
    var t = document.title, site = document.querySelector("header.top .brand");
    var suffix = site ? " · " + site.textContent.trim() : "";
    if (suffix && t.slice(-suffix.length) === suffix) t = t.slice(0, -suffix.length);
    var h1 = document.querySelector("main h1");
    return (t && t !== (site && site.textContent.trim())) ? t : (h1 ? h1.textContent.trim() : t);
  }

  function showStar(on) {
    if (!star) return;
    star.setAttribute("aria-pressed", on ? "true" : "false");
    star.textContent = on ? "★" : "☆";
    star.title = on ? "Bookmarked: on the home page (click to remove)" : "Bookmark this page (on the home page)";
  }

  if (star) {
    star.addEventListener("click", function () {
      var on = star.getAttribute("aria-pressed") !== "true";
      showStar(on); // at once; put back if the server says no
      star.disabled = true;
      post(on ? "/api/bookmarks" : "/api/bookmarks/remove", { url: star.dataset.url, title: pageTitle() })
        .catch(function (err) {
          showStar(!on);
          star.title = "Couldn't change the bookmark: " + err.message;
        })
        .then(function () { star.disabled = false; });
    });
  }

  function reloadCards() {
    if (!cards) return;
    fetch(base + "/api/bookmarks/cards", { headers: { "Accept": "text/html" } })
      .then(function (r) { return r.ok ? r.text() : null; })
      .then(function (html) { if (html !== null) cards.innerHTML = html; })
      .catch(function () { /* offline: keep what's shown */ });
  }

  if (cards) {
    cards.addEventListener("click", function (ev) {
      var btn = ev.target.closest(".bm-remove");
      if (!btn) return;
      var card = btn.closest(".bm-card");
      card.classList.add("leaving");
      post("/api/bookmarks/remove", { url: btn.dataset.url })
        .then(reloadCards)
        .catch(function () { card.classList.remove("leaving"); });
    });
  }

  // another tab or device changed them
  document.addEventListener("zortex:bookmarks", function (ev) {
    var d = ev.detail || {};
    if (star && d.url === star.dataset.url) showStar(!!d.bookmarked);
    reloadCards();
  });
  document.addEventListener("zortex:resync", reloadCards);
})();
