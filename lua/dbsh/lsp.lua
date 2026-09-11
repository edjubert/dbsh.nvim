-- External compatibility adapter and dbsh-owned PostgreSQL Language Server pool.

local config = require("dbsh.config")
local context = require("dbsh.context")

local M = {}
local state = {}

M._warned = { env = false, command = false, failures = {} }

function M.setup()
	state = {
		pool = {},
		errors = {},
		failures = {},
		external_snapshot = nil,
	}
end

function M._clients(name)
	return vim.lsp.get_clients({ name = name })
end

function M._buffers(client)
	return vim.lsp.get_buffers_by_client_id(client.id)
end

local function concrete_bufnr(bufnr)
	if bufnr == 0 then
		return vim.api.nvim_get_current_buf()
	end
	return bufnr
end

function M.start_client(client_config)
	return vim.lsp.start(client_config, { attach = false })
end

function M.attach_client(client_id, bufnr)
	return vim.lsp.buf_attach_client(bufnr, client_id)
end

function M.detach_client(client_id, bufnr)
	return vim.lsp.buf_detach_client(bufnr, client_id)
end

function M.stop_client(client_id)
	local client = vim.lsp.get_client_by_id(client_id)
	if client ~= nil then
		client:stop(true)
	end
end

function M.reset_diagnostics(client_id, bufnr)
	vim.diagnostic.reset(vim.lsp.diagnostic.get_namespace(client_id), bufnr)
end

function M.schedule_timer(timeout_ms, callback)
	return vim.defer_fn(callback, timeout_ms)
end

function M.cancel_timer(timer)
	if timer ~= nil and not timer:is_closing() then
		timer:stop()
		timer:close()
	end
end

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
		return client:request(method, params, handler)
	end
	return client.request(method, params, handler)
end

M.request = request

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

local function effective_database(snapshot)
	return (snapshot.levels or {}).database or (snapshot.connection or {}).database
end

local function public_snapshot(snapshot)
	local backend = context.backend(snapshot)
	return {
		backend = backend and backend.name or snapshot.backend_name,
		connection_name = snapshot.connection_name,
		database = effective_database(snapshot),
		project_root = context.resolved_project_root(snapshot),
		search_path = context.resolved_search_path(snapshot),
	}
end

local function external_target(snapshot)
	local opts = config.options()
	if opts.lsp.mode ~= "external" or snapshot == nil or snapshot.connection == nil then
		return nil
	end
	local backend = context.backend(snapshot)
	if backend == nil or backend.name ~= "postgres" or backend.lsp == nil then
		return nil
	end
	return backend.lsp, snapshot.connection, opts
end

function M.sync_external(snapshot)
	local descriptor, connection, opts = external_target(snapshot)
	if descriptor == nil then
		return
	end
	state.external_snapshot = public_snapshot(snapshot)
	local settings = descriptor.settings(connection, opts)
	warn_conflicting_env()
	for _, client in ipairs(M._clients(descriptor.client_name)) do
		notify(client, "workspace/didChangeConfiguration", { settings = vim.deepcopy(settings) })
	end
end

function M.sync_external_client(client, snapshot)
	local descriptor, connection, opts = external_target(snapshot)
	if descriptor == nil or client == nil or client.name ~= descriptor.client_name then
		return
	end
	state.external_snapshot = public_snapshot(snapshot)
	warn_conflicting_env()
	notify(client, "workspace/didChangeConfiguration", {
		settings = vim.deepcopy(descriptor.settings(connection, opts)),
	})
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

local function warm(client, bufnr)
	bufnr = bufnr or M._buffers(client)[1]
	if bufnr == nil then
		return
	end
	M.request(client, "textDocument/completion", {
		textDocument = { uri = vim.uri_from_bufnr(bufnr) },
		position = { line = 0, character = 0 },
	}, function() end)
end

function M.invalidate_external(snapshot)
	local descriptor = external_target(snapshot)
	if descriptor == nil or descriptor.invalidate_command == nil then
		return
	end
	for _, client in ipairs(M._clients(descriptor.client_name)) do
		M.request(client, "workspace/executeCommand", { command = descriptor.invalidate_command }, function(err)
			if err ~= nil then
				warn_refusal(err)
				return
			end
			warm(client)
		end)
	end
