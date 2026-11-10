local helpers = dofile("tests/helpers.lua")
local eq, expect_match = helpers.eq, helpers.expect_match

local config = require("dbsh.config")
local context = require("dbsh.context")
local credentials = require("dbsh.credentials")
local lsp = require("dbsh.lsp")

local originals
local active_snapshot
local pgpassfile

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

-- Managed clients belong to normal files, including persisted dbsh
-- scratchpads. Internal nofile/prompt buffers are intentionally excluded.
local function sql_buf()
	local buf = vim.api.nvim_create_buf(true, false)
	vim.bo[buf].filetype = "sql"
	return buf
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
				detach_client = lsp.detach_client,
				reset_diagnostics = lsp.reset_diagnostics,
				schedule_timer = lsp.schedule_timer,
				cancel_timer = lsp.cancel_timer,
				sync_external = lsp.sync_external,
				reconcile_managed = lsp.reconcile_managed,
				notify = vim.notify,
				pgpassfile = vim.env.PGPASSFILE,
			}
			pgpassfile = vim.fn.tempname()
			vim.env.PGPASSFILE = pgpassfile
			lsp._warned = { env = false, command = false, failures = {} }
			lsp.setup()
			lsp.detach_client = function() return true end
			lsp.reset_diagnostics = function() end
			active_snapshot = setup_with({ enabled = true })
		end,
		post_case = function()
			lsp._clients = originals.clients
			lsp._buffers = originals.buffers
			lsp.start_client = originals.start_client
			lsp.attach_client = originals.attach_client
			lsp.request = originals.request
			lsp.stop_client = originals.stop_client
			lsp.detach_client = originals.detach_client
			lsp.reset_diagnostics = originals.reset_diagnostics
			lsp.schedule_timer = originals.schedule_timer
			lsp.cancel_timer = originals.cancel_timer
			lsp.sync_external = originals.sync_external
			lsp.reconcile_managed = originals.reconcile_managed
			vim.notify = originals.notify
			vim.env.PGPASSFILE = originals.pgpassfile
			vim.fn.delete(pgpassfile)
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
	local buf = sql_buf()
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

T["starts one managed client per key and sends official configuration overrides"] = function()
	local buf = sql_buf()
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
	eq(requests.method, "pgls/set_configuration_overrides")
	eq(requests.params, {
		overrides = {
			db = {
				host = "localhost",
				port = 5432,
				username = "dev",
				password = "never-send",
				database = "postgres",
				disableConnection = false,
			},
			typecheck = {
				searchPath = { "tenant", "extensions", "public" },
			},
		},
	})
	eq(requests.params.overrides.db.connectionString, nil)
	eq(requests.params.overrides.db.role, nil)
	eq(vim.inspect(lsp.status()):find("never%-send"), nil)
	vim.api.nvim_buf_delete(buf, { force = true })
end

T["resolves password callbacks lazily with the effective database and an isolated connection"] = function()
	local calls = 0
	local callback = function(connection)
		calls = calls + 1
		eq(connection.host, "localhost")
		eq(connection.port, 5432)
		eq(connection.username, "dev")
		eq(connection.database, "analytics")
		connection.host = "mutated-by-callback"
		connection.database = "mutated-by-callback"
		return "resolved-password"
	end
	local buf = sql_buf()
	local snapshot = setup_with({ mode = "managed" }, { password = callback })
	snapshot.bufnr = buf
	snapshot.project_root = "/work/project"
	snapshot.levels.database = "analytics"
	config.options().connections.unused = { password = function() error("unused callback") end }
	eq(calls, 0)
	local client = fake_client(42)
	local started
	lsp.start_client = function(client_config)
		started = client_config
		return client
	end
	lsp.attach_client = function() return true end

	eq(lsp.attach_managed(buf, snapshot), 42)

	eq(calls, 1)
	eq(client.requested[1].params.overrides.db.database, "analytics")
	eq(client.requested[1].params.overrides.db.host, "localhost")
	eq(client.requested[1].params.overrides.db.password, "resolved-password")
	eq(config.options().connections.local_db.password, callback)
	eq(snapshot.connection.password, callback)
	eq(snapshot.connection.database, "postgres")
	eq(vim.inspect(started):find("resolved-password", 1, true), nil)
	eq(vim.inspect(lsp.status()):find("resolved-password", 1, true), nil)
	vim.api.nvim_buf_delete(buf, { force = true })
end

