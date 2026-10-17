-- ui/picker/projects.lua - The project picker (a view over services/projects)
--
--   <CR>   open the project (split / vsplit / tab: the picker's own keys)
--   <C-l>  insert its link at the cursor     <C-y>  yank its link
--   <M-s>  cycle the sort order              <M-d>  show / hide done projects
--   <M-e>  leaf projects only / all
local M = {}

local P = require("zortex.services.projects")
local score = require("zortex.services.projects.score")
local datetime = require("zortex.utils.datetime")
local Picker = require("zortex.ui.picker")

local SORTS = { "score", "okr", "priority", "due", "remaining", "size", "completion", "path", "name" }

-- =============================================================================
-- Formatting
-- =============================================================================

local function progress_bar(ratio, width)
	local filled = math.floor(ratio * width + 0.5)
	return string.rep("█", filled) .. string.rep("░", width - filled)
end

local function fmt_date(d)
	return d and datetime.format_datetime(d, "YYYY-MM-DD") or nil
end

local function display_parts(project)
	local r = project:rollup()
	local progress = r.total > 0 and string.format("%d/%d", r.done, r.total) or ""
	local indicators = score.indicators(project)
	return {
		ancestors = #project.path > 1 and (table.concat(project.path, " › ", 1, #project.path - 1) .. " › ") or "",
		name = project.name,
		progress = progress,
		points = r.points_open > 0 and (string.format("%g", math.floor(r.points_open * 10 + 0.5) / 10) .. "pt") or "",
		indicators = #indicators > 0 and ("[" .. table.concat(indicators, ",") .. "]") or "",
	}
end

local function format(project)
	local d = display_parts(project)
	return {
		{ d.ancestors, "Comment" },
		{ d.name, project:is_leaf() and "ZortexHeading2" or "ZortexHeading1" },
		{ d.progress ~= "" and ("  " .. d.progress) or "", "Number" },
		{ d.points ~= "" and ("  " .. d.points) or "", "Comment" },
		{ d.indicators ~= "" and ("  " .. d.indicators) or "", "WarningMsg" },
	}
end

local function preview_lines(project)
	local lines = {}
	local function add(s)
		lines[#lines + 1] = s
	end

	add(project:breadcrumb())
	add(project.link or "")
	add("")

	local attrs = project.attributes
	local meta = {}
	if attrs.p then
		meta[#meta + 1] = "priority " .. attrs.p
	end
	if attrs.i then
		meta[#meta + 1] = "importance " .. attrs.i
	end
	if attrs.size then
		meta[#meta + 1] = "size " .. attrs.size
	end
	if attrs.due then
		meta[#meta + 1] = "due " .. fmt_date(attrs.due)
	end
	meta[#meta + 1] = string.format("score %.0f", score.project_score(project))
	add(table.concat(meta, " · "))

	local own, r = project:stats(), project:rollup()
	add(string.format("Own:   %d/%d done  %.3g/%.3g pts", own.done, own.total, own.points_done, own.points))
	if #project.children > 0 then
		add(string.format("Total: %d/%d done  %.3g/%.3g pts", r.done, r.total, r.points_done, r.points))
	end
	if r.total > 0 then
		add(string.format("[%s] %.0f%%", progress_bar(r.completion, 30), r.completion * 100))
	end

	local areas = project:areas({ inherit = true })
	local broken = vim.tbl_filter(function(l)
		return not l.area
	end, project:area_links())
	if #areas > 0 or #broken > 0 then
		add("")
		add("Areas:")
		for _, a in ipairs(areas) do
			add("  " .. a:breadcrumb())
		end
		for _, l in ipairs(broken) do
			add("  " .. l.link .. " (unresolved)")
		end
	end

	local krs = project:key_results({ inherit = true })
	if #krs > 0 then
		add("")
		add("Key results:")
		for _, kr in ipairs(krs) do
			add(
				string.format(
					"  %s %s: %s  %d%%  (%s)",
					kr:is_done() and "☑" or "☐",
					kr.id,
					kr.text,
					math.floor(kr:progress() * 100 + 0.5),
					kr.objective.title
				)
			)
		end
	end

	local today = datetime.format_datetime(datetime.get_current_date(), "YYYY-MM-DD")
	local upcoming = project:schedule({ descendants = true, from = today })
	if #upcoming > 0 then
		add("")
		add("Scheduled:")
		for i, item in ipairs(upcoming) do
			if i > 5 then
				add(string.format("  … %d more", #upcoming - 5))
				break
			end
			add(string.format("  %s %s %s", item.date, item.time or "     ", item.entry.text))
		end
	end

	local tasks = vim.list_slice(project:tasks())
	if #tasks > 0 then
		table.sort(tasks, function(a, b)
			return score.task_score(a) > score.task_score(b)
		end)
		add("")
		add("Tasks:")
		for i, task in ipairs(tasks) do
			if i > 15 then
				add(string.format("  … %d more", #tasks - 15))
				break
			end
			local extra = {}
			if task.attributes.p then
				extra[#extra + 1] = "p" .. task.attributes.p
			end
			if task.attributes.size then
				extra[#extra + 1] = task.attributes.size
			end
			if task.attributes.due then
				extra[#extra + 1] = "due " .. fmt_date(task.attributes.due)
			end
			add(
				string.format(
					"  %s %s%s",
					task.completed and "☑" or "☐",
					task.text,
					#extra > 0 and ("  (" .. table.concat(extra, ", ") .. ")") or ""
				)
			)
		end
	end

	if #project.children > 0 then
		add("")
		add("Sub-projects:")
		for _, child in ipairs(project.children) do
			local cr = child:rollup()
			add(string.format("  %s  %d/%d", child.name, cr.done, cr.total))
		end
	end

	return lines
end

-- =============================================================================
-- Picker
-- =============================================================================

---@param opts { sort?: string, leaf?: boolean, include_done?: boolean, include_roots?: boolean }?
function M.spec(opts)
	opts = vim.tbl_extend("keep", opts or {}, { sort = "score", include_done = false })

	local function title()
		local flags = {}
		if opts.leaf then
			flags[#flags + 1] = "leaf"
		end
		if opts.include_done then
			flags[#flags + 1] = "+done"
		end
		return "Projects (" .. opts.sort .. (#flags > 0 and (", " .. table.concat(flags, ", ")) or "") .. ")"
	end

	local function insert_link(project)
		if project and project.link then
			vim.api.nvim_put({ project.link }, "c", true, true)
		end
	end

	return {
		title = title,
		items = function()
			return P.query({
				sort = opts.sort,
				leaf = opts.leaf,
				include_done = opts.include_done,
				include_roots = opts.include_roots,
			})
		end,
		text = function(project)
			return project:breadcrumb(" ") .. " " .. table.concat(project.tags, " ")
		end,
		format = format,
		location = function(project)
			return { file = project.file, lnum = project.lnum, text = project:breadcrumb(" › ") }
		end,
		open = function(project, cmd)
			P.jump(project, cmd)
		end,
		preview = function(project)
			return { lines = preview_lines(project), title = "Project" }
		end,
		-- the keys: zortex.keys ("projects")
		keys = require("zortex.keys").picker_keys("projects", {
			insert_link = { close = true, fn = insert_link },
			yank_link = {
				fn = function(project)
					if project and project.link then
						vim.fn.setreg('"', project.link)
						pcall(vim.fn.setreg, "+", project.link)
						vim.notify("Yanked " .. project.link)
					end
				end,
			},
			sort = {
				refresh = true,
				fn = function()
					local idx = 1
					for i, s in ipairs(SORTS) do
						if s == opts.sort then
							idx = i
						end
					end
					opts.sort = SORTS[idx % #SORTS + 1]
				end,
			},
			done = {
				refresh = true,
				fn = function()
					opts.include_done = not opts.include_done
				end,
			},
			leaf = {
				refresh = true,
				fn = function()
					opts.leaf = not opts.leaf
				end,
			},
		}),
	}
end

function M.open(opts)
	return Picker.pick(M.spec(opts))
end

M.preview_lines = preview_lines

return M
