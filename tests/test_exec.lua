local helpers = dofile("tests/helpers.lua")
local eq, expect_match = helpers.eq, helpers.expect_match

local config = require("dbsh.config")
local context = require("dbsh.context")
local exec = require("dbsh.exec")
local postgres = require("dbsh.backends.postgres")

local original_runner

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			config.setup({
				connections = {
					local_db = { host = "localhost", port = 5432, database = "postgres", username = "dev" },
					staging = { host = "db.example.com", port = 5432, database = "app", username = "readonly" },
				},
				default = "local_db",
			})
			context.setup()
			original_runner = exec.runner
		end,
		post_case = function()
			exec.runner = original_runner
			exec.slots = {}
		end,
	},
})

local function two_snapshots()
	local a = vim.api.nvim_create_buf(false, true)
	local b = vim.api.nvim_create_buf(false, true)
	assert(context.bind(a, "local_db", "test"))
	assert(context.bind(b, "staging", "test"))
	return a, b, context.snapshot(a), context.snapshot(b)
end

T["passes PGCONNECT_TIMEOUT and never PGPASSWORD"] = function()
	local captured_opts
	exec.runner = function(_, opts, _)
		captured_opts = opts
		return { kill = function() end }
	end

	exec.run("SELECT 1;", {}, function() end)

	eq(captured_opts.env.PGCONNECT_TIMEOUT, "5")
	eq(captured_opts.env.PGPASSWORD, nil)
end

T["delivers the result when the captured context is unchanged"] = function()
	local on_exit
	exec.runner = function(_, _, cb)
		on_exit = cb
		return { kill = function() end }
	end

	local got
	exec.run("SELECT 1;", {}, function(code, stdout)
		got = { code = code, stdout = stdout }
	end)
	on_exit({ code = 0, stdout = "ok", stderr = "" })

	vim.wait(200, function() return got ~= nil end)
	eq(got.code, 0)
	eq(got.stdout, "ok")
end

