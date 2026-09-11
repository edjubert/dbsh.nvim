local helpers = dofile("tests/helpers.lua")
local eq = helpers.eq

local config = require("dbsh.config")
local context = require("dbsh.context")
local lsp = require("dbsh.lsp")

local original_clients, original_buffers, original_notify
local active_snapshot

local function fake_client(name)
	local client = { name = name, id = 1, settings = {}, notified = {}, requested = {}, handlers = {} }

	client.notify = function(a, b, c)
		if a == client then
			table.insert(client.notified, { method = b, params = c })
		else
			table.insert(client.notified, { method = a, params = b })
		end
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
	end

	return client
end

local function setup_with(lsp_opts)
	config.setup({
		connections = {
			local_db = {
				host = "localhost",
				port = 5432,
				database = "postgres",
				username = "dev",
				password = "never-send",
			},
		},
		default = "local_db",
		lsp = lsp_opts,
	})
	context.setup()
	return context.snapshot(0)
end

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			original_clients = lsp._clients
			original_buffers = lsp._buffers
			original_notify = vim.notify
			lsp._warned = { env = false, command = false }
			active_snapshot = setup_with({ enabled = true })
		end,
		post_case = function()
			lsp._clients = original_clients
			lsp._buffers = original_buffers
			vim.notify = original_notify
			vim.env.PGDATABASE = nil
		end,
	},
})

T["pushes an explicit context without a password"] = function()
	local client = fake_client("postgres_lsp")
	lsp._clients = function() return { client } end

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
end

T["preserves user-owned settings but sends a password-free delta"] = function()
	local client = fake_client("postgres_lsp")
	client.settings = { db = { password = "kept" }, other = true }
	lsp._clients = function() return { client } end

	lsp.sync_external(active_snapshot)

	eq(client.settings.other, true)
	eq(client.settings.db.password, "kept")
	eq(client.settings.db.database, "postgres")
	eq(client.notified[1].params.settings.db.password, nil)
	eq(client.notified[1].params.settings.other, nil)
end

T["does nothing when the integration is disabled"] = function()
	local snapshot = setup_with({ enabled = false })
	local client = fake_client("postgres_lsp")
	lsp._clients = function() return { client } end

	lsp.sync_external(snapshot)

	eq(#client.notified, 0)
end

T["does nothing when the backend declares no language server"] = function()
	local backends = require("dbsh.backends")
	local postgres = backends.registry.postgres
	local saved = postgres.lsp
	postgres.lsp = nil

	local client = fake_client("postgres_lsp")
	lsp._clients = function() return { client } end
	lsp.sync_external(active_snapshot)
	postgres.lsp = saved

	eq(#client.notified, 0)
end

T["does nothing when no client is alive"] = function()
	local called = false
	lsp._clients = function()
		called = true
		return {}
	end

	lsp.sync_external(active_snapshot)

	eq(called, true)
end

T["syncs one freshly attached client only when it is the right one"] = function()
	local right = fake_client("postgres_lsp")
	local wrong = fake_client("lua_ls")

	lsp.sync_external_client(right, active_snapshot)
	lsp.sync_external_client(wrong, active_snapshot)
	lsp.sync_external_client(nil, active_snapshot)

	eq(#right.notified, 1)
	eq(#wrong.notified, 0)
end

T["warns once about a conflicting environment variable"] = function()
	vim.env.PGDATABASE = "somewhere_else"
	local warnings = 0
	vim.notify = function(msg, level)
		if level == vim.log.levels.WARN and msg:find("PGDATABASE", 1, true) then
			warnings = warnings + 1
		end
	end

	local client = fake_client("postgres_lsp")
	lsp._clients = function() return { client } end
	lsp.sync_external(active_snapshot)
	lsp.sync_external(active_snapshot)

	eq(warnings, 1)
end

T["invalidates then warms the schema cache for an explicit context"] = function()
	local client = fake_client("postgres_lsp")
	local buf = vim.api.nvim_create_buf(false, true)
	lsp._clients = function() return { client } end
	lsp._buffers = function() return { buf } end

	lsp.invalidate_external(active_snapshot)

	eq(#client.requested, 2)
	eq(client.requested[1].method, "workspace/executeCommand")
	eq(client.requested[1].params.command, "pgls.invalidateSchemaCache")
	eq(client.requested[1].params.arguments, nil)
	eq(client.requested[2].method, "textDocument/completion")
	eq(client.requested[2].params.position, { line = 0, character = 0 })

	vim.api.nvim_buf_delete(buf, { force = true })
end

T["skips the warm-up when no buffer is attached"] = function()
	local client = fake_client("postgres_lsp")
	lsp._clients = function() return { client } end
	lsp._buffers = function() return {} end

	lsp.invalidate_external(active_snapshot)

	eq(#client.requested, 1)
	eq(client.requested[1].method, "workspace/executeCommand")
end

T["does not invalidate when the integration is disabled"] = function()
	local snapshot = setup_with({ enabled = false })
	local client = fake_client("postgres_lsp")
	lsp._clients = function() return { client } end

	lsp.invalidate_external(snapshot)

	eq(#client.requested, 0)
end

T["warns once when the server refuses the command"] = function()
	local client = fake_client("postgres_lsp")
	client.request_error = { message = "unknown command" }
	lsp._clients = function() return { client } end
	lsp._buffers = function() return {} end

	local warnings = 0
	vim.notify = function(msg, level)
		if level == vim.log.levels.WARN and msg:find("unknown command", 1, true) then
			warnings = warnings + 1
		end
	end

	lsp.invalidate_external(active_snapshot)
	lsp.invalidate_external(active_snapshot)

	eq(warnings, 1)
	eq(#client.requested, 2)
	eq(client.requested[1].method, "workspace/executeCommand")
	eq(client.requested[2].method, "workspace/executeCommand")
end

T["swallows the schema cache message and lets the rest through"] = function()
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
