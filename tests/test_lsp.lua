local helpers = dofile("tests/helpers.lua")
local eq, expect_match = helpers.eq, helpers.expect_match

local config = require("dbsh.config")
local context = require("dbsh.context")
local lsp = require("dbsh.lsp")

local originals
local active_snapshot

local function fake_client(id, name)
	local client = {
		id = id,
		name = name or "postgres_lsp",
		initialized = true,
		settings = {},
		notified = {},
		requested = {},
		handlers = {},
	}

	client.notify = function(a, b, c)
		local method, params = a, b
		if a == client then
			method, params = b, c
		end
		table.insert(client.notified, { method = method, params = params })
	end

	client.request = function(a, b, c, d)
		local method, params, handler = a, b, c
		if a == client then
			method, params, handler = b, c, d
		end
		table.insert(client.requested, { method = method, params = params })
		if handler ~= nil then
			handler(client.request_error, nil, nil)
		end
		return true
	end

	return client
end

local function setup_with(lsp_opts, connection)
	connection = vim.tbl_extend("force", {
		host = "localhost",
		port = 5432,
		database = "postgres",
		username = "dev",
		password = "never-send",
	}, connection or {})
	config.setup({
		connections = { local_db = connection },
		default = "local_db",
		lsp = lsp_opts,
	})
	context.setup()
	return context.snapshot(0)
end

local function managed_snapshot(bufnr, opts)
	local snapshot = setup_with(opts or { mode = "managed" }, {
		search_path = { "extensions", "public" },
	})
	snapshot.bufnr = bufnr
	snapshot.project_root = "/work/project"
	snapshot.levels.schema = "tenant"
	return snapshot
end

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			originals = {
				clients = lsp._clients,
				buffers = lsp._buffers,
				start_client = lsp.start_client,
				attach_client = lsp.attach_client,
				request = lsp.request,
				stop_client = lsp.stop_client,
				notify = vim.notify,
			}
			lsp._warned = { env = false, command = false, failures = {} }
			lsp.setup()
			active_snapshot = setup_with({ enabled = true })
		end,
		post_case = function()
			lsp._clients = originals.clients
			lsp._buffers = originals.buffers
			lsp.start_client = originals.start_client
			lsp.attach_client = originals.attach_client
			lsp.request = originals.request
			lsp.stop_client = originals.stop_client
			vim.notify = originals.notify
			vim.env.PGDATABASE = nil
			lsp.setup()
		end,
	},
})

