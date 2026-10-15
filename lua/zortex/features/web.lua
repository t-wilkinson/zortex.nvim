-- features/web.lua - Opening links in the web app (`zortex serve`)
--
-- :ZortexLinkOpenWeb (<prefix>gX) shows what the cursor is on in the web
-- app instead of in Neovim:
--
--   [R/#Rust], [/#Local], @[rust]    /link?to=...&from=<note>: the server
--                                    resolves it (one match: its line;
--                                    several: a list, or a tag table)
--   [./z/scan.pdf], ./pinout.png     /f/<path>: the file viewer
--   https://...                      the URL itself
--   a tag index line                 the index, with that line's chip chosen
--   anything else                    this note at the cursor's line
--
-- The web app's address is Config.server.web_url, or api_endpoint. With the
-- server enabled, the page goes to the tab on this device that was focused
-- last (app/web/open.go), when there is one; otherwise to a new tab
-- (features.web.reuse_tab = false: always a new tab). gx on a tag index's
-- label opens the index here too.
local M = {}

local Config = require("zortex.config")
local link_mod = require("zortex.core.link")
local buffer = require("zortex.utils.buffer")

local function notify(msg, level)
	vim.notify(msg, level or vim.log.levels.INFO, { title = "Zortex" })
end

local function escape(segment)
	return (segment:gsub("[^%w%-%._~]", function(c)
		return string.format("%%%02X", c:byte())
	end))
end

-- query-string escaping: spaces as "+"
local function qescape(s)
	return (s:gsub("[^%w%-%._~ ]", function(c)
		return string.format("%%%02X", c:byte())
	end):gsub(" ", "+"))
end

--- The web app's address ("https://zortex.home.lab/notes"), or nil, err.
function M.base()
	local server = Config.server or {}
	local web = server.web_url or server.api_endpoint
	if type(web) ~= "string" or web == "" then
		return nil, "Set server.web_url to the web app's address"
	end
	return (web:gsub("/+$", ""))
end

--- A file's path relative to notes_dir ("z/resources.zortex"), or nil.
function M.rel(filepath)
	if not filepath or filepath == "" then
		return nil
	end
	local root = vim.fs.normalize(vim.fn.fnamemodify(Config.notes_dir, ":p")):gsub("/+$", "")
	local path = vim.fs.normalize(vim.fn.fnamemodify(filepath, ":p"))
	if path:sub(1, #root + 1) ~= root .. "/" then
		return nil
	end
	return path:sub(#root + 2)
end

local function escape_rel(rel)
	local parts = vim.split(rel, "/", { plain = true })
	for i, p in ipairs(parts) do
		parts[i] = escape(p)
	end
	return table.concat(parts, "/")
end

--- The app path of a note at a line ("/n/z/x.zortex#L12"), or nil, err.
function M.note_path(filepath, lnum)
	local rel = M.rel(filepath)
	if not rel then
		return nil, "Not a note in notes_dir"
	end
	local p = "/n/" .. escape_rel(rel)
	if lnum and lnum > 0 then
		p = p .. "#L" .. lnum
	end
	return p
end

--- The app path of a file's viewer ("/f/z/scan.pdf"), or nil, err.
function M.file_path(filepath)
	local rel = M.rel(filepath)
	if not rel then
		return nil, "The file is outside notes_dir, so the web app can't show it"
	end
	return "/f/" .. escape_rel(rel)
end

--- The app path that resolves a link ("/link?to=...&from=..."). def is
--- "[R/#Rust]" or "@[rust]".
function M.link_path(def, filepath)
	local p = "/link?to=" .. qescape(def)
	local rel = M.rel(filepath)
	if rel then
		p = p .. "&from=" .. qescape(rel)
	end
	return p
end

local function resolve_file(p, filepath)
	p = p:gsub("[%.,;:!%?]+$", "")
	if p:match("^%.%.?/") then
		p = vim.fn.simplify(vim.fn.fnamemodify(filepath, ":p:h") .. "/" .. p)
	elseif not p:match("^/") and not p:match("^~") then
		p = Config.notes_dir .. p
	end
	return vim.fn.expand(p)
end

--- Where a link (as core/link.at returns it) goes in the web app:
--- { path = "/n/..." } in the app, { url = "https://..." } elsewhere, or
--- nil, err. ctx: file, lnum and lines of where the link is written.
function M.target(link_info, ctx)
	local file = ctx.file
	local t = link_info.type
	if t == "link" or t == "live_link" then
		local def = link_info.definition
		if link_mod.is_parent_relative(def) then
			local abs, err = link_mod.absolute(def, ctx.lines or {}, ctx.lnum or 0)
			if not abs then
				return nil, err
			end
			def = abs
		end
		local rel = link_mod.relative_path(def, file)
		if rel then
			local p, err = M.file_path(rel)
			return p and { path = p } or nil, err
		end
		return { path = M.link_path("[" .. def .. "]", file) }
	elseif t == "tag_search" then
		return { path = M.link_path("@[" .. link_info.display_text .. "]", file) }
	elseif t == "website" then
		return { url = link_info.url }
	elseif t == "markdown" then
		local url = link_info.url or ""
		if url:match("^%a[%w+.-]*://") or url:match("^mailto:") then
			return { url = url }
		end
		local p, err = M.file_path(resolve_file(url:gsub("#.*$", ""), file))
		return p and { path = p } or nil, err
	elseif t == "filepath" then
		local p, err = M.file_path(resolve_file(link_info.path, file))
		return p and { path = p } or nil, err
	elseif t == "footnote" then
		local prefix = "[^" .. link_info.ref_id .. "]:"
		for lnum, line in ipairs(ctx.lines or {}) do
			if line:sub(1, #prefix) == prefix then
				return { path = M.note_path(file, lnum) }
			end
		end
		return nil, "Footnote definition [^" .. link_info.ref_id .. "] not found"
	end
	return nil, "Can't open this kind of link in the web app"
end

--- The tag index around a line: the index, at its label or with a line's
--- chip chosen ({ path }), or nil.
function M.index_target(doc, filepath, lnum)
	local ix, query = require("zortex.core.tag_index").at(doc, lnum)
	if not ix then
		return nil
	end
	local p = M.note_path(filepath)
	if not p then
		return nil
	end
	if query then
		-- the chip, as the page writes it: #tags=R/rust,rl+async
		local enc = qescape(query):gsub("%%2F", "/"):gsub("%%2C", ",")
		return { path = p .. "#tags=" .. enc }
	end
	return { path = p .. "#L" .. ix.lnum }
end

local function open_new(url)
	local _, err = vim.ui.open(url)
	if err then
		notify(err .. ": " .. url, vim.log.levels.WARN)
	end
end

--- Shows a target in the web app: an app path in the tab focused last on
--- this device when the server can reach one, else in a new tab.
function M.open(target)
	if target.url then
		return open_new(target.url)
	end
	local base, err = M.base()
	if not base then
		return notify(err, vim.log.levels.WARN)
	end
	local url = base .. target.path
	local server = require("zortex.notifications.server")
	local reuse = ((Config.features or {}).web or {}).reuse_tab ~= false
	if not reuse or not server.enabled() then
		return open_new(url)
	end
	server.request("POST", "/api/open", { path = target.path }, function(ok, body)
		if not (ok and type(body) == "table" and body.opened) then
			open_new(url)
		end
	end, { timeout = 4 })
end

--- What the cursor is on, shown in the web app.
function M.open_at_cursor()
	local file = vim.api.nvim_buf_get_name(0)
	local lnum = buffer.get_cursor_pos()
	if vim.bo.modified and file ~= "" then
		vim.cmd("silent! write")
	end
	local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
	local ctx = { file = file, lnum = lnum, lines = lines }

	local doc = require("zortex.core.document").from_buffer(0)
	local target, err
	local index = doc and M.index_target(doc, file, lnum)
	local info = require("zortex.features.links").link_at_cursor()
	if info and not (index and info.type == "tag_search") then
		target, err = M.target(info, ctx)
	elseif index then
		target = index
	else
		target, err = M.note_path(file, lnum)
		target = target and { path = target }
	end
	if not target then
		return notify(err or "Nothing to open", vim.log.levels.WARN)
	end
	M.open(target)
	return target
end

return M
