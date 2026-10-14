// zortex serve: tag tables (!@[...] in a note, @[...] link pages): sort by
// a column, filter by text, kind or tag. Event delegation, so tables that
// arrive with a redrawn note work without setup.
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
})();
