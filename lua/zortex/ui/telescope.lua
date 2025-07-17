local M = {}

local projects = require("zortex.ui.projects")

-- =============================================================================
-- Setup telescope
-- =============================================================================

function M.setup_telescope()
	local ok, telescope = pcall(require, "telescope")
	if not ok then
		return
	end

	telescope.register_extension({
		setup = function(ext_config, config)
			-- Extension setup if needed
		end,
		exports = {
			zortex = function(opts)
				opts = opts or {}

				local pickers = require("telescope.pickers")
				local finders = require("telescope.finders")
				local conf = require("telescope.config").values
				local actions = require("telescope.actions")
				local action_state = require("telescope.actions.state")

				local picker_list = {
					-- { "Today's Digest", M.telescope.today_digest },
					-- { "Calendar", M.telescope.calendar },
					{ "Projects", projects },
					{ "Skill Tree", M.skill_tree.show },
				}

				pickers
					.new(opts, {
						prompt_title = "Zortex",
						finder = finders.new_table({
							results = picker_list,
							entry_maker = function(entry)
								return {
									value = entry,
									display = entry[1],
									ordinal = entry[1],
								}
							end,
						}),
						sorter = conf.generic_sorter(opts),
						attach_mappings = function(prompt_bufnr, map)
							actions.select_default:replace(function()
								actions.close(prompt_bufnr)
								local selection = action_state.get_selected_entry()
								if selection then
									selection.value[2]()
								end
							end)
							return true
						end,
					})
					:find()
			end,
			-- today = M.today_digest,
			projects = projects,
		},
	})
end

function M.setup()
	M.setup_telescope()
end

return M
