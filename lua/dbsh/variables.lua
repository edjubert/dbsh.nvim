-- SQL variable support.
-- Detection is ours; substitution is left to psql, which interpolates :name
-- from a \set directive and, unlike a textual replacement, never touches the
-- inside of a quoted literal.

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

-- psql processes escape sequences inside a single-quoted \set argument.
-- Backslashes have to go first: doing the quotes first would then double
-- the backslashes this very step introduces.
function M.escape_value(value)
	local escaped = tostring(value or "")
	escaped = (escaped:gsub("\\", "\\\\"))
	escaped = (escaped:gsub("'", "\\'"))
	return escaped
end

function M.set_command(name, value)
	return string.format("\\set %s '%s'", name, M.escape_value(value))
end

-- Directives are line-oriented, hence the trailing newline on each. Returns
-- an empty string for an empty list, so it can be concatenated in front of a
-- query without shifting the line numbers psql reports on error.
function M.preamble(names, values)
	values = values or {}
	local lines = {}
	for _, name in ipairs(names or {}) do
		table.insert(lines, M.set_command(name, values[name] or ""))
	end
	if #lines == 0 then
		return ""
	end
	return table.concat(lines, "\n") .. "\n"
end

return M