T["external mode sends only the legacy password-free delta"] = function()
	local client = fake_client(1)
	client.settings = { db = { password = "kept" }, other = true }
	local starts, stops = 0, 0
	lsp._clients = function() return { client } end
	lsp.start_client = function() starts = starts + 1 end
	lsp.stop_client = function() stops = stops + 1 end

	lsp.sync_external(active_snapshot)

	eq(#client.notified, 1)
	eq(client.notified[1].method, "workspace/didChangeConfiguration")
	eq(client.notified[1].params.settings.db, {
		host = "localhost",
		port = 5432,
		username = "dev",
		database = "postgres",
		connTimeoutSecs = 5,
	})
	eq(client.notified[1].params.settings.db.password, nil)
	eq(client.settings, { db = { password = "kept" }, other = true })
	eq(starts, 0)
	eq(stops, 0)
end

T["external invalidation stays targeted to user-owned clients"] = function()
	local client = fake_client(1)
	local buf = vim.api.nvim_create_buf(false, true)
	lsp._clients = function() return { client } end
	lsp._buffers = function() return { buf } end

	lsp.invalidate(active_snapshot)

	eq(#client.requested, 2)
	eq(client.requested[1].method, "workspace/executeCommand")
	eq(client.requested[1].params.command, "pgls.invalidateSchemaCache")
	eq(client.requested[2].method, "textDocument/completion")
	vim.api.nvim_buf_delete(buf, { force = true })
end

T["off mode has no client-management side effects"] = function()
	local snapshot = setup_with({ mode = "off" })
	local client = fake_client(1)
	local starts, stops = 0, 0
	lsp._clients = function() return { client } end
	lsp.start_client = function() starts = starts + 1 end
	lsp.stop_client = function() stops = stops + 1 end

	lsp.sync_external(snapshot)
	lsp.invalidate(snapshot)
	lsp.attach_managed(vim.api.nvim_get_current_buf(), snapshot)

	eq(#client.notified, 0)
	eq(#client.requested, 0)
	eq(starts, 0)
	eq(stops, 0)
end

T["derives distinct public managed keys and prepends the selected schema"] = function()
	local snapshot = managed_snapshot(vim.api.nvim_get_current_buf())
	local different_database = vim.deepcopy(snapshot)
	different_database.connection.database = "analytics"
	different_database.levels.database = "analytics"
	local different_root = vim.deepcopy(snapshot)
	different_root.project_root = "/work/other"
	local different_schema = vim.deepcopy(snapshot)
	different_schema.levels.schema = "reporting"

	eq(context.resolved_search_path(snapshot), { "tenant", "extensions", "public" })
	eq(lsp.client_key(snapshot) == lsp.client_key(different_database), false)
	eq(lsp.client_key(snapshot) == lsp.client_key(different_root), false)
	eq(lsp.client_key(snapshot) == lsp.client_key(different_schema), false)
	eq(vim.inspect(lsp.client_key(snapshot)):find("never%-send"), nil)
end

T["starts one managed client per key and sends the strict context request"] = function()
	local buf = vim.api.nvim_create_buf(false, true)
	local snapshot = managed_snapshot(buf)
	local client = fake_client(42, "dbsh_pgls")
	local starts, attachments, requests
	lsp.start_client = function(client_config)
		starts = client_config
		return client
	end
	lsp.attach_client = function(client_id, bufnr)
		attachments = { client_id = client_id, bufnr = bufnr }
		return true
	end
	lsp.request = function(request_client, method, params, handler)
		requests = { client = request_client, method = method, params = params }
		handler(nil, nil)
		return true
	end

	lsp.attach_managed(buf, snapshot)

	eq(starts.cmd, { "postgres-language-server", "lsp-proxy" })
	eq(starts.root_dir, "/work/project")
	eq(starts.name:find(lsp.client_key(snapshot):sub(1, 12), 1, true) ~= nil, true)
	eq(attachments, { client_id = 42, bufnr = buf })
	eq(requests.method, "pgls/setDatabaseContext")
	eq(requests.params, {
		context = {
			connection = {
				host = "localhost",
				port = 5432,
				username = "dev",
				password = "never-send",
				database = "postgres",
			},
			searchPath = { "tenant", "extensions", "public" },
		},
	})
	eq(requests.params.context.connection.connectionString, nil)
	eq(requests.params.context.connection.role, nil)
	eq(vim.inspect(lsp.status()):find("never%-send"), nil)
	vim.api.nvim_buf_delete(buf, { force = true })
end

T["waits for client initialization before sending database context"] = function()
	local buf = vim.api.nvim_create_buf(false, true)
	local snapshot = managed_snapshot(buf)
	local client = fake_client(42)
	client.initialized = false
	local started, requests
	lsp.start_client = function(client_config)
		started = client_config
		return client
	end
	lsp.attach_client = function() return true end
	lsp.request = function(_, method, _, handler)
		requests = (requests or 0) + 1
		eq(method, "pgls/setDatabaseContext")
		handler(nil, nil)
		return true
	end

	lsp.attach_managed(buf, snapshot)
	eq(requests, nil)

	client.initialized = true
	started.on_init(client)
	eq(vim.wait(1000, function() return requests == 1 end, 10), true)
	eq(requests, 1)
	vim.api.nvim_buf_delete(buf, { force = true })
end

T["reuses a managed client for equal keys and tracks both buffers"] = function()
	local first = vim.api.nvim_create_buf(false, true)
	local second = vim.api.nvim_create_buf(false, true)
	local snapshot = managed_snapshot(first)
	local same_context = vim.deepcopy(snapshot)
	same_context.bufnr = second
	local client = fake_client(42)
	local starts, attachments = 0, {}
	lsp.start_client = function()
		starts = starts + 1
		return client
	end
	lsp.attach_client = function(client_id, bufnr)
		table.insert(attachments, { client_id = client_id, bufnr = bufnr })
		return true
	end
	lsp.request = function(_, _, _, handler)
		handler(nil, nil)
		return true
	end

	lsp.attach_managed(first, snapshot)
	lsp.attach_managed(second, same_context)

	eq(starts, 1)
	eq(attachments, { { client_id = 42, bufnr = first }, { client_id = 42, bufnr = second } })
	eq(lsp.status().clients[1].buffers, { first, second })
	vim.api.nvim_buf_delete(first, { force = true })
	vim.api.nvim_buf_delete(second, { force = true })
end

T["managed invalidation affects only the pooled client for the snapshot"] = function()
	local buf = vim.api.nvim_create_buf(false, true)
	local snapshot = managed_snapshot(buf)
	local client = fake_client(42)
	local requested = {}
	lsp._clients = function()
		error("managed invalidation must not enumerate user-owned clients")
	end
	lsp.start_client = function() return client end
	lsp.attach_client = function() return true end
	lsp.request = function(_, method, params, handler)
		table.insert(requested, { method = method, params = params })
		handler(nil, nil)
		return true
	end

	lsp.attach_managed(buf, snapshot)
	lsp.invalidate(snapshot)

	eq(requested[1].method, "pgls/setDatabaseContext")
	eq(requested[2].method, "workspace/executeCommand")
	eq(requested[2].params.command, "pgls.invalidateSchemaCache")
	eq(requested[3].method, "textDocument/completion")
	vim.api.nvim_buf_delete(buf, { force = true })
end

T["does not start managed PgLS for a non-PostgreSQL snapshot"] = function()
	local backends = require("dbsh.backends")
	local previous = backends.registry.snowflake
	backends.registry.snowflake = { name = "snowflake" }
	local snapshot = managed_snapshot(vim.api.nvim_get_current_buf())
	snapshot.connection.type = "snowflake"
	snapshot.backend_name = "snowflake"
	local starts = 0
	lsp.start_client = function() starts = starts + 1 end

	lsp.attach_managed(snapshot.bufnr, snapshot)

	backends.registry.snowflake = previous
	eq(starts, 0)
end

T["stops an incompatible PgLS binary without a legacy fallback"] = function()
	local buf = vim.api.nvim_create_buf(false, true)
	local snapshot = managed_snapshot(buf)
	local client = fake_client(42)
	local stopped, notices = {}, 0
	lsp.start_client = function() return client end
	lsp.attach_client = function() return true end
	lsp.stop_client = function(client_id) table.insert(stopped, client_id) end
	lsp.request = function(_, _, _, handler)
		handler({ code = -32601, message = "Method not found" }, nil)
		return true
	end
	vim.notify = function(message, level)
		if level == vim.log.levels.WARN then
			notices = notices + 1
			expect_match(message, "requires a PgLS build")
		end
	end

	lsp.attach_managed(buf, snapshot)

	eq(stopped, { 42 })
	eq(#client.notified, 0)
	eq(notices, 1)
	eq(lsp.status().errors[1].message:find("never%-send"), nil)
	eq(lsp.status().errors[1].message:find("Method not found", 1, true), nil)
	vim.api.nvim_buf_delete(buf, { force = true })
end

T["passes an absolute patched binary command unchanged without exposing it in status"] = function()
	local command = { "/tmp/pgls/postgres-language-server", "lsp-proxy" }
	local buf = vim.api.nvim_create_buf(false, true)
	local snapshot = managed_snapshot(buf, { mode = "managed", command = command })
	local client = fake_client(42)
	local started
	lsp.start_client = function(client_config)
		started = client_config
		return client
	end
	lsp.attach_client = function() return true end
	lsp.request = function(_, _, _, handler)
		handler(nil, nil)
		return true
	end

	lsp.attach_managed(buf, snapshot)

	eq(started.cmd, command)
	eq(vim.inspect(lsp.status()):find("/tmp/pgls", 1, true), nil)
	vim.api.nvim_buf_delete(buf, { force = true })
end

T["keeps the schema-cache message handler narrow"] = function()
	local seen = {}
	local original_handler = vim.lsp.handlers["window/showMessage"]
	vim.lsp.handlers["window/showMessage"] = function(_, result, _)
		table.insert(seen, result.message)
	end

	lsp._show_message_handler(nil, { type = 3, message = "Schema cache invalidated" }, {})
	lsp._show_message_handler(nil, { type = 1, message = "connection refused" }, {})

	vim.lsp.handlers["window/showMessage"] = original_handler
	eq(seen, { "connection refused" })
end

return T