T["pgpass callbacks use the selected database and leave other profiles usable on a miss"] = function()
	vim.fn.writefile({
		"localhost:5432:postgres:dev:default-password",
		"localhost:5432:analytics:dev:selected-password",
	}, pgpassfile)
	assert(vim.uv.fs_chmod(pgpassfile, 384))
	local buf = sql_buf()
	local snapshot = setup_with({ mode = "managed" }, { password = credentials.pgpass })
	snapshot.bufnr = buf
	snapshot.project_root = "/work/project"
	snapshot.levels.database = "missing"
	local notices = {}
	vim.notify = function(message) notices[#notices + 1] = message end
	local starts = 0
	local client = fake_client(42)
	lsp.start_client = function()
		starts = starts + 1
		return client
	end
	lsp.attach_client = function() return true end

	eq(lsp.attach_managed(buf, snapshot), nil)
	eq(starts, 0)
	eq(#notices, 1)
	eq(config.options().connections.local_db.password, credentials.pgpass)
	eq(vim.inspect(lsp.status()):find("default-password", 1, true), nil)

	snapshot.levels.database = "analytics"
	eq(lsp.attach_managed(buf, snapshot), 42)
	eq(starts, 1)
	eq(client.requested[1].params.overrides.db.password, "selected-password")
	eq(client.requested[1].params.overrides.db.database, "analytics")
	vim.api.nvim_buf_delete(buf, { force = true })
end

T["sanitizes callback exceptions and rejects missing or non-string passwords"] = function()
	local buf = sql_buf()
	local snapshot = managed_snapshot(buf)
	local notices = {}
	vim.notify = function(message) notices[#notices + 1] = message end
	lsp.start_client = function() error("must not start without a password") end
	for _, callback in ipairs({
		function() error("secret-from-callback") end,
		function() return nil, "secret-from-callback" end,
		function() return "" end,
		function() return { password = "secret-from-callback" } end,
	}) do
		snapshot.connection.password = callback
		eq(lsp.attach_managed(buf, snapshot), nil)
		eq(vim.inspect(lsp.status()):find("secret-from-callback", 1, true), nil)
		eq(vim.inspect(notices):find("secret-from-callback", 1, true), nil)
	end
	eq(#notices, 1)
	vim.api.nvim_buf_delete(buf, { force = true })
end

T["does not invoke password callbacks in off or external mode"] = function()
	local buf = sql_buf()
	for _, mode in ipairs({ "off", "external" }) do
		local snapshot = setup_with({ mode = mode }, {
			password = function() error("callback should only run for managed PgLS") end,
		})
		snapshot.bufnr = buf
		lsp._clients = function() return {} end
		lsp.sync_external(snapshot)
		eq(lsp.attach_managed(buf, snapshot), nil)
	end
	vim.api.nvim_buf_delete(buf, { force = true })
end

T["waits for client initialization before sending configuration overrides"] = function()
	local buf = sql_buf()
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
		eq(method, "pgls/set_configuration_overrides")
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
	local first = sql_buf()
	local second = sql_buf()
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
	local buf = sql_buf()
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

	eq(requested[1].method, "pgls/set_configuration_overrides")
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

T["stops a pre-0.26 PgLS binary without a legacy fallback"] = function()
	local buf = sql_buf()
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
			expect_match(message, "requires PgLS 0.26.0 or newer")
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

T["passes an absolute binary command unchanged without exposing it in status"] = function()
	local command = { "/tmp/pgls/postgres-language-server", "lsp-proxy" }
	local buf = sql_buf()
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

T["dispatches context changes by mode without mixing external and managed clients"] = function()
	local external_calls, managed_calls = 0, 0
	lsp.sync_external = function() external_calls = external_calls + 1 end
	lsp.reconcile_managed = function() managed_calls = managed_calls + 1 end

	lsp.on_context_changed(active_snapshot.bufnr, active_snapshot)
	eq(external_calls, 1)
	eq(managed_calls, 0)

	local managed = managed_snapshot(vim.api.nvim_get_current_buf())
	lsp.on_context_changed(managed.bufnr, managed)
	eq(external_calls, 1)
	eq(managed_calls, 1)

	local off = setup_with({ mode = "off" })
	lsp.on_context_changed(off.bufnr, off)
	eq(external_calls, 1)
	eq(managed_calls, 1)
end

T["reconciles a changed buffer context without stopping a shared client"] = function()
	local first = sql_buf()
	local second = sql_buf()
	local original = managed_snapshot(first)
	local shared = vim.deepcopy(original)
	shared.bufnr = second
	local changed = vim.deepcopy(original)
	changed.levels.schema = "reporting"
	local starts, attached, detached, reset, stopped = 0, {}, {}, {}, {}
	lsp.start_client = function()
		starts = starts + 1
		return fake_client(starts)
	end
	lsp.attach_client = function(client_id, bufnr)
		table.insert(attached, { client_id = client_id, bufnr = bufnr })
		return true
	end
	lsp.detach_client = function(client_id, bufnr)
		table.insert(detached, { client_id = client_id, bufnr = bufnr })
	end
	lsp.reset_diagnostics = function(client_id, bufnr)
		table.insert(reset, { client_id = client_id, bufnr = bufnr })
	end
	lsp.stop_client = function(client_id) table.insert(stopped, client_id) end
	lsp.request = function(_, _, _, handler)
		handler(nil, nil)
		return true
	end

	lsp.reconcile_managed(first, original)
	lsp.reconcile_managed(second, shared)
	lsp.reconcile_managed(first, changed)

	eq(starts, 2)
	eq(detached, { { client_id = 1, bufnr = first } })
	eq(reset, { { client_id = 1, bufnr = first } })
	eq(stopped, {})
	eq(attached, {
		{ client_id = 1, bufnr = first },
		{ client_id = 1, bufnr = second },
		{ client_id = 2, bufnr = first },
	})
	local records = lsp.status().clients
	eq(#records, 2)
	eq(vim.inspect(records):find("never%-send"), nil)
	vim.api.nvim_buf_delete(first, { force = true })
	vim.api.nvim_buf_delete(second, { force = true })
end

T["keeps an unchanged managed key attached once"] = function()
	local buf = sql_buf()
	local snapshot = managed_snapshot(buf)
	local starts, attached = 0, 0
	lsp.start_client = function()
		starts = starts + 1
		return fake_client(42)
	end
	lsp.attach_client = function()
		attached = attached + 1
		return true
	end
	lsp.request = function(_, _, _, handler)
		handler(nil, nil)
		return true
	end

	lsp.reconcile_managed(buf, snapshot)
	lsp.reconcile_managed(buf, snapshot)

	eq(starts, 1)
	eq(attached, 1)
	vim.api.nvim_buf_delete(buf, { force = true })
end

T["normalizes the current buffer before tracking a managed reference"] = function()
	local previous = vim.api.nvim_get_current_buf()
	local buf = sql_buf()
	vim.api.nvim_set_current_buf(buf)
	local snapshot = managed_snapshot(buf)
	local attached
	lsp.start_client = function() return fake_client(42) end
	lsp.attach_client = function(_, bufnr)
		attached = bufnr
		return true
	end
	lsp.request = function(_, _, _, handler)
		handler(nil, nil)
		return true
	end

	lsp.reconcile_managed(0, snapshot)

	vim.api.nvim_set_current_buf(previous)
	eq(attached, buf)
	eq(lsp.status().clients[1].buffers, { buf })
	vim.api.nvim_buf_delete(buf, { force = true })
end

T["stops only after the last immediate managed reference detaches"] = function()
	local first = sql_buf()
	local second = sql_buf()
	local snapshot = managed_snapshot(first)
	local shared = vim.deepcopy(snapshot)
	shared.bufnr = second
	local detached, reset, stopped = {}, {}, {}
	lsp.start_client = function() return fake_client(42) end
	lsp.attach_client = function() return true end
	lsp.detach_client = function(client_id, bufnr)
		table.insert(detached, { client_id = client_id, bufnr = bufnr })
	end
	lsp.reset_diagnostics = function(client_id, bufnr)
		table.insert(reset, { client_id = client_id, bufnr = bufnr })
	end
	lsp.stop_client = function(client_id) table.insert(stopped, client_id) end
	lsp.request = function(_, _, _, handler)
		handler(nil, nil)
		return true
	end

	lsp.reconcile_managed(first, snapshot)
	lsp.reconcile_managed(second, shared)
	lsp.detach_managed(first)
	eq(stopped, {})
	lsp.detach_managed(second)

	eq(detached, { { client_id = 42, bufnr = first }, { client_id = 42, bufnr = second } })
	eq(reset, detached)
	eq(stopped, { 42 })
	eq(lsp.status().clients, {})
	vim.api.nvim_buf_delete(first, { force = true })
	vim.api.nvim_buf_delete(second, { force = true })
end

T["cancels an idle retirement when a managed buffer reattaches"] = function()
	local buf = sql_buf()
	local snapshot = managed_snapshot(buf, {
		mode = "managed",
		client_pool = { strategy = "idle", idle_timeout_ms = 25 },
	})
	local timers, stopped = {}, {}
	lsp.start_client = function() return fake_client(42) end
	lsp.attach_client = function() return true end
	lsp.detach_client = function() end
	lsp.reset_diagnostics = function() end
	lsp.stop_client = function(client_id) table.insert(stopped, client_id) end
	lsp.request = function(_, _, _, handler)
		handler(nil, nil)
		return true
	end
	lsp.schedule_timer = function(timeout, callback)
		local timer = { timeout = timeout, callback = callback }
		table.insert(timers, timer)
		return timer
	end
	lsp.cancel_timer = function(timer) timer.cancelled = true end

	lsp.reconcile_managed(buf, snapshot)
	lsp.detach_managed(buf)
	lsp.detach_managed(buf)
	eq(#timers, 1)
	eq(timers[1].timeout, 25)
	lsp.reconcile_managed(buf, snapshot)
	eq(timers[1].cancelled, true)
	timers[1].callback()
	eq(stopped, {})

	lsp.detach_managed(buf)
	eq(#timers, 2)
	timers[2].callback()
	eq(stopped, { 42 })
	vim.api.nvim_buf_delete(buf, { force = true })
end

T["keeps session clients until managed shutdown"] = function()
	local buf = sql_buf()
	local snapshot = managed_snapshot(buf, {
		mode = "managed",
		client_pool = { strategy = "session", idle_timeout_ms = 0 },
	})
	local stopped = {}
	lsp.start_client = function() return fake_client(42) end
	lsp.attach_client = function() return true end
	lsp.detach_client = function() end
	lsp.reset_diagnostics = function() end
	lsp.stop_client = function(client_id) table.insert(stopped, client_id) end
	lsp.request = function(_, _, _, handler)
		handler(nil, nil)
		return true
	end

	lsp.reconcile_managed(buf, snapshot)
	lsp.detach_managed(buf)
	eq(stopped, {})
	lsp.shutdown_managed()
	eq(stopped, { 42 })
	vim.api.nvim_buf_delete(buf, { force = true })
end

T["notifies once for repeated failures of the same managed key"] = function()
	local buf = sql_buf()
	local snapshot = managed_snapshot(buf)
	local notices = 0
	local original_notify = vim.notify
	lsp.start_client = function() return fake_client(42) end
	lsp.attach_client = function() return true end
	lsp.request = function(_, _, _, handler)
		handler({ code = -32000, message = "connection failed" }, nil)
		return true
	end
	vim.notify = function(_, level)
		if level == vim.log.levels.WARN then
			notices = notices + 1
		end
	end

	lsp.attach_managed(buf, snapshot)
	lsp.attach_managed(buf, snapshot)

	vim.notify = original_notify
	eq(notices, 1)
	eq(lsp.status().clients[1].state, "failed")
	vim.api.nvim_buf_delete(buf, { force = true })
end

T["reports a redacted external status with last-synchronized context wins"] = function()
	local client = fake_client(1)
	client.settings = { db = { password = "kept" } }
	lsp._clients = function() return { client } end

	lsp.sync_external(active_snapshot)

	local status = lsp.status(active_snapshot)
	local message = lsp.status_message(active_snapshot)
	eq(status.external.database, "postgres")
	eq(vim.inspect(status):find("kept", 1, true), nil)
	eq(message:find("user-owned", 1, true) ~= nil, true)
	eq(message:find("last-synchronized context wins", 1, true) ~= nil, true)
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

T["refuses to attach a managed client to a buffer outside the backend filetype"] = function()
	local buf = sql_buf()
	vim.bo[buf].filetype = "markdown"
	local snapshot = managed_snapshot(buf)
	local starts, attachments = 0, 0
	lsp.start_client = function()
		starts = starts + 1
		return fake_client(7, "dbsh_pgls")
	end
	lsp.attach_client = function()
		attachments = attachments + 1
		return true
	end

	eq(lsp.attach_managed(buf, snapshot), nil)
	eq(starts, 0)
	eq(attachments, 0)
	eq(lsp.status().clients, {})
	eq(lsp.status().errors, {})
	vim.api.nvim_buf_delete(buf, { force = true })
end

T["refuses to attach a managed client to an internal SQL buffer"] = function()
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].filetype = "sql"
	local snapshot = managed_snapshot(buf)
	local starts, attachments = 0, 0
	lsp.start_client = function()
		starts = starts + 1
		return fake_client(7, "dbsh_pgls")
	end
	lsp.attach_client = function()
		attachments = attachments + 1
		return true
	end

	eq(vim.bo[buf].buftype, "nofile")
	eq(lsp.attach_managed(buf, snapshot), nil)
	eq(starts, 0)
	eq(attachments, 0)
	eq(lsp.status().clients, {})
	vim.api.nvim_buf_delete(buf, { force = true })
end

T["detaches a managed client when the buffer filetype leaves the backend"] = function()
	local buf = sql_buf()
	vim.bo[buf].filetype = "sql"
	local snapshot = managed_snapshot(buf)
	local client = fake_client(11, "dbsh_pgls")
	local detached = {}
	lsp.start_client = function() return client end
	lsp.attach_client = function() return true end
	lsp.detach_client = function(client_id, bufnr)
		table.insert(detached, { client_id = client_id, bufnr = bufnr })
		return true
	end

	eq(lsp.reconcile_managed(buf, snapshot), 11)

	vim.bo[buf].filetype = "markdown"
	lsp.reconcile_managed(buf, snapshot)

	eq(detached, { { client_id = 11, bufnr = buf } })
	vim.api.nvim_buf_delete(buf, { force = true })
end

return T
