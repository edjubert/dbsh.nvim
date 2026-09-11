local helpers = dofile("tests/helpers.lua")
local eq, expect_match = helpers.eq, helpers.expect_match

local config = require("dbsh.config")
local context = require("dbsh.context")

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			config.setup({
				connections = {
					local_db = {
						host = "localhost",
						port = 5432,
						database = "postgres",
						username = "dev",
						password = "never-public",
						password_command = { "secret", "read" },
					},
					staging = { host = "db.example.com", port = 5432, database = "app", username = "readonly" },
				},
				default = "local_db",
			})
			context.setup()
		end,
	},
})

T["uses the configured fallback for an unbound buffer"] = function()
	local current = context.current(0)
	eq(current.kind, "fallback")
	eq(current.connection_name, "local_db")
	eq(current.connection.database, "postgres")
end

T["binds an explicit ephemeral context to a buffer"] = function()
	local bufnr = vim.api.nvim_create_buf(false, true)
	assert(context.bind(bufnr, "staging", "connections"))

	local current = context.current(bufnr)
	eq(current.kind, "buffer")
	eq(current.connection_name, "staging")
	eq(current.connection.database, "app")

	vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["keeps generations independent for separate buffers"] = function()
	local a = vim.api.nvim_create_buf(false, true)
	local b = vim.api.nvim_create_buf(false, true)
	assert(context.bind(a, "local_db", "test"))
	assert(context.bind(b, "staging", "test"))

	local before_a = context.generation(a)
	local before_b = context.generation(b)
	assert(context.set_level(a, "database", "analytics", "test"))

	eq(context.generation(a) > before_a, true)
	eq(context.generation(b), before_b)

	vim.api.nvim_buf_delete(a, { force = true })
	vim.api.nvim_buf_delete(b, { force = true })
end

T["changes levels only on the active buffer context"] = function()
	local a = vim.api.nvim_create_buf(false, true)
	local b = vim.api.nvim_create_buf(false, true)
	assert(context.bind(a, "local_db", "test"))
	assert(context.bind(b, "local_db", "test"))
	assert(context.set_level(a, "schema", "analytics", "test"))

	eq(context.current(a).levels.schema, "analytics")
	eq(context.current(b).levels.schema, nil)
	eq(config.options().connections.local_db.schema, nil)

	vim.api.nvim_buf_delete(a, { force = true })
	vim.api.nvim_buf_delete(b, { force = true })
end

T["applies a context selector to the snapshot owning buffer"] = function()
	local a = vim.api.nvim_create_buf(false, true)
	local b = vim.api.nvim_create_buf(false, true)
	assert(context.bind(a, "local_db", "test"))
	assert(context.bind(b, "local_db", "test"))
	local snapshot = context.snapshot(a)

	assert(context.apply(snapshot, "schema", "reporting", "catalog"))

	eq(context.current(a).levels.schema, "reporting")
	eq(context.current(b).levels.schema, nil)

	vim.api.nvim_buf_delete(a, { force = true })
	vim.api.nvim_buf_delete(b, { force = true })
end

T["changes only the fallback through set_global"] = function()
	local bound = vim.api.nvim_create_buf(false, true)
	local unbound = vim.api.nvim_create_buf(false, true)
	assert(context.bind(bound, "local_db", "test"))
	assert(context.set_global("staging", "global"))

	eq(context.current(bound).connection_name, "local_db")
	eq(context.current(unbound).connection_name, "staging")

	vim.api.nvim_buf_delete(bound, { force = true })
	vim.api.nvim_buf_delete(unbound, { force = true })
end

T["forgets a buffer binding and returns it to the fallback"] = function()
	local bufnr = vim.api.nvim_create_buf(false, true)
	assert(context.bind(bufnr, "staging", "test"))
	assert(context.forget(bufnr, "forget"))

	eq(context.current(bufnr).kind, "fallback")
	eq(context.current(bufnr).connection_name, "local_db")

	vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["rejects an unknown profile"] = function()
	local current, err = context.bind(0, "missing", "test")
	eq(current, nil)
	expect_match(err, "unknown connection")
