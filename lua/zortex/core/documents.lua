-- core/documents.lua - Markdown and HTML files as read-only notes
--
-- The files in Config.documents' folders (default z/markdown and z/html)
-- join the notes for links, search and completion, without becoming notes:
-- [Rust ownership/#Borrowing] finds a heading in z/html/rust-ownership.html,
-- the search lists its sections and lines. Their tasks, links and tags don't
-- count anywhere else (projects, XP, backlinks from them, broken links in
-- them), and nothing in Zortex edits them.
--
--   Markdown   read where it is (Document.from_lines asks M.markdown): the
--              name is the front matter's title (else a first "# Title",
--              else the file name), aliases and tags from the front matter,
--              the file name as one more name; headings are sections. The
--              front matter's lines read as blank and setext headings as
--              "#" ones, so every line keeps its number.
--   HTML       converted (core/html) into notes_dir/.z/html/<path>.zortex,
--              rewritten when the page changes; that copy is what Neovim
--              indexes and opens (read-only). Its first lines say which page
--              it came from.
--
-- `zortex serve` reads the same files the same way (app/notes/documents.go);
-- the folders go to .z/syntax.json (core/syntax_config).
local M = {}

M.DEFAULT = { "z/markdown", "z/html" }

local MARKDOWN = { md = true, markdown = true }
local HTML = { html = true, htm = true }

local function Config()
	return require("zortex.config")
end

local function root()
	local dir = Config().notes_dir or ""
	return dir:match("/$") and dir or (dir .. "/")
end

