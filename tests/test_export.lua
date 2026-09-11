local helpers = dofile("tests/helpers.lua")
local eq, expect_match = helpers.eq, helpers.expect_match

local config = require("dbsh.config")
local context = require("dbsh.context")
local dbsh = require("dbsh")
local exec = require("dbsh.exec")
local export = require("dbsh.export")
local results = require("dbsh.results")

local original_runner
local tmpdir

-- Replaces the runner with one that immediately returns the given output.
local function stub_output(stdout, code)
	exec.runner = function(_, _, on_exit)
		vim.schedule(function()
			on_exit({ code = code or 0, stdout = stdout, stderr = code == 0 and "" or "boom" })
		end)
		return { kill = function() end }
	end
end

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			config.setup({
				connections = {
					local_db = { host = "localhost", port = 5432, database = "postgres", username = "dev" },
				},
				default = "local_db",
			})
			context.setup()
			original_runner = exec.runner
			tmpdir = vim.fn.tempname()
			vim.fn.mkdir(tmpdir, "p")
		end,
		post_case = function()
			exec.runner = original_runner
			exec.slots = {}
			for _, buf in ipairs(vim.api.nvim_list_bufs()) do
				local name = vim.api.nvim_buf_get_name(buf)
				if vim.api.nvim_buf_is_valid(buf) and vim.startswith(vim.fs.basename(name), "__DBSH__ ") then
					vim.api.nvim_buf_delete(buf, { force = true })
				end
			end
			vim.fn.delete(tmpdir, "rf")
		end,
	},
})

T["returns the path untouched when it is free"] = function()
	local path = vim.fs.joinpath(tmpdir, "20260828_local_db.csv")
	eq(export.free_path(path), path)
end

T["suffixes the path when the file already exists"] = function()
	local path = vim.fs.joinpath(tmpdir, "20260828_local_db.csv")
	vim.fn.writefile({ "x" }, path)
	eq(export.free_path(path), vim.fs.joinpath(tmpdir, "20260828_local_db_1.csv"))
end

T["keeps suffixing until a name is free"] = function()
	vim.fn.writefile({ "x" }, vim.fs.joinpath(tmpdir, "20260828_local_db.csv"))
	vim.fn.writefile({ "x" }, vim.fs.joinpath(tmpdir, "20260828_local_db_1.csv"))
	eq(
		export.free_path(vim.fs.joinpath(tmpdir, "20260828_local_db.csv")),
		vim.fs.joinpath(tmpdir, "20260828_local_db_2.csv")
	)
end

T["builds the default path from the date and the base name"] = function()
	eq(
		export.default_path(tmpdir, "local_db", "20260828"),
		vim.fs.joinpath(tmpdir, "20260828_local_db.csv")
	)
end

T["writes the psql output to the target file"] = function()
	stub_output("id,name\n1,alice\n")
	local path = vim.fs.joinpath(tmpdir, "out.csv")
	local got
	export.run("SELECT 1;", path, nil, function(p) got = p end)
	vim.wait(500, function() return got ~= nil end)
	eq(got, path)
	eq(vim.fn.readfile(path), { "id,name", "1,alice" })
end

T["surfaces the error when the CLI fails"] = function()
	stub_output("", 2)
	local err
	export.run("SELECT 1;", vim.fs.joinpath(tmpdir, "out.csv"), nil, function(_, e) err = e end)
	vim.wait(500, function() return err ~= nil end)
	expect_match(err, "boom")
end

T["sends the preamble before the copy statement"] = function()
	local seen
	exec.runner = function(argv, _, on_exit)
		-- exec.run writes the script to the file passed after -f.
		for index, argument in ipairs(argv) do
			if argument == "-f" then
				seen = table.concat(vim.fn.readfile(argv[index + 1]), "\n")
			end
		end
		vim.schedule(function()
			on_exit({ code = 0, stdout = "", stderr = "" })
		end)
		return { kill = function() end }
	end

	local got
	export.run(
		"SELECT * FROM :raw_data;",
		vim.fs.joinpath(tmpdir, "out.csv"),
		"\\set raw_data 'public.events'\n",
		function(p) got = p end
	)
	vim.wait(500, function() return got ~= nil end)

	local set_at = seen:find("\\set raw_data", 1, true)
	local copy_at = seen:find("COPY (", 1, true)
	eq(set_at ~= nil, true)
	eq(copy_at ~= nil, true)
	eq(set_at < copy_at, true)
end

T["works without a preamble"] = function()
	stub_output("id\n1\n")
	local path = vim.fs.joinpath(tmpdir, "plain.csv")
	local got
	export.run("SELECT 1;", path, nil, function(p) got = p end)
	vim.wait(500, function() return got ~= nil end)
	eq(vim.fn.readfile(path), { "id", "1" })
end

T["reports an unresolvable backend without running anything"] = function()
	config.setup({
		connections = { weird = { type = "oracle", host = "h", port = 1, database = "d", username = "u" } },
		default = "weird",
	})
	context.setup()
	local err
	export.run("SELECT 1;", vim.fs.joinpath(tmpdir, "out.csv"), nil, function(_, e) err = e end)
	vim.wait(500, function() return err ~= nil end)
	expect_match(err, "unknown connection type")
end

T["exports the query belonging to the displayed result session"] = function()
	dbsh.setup({
		connections = {
			local_db = { host = "localhost", port = 5432, database = "postgres", username = "dev" },
			staging = { host = "db.example.com", port = 5432, database = "app", username = "readonly" },
		},
		default = "local_db",
	})
	local a = vim.api.nvim_create_buf(false, true)
	local b = vim.api.nvim_create_buf(false, true)
	assert(context.bind(a, "local_db", "test"))
	assert(context.bind(b, "staging", "test"))
	local snapshot_b = context.snapshot(b)

	local callbacks = {}
	exec.runner = function(_, _, callback)
		table.insert(callbacks, callback)
		return { kill = function() end }
	end
	vim.api.nvim_set_current_buf(a)
	dbsh.query("SELECT 'a';")
	vim.api.nvim_set_current_buf(b)
	dbsh.query("SELECT 'b';")
	callbacks[1]({ code = 0, stdout = "a", stderr = "" })
	callbacks[2]({ code = 0, stdout = "b", stderr = "" })
	vim.wait(500, function() return results.find_buf(snapshot_b) ~= nil end)

	local original_run, original_input = export.run, vim.ui.input
	local captured
	export.run = function(sql, _, _, callback, snapshot)
		captured = { sql = sql, snapshot = snapshot }
		callback(vim.fs.joinpath(tmpdir, "out.csv"), nil)
	end
	vim.ui.input = function(_, callback) callback(vim.fs.joinpath(tmpdir, "out.csv")) end

	vim.api.nvim_set_current_buf(assert(results.find_buf(snapshot_b)))
	dbsh.export_csv({ range = 0 })

	vim.ui.input = original_input
	export.run = original_run
	eq(captured.sql, "SELECT 'b';")
	eq(captured.snapshot.id, snapshot_b.id)
end

return T