end

local function managed_target(snapshot)
	local opts = config.options()
	if opts.lsp.mode ~= "managed" or snapshot == nil or snapshot.connection == nil then
		return nil
	end
	local backend = context.backend(snapshot)
	if backend == nil or backend.name ~= "postgres" or backend.lsp == nil then
		return nil
	end
	return backend.lsp, snapshot.connection, opts
end

function M.client_key(snapshot)
	if snapshot == nil or snapshot.connection == nil then
		return nil
	end
	local connection = snapshot.connection
	local fields = {
		"postgres",
		tostring(connection.host or ""),
		tostring(connection.port or ""),
		tostring(connection.username or ""),
		tostring(connection.database or ""),
		tostring(effective_database(snapshot) or ""),
		context.resolved_project_root(snapshot),
	}
	for _, schema in ipairs(context.resolved_search_path(snapshot)) do
		table.insert(fields, schema)
	end
	return vim.fn.sha256(table.concat(fields, "\n"))
end

local function public_record(record)
	local buffers = vim.tbl_keys(record.refs)
	table.sort(buffers)
	return {
		key = record.key,
		backend = record.backend,
		project_root = record.project_root,
		search_path = vim.deepcopy(record.search_path),
		buffers = buffers,
		state = record.state,
		last_error = record.last_error,
		client_id = record.client_id,
	}
end

local function record_error(key, message, opts, snapshot)
	if key == nil then
		return
	end
	state.errors[key] = message
	local record = state.pool[key]
	if record ~= nil then
		record.state = "failed"
		record.last_error = message
	elseif snapshot ~= nil then
		local failed = public_snapshot(snapshot)
		failed.key = key
		failed.buffers = {}
		failed.state = "failed"
		failed.last_error = message
		state.failures[key] = failed
	elseif state.failures[key] ~= nil then
		state.failures[key].last_error = message
	end
	M._warned.failures = M._warned.failures or {}
	local notifications = opts.lsp and opts.lsp.notifications or opts.notifications
	if notifications.failures and not M._warned.failures[key] then
		M._warned.failures[key] = true
		vim.notify("dbsh.nvim: " .. message, vim.log.levels.WARN)
	end
end

local function clear_error(key)
	state.errors[key] = nil
	state.failures[key] = nil
	local record = state.pool[key]
	if record ~= nil then
		record.state = "ready"
		record.last_error = nil
	end
end

local function cancel_idle_timer(record)
	if record.idle_timer ~= nil then
		M.cancel_timer(record.idle_timer)
		record.idle_timer = nil
	end
end

local function stop_record(record)
	cancel_idle_timer(record)
	record.state = "stopping"
	M.stop_client(record.client_id)
	state.pool[record.key] = nil
end

local function method_not_found(err)
	if type(err) ~= "table" then
		return false
	end
	if err.code == -32601 then
		return true
	end
	return type(err.message) == "string" and err.message:lower():find("method not found", 1, true) ~= nil
end

local function database_context_payload(snapshot)
	local connection = snapshot.connection
	return {
		context = {
			connection = {
				host = connection.host,
				port = connection.port,
				username = connection.username,
				password = connection.password,
				database = effective_database(snapshot),
			},
			searchPath = context.resolved_search_path(snapshot),
		},
	}
end

local function configure_managed(record, snapshot, opts)
	record.state = "starting"
	local payload = database_context_payload(snapshot)
	local requested = M.request(record.client, "pgls/setDatabaseContext", payload, function(err)
		if err == nil then
			clear_error(record.key)
			return
		end
		if method_not_found(err) then
			local failed = public_record(record)
			failed.state = "failed"
			failed.last_error = "managed mode requires a PgLS build with pgls/setDatabaseContext"
			state.failures[record.key] = failed
			stop_record(record)
			record_error(
				record.key,
				"managed mode requires a PgLS build with pgls/setDatabaseContext",
				opts,
				snapshot
			)
			return
		end
		record_error(record.key, "managed PgLS database context request failed", opts, snapshot)
	end)
	if requested == false then
		record_error(record.key, "managed PgLS database context request failed", opts, snapshot)
	end
