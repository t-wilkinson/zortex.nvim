// zortex serve: tag tables (!@[...] in a note, @[...] link pages): sort by
// a column, filter by text, kind or tag; and tag indexes, whose chips load
// a table. Event delegation, so tables that arrive with a redrawn note work
// without setup.
(function () {
  "use strict";

  function cellValue(row, i) {
    var td = row.cells[i];
    if (!td) return "";
    return td.dataset.v != null ? td.dataset.v : td.textContent.trim();
  }
  function compare(a, b) {
    var na = parseFloat(a), nb = parseFloat(b);
    if (!isNaN(na) && !isNaN(nb) && String(na) === a.replace(/^0+(?=\d)/, "") && String(nb) === b.replace(/^0+(?=\d)/, "")) return na - nb;
    if (a === "" && b !== "") return 1; // empty cells last
    if (b === "" && a !== "") return -1;
    return a.localeCompare(b, undefined, { numeric: true, sensitivity: "base" });
  }

  function sortBy(btn) {
    var th = btn.closest("th"), table = btn.closest("table");
    var i = Array.prototype.indexOf.call(th.parentNode.children, th);
    var dir = th.getAttribute("aria-sort") === "ascending" ? -1 : 1;
    Array.prototype.forEach.call(th.parentNode.children, function (h) { h.removeAttribute("aria-sort"); });
    th.setAttribute("aria-sort", dir === 1 ? "ascending" : "descending");
    var body = table.tBodies[0];
    var rows = Array.prototype.slice.call(body.rows);
    rows.sort(function (a, b) {
      var x = cellValue(a, i), y = cellValue(b, i);
      if (x === "" || y === "") return compare(x, y); // empty last either way
      return dir * compare(x, y);
    });
    rows.forEach(function (r) { body.appendChild(r); });
  }

  function filter(box) {
    var input = box.querySelector(".tt-filter");
    var words = (input ? input.value : "").toLowerCase().split(/\s+/).filter(Boolean);
    var kinds = [], tags = [];
    Array.prototype.forEach.call(box.querySelectorAll(".tt-chip[aria-pressed=true]"), function (c) {
      if (c.dataset.kind) kinds.push(c.dataset.kind);
      if (c.dataset.tag) tags.push(c.dataset.tag);
    });
    var shown = 0, rows = box.querySelectorAll("tbody tr");
    Array.prototype.forEach.call(rows, function (r) {
      var text = r.textContent.toLowerCase();
      var rowTags = (r.dataset.tags || "").split(" ");
      var ok = words.every(function (w) { return text.indexOf(w) >= 0; }) &&
        (!kinds.length || kinds.indexOf(r.dataset.kind) >= 0) &&
        tags.every(function (t) { return rowTags.indexOf(t) >= 0; });
      r.hidden = !ok;
      if (ok) shown++;
    });
    var count = box.querySelector(".tt-count");
    if (count) count.textContent = shown === rows.length ? "" : shown + " of " + rows.length;
  }

  document.addEventListener("click", function (e) {
    var sort = e.target.closest(".tag-table .tt-sort");
    if (sort) return sortBy(sort);
    var chip = e.target.closest(".tag-table .tt-chip");
    if (chip) {
      chip.setAttribute("aria-pressed", chip.getAttribute("aria-pressed") === "true" ? "false" : "true");
      filter(chip.closest(".tag-table"));
    }
  });
  document.addEventListener("input", function (e) {
    if (e.target.classList && e.target.classList.contains("tt-filter")) filter(e.target.closest(".tag-table"));
  });

  // ---------------------------------------------------------------------------
  // Tag indexes: a chip loads its search's table under the rows. The choice
  // lives in the URL (#tags=rtos+embedded), so it can be linked and the back
  // button undoes it; nothing is chosen at first. Without this script the
  // chips are plain links to the search's page.
  // ---------------------------------------------------------------------------
  var base = document.body.dataset.base || "";

  function hashQuery() {
    var m = /^#tags=(.*)$/.exec(location.hash);
    if (!m) return "";
    try { return decodeURIComponent(m[1].replace(/\+/g, " ")); } catch (e) { return ""; }
  }
  // readable in the address bar: #tags=R/rust,rl+async
  function encodeQuery(q) {
    return encodeURIComponent(q).replace(/%2F/gi, "/").replace(/%2C/gi, ",").replace(/%20/g, "+");
  }

  function show(index, q) {
    var table = index.querySelector(".ti-table");
    Array.prototype.forEach.call(index.querySelectorAll(".ti-chip"), function (c) {
      if (c.dataset.q === q) c.setAttribute("aria-current", "true");
      else c.removeAttribute("aria-current");
    });
    if (!q) { table.innerHTML = ""; delete table.dataset.q; return; }
    if (table.dataset.q === q && table.firstChild) return;
    table.dataset.q = q;
    table.classList.add("loading");
    var url = base + "/api/tagtable?q=" + encodeURIComponent(q) + "&from=" + encodeURIComponent(index.dataset.from || "");
    fetch(url, { cache: "no-store" })
      .then(function (r) { return r.ok ? r.text() : Promise.reject(r.status); })
      .then(function (html) { if (table.dataset.q === q) table.innerHTML = html; })
      .catch(function () { if (table.dataset.q === q) table.innerHTML = '<p class="tt-empty dim">Could not load this search.</p>'; })
      .then(function () { table.classList.remove("loading"); });
  }

  // the hash's chip, in the first index that has it; the others clear.
  // scroll: bring that index into view (a link to it, not a click on it)
  function apply(scroll) {
    var q = hashQuery(), done = false;
    Array.prototype.forEach.call(document.querySelectorAll(".tag-index"), function (index) {
      var has = q && !done && Array.prototype.some.call(index.querySelectorAll(".ti-chip"), function (c) { return c.dataset.q === q; });
      show(index, has ? q : "");
      if (has) {
        done = true;
        if (scroll === true) index.scrollIntoView({ block: "start" });
      }
    });
  }

  document.addEventListener("click", function (e) {
    var chip = e.target.closest(".tag-index .ti-chip");
    if (!chip || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
    if (e.defaultPrevented) return; // editing the note: the editor has the click
    e.preventDefault();
    var q = chip.getAttribute("aria-current") === "true" ? "" : chip.dataset.q;
    var url = location.pathname + location.search + (q ? "#tags=" + encodeQuery(q) : "");
    history.pushState(null, "", url);
    apply(false);
  });
  window.addEventListener("popstate", function () { apply(false); });
  window.addEventListener("hashchange", function () { apply(true); });
  // a note redrawn in place (live.js) comes back with empty indexes
  document.addEventListener("zortex:note-updated", function () {
    Array.prototype.forEach.call(document.querySelectorAll(".tag-index .ti-table"), function (t) { delete t.dataset.q; });
    apply(false);
  });
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", function () { apply(true); });
  else apply(true);
})();
