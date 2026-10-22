-- features/diagnostics.lua - Broken links as vim.diagnostic
--
-- A link in a note that resolves nowhere (link_index.unresolved_in), or a
-- path to a file that isn't there, is a diagnostic on its span: ]d / [d
-- move between them, and :ZortexBrokenLinks lists those of every note. In
-- the calendar note, so are repeating entries that can't work
-- (services/calendar_rules.problems).
-- Updated when a note is opened, saved, or after changes settle.
local M = {}

local NS = vim.api.nvim_create_namespace("zortex_links")
local cfg = { enabled = true, severity = "WARN", delay = 500 }
local timers = {}

local function severity()
	return vim.diagnostic.severity[(cfg.severity or "WARN"):upper()] or vim.diagnostic.severity.WARN
end

--- The diagnostics of buffer `bufnr` (a note in notes_dir).
function M.compute(bufnr)
	local name = vim.api.nvim_buf_get_name(bufnr)
	if name == "" then
		return {}
	end
	local ok, refs = pcall(require("zortex.core.link_index").unresolved_in, name)
	if not ok then
		return {}
	end
	local out = {}
	local fs = require("zortex.utils.filesystem")
	local cal_ok, cal = pcall(fs.get_calendar_file)
	if cal_ok and cal and vim.fn.fnamemodify(cal, ":p") == vim.fn.fnamemodify(name, ":p") then
		local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		for _, p in ipairs(require("zortex.services.calendar_rules").problems(lines)) do
			out[#out + 1] = {
				lnum = p.lnum - 1,
				col = p.col,
				end_col = p.end_col,
				severity = severity(),
				source = "zortex",
				message = p.message,
			}
		end
	end
	for _, ref in ipairs(refs) do
		out[#out + 1] = {
			lnum = ref.lnum - 1,
			col = ref.col - 1,
			end_col = ref.col - 1 + #ref.text,
			severity = severity(),
			source = "zortex",
			message = ref.path and ("No such file: " .. ref.definition) or ("Link resolves nowhere: " .. ref.text),
		}
	end
	return out
end

function M.update(bufnr)
	bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
	if not cfg.enabled or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	vim.diagnostic.set(NS, bufnr, M.compute(bufnr))
end

local function later(bufnr, ms)
	if timers[bufnr] then
		timers[bufnr]:stop()
	else
		timers[bufnr] = vim.uv.new_timer()
	end
	timers[bufnr]:start(
		ms,
		0,
		vim.schedule_wrap(function()
			M.update(bufnr)
		end)
	)
end

function M.setup(opts)
	cfg = vim.tbl_extend("force", cfg, opts or {})
	local group = vim.api.nvim_create_augroup("ZortexDiagnostics", { clear = true })
	if not cfg.enabled then
		return
	end
	vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost" }, {
		group = group,
		pattern = "*.zortex",
		callback = function(args)
			later(args.buf, 50) -- after the note shows
		end,
	})
	vim.api.nvim_create_autocmd({ "TextChanged", "InsertLeave" }, {
		group = group,
		pattern = "*.zortex",
		callback = function(args)
			later(args.buf, cfg.delay)
		end,
	})
	vim.api.nvim_create_autocmd("BufWipeout", {
		group = group,
		pattern = "*.zortex",
		callback = function(args)
			if timers[args.buf] then
				timers[args.buf]:stop()
				timers[args.buf]:close()
				timers[args.buf] = nil
			end
		end,
	})
end

M.namespace = NS

return M
