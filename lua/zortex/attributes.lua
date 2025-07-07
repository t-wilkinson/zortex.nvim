-- attributes.lua - A flexible, configuration-driven attribute parser.
-- This module allows defining a set of attributes to be extracted from a string.
local M = {}

--- Parses a string to extract attributes based on a provided set of definitions.
-- The function iteratively matches patterns, extracts values, and removes the matched
-- text from the original string.
--
-- @param text string The input string to parse.
-- @param definitions table An array of attribute definitions. Each definition is a table with:
--   - name (string): The key for the attribute in the results table.
--   - pattern (string): The Lua pattern to match. Captures are passed to the transform function.
--   - transform (function, optional): A function to process the captured values.
--   - value (any, optional): A fixed value to assign if the pattern matches (for flags).
-- @return table The table of parsed attributes.
-- @return string The remaining text after all attributes have been stripped.
function M.parse(text, definitions)
	local attrs = {}
	local remaining_text = text

	for _, def in ipairs(definitions) do
		-- We use a while loop to catch multiple occurrences of the same attribute type,
		-- although for most cases a simple `if` would suffice.
		while true do
			local captures = { string.match(remaining_text, def.pattern) }
			if #captures > 0 then
				local value
				if def.transform then
					-- Pass all captures to the transform function.
					value = def.transform(unpack(captures))
				elseif def.value ~= nil then
					-- Use the predefined value for flag-like attributes.
					value = def.value
				else
					-- Default to the first captured value.
					value = captures[1]
				end

				-- Store the parsed attribute. If the name is already present,
				-- this will overwrite it. This is usually the desired behavior.
				attrs[def.name] = value

				-- Remove the matched pattern from the string to avoid re-matching.
				local full_match = remaining_text:match(def.pattern)
				remaining_text = remaining_text:gsub(full_match, "", 1)
			else
				-- No more matches for this definition, move to the next.
				break
			end
		end
	end

	-- Clean up any leftover whitespace.
	remaining_text = remaining_text:match("^%s*(.-)%s*$") or ""
	remaining_text = remaining_text:gsub("%s%s+", " ")

	return attrs, remaining_text
end

return M