end

T["isolates snapshots from mutable runtime and declared configuration"] = function()
	local snapshot = context.snapshot(0)
	snapshot.connection.database = "analytics"
	snapshot.levels.schema = "reporting"

	eq(context.current(0).connection.database, "postgres")
	eq(context.current(0).levels.schema, nil)
	eq(config.options().connections.local_db.database, "postgres")
end

T["resolves a standalone project root and ordered PostgreSQL search path"] = function()
	local snapshot = context.snapshot(0)
	snapshot.project_root = nil
	snapshot.levels.schema = "tenant"
	snapshot.connection.search_path = { "extensions", "tenant", "public" }

	eq(context.resolved_search_path(snapshot), { "tenant", "extensions", "public" })
	eq(context.resolved_project_root(snapshot), vim.fs.joinpath(vim.fn.stdpath("data"), "dbsh", "lsp"))
end

T["emits redacted public data for context changes and the legacy event once"] = function()
	local events, legacy = {}, 0
	local group = vim.api.nvim_create_augroup("dbsh_test_context_events", { clear = true })
	vim.api.nvim_create_autocmd("User", {
		pattern = "DbshContextChanged",
		group = group,
		callback = function(args) table.insert(events, args.data) end,
	})
	vim.api.nvim_create_autocmd("User", {
		pattern = "DbshConnectionChanged",
		group = group,
		callback = function() legacy = legacy + 1 end,
	})

	assert(context.bind(0, "staging", "connections"))

	vim.api.nvim_del_augroup_by_id(group)
	eq(#events, 1)
	eq(legacy, 1)
	eq(events[1].origin, "connections")
	eq(events[1].current.connection, nil)
	eq(events[1].current.password, nil)
	eq(events[1].current.password_command, nil)
	eq(events[1].current.connection_name, "staging")
end

T["persists scratchpad public context after successful mutations"] = function()
	local bufnr = vim.api.nvim_create_buf(false, true)
	local saved = {}
	local connection = assert(config.connection("local_db"))
	assert(context.attach(bufnr, {
		id = "scratchpad:monthly",
		scratchpad_id = "monthly",
		kind = "scratchpad",
		connection_name = "local_db",
		connection = connection,
		backend_name = "postgres",
		levels = { database = "postgres" },
		project_root = "/work/monthly",
		on_change = function(value) table.insert(saved, value) end,
	}))

	assert(context.set_level(bufnr, "schema", "reporting", "catalog"))
	assert(context.bind(bufnr, "staging", "connections"))

	eq(#saved, 2)
	eq(saved[1], {
		id = "scratchpad:monthly",
		kind = "scratchpad",
		bufnr = bufnr,
		scratchpad_id = "monthly",
		connection_name = "local_db",
		backend = "postgres",
		levels = { database = "postgres", schema = "reporting" },
		project_root = "/work/monthly",
		generation = 1,
		database = "postgres",
		schema = "reporting",
	})
	eq(saved[2].id, "scratchpad:monthly")
	eq(saved[2].connection_name, "staging")
	eq(saved[2].project_root, "/work/monthly")
	eq(saved[2].connection, nil)

	vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["refuses to forget a persistent scratchpad context"] = function()
	local bufnr = vim.api.nvim_create_buf(false, true)
	assert(context.attach(bufnr, {
		id = "scratchpad:monthly",
		scratchpad_id = "monthly",
		kind = "scratchpad",
		connection_name = "local_db",
		connection = assert(config.connection("local_db")),
	}))

	local current, err = context.forget(bufnr, "forget")
	eq(current, nil)
	expect_match(err, "persistent")

	vim.api.nvim_buf_delete(bufnr, { force = true })
end

return T
