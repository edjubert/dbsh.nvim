-- Static configuration for dbsh.nvim.
-- Mutable runtime connection selection belongs to dbsh.context.

local backends = require("dbsh.backends")

local M = {}

local defaults = {
	connections = {},
	default = nil,
	connect_timeout = 5,
	query_timeout = 30000,
	preview_limit = 10,
	catalog_page_size = 200,
	csv_delimiter = ",",
	export_dir = vim.fs.joinpath(vim.fn.stdpath("data"), "dbsh", "exports"),
	results_split = "horizontal",
	variable_patterns = {},
	lsp = { enabled = false },
}

M.state = {
	opts = vim.deepcopy(defaults),
}

function M.setup(opts)
	M.state.opts = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
	if type(M.state.opts.catalog_page_size) ~= "number"
		or M.state.opts.catalog_page_size <= 0
		or M.state.opts.catalog_page_size ~= math.floor(M.state.opts.catalog_page_size) then
		vim.notify(
			"dbsh.nvim: catalog_page_size must be a positive integer; using 200",
			vim.log.levels.WARN
		)
		M.state.opts.catalog_page_size = defaults.catalog_page_size
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

function M.connection(name)
	local connection = M.state.opts.connections[name]
	if connection == nil then
		return nil, string.format("unknown connection '%s'", tostring(name))
	end
	return vim.deepcopy(connection)
end

function M.default_name()
	return M.state.opts.default
end

function M.backend_for(connection)
	if connection == nil then
		return nil, "no connection"
	end
	return backends.get(connection.type)
end

return M