end

local function client_from_start(started)
	if type(started) == "table" then
		return started, started.id
	end
	if type(started) == "number" then
		return vim.lsp.get_client_by_id(started), started
	end
	return nil, nil
end

local function configure_when_ready(record, snapshot, opts)
	record.configure = function()
		configure_managed(record, snapshot, opts)
	end
	if record.client.initialized ~= true then
		return
	end
	local configure = record.configure
	record.configure = nil
	configure()
end

function M.attach_managed(bufnr, snapshot)
	bufnr = concrete_bufnr(bufnr)
	local descriptor, connection, opts = managed_target(snapshot)
	if descriptor == nil then
		return
	end
	local key = M.client_key(snapshot)
	if type(connection.host) ~= "string"
		or connection.host == ""
		or type(connection.port) ~= "number"
		or connection.port <= 0
		or type(connection.username) ~= "string"
		or connection.username == ""
		or type(connection.password) ~= "string"
		or connection.password == ""
		or type(effective_database(snapshot)) ~= "string"
		or effective_database(snapshot) == "" then
		record_error(
			key,
			"managed PgLS requires an in-memory PostgreSQL password and connection",
			opts,
			snapshot
		)
		return
	end

	local record = state.pool[key]
	local created = record == nil
	if record == nil then
		local root_dir = context.resolved_project_root(snapshot)
		if snapshot.project_root == nil or snapshot.project_root == "" then
			vim.fn.mkdir(root_dir, "p")
		end
		local started = M.start_client({
			name = "dbsh_pgls_" .. key:sub(1, 12),
			cmd = vim.deepcopy(opts.lsp.command),
			root_dir = root_dir,
			handlers = { ["window/showMessage"] = M._show_message_handler },
			on_init = function(client)
				M.schedule_timer(50, function()
					local pending = state.pool[key]
					if pending == nil or pending.client_id ~= client.id or pending.configure == nil then
						return
					end
					local configure = pending.configure
					pending.configure = nil
					configure()
				end)
			end,
		}, bufnr)
		local client, client_id = client_from_start(started)
		if client == nil or client_id == nil then
			record_error(key, "managed PgLS client could not start", opts, snapshot)
			return
		end
		record = {
			key = key,
			client = client,
			client_id = client_id,
			refs = {},
			invalidate_command = descriptor.invalidate_command,
			backend = "postgres",
			project_root = context.resolved_project_root(snapshot),
			search_path = context.resolved_search_path(snapshot),
			state = "starting",
			last_error = nil,
		}
		state.pool[key] = record
	else
		cancel_idle_timer(record)
	end

	if M.attach_client(record.client_id, bufnr) == false then
		if created then
			stop_record(record)
		end
		record_error(key, "managed PgLS client could not attach to the buffer", opts, snapshot)
		return
	end
	record.refs[bufnr] = true
	configure_when_ready(record, snapshot, opts)
	return record.client_id
end

local function record_for_buffer(bufnr)
	for _, record in pairs(state.pool) do
		if record.refs[bufnr] then
			return record
		end
	end
	return nil
end

local function retire_if_unreferenced(record)
	if next(record.refs) ~= nil then
		return
	end
	local pool = config.options().lsp.client_pool
	if pool.strategy == "immediate" then
		stop_record(record)
		return
	end
	if pool.strategy ~= "idle" or record.idle_timer ~= nil then
		return
	end

	local timer
	timer = M.schedule_timer(pool.idle_timeout_ms, function()
		if state.pool[record.key] ~= record or record.idle_timer ~= timer or next(record.refs) ~= nil then
			return
		end
		record.idle_timer = nil
		stop_record(record)
	end)
	record.idle_timer = timer
end

local function detach_record(record, bufnr)
	M.detach_client(record.client_id, bufnr)
	M.reset_diagnostics(record.client_id, bufnr)
	record.refs[bufnr] = nil
	retire_if_unreferenced(record)
end

function M.detach_managed(bufnr)
	if config.options().lsp.mode ~= "managed" then
		return
	end
	bufnr = concrete_bufnr(bufnr)
	local record = record_for_buffer(bufnr)
	if record ~= nil then
		detach_record(record, bufnr)
	end
