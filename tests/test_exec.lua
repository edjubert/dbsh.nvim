local helpers = dofile("tests/helpers.lua")
local eq, expect_match = helpers.eq, helpers.expect_match

local config = require("psql.config")
local exec = require("psql.exec")

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
			original_runner = exec.runner
		end,
		post_case = function()
			exec.runner = original_runner
			exec.slots = { user = nil, introspect = nil }
		end,
	},
})

T["builds a pretty argv without password flags"] = function()
	local argv = exec.build_argv(config.current(), "/tmp/script.sql", false)
	eq(argv, {
		"psql", "-X", "-w",
		"-h", "localhost",
		"-p", "5432",
		"-U", "dev",
		"-d", "postgres",
		"-f", "/tmp/script.sql",
	})
end

T["adds unaligned tuple flags in raw mode"] = function()
	local argv = exec.build_argv(config.current(), "/tmp/script.sql", true)
	eq(argv, {
		"psql", "-X", "-w",
		"-h", "localhost",
		"-p", "5432",
		"-U", "dev",
		"-d", "postgres",
		"-A", "-t", "-F", "\t",
		"-f", "/tmp/script.sql",
	})
end

T["writes the display preamble before the query in pretty mode"] = function()
	local path = exec.write_script("SELECT 1;", false)
	local content = table.concat(vim.fn.readfile(path), "\n")
	os.remove(path)
	expect_match(content, "\\pset border 2")
	expect_match(content, "SELECT 1;")
end

T["writes no display preamble in raw mode"] = function()
	local path = exec.write_script("SELECT 1;", true)
	local content = table.concat(vim.fn.readfile(path), "\n")
	os.remove(path)
	eq(content:find("pset border", 1, true), nil)
	expect_match(content, "ON_ERROR_STOP")
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

T["delivers the result when the generation is unchanged"] = function()
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

T["drops the result when the connection changed meanwhile"] = function()
	local on_exit
	exec.runner = function(_, _, cb)
		on_exit = cb
		return { kill = function() end }
	end
	local called = false
	exec.run("SELECT 1;", {}, function() called = true end)
	config.set_connection("staging")
	on_exit({ code = 0, stdout = "ok", stderr = "" })
	vim.wait(100, function() return called end)
	eq(called, false)
end

T["reports an error when there is no current connection"] = function()
	config.setup({ connections = {} })
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

return T
