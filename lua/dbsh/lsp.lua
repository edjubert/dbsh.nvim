-- Steers an already-running language server at the current connection.
-- dbsh does not own the client: it never starts it, never stops it, and never
-- configures anything beyond pointing it at the database the user picked.
-- This is the only module that knows the LSP protocol.

local config = require("dbsh.config")

local M = {}

-- Injection point: tests replace this with fake clients.
function M._clients(name)
	return vim.lsp.get_clients({ name = name })
end

-- Warn-once flags. A field rather than an upvalue so the tests can reset them.
M._warned = { env = false, command = false }

-- The server merges the environment last, so anything here silently wins over
-- what dbsh pushes -- and the failure would be completely mute.
local CONFLICTING_ENV = { "DATABASE_URL", "PGHOST", "PGPORT", "PGUSER", "PGDATABASE" }

-- client:notify is 0.11+; on 0.10 notify is a plain function without self.
-- Calling one for the other fails silently.
local function notify(client, method, params)
	if vim.fn.has("nvim-0.11") == 1 then
		client:notify(method, params)
	else
		client.notify(method, params)
	end
end

-- Same split as notify. Used by the schema cache refresh.
local function request(client, method, params, handler)
	if vim.fn.has("nvim-0.11") == 1 then
		client:request(method, params, handler)
	else
		client.request(method, params, handler)
	end
end

local function warn_conflicting_env()
	if M._warned.env then
		return
	end
	local found = {}
	for _, name in ipairs(CONFLICTING_ENV) do
		local value = vim.env[name]
		if value ~= nil and value ~= "" then
			table.insert(found, name)
		end
	end
	if #found == 0 then
		return
	end
	M._warned.env = true
	vim.notify(string.format(
		"dbsh.nvim: %s set in the environment; the language server merges it last, so it overrides the connection dbsh pushes",
		table.concat(found, ", ")
	), vim.log.levels.WARN)
end

-- Returns the backend's lsp descriptor, the current connection and the options,
-- or nil when there is simply nothing to steer. Every silent case lives here.
local function target()
	local opts = config.options()
	if not (opts.lsp or {}).enabled then
		return nil
	end
	local conn = config.current()
	if conn == nil then
		return nil
	end
	local backend = config.backend()
	if backend == nil or backend.lsp == nil then
		return nil
	end
	return backend.lsp, conn, opts
end

local function push(client, settings)
	warn_conflicting_env()
	-- Merged rather than replaced: the server only overrides the fields it
	-- receives, and Neovim hands client.settings back if it ever switches to
	-- pull-based configuration.
	client.settings = vim.tbl_deep_extend("force", client.settings or {}, settings)
	notify(client, "workspace/didChangeConfiguration", { settings = client.settings })
end

-- Pushes the current connection to every live client of the backend's server.
function M.sync()
	local lsp, conn, opts = target()
	if lsp == nil then
		return
	end
	local settings = lsp.settings(conn, opts)
	for _, client in ipairs(M._clients(lsp.client_name)) do
		push(client, settings)
	end
end

-- Same, for a single client. A client may attach long after the last connection
-- change: without this, opening a .sql file would leave the server on the
-- database of the project configuration file.
function M.sync_client(client)
	local lsp, conn, opts = target()
	if lsp == nil or client == nil or client.name ~= lsp.client_name then
		return
	end
	push(client, lsp.settings(conn, opts))
end

return M
