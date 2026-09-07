-- Connection state for dbsh.nvim.
-- Holds the declared connections, the currently selected one, the backend that
-- drives it, and a generation counter used to invalidate in-flight query
-- callbacks.

local backends = require("dbsh.backends")

local M = {}

local defaults = {
	-- Each connection may declare a `type` naming its backend. No type means
	-- "postgres", which is what every config written before backends existed
	-- meant.
	connections = {},
	default = nil,
	connect_timeout = 5,
	query_timeout = 30000,
	preview_limit = 10,
	-- Column separator used both by the CSV yank and by the file export.
	csv_delimiter = ",",
	export_dir = vim.fs.joinpath(vim.fn.stdpath("data"), "dbsh", "exports"),
	-- "horizontal", "vertical" or "float": which split opens the result
	-- buffer in. "float" is styled after the user's telescope config.
	results_split = "horizontal",
	-- Lua patterns, each with a single capture giving the variable name.
	-- Empty by default: no SQL file changes behaviour unless asked.
	variable_patterns = {},
}

M.state = {
	opts = vim.deepcopy(defaults),
	current_name = nil,
	current = nil,
	generation = 0,
}

-- The catalog commands are derived from the backend of the current connection,
-- so anything that changes the backend has to let dbsh.init know.
-- modeline = false: without it Neovim rereads the modelines of the current
-- buffer on every connection change.
local function announce_connection_change()
	vim.api.nvim_exec_autocmds("User", {
		pattern = "DbshConnectionChanged",
		modeline = false,
	})
end

function M.setup(opts)
	M.state.opts = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
	M.state.current_name = nil
	M.state.current = nil
	M.state.generation = 0

	local name = M.state.opts.default
	if name == nil then
		name = next(M.state.opts.connections)
	end
	if name ~= nil then
		M.set_connection(name)
	end
end

function M.options()
	return M.state.opts
end

function M.names()
	local names = vim.tbl_keys(M.state.opts.connections)
	table.sort(names)
	return names
end

function M.current()
	return M.state.current
end

function M.current_name()
	return M.state.current_name
end

function M.generation()
	return M.state.generation
end

-- Resolves the backend driving the current connection. Returns the backend,
-- or nil plus an error message.
function M.backend()
	if M.state.current == nil then
		return nil, "no current connection"
	end
	return backends.get(M.state.current.type)
end

-- Switch to a declared connection. Returns the connection, or nil plus an error.
function M.set_connection(name)
	local conn = M.state.opts.connections[name]
	if conn == nil then
		return nil, string.format("unknown connection '%s'", name)
	end
	-- Work on a copy so that set_level never mutates the declared table.
	M.state.current = vim.deepcopy(conn)
	M.state.current_name = name
	M.state.generation = M.state.generation + 1
	announce_connection_change()
	return M.state.current
end

-- Fixes one navigation level (database, schema, ...) on the current connection,
-- keeping everything else. The levels themselves are declared by the backend.
function M.set_level(key, value)
	if M.state.current == nil then
		return nil, "no current connection"
	end
	M.state.current[key] = value
	M.state.generation = M.state.generation + 1
	return M.state.current
end

return M