T["keeps cancellation and completion local to each context session"] = function()
	local callbacks, handles = {}, {}
	exec.runner = function(_, _, cb)
		local handle = {
			killed = false,
			kill = function(self) self.killed = true end,
		}
		table.insert(callbacks, cb)
		table.insert(handles, handle)
		return handle
	end

	local a, b, snapshot_a, snapshot_b = two_snapshots()
	local delivered = {}

	exec.run("SELECT 'a1';", { context = snapshot_a }, function()
		table.insert(delivered, "a1")
	end)
	exec.run("SELECT 'b';", { context = snapshot_b }, function()
		table.insert(delivered, "b")
	end)
	eq(handles[1].killed, false)
	eq(handles[2].killed, false)

	exec.run("SELECT 'a2';", { context = snapshot_a }, function()
		table.insert(delivered, "a2")
	end)
	eq(handles[1].killed, true)
	eq(handles[2].killed, false)
	eq(exec.slots[snapshot_a.id].user, handles[3])
	eq(exec.slots[snapshot_b.id].user, handles[2])

	callbacks[1]({ code = 0, stdout = "obsolete", stderr = "" })
	callbacks[2]({ code = 0, stdout = "b", stderr = "" })
	callbacks[3]({ code = 0, stdout = "a2", stderr = "" })
	vim.wait(200, function() return #delivered == 2 end)

	eq(delivered, { "b", "a2" })
	eq(exec.slots[snapshot_a.id], nil)
	eq(exec.slots[snapshot_b.id], nil)

	vim.api.nvim_buf_delete(a, { force = true })
	vim.api.nvim_buf_delete(b, { force = true })
end

T["cancels only the selected context session"] = function()
	local handles = {}
	exec.runner = function(_, _, _)
		local handle = {
			killed = false,
			kill = function(self) self.killed = true end,
		}
		table.insert(handles, handle)
		return handle
	end

	local a, b, snapshot_a, snapshot_b = two_snapshots()
	exec.run("SELECT 1;", { context = snapshot_a }, function() end)
	exec.run("SELECT 2;", { context = snapshot_b }, function() end)
	exec.cancel("user", snapshot_a)

	eq(handles[1].killed, true)
	eq(handles[2].killed, false)
	eq(exec.slots[snapshot_a.id], nil)
	eq(exec.slots[snapshot_b.id].user, handles[2])

	vim.api.nvim_buf_delete(a, { force = true })
	vim.api.nvim_buf_delete(b, { force = true })
end

T["drops only results whose originating buffer context changed"] = function()
	local exits = {}
	exec.runner = function(_, _, cb)
		table.insert(exits, cb)
		return { kill = function() end }
	end

	local a, b, snapshot_a = two_snapshots()
	local delivered_from_a = false
	exec.run("SELECT 1;", { context = snapshot_a }, function()
		delivered_from_a = true
	end)
	assert(context.set_level(b, "database", "other", "test"))
	exits[1]({ code = 0, stdout = "ok", stderr = "" })
	vim.wait(200, function() return delivered_from_a end)
	eq(delivered_from_a, true)

	local dropped_from_a = false
	exec.run("SELECT 1;", { context = context.snapshot(a) }, function()
		dropped_from_a = true
	end)
	assert(context.set_level(a, "database", "analytics", "test"))
	exits[2]({ code = 0, stdout = "ok", stderr = "" })
	vim.wait(100, function() return dropped_from_a end)
	eq(dropped_from_a, false)

	vim.api.nvim_buf_delete(a, { force = true })
	vim.api.nvim_buf_delete(b, { force = true })
end

T["reports an error when there is no effective connection"] = function()
	config.setup({ connections = {} })
	context.setup()

	local code, stderr
	exec.run("SELECT 1;", {}, function(c, _, e)
		code, stderr = c, e
	end)

	eq(code, 1)
	expect_match(stderr, "no current connection")
end

T["keeps user and introspection slots separate in one session"] = function()
	local killed = {}
	exec.runner = function(argv, _, _)
		local id = argv[#argv]
		return { kill = function() table.insert(killed, id) end }
	end

	exec.run("SELECT 1;", { slot = "user" }, function() end)
	exec.run("SELECT 2;", { slot = "introspect" }, function() end)
	eq(#killed, 0)
	exec.run("SELECT 3;", { slot = "user" }, function() end)
	eq(#killed, 1)
end

T["runs definition argv without writing a temporary SQL script"] = function()
	local original_write_script = exec.write_script
	exec.write_script = function()
		error("run_argv must not create a SQL script")
	end
	local captured
	exec.runner = function(argv, opts, callback)
		captured = { argv = argv, opts = opts }
		vim.schedule(function()
			callback({ code = 0, stdout = "DDL", stderr = "" })
		end)
		return { kill = function() end }
	end

	local got
	exec.run_argv(context.snapshot(0), {
		argv = { "pg_dump", "--schema-only" },
		env = { PGCONNECT_TIMEOUT = "9" },
	}, function(code, stdout)
		got = { code = code, stdout = stdout }
	end)
	vim.wait(500, function() return got ~= nil end)

	exec.write_script = original_write_script
	eq(captured.argv, { "pg_dump", "--schema-only" })
	eq(captured.opts.env, { PGCONNECT_TIMEOUT = "9" })
	eq(got, { code = 0, stdout = "DDL" })
end

T["keeps definition argv in an independent session slot"] = function()
	local handles = {}
	exec.runner = function(_, _, _)
		local handle = {
			killed = false,
			kill = function(self) self.killed = true end,
		}
		table.insert(handles, handle)
		return handle
	end

	local snapshot = context.snapshot(0)
	exec.run("SELECT 1;", { context = snapshot }, function() end)
	exec.run_argv(snapshot, { argv = { "pg_dump" }, env = {} }, function() end)
	eq(handles[1].killed, false)
	eq(handles[2].killed, false)
	eq(exec.slots[snapshot.id].user, handles[1])
	eq(exec.slots[snapshot.id].definition, handles[2])
end

T["drops a stale definition argv callback"] = function()
	local on_exit
	exec.runner = function(_, _, callback)
		on_exit = callback
		return { kill = function() end }
	end
	local snapshot = context.snapshot(0)
	local delivered = false

	exec.run_argv(snapshot, { argv = { "pg_dump" }, env = {} }, function()
		delivered = true
	end)
	assert(context.bind(snapshot.bufnr, "staging", "test"))
	on_exit({ code = 0, stdout = "old", stderr = "" })
	vim.wait(100, function() return delivered end)

	eq(delivered, false)
end

T["writes the backend preamble before the query"] = function()
	local path = exec.write_script(postgres, "SELECT 1;", "pretty")
	local content = table.concat(vim.fn.readfile(path), "\n")
	os.remove(path)
	expect_match(content, "\\pset border 2")
	expect_match(content, "SELECT 1;")
end

T["asks the backend for the raw preamble in raw mode"] = function()
	local path = exec.write_script(postgres, "SELECT 1;", "raw")
	local content = table.concat(vim.fn.readfile(path), "\n")
	os.remove(path)
	eq(content:find("pset border", 1, true), nil)
	expect_match(content, "ON_ERROR_STOP")
end

T["asks the backend for the argv"] = function()
	local captured
	exec.runner = function(argv, _, _)
		captured = argv
		return { kill = function() end }
	end
	exec.run("SELECT 1;", {}, function() end)
	eq(captured[1], "psql")
	eq(vim.tbl_contains(captured, "-A"), false)
end

T["passes the raw mode down to the backend argv"] = function()
	local captured
	exec.runner = function(argv, _, _)
		captured = argv
		return { kill = function() end }
	end
	exec.run("SELECT 1;", { mode = "raw" }, function() end)
	eq(vim.tbl_contains(captured, "-A"), true)
end

T["reports an error when the context connection type has no backend"] = function()
	config.setup({
		connections = { weird = { type = "oracle", host = "h", port = 1, database = "d", username = "u" } },
		default = "weird",
	})
	context.setup()

	local code, stderr
	exec.run("SELECT 1;", {}, function(c, _, e)
		code, stderr = c, e
	end)

	eq(code, 1)
	expect_match(stderr, "unknown connection type")
end

return T
