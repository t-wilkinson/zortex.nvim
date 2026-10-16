-- services/search.lua - Structural search: index, matching and ranking
--
-- Results are sections shown as breadcrumbs of their hierarchy, then matching
-- lines. Search words are matched against a section's PATH, in order:
-- earlier words match ancestors, the last word matches the section itself,
-- and consecutive words may share one section. So "2 4" finds 1 › 2 › 3 › 4,
-- 2 › 4 and 2 › 3 › 4, but not 4 › 2.
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
--                       rank higher. Stored in notes_dir/.z/search_history.json
--   breadcrumb_display
--                       reserved (results always show the full breadcrumb)
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
				local sections = {}
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
					sections[#sections + 1] = {
						node = node,
						filepath = filepath,
						breadcrumb = node:get_breadcrumb(" › "),
						path = typed,
						root_level = root_level,
					}
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
-- may share an element. nil when there is no such match.
-- best[j][i]: words 1..j matched, word j on element i.
local function path_match(path, tokens)
	local n, m = #path, #tokens
	if n == 0 then
		return nil
	end
	local prev = {}
	for i = 1, n do
		local q = token_score(tokens[1], path[i])
		prev[i] = q > 0 and q or nil
	end
	for j = 2, m do
		local cur, run = {}, nil -- run = best of prev[1..i]
		for i = 1, n do
			if prev[i] and (not run or prev[i] > run) then
				run = prev[i]
			end
			local q = token_score(tokens[j], path[i])
			if run and q > 0 then
				cur[i] = run + q
			end
		end
		prev = cur
	end
	return prev[n]
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
local function match_sections(index, tokens, allowed, with_children)
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
			if #tokens == 0 then
				-- Empty prompt: top-level sections only
				if #sec.path == 1 and allowed(sec) then
					score = type_bonus(node)
				end
			elseif allowed(sec) then
				local q = path_match(sec.path, tokens)
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
		return a.results[1].filepath < b.results[1].filepath
	end)

	local out = {}
	for _, g in ipairs(groups) do
		vim.list_extend(out, g.results) -- already in document order
	end
	return out
end

-- AND match: every token must appear somewhere in the line.
local function match_lines(index, tokens)
	local results = {}
	if #tokens == 0 then
		return results
	end
	for _, file in ipairs(index) do
		for _, ln in ipairs(file.lines) do
			local all = true
			for _, tok in ipairs(tokens) do
				if not ln.lower:find(tok.text, 1, true) then
					all = false
					break
				end
			end
			if all then
				results[#results + 1] = {
					result_type = "line",
					filepath = ln.filepath,
					lnum = ln.lnum,
					line = ln.line,
					article_name = ln.article_name,
				}
			end
		end
	end
	return results
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

-- Full query over a pre-built index.
--   "section" mode: section matches (with their direct sub-sections), then
--                   lines containing every word
--   "article" mode: articles only
--   "text" mode:    lines containing the prompt as typed (match_text)
-- Results are capped at max_results and numbered (`rank`) for the picker.
---@param opts { mode?: "section"|"article"|"text" }?
function M.query_index(index, prompt, opts)
	local c = cfg()
	local mode = (opts and opts.mode) or c.default_mode or "section"
	local tokens = tokenize(prompt)

	local results
	if mode == "text" then
		results = match_text(index, prompt)
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
		local allowed = (typed or (opts and opts.all_sections)) and function()
			return true
		end or section_filter(#tokens)
		results = match_sections(index, tokens, allowed, true)
		vim.list_extend(results, match_lines(index, tokens))
	end

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
--- filesystem.
function M.files()
	return require("zortex.core.notes").files({ include_archived = true })
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
