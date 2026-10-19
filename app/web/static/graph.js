// /graph: hovering a note marks the notes it links with, a tag marks its
// notes, and the filter box narrows the cards, tags and unlinked notes
// ("@word" filters by tag; Enter opens the first match).
(function () {
  "use strict";
  var page = document.getElementById("graph-page");
  if (!page) return;
  var each = function (list, f) { Array.prototype.forEach.call(list, f); };
  var notes = page.querySelectorAll(".gt-note");
  var tagButtons = page.querySelectorAll(".gt-tag");
  var info = document.getElementById("gt-tag-info");
  var box = document.getElementById("graph-q");
  var status = document.getElementById("graph-status");
  var tag = null; // the selected tag

  // ---- marking -------------------------------------------------------------
  function tagsOf(el) { return (el.dataset.tags || "").split(" "); }
  function clear() {
    page.classList.remove("focus");
    each(page.querySelectorAll(".gt-note.hit, .gt-note.self"), function (el) { el.classList.remove("hit", "self"); });
  }
  function markTag() {
    clear();
    if (!tag) return;
    page.classList.add("focus");
    each(notes, function (el) { if (tagsOf(el).indexOf(tag) >= 0) el.classList.add("hit"); });
  }
  function markLinks(a) {
    clear();
    page.classList.add("focus");
    var rels = (a.dataset.links || "").split("\n");
    each(notes, function (el) {
      if (el.dataset.rel === a.dataset.rel) el.classList.add("self");
      else if (rels.indexOf(el.dataset.rel) >= 0) el.classList.add("hit");
    });
  }
  page.addEventListener("mouseover", function (e) { var a = e.target.closest(".gt-note"); if (a) markLinks(a); });
  page.addEventListener("mouseout", function (e) { if (e.target.closest(".gt-note")) markTag(); });
  page.addEventListener("focusin", function (e) { var a = e.target.closest(".gt-note"); if (a) markLinks(a); });
  page.addEventListener("focusout", function (e) { if (e.target.closest(".gt-note")) markTag(); });

  function selectTag(b) {
    tag = b && b.dataset.tag !== tag ? b.dataset.tag : null;
    each(tagButtons, function (x) { x.setAttribute("aria-pressed", String(x.dataset.tag === tag)); });
    if (info) {
      info.hidden = !tag;
      info.textContent = "";
      if (tag) {
        var n = 0;
        each(notes, function (el) { if (tagsOf(el).indexOf(tag) >= 0) n++; });
        var a = document.createElement("a");
        a.href = b.dataset.href;
        a.textContent = "@" + b.dataset.name + " page";
        info.append(n + " marked · ", a);
      }
    }
    markTag();
  }
  each(tagButtons, function (b) { b.addEventListener("click", function () { selectTag(b); }); });

  // ---- (children): to where a note listed again is expanded ----------------
  function reveal(id, smooth) {
    var el = id && document.getElementById(id);
    if (!el || !page.contains(el)) return false;
    // open the lists it is in, and show it if the filter hid it
    for (var p = el; p && p !== page; p = p.parentElement) {
      if (p.tagName === "DETAILS") p.open = true;
      if (p.hidden) p.hidden = false;
    }
    if (el.tagName === "LI") {
      var own = el.querySelector(":scope > details");
      if (own) own.open = true;
    }
    el.classList.remove("gt-flash");
    void el.offsetWidth; // restart the animation
    el.classList.add("gt-flash");
    el.scrollIntoView({ block: "center", behavior: smooth ? "smooth" : "auto" });
    return true;
  }
  page.addEventListener("click", function (e) {
    var a = e.target.closest("a.gt-goto");
    if (!a) return;
    var id = a.getAttribute("href").slice(1);
    if (reveal(id, true)) {
      e.preventDefault();
      history.replaceState(null, "", "#" + id);
    }
  });
  if (location.hash.indexOf("#gt-") === 0) reveal(location.hash.slice(1), false);

  // ---- filtering -----------------------------------------------------------
  each(page.querySelectorAll(".graph-tree details"), function (d) { d.dataset.open = d.open ? "1" : ""; });
  function textOf(el) { return (el.textContent + " " + (el.dataset.rel || "")).toLowerCase(); }
  function has(text, words) { return words.every(function (w) { return text.indexOf(w) >= 0; }); }
  function ownNote(li) { return li.querySelector(":scope > .gt-note, :scope > details > summary > .gt-note"); }
  function ownTitle(li) { return li.querySelector(":scope > details > summary"); }

  function filter() {
    var v = box.value.trim().toLowerCase();
    var byTag = v.charAt(0) === "@";
    var words = (byTag ? v.slice(1) : v).split(/\s+/).filter(Boolean);
    var on = words.length > 0;
    page.classList.toggle("filtering", on);
    each(page.querySelectorAll(".gt-q"), function (el) { el.classList.remove("gt-q"); });

    var shownTags = 0;
    each(tagButtons, function (b) {
      b.hidden = on && !has(b.dataset.tag, words);
      if (!b.hidden) shownTags++;
    });
    function matches(a) {
      if (!a) return false;
      if (byTag) return tagsOf(a).some(function (t) { return t && has(t, words); });
      return has(textOf(a), words);
    }
    var found = 0;
    function mark(a) { if (a && !a.classList.contains("gt-q")) { a.classList.add("gt-q"); found++; } }

    // tree: children before parents, so a parent sees whether any child matched
    var items = Array.prototype.slice.call(page.querySelectorAll(".graph-tree li")).reverse();
    items.forEach(function (li) {
      li.classList.remove("gt-m");
      if (!on) { li.hidden = false; return; }
      var a = ownNote(li);
      var self = matches(a);
      if (!self && !byTag && li.classList.contains("gt-sec")) self = has(textOf(ownTitle(li)), words);
      if (self && a) mark(a);
      var vis = self || !!li.querySelector("li.gt-m");
      li.classList.toggle("gt-m", vis);
      li.hidden = !vis;
    });
    // a matching section shows everything under it
    if (on && !byTag) {
      each(page.querySelectorAll(".graph-tree li.gt-sec.gt-m"), function (sec) {
        if (has(textOf(ownTitle(sec)), words)) each(sec.querySelectorAll("li"), function (li) { li.hidden = false; });
      });
    }
    each(page.querySelectorAll(".graph-tree details"), function (d) {
      d.open = on ? !!d.querySelector("li.gt-m") : d.dataset.open === "1";
    });
    each(page.querySelectorAll(".gt-card"), function (card) {
      if (!on) { card.hidden = false; return; }
      var head = card.querySelector("h2");
      var self = matches(head.querySelector(".gt-note")) || (!byTag && has(textOf(head), words));
      if (self) {
        mark(head.querySelector(".gt-note"));
        each(card.querySelectorAll("li"), function (li) { li.hidden = false; });
      }
      card.hidden = !self && !card.querySelector("li.gt-m");
    });
    each(page.querySelectorAll(".gt-unlinked li"), function (li) {
      var a = li.querySelector(".gt-note");
      var m = on && matches(a);
      if (m) mark(a);
      li.hidden = on && !m;
    });
    if (status) {
      status.textContent = on ? found + (found === 1 ? " note" : " notes") + ", " + shownTags + (shownTags === 1 ? " tag" : " tags") : "";
    }
  }
  if (box) {
    box.addEventListener("input", filter);
    box.addEventListener("keydown", function (e) {
      if (e.key === "Enter") {
        var first = page.querySelector(".gt-note.gt-q");
        if (first) { e.preventDefault(); location.href = first.href; }
      } else if (e.key === "Escape" && box.value) {
        box.value = "";
        filter();
      }
    });
    if (box.value) filter(); // kept by the browser on back
  }
})();
