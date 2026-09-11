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
	safety = { mode = "confirm" },
	lsp = {
		mode = "off",
		command = { "postgres-language-server", "lsp-proxy" },
		client_pool = {
			strategy = "immediate",
			idle_timeout_ms = 30000,
		},
		notifications = { failures = true },
	},
}

M.state = {
	opts = vim.deepcopy(defaults),
}

M._warned = { legacy_lsp = false, ignored_legacy_lsp = false }

local function warn(message)
	vim.notify("dbsh.nvim: " .. message, vim.log.levels.WARN)
end

local function valid_command(command)
	if type(command) ~= "table" or #command == 0 then
		return false
	end
	for _, argument in ipairs(command) do
		if type(argument) ~= "string" or argument == "" then
			return false
		end
	end
	return true
end

local function normalize_lsp(raw_lsp)
	local lsp = M.state.opts.lsp
	local explicit_mode = type(raw_lsp) == "table" and raw_lsp.mode ~= nil

	if explicit_mode and type(raw_lsp.enabled) == "boolean" then
		if not M._warned.ignored_legacy_lsp then
			M._warned.ignored_legacy_lsp = true
			warn("lsp.enabled is deprecated and ignored when lsp.mode is set")
		end
	elseif raw_lsp ~= nil and type(raw_lsp.enabled) == "boolean" then
		lsp.mode = raw_lsp.enabled and "external" or "off"
		if raw_lsp.enabled and not M._warned.legacy_lsp then
			M._warned.legacy_lsp = true
			warn("lsp.enabled is deprecated; use lsp.mode = 'external'")
		end
	end
	lsp.enabled = nil

	if lsp.mode ~= "off" and lsp.mode ~= "external" and lsp.mode ~= "managed" then
		warn("lsp.mode must be 'off', 'external', or 'managed'; using 'off'")
		lsp.mode = defaults.lsp.mode
	end
	if not valid_command(lsp.command) then
		warn("lsp.command must be a non-empty array of strings; using the default")
		lsp.command = vim.deepcopy(defaults.lsp.command)
	end
	if type(lsp.client_pool) ~= "table"
		or (lsp.client_pool.strategy ~= "immediate"
			and lsp.client_pool.strategy ~= "idle"
			and lsp.client_pool.strategy ~= "session") then
		warn("lsp.client_pool.strategy must be 'immediate', 'idle', or 'session'; using 'immediate'")
		lsp.client_pool = vim.deepcopy(defaults.lsp.client_pool)
	elseif type(lsp.client_pool.idle_timeout_ms) ~= "number"
		or lsp.client_pool.idle_timeout_ms < 0
		or lsp.client_pool.idle_timeout_ms ~= math.floor(lsp.client_pool.idle_timeout_ms) then
		warn("lsp.client_pool.idle_timeout_ms must be a non-negative integer; using 30000")
		lsp.client_pool.idle_timeout_ms = defaults.lsp.client_pool.idle_timeout_ms
	end
	if type(lsp.notifications) ~= "table" or type(lsp.notifications.failures) ~= "boolean" then
		warn("lsp.notifications.failures must be a boolean; using true")
		lsp.notifications = vim.deepcopy(defaults.lsp.notifications)
	end
end

function M.setup(opts)
	local input = vim.deepcopy(opts or {})
	local raw_lsp = input.lsp
	if raw_lsp ~= nil and type(raw_lsp) ~= "table" then
		warn("lsp must be a table; using default LSP options")
		input.lsp = {}
		raw_lsp = input.lsp
	end
	M.state.opts = vim.tbl_deep_extend("force", vim.deepcopy(defaults), input)
	normalize_lsp(raw_lsp)
	if type(M.state.opts.catalog_page_size) ~= "number"
		or M.state.opts.catalog_page_size <= 0
		or M.state.opts.catalog_page_size ~= math.floor(M.state.opts.catalog_page_size) then
		warn("catalog_page_size must be a positive integer; using 200")
		M.state.opts.catalog_page_size = defaults.catalog_page_size
	end
	if type(M.state.opts.safety) ~= "table"
		or (M.state.opts.safety.mode ~= "confirm" and M.state.opts.safety.mode ~= "off") then
		warn("safety.mode must be 'confirm' or 'off'; using 'confirm'")
		M.state.opts.safety = vim.deepcopy(defaults.safety)
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
