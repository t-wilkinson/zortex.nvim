-- core/tag_index.lua - Tag indexes: labels whose lines are tag searches
--
--   Topics:
--   - AI @[rl, ai-model]          a chip, and a group of the chips under it
--     - Reinforcement learning @[rl]
--   - Embedded                    a group: its chip searches everything under it
--     - RTOS @[rtos embedded]
--
-- A top-level label is an index when its lines, up to the first blank line,
-- are all list items (or bare @[...] lines) holding at most one search, at
-- least one line has one, and an item without one has items under it. The
-- web app shows an index as rows of chips over one table (app/web/tagindex.go
-- has the same rule); following the label (gx) opens it there.
local M = {}

local syntax = require("zortex.core.syntax")

local function trim(s)
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- The one tag search among spans: span (or nil), ok (false: several, or
-- one shown in place with !@[...])
local function search_of(spans)
	local found
	for _, sp in ipairs(spans) do
		if sp.type == "tag_search" then
			if found or sp.embed then
				return nil, false
			end
			found = sp
		end
	end
	return found, true
end

local function chip_name(text)
	local t = syntax.strip_attributes(text):gsub("%*%*", ""):gsub("`", "")
	return trim((t:gsub("%s+", " ")))
end

--- The index whose label is at lnum, or nil:
--- { lnum, last, name, nodes = { { lnum, name, query, indent, children }... } }
function M.at_label(doc, lnum)
	local d = doc:info(lnum)
	if not d or d.kind ~= "label" or d.item or (d.indent or 0) > 0 or doc:in_code(lnum) then
		return nil
	end
	local ix = { lnum = lnum, last = lnum, name = d.text or "", nodes = {} }
	local all, searches = {}, 0
	for l = lnum + 1, #doc.lines do
		local line = doc.lines[l]
		if trim(line) == "" then
			break
		end
		local ld = doc:info(l)
		local sp, ok = search_of(doc:inline(l))
		if not ok then
			return nil
		end
		local node = { lnum = l, indent = ld.indent or 0, children = {} }
		local from
		if ld.item and ld.kind == "label" then
			-- "- Embedded:": a group named by its text
			if sp then
				return nil
			end
			node.name = ld.text or ""
		elseif ld.item and ld.kind == "item" then
			from = ld.item.content_col
		elseif ld.kind == "text" and sp then
			from = #line:match("^%s*")
		else
			return nil
		end
		if sp then
			searches = searches + 1
			node.query = trim(sp.content)
			node.name = chip_name(line:sub(from + 1, sp.s) .. " " .. line:sub(sp.e + 1))
		elseif not node.name then
			node.name = chip_name(line:sub(from + 1))
		end
		ix.last = l
		all[#all + 1] = node
	end
	if searches == 0 then
		return nil
	end
	local stack = {}
	for i, n in ipairs(all) do
		while #stack > 0 and stack[#stack].indent >= n.indent do
			table.remove(stack)
		end
		if #stack == 0 then
			table.insert(ix.nodes, n)
		else
			table.insert(stack[#stack].children, n)
		end
		stack[#stack + 1] = n
		if not n.query and (not all[i + 1] or all[i + 1].indent <= n.indent) then
			return nil
		end
	end
	return ix
end

--- A search's scope ("R/#Rust/", "/", "") and tags ("rust async, rl").
function M.query_parts(q)
	q = trim(q)
	local i = q:match(".*()/")
	if not i then
		return "", q
	end
	return q:sub(1, i), trim(q:sub(i + 1))
end

--- One search for any of qs ("rl", "ml" -> "rl, ml"), or nil when they look
--- in different places.
function M.union(qs)
	if #qs == 0 then
		return nil
	end
	local scope = M.query_parts(qs[1])
	local tags, seen = {}, {}
	for _, q in ipairs(qs) do
		local s, t = M.query_parts(q)
		if s ~= scope then
			return nil
		end
		for alt in t:gmatch("[^,]+") do
			alt = trim(alt:gsub("%s+", " "))
			if alt ~= "" and not seen[alt] then
				seen[alt] = true
				tags[#tags + 1] = alt
			end
		end
	end
	return scope .. table.concat(tags, ", ")
end

local function queries(n, out)
	out = out or {}
	if n.query then
		out[#out + 1] = n.query
	end
	for _, c in ipairs(n.children) do
		queries(c, out)
	end
	return out
end

--- What choosing a line's chip searches: its own search, or the union of
--- those under it.
function M.group_query(n)
	return n.query or M.union(queries(n))
end

local function find(nodes, lnum)
	for _, n in ipairs(nodes) do
		if n.lnum == lnum then
			return n
		end
		local hit = find(n.children, lnum)
		if hit then
			return hit
		end
	end
end

--- The index lnum is in (its label or one of its lines), or nil. Returns
--- the index and, on one of its lines, that line's chip search.
function M.at(doc, lnum)
	for l = lnum, 1, -1 do
		local d = doc:info(l)
		if not d then
			return nil
		end
		if l < lnum and trim(doc.lines[l]) == "" then
			return nil
		end
		if d.kind == "label" and not d.item and (d.indent or 0) == 0 then
			local ix = M.at_label(doc, l)
			if not ix or lnum > ix.last then
				return nil
			end
			if l == lnum then
				return ix, nil
			end
			local n = find(ix.nodes, lnum)
			return ix, n and M.group_query(n) or nil
		end
	end
	return nil
end

return M