--- The folders, notes-relative, without slashes at either end.
---@return string[]
function M.folders()
	local list = Config().documents
	if list == nil then
		list = M.DEFAULT
	end
	local out = {}
	for _, f in ipairs(type(list) == "table" and list or {}) do
		f = tostring(f):gsub("^%./", ""):gsub("^/+", ""):gsub("/+$", "")
		if f ~= "" then
			out[#out + 1] = f
		end
	end
	return out
end

local function ext(path)
	return (path:match("%.([%w]+)$") or ""):lower()
end

--- `path` from the notes folder, or nil when it is outside.
function M.rel(path)
	local r = root()
	if path:sub(1, #r) == r then
		return path:sub(#r + 1)
	end
	local real = vim.uv.fs_realpath(path)
	local rr = vim.uv.fs_realpath(r)
	if real and rr and real:sub(1, #rr + 1) == rr .. "/" then
		return real:sub(#rr + 2)
	end
	return nil
end

local function in_folders(rel)
	for _, f in ipairs(M.folders()) do
		if rel:sub(1, #f + 1) == f .. "/" then
			return true
		end
	end
	return false
end

--- "markdown" or "html" for a file in the documents' folders, else nil.
function M.kind(path)
	if not path then
		return nil
	end
	local e = ext(path)
	if not MARKDOWN[e] and not HTML[e] then
		return nil
	end
	local rel = M.rel(path)
	if not rel or not in_folders(rel) then
		return nil
	end
	return MARKDOWN[e] and "markdown" or "html"
end

local COPIES = ".z/html/"

--- Where an HTML page's note lives: .z/html/<path without .html>.zortex
function M.copy_path(rel)
	return root() .. COPIES .. rel:gsub("%.[^./]+$", "") .. (Config().extension or ".zortex")
end

--- The page a copy in .z/html was made from (absolute), or nil.
function M.source_of(path)
	local r = root()
	local prefix = r .. COPIES
	if not path or path:sub(1, #prefix) ~= prefix then
		return nil
	end
	local base = path:sub(#prefix + 1):gsub("%" .. (Config().extension or ".zortex") .. "$", "")
	for _, e in ipairs({ ".html", ".htm" }) do
		if vim.uv.fs_stat(r .. base .. e) then
			return r .. base .. e
		end
	end
	return nil
end

--- A document's path from the notes folder, as the server names it: the
--- page for a copy in .z/html, else the file's own.
function M.display_rel(path)
	local src = M.source_of(path)
	return M.rel(src or path)
end

-- =============================================================================
-- Markdown
-- =============================================================================

local function trim(s)
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function fence_of(line)
	local f = line:match("^%s*([`~][`~][`~]+)")
	if f and (f:match("^`+$") or f:match("^~+$")) then
		return f
	end
	return nil
end

local function plain(text)
	return trim((text:gsub("%[([^%]]*)%]%([^)]*%)", "%1"):gsub("[*_`]", "")))
end

-- "## Title ##" -> "Title", "Title {#id}" -> "Title"
local function heading_text(text)
	return trim((trim(text):gsub("%s+#+$", ""):gsub("%s*{#[^}]*}$", "")))
end

local function tag_word(s)
	s = trim(tostring(s)):gsub("^#", ""):gsub("[/%s]+", "-")
	return (s:gsub("[^%w_%-\128-\255]", ""))
end

local function stem_of(path)
	local name = path:match("([^/]+)$") or path
	return name:match("^(.+)%.[^.]+$") or name
end

--- A Markdown file's lines as Zortex reads them, and its header (names,
--- tags; the article starts on line 1). Same number of lines.
---@param lines string[]
---@param path string
---@return string[] lines, table header
function M.markdown(lines, path)
	local out = {}
	for i, l in ipairs(lines) do
		out[i] = l
	end
	if out[1] then
		out[1] = out[1]:gsub("^\239\187\191", "")
	end
	local title, aliases, tags = nil, {}, {}
	local fm, body = require("zortex.features.markdown_import").front_matter(out)
	if fm then
		for i = 1, body - 1 do
			out[i] = ""
		end
		for _, e in ipairs(fm) do
			local k, v = e.key:lower(), e.value
			if (k == "title" or k == "name") and type(v) == "string" and v ~= "" and not title then
				title = v
			elseif (k == "aliases" or k == "alias") and v then
				for _, a in ipairs(type(v) == "table" and v or { v }) do
					if a ~= "" then
						aliases[#aliases + 1] = a
					end
				end
			elseif (k == "tags" or k == "tag" or k == "keywords") and v then
				local list = type(v) == "table" and v or vim.split(v, "[,%s]+", { trimempty = true })
				for _, t in ipairs(list) do
					local w = tag_word(t)
					if w ~= "" then
						tags[#tags + 1] = w
					end
				end
			end
		end
	end

	local fence
	local first = true -- the first line with content after the front matter
	local i = body or 1
	while i <= #out do
		local line = out[i]
		local f = fence_of(line)
		if fence then
			if f and f:sub(1, 1) == fence then
				fence = nil
			end
		elseif f then
			fence = f:sub(1, 1)
			first = false
		elseif line:match("%S") then
			local hashes, text = line:match("^(#+)%s+(.-)%s*$")
			if hashes and #hashes <= 6 then
				text = heading_text(text)
				out[i] = hashes .. " " .. text
				if first and #hashes == 1 and not title then
					title = plain(text)
				end
			else
				local under = out[i + 1]
				local level = under and (under:match("^=+%s*$") and 1 or under:match("^%-%-+%s*$") and 2)
				if level and not line:match("^%s") and not line:match("^[-*+>|]") and not line:match("^%d+[.)]%s") then
					out[i] = ("#"):rep(level) .. " " .. trim(line)
					out[i + 1] = ""
					if first and level == 1 and not title then
						title = plain(line)
					end
					i = i + 1
				end
			end
			first = false
		end
		i = i + 1
	end

	local stem = stem_of(path)
	local names = { (title and title ~= "") and title or stem }
	local seen = { [names[1]:lower()] = true }
	for _, a in ipairs(aliases) do
		if not seen[a:lower()] then
			seen[a:lower()] = true
			names[#names + 1] = a
		end
	end
	if not seen[stem:lower()] then
		names[#names + 1] = stem
	end
	return out, { names = names, tags = tags, tag_lines = {}, name_lnum = 1, last_lnum = 0 }
end

-- =============================================================================
-- The files, and the HTML copies
-- =============================================================================

local made = {} -- page path -> { mtime, nsec, size } of the page last converted

local function read(path)
	local f = io.open(path, "rb")
	if not f then
		return nil
	end
	local text = f:read("*a")
	f:close()
	return text
end

--- Bring a page's copy up to date (written only when its text changes).
--- Returns the copy's path.
function M.ensure_copy(path)
	local rel = M.rel(path)
	if not rel then
		return nil
	end
	local copy = M.copy_path(rel)
	local st = vim.uv.fs_stat(path)
	if not st then
		return nil
	end
	local m = made[path]
	if m and m.mtime == st.mtime.sec and m.nsec == st.mtime.nsec and m.size == st.size and vim.uv.fs_stat(copy) then
		return copy
	end
	local text = read(path)
	if not text then
		return nil
	end
	local want = table.concat(require("zortex.core.html").convert(text, rel), "\n") .. "\n"
	if read(copy) ~= want then
		vim.fn.mkdir(vim.fn.fnamemodify(copy, ":h"), "p")
		local f = io.open(copy, "wb")
		if not f then
			return nil
		end
		f:write(want)
		f:close()
		require("zortex.core.document").invalidate(copy)
	end
	made[path] = { mtime = st.mtime.sec, nsec = st.mtime.nsec, size = st.size }
	return copy
end

--- Every document in the folders, as the paths Zortex reads: a Markdown
--- file itself, an HTML page's copy (brought up to date). Top folders
--- first, then by path.
---@return string[]
function M.paths()
	local fs = require("zortex.utils.filesystem")
	local r = root()
	local out = {}
	local function scan(dir)
		local h = vim.uv.fs_scandir(dir)
		if not h then
			return
		end
		while true do
			local name, t = vim.uv.fs_scandir_next(h)
			if not name then
				break
			end
			local full = dir .. "/" .. name
			if t == "directory" and not name:match("^%.") then
				scan(full)
			elseif t == "file" and not name:match("^%.") and not fs.is_conflict_copy(name) then
				local e = ext(name)
				if MARKDOWN[e] then
					out[#out + 1] = full
				elseif HTML[e] then
					local copy = M.ensure_copy(full)
					if copy then
						out[#out + 1] = copy
					end
				end
			end
		end
	end
	for _, f in ipairs(M.folders()) do
		scan(r .. f)
	end
	table.sort(out, function(a, b)
		local ra, rb = M.display_rel(a) or a, M.display_rel(b) or b
		local da, db = select(2, ra:gsub("/", "")), select(2, rb:gsub("/", ""))
		if da ~= db then
			return da < db
		end
		return ra < rb
	end)
	return out
end

--- Is `path` a document (a Markdown file in the folders, or a page's copy)?
function M.is_document(path)
	return M.kind(path) == "markdown" or M.source_of(path) ~= nil
end

--- Neovim opens a page's copy read-only: what it says comes from the page.
function M.setup()
	local group = vim.api.nvim_create_augroup("ZortexDocuments", { clear = true })
	vim.api.nvim_create_autocmd("BufReadPost", {
		group = group,
		pattern = "*/.z/html/*",
		callback = function(ev)
			if M.source_of(vim.api.nvim_buf_get_name(ev.buf)) then
				vim.bo[ev.buf].readonly = true
				vim.bo[ev.buf].modifiable = false
			end
		end,
	})
end

function M._reset()
	made = {}
end

return M
