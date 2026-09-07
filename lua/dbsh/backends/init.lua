-- Backend registry. A connection declares its type; this maps that type to
-- the table of pure functions that knows the CLI behind it.

local M = {}

M.default = "postgres"

M.registry = {
	postgres = require("dbsh.backends.postgres"),
}

-- Returns the backend, or nil plus an error message. A connection with no
-- declared type is a postgres connection: that is what every existing user
-- config means.
function M.get(name)
	local backend = M.registry[name or M.default]
	if backend == nil then
		return nil, string.format("unknown connection type '%s'", tostring(name))
	end
	return backend
end

return M
