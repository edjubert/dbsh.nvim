-- SQL variable detection.
-- Detection is ours and is shared by every backend: it is textual, driven by
-- the user's patterns. Declaring the values is not shared -- each CLI has its
-- own directive -- and lives in the backend.

local M = {}

-- patterns: Lua patterns, each with a single capture giving the name.
-- Returns the names in the order they appear, without duplicates.
function M.detect(sql, patterns)
	local seen = {}
	local names = {}
	for _, pattern in ipairs(patterns or {}) do
		for name in (sql or ""):gmatch(pattern) do
			if not seen[name] then
				seen[name] = true
				table.insert(names, name)
			end
		end
	end
	return names
end

return M
