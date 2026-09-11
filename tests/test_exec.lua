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
			exec.slots = { user = nil, introspect = nil }
		end,
	},
})

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

T["drops only results whose originating buffer context changed"] = function()
	local exits = {}
	exec.runner = function(_, _, cb)
		table.insert(exits, cb)
		return { kill = function() end }
	end

	local a = vim.api.nvim_create_buf(false, true)
	local b = vim.api.nvim_create_buf(false, true)
	assert(context.bind(a, "local_db", "test"))
	assert(context.bind(b, "staging", "test"))

	local delivered_from_a = false
	exec.run("SELECT 1;", { context = context.snapshot(a) }, function()
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

T["cancels the previous query in the same slot only"] = function()
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