end

function M.reconcile_managed(bufnr, snapshot)
	if config.options().lsp.mode ~= "managed" then
		return
	end
	bufnr = concrete_bufnr(bufnr)
	local descriptor = managed_target(snapshot)
	local key = descriptor and M.client_key(snapshot) or nil
	local record = record_for_buffer(bufnr)
	if record ~= nil and record.key == key then
		return record.client_id
	end
	if record ~= nil then
		detach_record(record, bufnr)
	end
	if key ~= nil then
		return M.attach_managed(bufnr, snapshot)
	end
end

function M.on_context_changed(bufnr, snapshot)
	local mode = config.options().lsp.mode
	if mode == "external" then
		M.sync_external(snapshot)
	elseif mode == "managed" then
		M.reconcile_managed(bufnr, snapshot)
	end
end

function M.shutdown_managed()
	local records = vim.tbl_values(state.pool)
	for _, record in ipairs(records) do
		stop_record(record)
	end
	state.pool = {}
	state.errors = {}
	state.failures = {}
end

local function invalidate_managed(snapshot)
	local key = M.client_key(snapshot)
	local record = key and state.pool[key] or nil
	if record == nil or not record.refs[snapshot.bufnr] or record.invalidate_command == nil then
		return
	end
	M.request(record.client, "workspace/executeCommand", { command = record.invalidate_command }, function(err)
		if err ~= nil then
			record_error(
				record.key,
				"managed PgLS schema cache invalidation failed",
				config.options(),
				snapshot
			)
			return
		end
		warm(record.client, snapshot.bufnr)
	end)
end

function M.invalidate(snapshot)
	local mode = config.options().lsp.mode
	if mode == "external" then
		M.invalidate_external(snapshot)
	elseif mode == "managed" then
		invalidate_managed(snapshot)
	end
end

function M.status(snapshot)
	local clients, errors, failures = {}, {}, {}
	local active_key = snapshot and M.client_key(snapshot) or nil
	for _, record in pairs(state.pool) do
		if snapshot == nil or record.key == active_key then
			table.insert(clients, public_record(record))
		end
	end
	for error_key, message in pairs(state.errors) do
		if snapshot == nil or error_key == active_key then
			table.insert(errors, { key = error_key, message = message })
		end
	end
	for failure_key, failure in pairs(state.failures) do
		if snapshot == nil or failure_key == active_key then
			table.insert(failures, vim.deepcopy(failure))
		end
	end
	table.sort(clients, function(a, b) return a.key < b.key end)
	table.sort(errors, function(a, b) return a.key < b.key end)
	table.sort(failures, function(a, b) return a.key < b.key end)
	return {
		mode = config.options().lsp.mode,
		clients = clients,
		errors = errors,
		failures = failures,
		external = config.options().lsp.mode == "external" and vim.deepcopy(state.external_snapshot) or nil,
	}
end

function M.status_message(snapshot)
	local status = M.status(snapshot)
	if status.mode == "off" then
		return "dbsh.nvim: PgLS integration is off"
	end
	if status.mode == "external" then
		local message = "dbsh.nvim: external PgLS client is user-owned and shared; last-synchronized context wins"
		if status.external == nil then
			return message .. " (no context synchronized yet)"
		end
		return string.format(
			"%s — backend=%s database=%s root=%s search_path=%s",
			message,
			tostring(status.external.backend),
			tostring(status.external.database),
			tostring(status.external.project_root),
			table.concat(status.external.search_path, ",")
		)
	end
	local record = status.clients[1] or status.failures[1]
	if record == nil then
		return "dbsh.nvim: no managed PgLS client for the active context"
	end
	local message = string.format(
		"dbsh.nvim: managed PgLS key=%s state=%s buffers=%s backend=%s database=%s root=%s search_path=%s",
		record.key,
		record.state,
		table.concat(record.buffers, ","),
		tostring(record.backend),
		tostring(snapshot and effective_database(snapshot)),
		tostring(record.project_root),
		table.concat(record.search_path, ",")
	)
	if record.last_error ~= nil then
		message = message .. " error=" .. record.last_error
	end
	return message
end

M.setup()

return M
