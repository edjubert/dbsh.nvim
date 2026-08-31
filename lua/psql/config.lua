-- Connection state for psql.nvim.
-- Holds the declared connections, the currently selected one, and a generation
-- counter used to invalidate in-flight query callbacks.

local M = {}

local defaults = {
	connections = {},
	default = nil,
	connect_timeout = 5,
	query_timeout = 30000,
	preview_limit = 10,
	-- Column separator used both by the CSV yank and by the file export.
	csv_delimiter = ",",
	export_dir = vim.fs.joinpath(vim.fn.stdpath("data"), "psql", "exports"),
	-- "horizontal" or "vertical": which split opens the result buffer in.
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

-- Switch to a declared connection. Returns the connection, or nil plus an error.
function M.set_connection(name)
	local conn = M.state.opts.connections[name]
	if conn == nil then
		return nil, string.format("unknown connection '%s'", name)
	end
	-- Work on a copy so that set_database never mutates the declared table.
	M.state.current = vim.deepcopy(conn)
	M.state.current_name = name
	M.state.generation = M.state.generation + 1
	return M.state.current
end

-- Switch database on the current connection, keeping host, port and username.
function M.set_database(dbname)
	if M.state.current == nil then
		return nil, "no current connection"
	end
	M.state.current.database = dbname
	M.state.generation = M.state.generation + 1
	return M.state.current
end

return M
