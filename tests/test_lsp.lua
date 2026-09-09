local helpers = dofile("tests/helpers.lua")
local eq = helpers.eq

local config = require("dbsh.config")
local lsp = require("dbsh.lsp")

local original_clients, original_notify

-- A stand-in for a vim.lsp client, recording what dbsh sends it. notify is
-- written to work under both shims: the 0.10 branch calls notify(method,
-- params), the 0.11 branch calls client:notify(method, params).
local function fake_client(name)
	local client = { name = name, id = 1, settings = {}, notified = {} }
	client.notify = function(a, b, c)
		if a == client then
			table.insert(client.notified, { method = b, params = c })
		else
			table.insert(client.notified, { method = a, params = b })
		end
	end
	return client
end

local function setup_with(lsp_opts)
	config.setup({
		connections = {
			local_db = { host = "localhost", port = 5432, database = "postgres", username = "dev" },
		},
		default = "local_db",
		lsp = lsp_opts,
	})
end

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			original_clients = lsp._clients
			original_notify = vim.notify
			lsp._warned = { env = false, command = false }
			setup_with({ enabled = true })
		end,
		post_case = function()
			lsp._clients = original_clients
			vim.notify = original_notify
			vim.env.PGDATABASE = nil
		end,
	},
})

T["pushes the connection without a password"] = function()
	local client = fake_client("postgres_lsp")
	lsp._clients = function()
		return { client }
	end

	lsp.sync()

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

T["merges into the existing settings rather than replacing them"] = function()
	local client = fake_client("postgres_lsp")
	client.settings = { db = { password = "kept" }, other = true }
	lsp._clients = function()
		return { client }
	end

	lsp.sync()

	eq(client.settings.other, true)
	eq(client.settings.db.password, "kept")
	eq(client.settings.db.database, "postgres")
	-- The notification carries the merged table, not just the delta.
	eq(client.notified[1].params.settings, client.settings)
end

T["does nothing when the integration is disabled"] = function()
	setup_with({ enabled = false })
	local client = fake_client("postgres_lsp")
	lsp._clients = function()
		return { client }
	end

	lsp.sync()

	eq(#client.notified, 0)
end

T["does nothing when the backend declares no language server"] = function()
	local backends = require("dbsh.backends")
	local postgres = backends.registry.postgres
	local saved = postgres.lsp
	postgres.lsp = nil

	local client = fake_client("postgres_lsp")
	lsp._clients = function()
		return { client }
	end

	lsp.sync()
	postgres.lsp = saved

	eq(#client.notified, 0)
end

T["does nothing when no client is alive"] = function()
	local called = false
	lsp._clients = function()
		called = true
		return {}
	end

	lsp.sync()

	eq(called, true)
end

T["syncs one freshly attached client, and only if it is the right one"] = function()
	local right = fake_client("postgres_lsp")
	local wrong = fake_client("lua_ls")

	lsp.sync_client(right)
	lsp.sync_client(wrong)
	lsp.sync_client(nil)

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
	lsp._clients = function()
		return { client }
	end

	lsp.sync()
	lsp.sync()

	eq(warnings, 1)
end

return T
