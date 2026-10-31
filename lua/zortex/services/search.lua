-- services/search.lua - Structural search: index, matching and ranking
--
-- Results are sections shown as breadcrumbs of their hierarchy, then matching
-- lines. Search words are matched against a section's PATH, in order:
-- earlier words match ancestors, the last word matches the section itself,
-- and consecutive words may share one section. So "2 4" finds 1 › 2 › 3 › 4,
-- 2 › 4 and 2 › 3 › 4, but not 4 › 2. A line's path is its section's path
-- and then the line, so "car oil" finds "- oil change" under "Car", and a
-- line holding every word still matches (the words share the line).
--
-- A scope ({ filepath, first, last, depth }: a section, from the picker's
-- narrow key) keeps only what is inside it: every section at any depth and
-- every line, no result cap, and the words match the path below the scope.
--
-- Word syntax: "@@name" articles only, "#name" headings only, ":name" labels
-- only, "*name" bold headings only, plain words any section. "_" or "\ "
-- inside a word is a space ("1.4_zortex"). A prefix alone ("@@") matches any
-- section of that type.
--
-- Ranking:
--   score  = 100 × word quality (exact 3, prefix 2, substring 1, summed)
--          + type bonus (article 2000, heading 1000 − 50 × level,
--            bold heading 400, label 300)
--   order  = files grouped by their best score (live notes before archived),
--            then document order inside a file, so parents precede children.
--   The direct sub-sections of a match are listed under it.
--
-- Plain text mode ("text") skips all of the above: the prompt is one literal
-- string (no word syntax, spaces included) matched against every line,
-- headings too. Smart case: case-insensitive unless the prompt has a capital.
-- Results are lines, live notes before archived, then in document order.
--
-- Configuration (Config.ui.search, see config.lua):
--   default_mode        "section" (sections + matching lines) | "article"
--                       | "text" (plain text over every line)
--   max_results         cap on results per query
--   token_filters       [n] = section types that may be a result when the
--                       prompt has n words ("all" = every type); bold
--                       headings and labels above the first heading count
--                       as H1. Typed words (#, :, *, @@) ignore the filter.
--   access_decay_rate   per-day decay of a note's "opened from search" score
--   history             { enabled, max_entries, score_decay, propagation_decay }
--                       per-section history (see services/search_history);
--                       both add a boost so frequently/recently opened places
--                       rank higher. Stored per machine (core/state, search_history.json)
--
-- No UI here: ui/picker/search.lua is the picker, zortex.query.search the
-- plain-data entry point.
local M = {}
local Config = require("zortex.config")

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------

-- Built-in defaults (Config.defaults.ui.search) overlaid with `opts`.
function M.setup(opts)
	local defaults = vim.deepcopy(Config.defaults and Config.defaults.ui and Config.defaults.ui.search or {})
	M.config = vim.tbl_deep_extend("force", defaults, opts or {})
	return M.config
end

local function cfg()
	return M.config or M.setup()
end

-- Predicate over index entries: may this section be a result when the
-- prompt has `n` words? Bold headings and labels above the first heading of
-- their article are treated as level-1 headings.
local function section_filter(n)
	local filters = cfg().token_filters or {}
	local spec = filters[math.max(1, math.min(n, #filters))]
	if spec == nil or spec == "all" then
		return function()
			return true
		end
	end

	local function allows(node_type, level)
		for _, rule in ipairs(spec) do
			if type(rule) == "string" then
				if node_type == rule then
					return true
				end
			elseif node_type == rule[1] and (not rule.max_level or (level or 0) <= rule.max_level) then
				return true
			end
		end
		return false
	end

	return function(entry)
		local node = entry.node
		if entry.root_level and (node.type == "bold_heading" or node.type == "label") then
			return allows("heading", 1)
		end
		return allows(node.type, node.level)
	end
end

-- ---------------------------------------------------------------------------
-- Tokenization
-- ---------------------------------------------------------------------------

local TOKEN_PREFIXES = {
	{ "@@", "article" },
	{ "#", "heading" },
	{ ":", "label" },
	{ "*", "bold_heading" },
}

-- Split a prompt into typed words. "\ " and "_" are spaces inside a word.
local function tokenize(query)
	local tokens = {}
	local escaped = (query or ""):gsub("\\ ", "\0")
	for word in escaped:gmatch("%S+") do
		word = word:gsub("%z", " "):gsub("_", " "):lower()
		local kind = "general"
		for _, pref in ipairs(TOKEN_PREFIXES) do
			if word:sub(1, #pref[1]) == pref[1] then
				kind = pref[2]
				word = word:sub(#pref[1] + 1)
				if kind == "heading" then
					word = word:gsub("^#+", "")
				end
				break
			end
		end
		tokens[#tokens + 1] = { type = kind, text = word }
	end
	return tokens
end

-- ---------------------------------------------------------------------------
-- Index helpers (shared by indexing + matching)
-- ---------------------------------------------------------------------------

-- Collect set of line numbers that are structural section start lines
local function collect_structural_lines(node, set)
	if node.type ~= "root" then
		set[node.start_line] = true
	end
	for _, child in ipairs(node.children) do
		collect_structural_lines(child, set)
	end
end

-- Find the article node whose range contains lnum
local function get_article_for_line(tree, lnum)
	for _, child in ipairs(tree.children) do
		if child.type == "article" and lnum >= child.start_line and lnum <= child.end_line then
			return child
		end
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- Indexing: ALL disk reads, tree parsing and lower-casing happen here, once.
-- The picker builds the index when it opens; each keystroke then filters this
-- purely in-memory structure (see M.query_index).
-- ---------------------------------------------------------------------------

-- A note's file name without folder or extension ("z/bread.zortex" -> "bread"):
-- searched as one more alias of each of its articles.
local function file_stem(filepath)
	local name = filepath:match("([^/]+)$") or filepath
	return name:match("^(.+)%.[^.]+$") or name
end

function M.build_index(files)
	local index = {}
	for _, filepath in ipairs(files) do
		local stem = file_stem(filepath)
		local stem_lower = stem:lower()
		local doc = require("zortex.core.document").get(filepath)
		local lines = doc and doc.lines
		if lines and not doc:has_tag("Ignore") then
			local tree = doc.tree
			if tree then
				-- Lower-case every line a single time.
				local lower_lines = {}
				for i, l in ipairs(lines) do
					lower_lines[i] = l:lower()
				end

				-- Structural start lines so the line scan can skip them.
				local structural = {}
				collect_structural_lines(tree, structural)

				-- Pre-compute section candidates: each carries its typed,
				-- lower-cased path (ancestors + self) for fast matching.
				-- owner[lnum]: the innermost section a line is in.
				local sections, owner = {}, {}
				local nodes = tree:get_descendants()
				for _, node in ipairs(nodes) do
					local root_level = true
					for _, anc in ipairs(node:ancestors()) do
						if anc.type == "heading" then
							root_level = false
							break
						end
					end
					local typed = {}
					for _, p in ipairs(node:get_full_path()) do
						if not p:is_root() then
							local texts = { (p.text or ""):lower() }
							for _, alias in ipairs(p.names or {}) do
								texts[#texts + 1] = alias:lower()
							end
							if p.type == "article" and stem_lower ~= texts[1] then
								texts[#texts + 1] = stem_lower
							end
							typed[#typed + 1] = { type = p.type, text = texts[1], texts = texts }
						end
					end
					local hay = {}
					for _, el in ipairs(typed) do
						hay[#hay + 1] = table.concat(el.texts, "\0")
					end
					local sec = {
						node = node,
						filepath = filepath,
						breadcrumb = node:get_breadcrumb(" › "),
						path = typed,
						hay = table.concat(hay, "\0"), -- every text of the path, for a quick test
						root_level = root_level,
					}
					sections[#sections + 1] = sec
					-- document order: a sub-section overwrites its parent
					for l = node.start_line, node.end_line or node.start_line do
						owner[l] = sec
					end
				end

				-- Pre-compute line candidates (skip structural + blank lines).
				local line_items = {}
				for lnum, line in ipairs(lines) do
					if not structural[lnum] and vim.trim(line) ~= "" then
						local article = get_article_for_line(tree, lnum)
						line_items[#line_items + 1] = {
							filepath = filepath,
							lnum = lnum,
							line = line,
							lower = lower_lines[lnum],
							article_name = article and article.text or nil,
							sec = owner[lnum],
							el = { type = "line", texts = { vim.trim(lower_lines[lnum]) } },
						}
					end
				end

				-- Article ranges, for naming the article of a text match.
				local articles = {}
				for _, child in ipairs(tree.children) do
					if child.type == "article" then
						articles[#articles + 1] = child
					end
				end

				index[#index + 1] = {
					filepath = filepath,
					-- ties go by path from the notes folder; a page's copy in
					-- .z/html by the page's path (as the web app's search)
					sort_key = require("zortex.core.documents").display_rel(filepath) or filepath,
					stem = stem,
					archived = require("zortex.core.notes").is_archived(filepath),
					raw_lines = lines,
					lower_lines = lower_lines,
					articles = articles,
					sections = sections,
					lines = line_items,
				}
			end
		end
	end
	return index
end

-- ---------------------------------------------------------------------------
-- Matching (pure in-memory, no I/O)
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Ordered path matching & scoring
-- ---------------------------------------------------------------------------

local TYPE_OK = {
	general = function()
		return true
	end,
	article = function(t)
		return t == "article"
	end,
	heading = function(t)
		return t == "heading"
	end,
	label = function(t)
		return t == "label"
	end,
	bold_heading = function(t)
		return t == "bold_heading"
	end,
}

-- Quality of one word on one path element: exact 3, prefix 2, substring 1,
-- 0 = no match. Article aliases count; a bare prefix ("@@") matches any
-- element of its type.
local function token_score(tok, el)
	if not TYPE_OK[tok.type](el.type) then
		return 0
	end
	if tok.text == "" then
		return 1
	end
	local best = 0
	for _, text in ipairs(el.texts or { el.text }) do
		local q = 0
		if text == tok.text then
			q = 3
		elseif text:sub(1, #tok.text) == tok.text then
			q = 2
		elseif text:find(tok.text, 1, true) then
			q = 1
		end
		if q > best then
			best = q
		end
	end
	return best
end

-- Best total word quality for matching the words along `path` in order, with
-- the LAST word on the last element (the section itself). Consecutive words
-- may share an element. nil when there is no such match. `from` skips the
-- elements before it (a scope's), `extra` is one more element after the
-- path (a line), so neither needs a new table.
-- best[j][i]: words 1..j matched, word j on element i.
local prev_s, cur_s = {}, {} -- reused: this runs for many lines per keystroke
local function path_match(path, tokens, from, extra)
	from = from or 1
	local count = #path - from + 1
	local n, m = count + (extra and 1 or 0), #tokens
	if n <= 0 then
		return nil
	end
	if m == 1 then
		-- one word: on the last element
		local q = token_score(tokens[1], extra or path[#path])
		return q > 0 and q or nil
	end
	local function el(i)
		return i <= count and path[from + i - 1] or extra
	end
	local prev, cur = prev_s, cur_s
	for i = 1, n do
		local q = token_score(tokens[1], el(i))
		prev[i] = q > 0 and q or false
	end
	for j = 2, m do
		local run = false -- best of prev[1..i]
		for i = 1, n do
			if prev[i] and (not run or prev[i] > run) then
				run = prev[i]
			end
			local q = run and token_score(tokens[j], el(i)) or 0
			cur[i] = (run and q > 0) and (run + q) or false
		end
		prev, cur = cur, prev
	end
	return prev[n] or nil
end

local function type_bonus(node)
	if node.type == "article" then
		return 2000
	elseif node.type == "heading" then
		return 1000 - (node.level or 1) * 50
	elseif node.type == "bold_heading" then
		return 400
	elseif node.type == "label" then
		return 300
	end
	return 0
end

local function section_result(sec, file, score, extra)
	local r = {
		result_type = "section",
		filepath = sec.filepath,
		node = sec.node,
		breadcrumb = sec.breadcrumb,
		score = score,
		archived = file.archived,
	}
	for k, v in pairs(extra or {}) do
		r[k] = v
	end
	return r
end

-- Section results, grouped by file (best file first, live before archived),
-- in document order within a file.
--   allowed(entry)    which sections may be results
--   with_children     also list the direct sub-sections of each match
-- Whether line `lnum` of `file` is inside `scope` (a section, its own
-- start line left out); everything is without a scope.
local function in_scope(scope, file, lnum)
	return not scope or (file.filepath == scope.filepath and lnum > scope.first and lnum <= scope.last)
end

-- The part of a path below the scope (the whole path without one)
local function below(scope)
	return scope and (scope.depth + 1) or 1
end

local function match_sections(index, tokens, allowed, with_children, scope)
	local history = require("zortex.services.search_history")
	local now = os.time()
	local groups = {}
	for _, file in ipairs(index) do
		local results, best = {}, -math.huge
		local file_boost = file.filepath and history.file_boost(file.filepath, now) or 0
		local matched = {} -- node -> score of explicit matches in this file
		for _, sec in ipairs(file.sections) do
			local node = sec.node
			local score
			if not in_scope(scope, file, node.start_line) then
				score = nil
			elseif #tokens == 0 then
				-- Empty prompt: top-level sections only (in a scope, all of them)
				if (scope or #sec.path == 1) and allowed(sec) then
					score = type_bonus(node)
				end
			elseif allowed(sec) then
				local q = path_match(sec.path, tokens, below(scope))
				score = q and (q * 100 + type_bonus(node)) or nil
			end

			if score then
				-- Frequently/recently opened notes and sections rank higher
				score = score + file_boost + history.section_boost(sec.filepath, sec.breadcrumb, now)
				matched[node] = score
				results[#results + 1] = section_result(sec, file, score)
				best = math.max(best, score)
			elseif with_children and #tokens > 0 and node.parent and matched[node.parent] then
				results[#results + 1] = section_result(sec, file, matched[node.parent], { child = true })
			end
		end
		if #results > 0 then
			groups[#groups + 1] = { file = file, results = results, best = best }
		end
	end

	table.sort(groups, function(a, b)
		if a.file.archived ~= b.file.archived then
			return not a.file.archived
		end
		if a.best ~= b.best then
			return a.best > b.best
		end
		return a.file.sort_key < b.file.sort_key
	end)

	local out = {}
	for _, g in ipairs(groups) do
		vim.list_extend(out, g.results) -- already in document order
	end
	return out
end

local NO_PATH = {}

-- Whether every word is somewhere on the line or its section's path (a
-- quick test before path_match; in a scope, path_match alone decides)
local function maybe(ln, tokens, scope)
	if scope then
		return true
	end
	local hay = ln.sec and ln.sec.hay or ""
	for _, tok in ipairs(tokens) do
		if not (ln.lower:find(tok.text, 1, true) or hay:find(tok.text, 1, true)) then
			return false
		end
	end
	return true
end

-- Lines whose path (their section's, then the line) the words match, the
-- last word on the line: grouped by file (best first, live before
-- archived), in document order inside a file. In a scope, an empty prompt
-- lists every line in it.
local function match_lines(index, tokens, scope)
	local groups = {}
	local last = tokens[#tokens]
	if (#tokens == 0 and not scope) or (last and last.type ~= "general") then
		return {}
	end
	for _, file in ipairs(index) do
		local results, best = {}, -math.huge
		for _, ln in ipairs(file.lines) do
			local score
			if not in_scope(scope, file, ln.lnum) then
				score = nil
			elseif #tokens == 0 then
				score = 0
			elseif ln.lower:find(last.text, 1, true) and maybe(ln, tokens, scope) then
				-- the cheap tests first: the last word is on the line, and
				-- every word is on the line or its section's path
				local q = path_match(ln.sec and ln.sec.path or NO_PATH, tokens, below(scope), ln.el)
				score = q and q * 100 or nil
			end
			if score then
				results[#results + 1] = {
					result_type = "line",
					filepath = ln.filepath,
					lnum = ln.lnum,
					line = ln.line,
					article_name = ln.article_name,
					section_node = ln.sec and ln.sec.node, -- what narrowing on it keeps
					score = score,
					archived = file.archived,
				}
				best = math.max(best, score)
			end
		end
		if #results > 0 then
			groups[#groups + 1] = { file = file, results = results, best = best }
		end
	end
	table.sort(groups, function(a, b)
		if a.file.archived ~= b.file.archived then
			return not a.file.archived
		end
		if a.best ~= b.best then
			return a.best > b.best
		end
		return a.file.sort_key < b.file.sort_key
	end)
	local out = {}
	for _, g in ipairs(groups) do
		vim.list_extend(out, g.results)
	end
	return out
end

-- Plain text: every line containing `prompt` literally (smart case), live
-- notes first, then document order. `col` is the 1-based start of the match.
-- A note whose file name contains `prompt` also gives its first article line
-- (`file_match`), before its other lines.
local function match_text(index, prompt)
	local results = {}
	if not prompt or prompt == "" then
		return results
	end
	local ignore_case = prompt:lower() == prompt
	local files = {}
	for _, file in ipairs(index) do
		if not file.archived then
			files[#files + 1] = file
		end
	end
	for _, file in ipairs(index) do
		if file.archived then
			files[#files + 1] = file
		end
	end
	for _, file in ipairs(files) do
		local haystack = ignore_case and file.lower_lines or file.raw_lines or {}
		local a = 1
		local stem = file.stem and (ignore_case and file.stem:lower() or file.stem)
		local named_lnum
		if stem and stem:find(prompt, 1, true) and file.raw_lines and #file.raw_lines > 0 then
			local first = (file.articles or {})[1]
			named_lnum = first and first.start_line or 1
			results[#results + 1] = {
				result_type = "line",
				filepath = file.filepath,
				lnum = named_lnum,
				line = file.raw_lines[named_lnum],
				article_name = first and first.text or nil,
				archived = file.archived,
				file_match = file.stem,
			}
		end
		for lnum, text in ipairs(haystack) do
			local col = lnum ~= named_lnum and text:find(prompt, 1, true)
			if col then
				local articles = file.articles or {}
				while articles[a] and articles[a].end_line < lnum do
					a = a + 1
				end
				local article = articles[a]
				if article and article.start_line > lnum then
					article = nil
				end
				results[#results + 1] = {
					result_type = "line",
					filepath = file.filepath,
					lnum = lnum,
					col = col,
					line = file.raw_lines[lnum],
					article_name = article and article.text or nil,
					archived = file.archived,
				}
			end
		end
	end
	return results
end

--- The scope of a result: what a search narrowed on it keeps. A section's
--- own, a line's section's (the line found by its path), nil for a line
--- outside any section.
function M.scope_of(r)
	local node = r and (r.result_type == "section" and r.node or r.section_node)
	if not node then
		return nil
	end
	local depth = 0
	local crumbs = {}
	for _, p in ipairs(node:get_full_path()) do
		if not p:is_root() then
			depth = depth + 1
			crumbs[#crumbs + 1] = p.text or ""
		end
	end
	return {
		filepath = r.filepath,
		first = node.start_line,
		last = node.end_line or node.start_line,
		depth = depth,
		breadcrumb = table.concat(crumbs, " › "),
	}
end

-- Full query over a pre-built index.
--   "section" mode: section matches (with their direct sub-sections), then
--                   lines whose path the words match (match_lines)
--   "article" mode: articles only
--   "text" mode:    lines containing the prompt as typed (match_text)
-- opts.scope (M.scope_of): only what is inside that section, every section
-- type, and no cap. Results are capped at max_results and numbered (`rank`)
-- for the picker.
---
--- opts.here (a note's path, the one being edited): its own sections and
--- lines come first, the words matched below its title (an empty prompt
--- lists its sections: a table of contents); its title and name match
--- nothing; then every other note as usual.
---@param opts { mode?: "section"|"article"|"text", scope?: table, all_sections?: boolean, here?: string }?
function M.query_index(index, prompt, opts)
	local c = cfg()
	local mode = (opts and opts.mode) or c.default_mode or "section"
	local scope = opts and opts.scope
	local tokens = tokenize(prompt)

	if opts and opts.here and not scope then
		local here = vim.fn.fnamemodify(opts.here, ":p")
		local file
		for _, f in ipairs(index) do
			if f.filepath and vim.fn.fnamemodify(f.filepath, ":p") == here then
				file = f
			end
		end
		if file then
			return M._with_here(index, file, prompt, tokens, opts, mode, c)
		end
	end

	local results
	if mode == "text" then
		results = match_text(index, prompt)
		if scope then
			results = vim.tbl_filter(function(r)
				return r.filepath == scope.filepath and r.lnum > scope.first and r.lnum <= scope.last
			end, results)
		end
	elseif mode == "article" then
		results = match_sections(index, tokens, function(entry)
			return entry.node.type == "article"
		end, false)
	else
		-- Typed words (#, :, *, @@) are explicit structural queries and may
		-- match at any depth; token_filters only shape untyped searches.
		local typed = false
		for _, tok in ipairs(tokens) do
			typed = typed or tok.type ~= "general"
		end
		-- opts.all_sections: every section at any depth (picking a place to
		-- move something to, where a deep label is as likely as a note)
		local allowed = (typed or scope or (opts and opts.all_sections)) and function()
			return true
		end or section_filter(#tokens)
		results = match_sections(index, tokens, allowed, true, scope)
		-- lines come after the sections: none would show past the cap
		if scope or not c.max_results or #results < c.max_results then
			vim.list_extend(results, match_lines(index, tokens, scope))
		end
	end

	local max = c.max_results
	if max and not scope and #results > max then
		results = vim.list_slice(results, 1, max)
	end
	for i, r in ipairs(results) do
		r.rank = i
	end
	return results
end

-- query_index with the note being edited first. Its own results are found
-- below its title (a scope of the whole note): its sections and lines, never
-- its title row, so its name matches nothing; an empty prompt lists its
-- sections, a table of contents. Then every other note as usual: typing the
-- note's own name ("Business" in @@Business) finds the other notes that
-- answer to it ("Business economics"), not this one's sections again.
function M._with_here(index, file, prompt, tokens, opts, mode, c)
	local whole = { filepath = file.filepath, first = 0, last = math.huge, depth = 1, breadcrumb = file.stem }
	local others = {}
	for _, f in ipairs(index) do
		if f ~= file then
			others[#others + 1] = f
		end
	end
	local own = {}
	if mode == "text" then
		if #tokens > 0 then
			own = M.query_index({ file }, prompt, vim.tbl_extend("force", opts, { here = false }))
		end
	elseif mode ~= "article" then
		own = match_sections({ file }, tokens, function()
			return true
		end, false, whole)
		if #tokens > 0 then
			vim.list_extend(own, match_lines({ file }, tokens, whole))
		end
	end
	-- never the note itself: its title (and @@ names) or a match on its file name
	local results = {}
	for _, r in ipairs(own) do
		local title = (r.node and r.node.type == "article") or r.file_match or (r.line and r.line:match("^@@"))
		if not title then
			r.here = true
			results[#results + 1] = r
		end
	end
	vim.list_extend(results, M.query_index(others, prompt, vim.tbl_extend("force", opts, { here = false })))
	local max = c.max_results
	if max and #results > max then
		results = vim.list_slice(results, 1, max)
	end
	for i, r in ipairs(results) do
		r.rank = i
	end
	return results
end

-- Exposed for tests
M._tokenize = tokenize
M._path_match = path_match

--- Every note to search, archived ones included, in a stable order (top-level
--- first, then by path; core/notes), so line results come out the same on any
--- filesystem; then the Markdown and HTML documents (core/documents).
function M.files()
	return require("zortex.core.notes").files({ include_archived = true, documents = true })
end

--- Search every note: { results, ... } as query_index returns them.
---@param opts { mode?: "section"|"article"|"text", files?: string[] }?
function M.search(prompt, opts)
	opts = opts or {}
	return M.query_index(M.build_index(opts.files or M.files()), prompt, opts)
end

M.tokenize = tokenize

--- The modes query_index understands, in the picker's <C-t> order.
M.MODES = { "section", "article", "text" }

return M
