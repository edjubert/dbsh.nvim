-- Compatibility adapter for a user-owned PostgreSQL language server.
-- dbsh never starts, stops, pools, or detaches this client.

local config = require("dbsh.config")
local context = require("dbsh.context")

local M = {}

function M._clients(name)
	return vim.lsp.get_clients({ name = name })
end

function M._buffers(client)
	return vim.lsp.get_buffers_by_client_id(client.id)
end

M._warned = { env = false, command = false }

local CONFLICTING_ENV = { "DATABASE_URL", "PGHOST", "PGPORT", "PGUSER", "PGDATABASE" }
local SILENCED_MESSAGE = "Schema cache invalidated"

function M._show_message_handler(err, result, ctx)
	if result ~= nil and type(result.message) == "string"
		and result.message:find(SILENCED_MESSAGE, 1, true) then
		return
	end
	return vim.lsp.handlers["window/showMessage"](err, result, ctx)
end

local function notify(client, method, params)
	if vim.fn.has("nvim-0.11") == 1 then
		client:notify(method, params)
	else
		client.notify(method, params)
	end
end

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

local function target(snapshot)
	local opts = config.options()
	if not (opts.lsp or {}).enabled then
		return nil
	end
	if snapshot == nil or snapshot.connection == nil then
		return nil
	end
	local backend = context.backend(snapshot)
	if backend == nil or backend.lsp == nil then
		return nil
	end
	return backend.lsp, snapshot.connection, opts
end

local function push(client, settings)
	warn_conflicting_env()
	-- Preserve the user's in-memory settings, which may include credentials,
	-- but notify only the backend-generated password-free delta.
	client.settings = vim.tbl_deep_extend("force", client.settings or {}, vim.deepcopy(settings))
	notify(client, "workspace/didChangeConfiguration", { settings = vim.deepcopy(settings) })
end

function M.sync_external(snapshot)
	local descriptor, connection, opts = target(snapshot)
	if descriptor == nil then
		return
	end
	local settings = descriptor.settings(connection, opts)
	for _, client in ipairs(M._clients(descriptor.client_name)) do
		push(client, settings)
	end
end

function M.sync_external_client(client, snapshot)
	local descriptor, connection, opts = target(snapshot)
	if descriptor == nil or client == nil or client.name ~= descriptor.client_name then
		return
	end
	push(client, descriptor.settings(connection, opts))
	client.handlers = client.handlers or {}
	client.handlers["window/showMessage"] = M._show_message_handler
end

local function warn_refusal(err)
	if M._warned.command then
		return
	end
	M._warned.command = true
	local detail = type(err) == "table" and err.message or vim.inspect(err)
	vim.notify(
		"dbsh.nvim: the language server refused the schema cache command ("
			.. tostring(detail) .. "); diagnostics may go stale",
		vim.log.levels.WARN
	)
end

local function warm(client)
	local bufnr = M._buffers(client)[1]
	if bufnr == nil then
		return
	end
	request(client, "textDocument/completion", {
		textDocument = { uri = vim.uri_from_bufnr(bufnr) },
		position = { line = 0, character = 0 },
	}, function() end)
end

function M.invalidate_external(snapshot)
	local descriptor = target(snapshot)
	if descriptor == nil or descriptor.invalidate_command == nil then
		return
	end
	for _, client in ipairs(M._clients(descriptor.client_name)) do
		request(client, "workspace/executeCommand", { command = descriptor.invalidate_command }, function(err)
			if err ~= nil then
				warn_refusal(err)
				return
			end
			warm(client)
		end)
	end
end

return M
