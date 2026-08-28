local helpers = dofile("tests/helpers.lua")
local eq, expect_match = helpers.eq, helpers.expect_match

local config = require("psql.config")
local exec = require("psql.exec")
local export = require("psql.export")

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
			original_runner = exec.runner
			tmpdir = vim.fn.tempname()
			vim.fn.mkdir(tmpdir, "p")
		end,
		post_case = function()
			exec.runner = original_runner
			exec.slots = { user = nil, introspect = nil }
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

T["wraps the query in a COPY TO STDOUT statement"] = function()
	local query = export.copy_query("SELECT 1;", ",")
	expect_match(query, "COPY %(SELECT 1%) TO STDOUT")
	expect_match(query, "FORMAT CSV, HEADER, DELIMITER ','")
end

T["keeps a multi line query intact"] = function()
	expect_match(export.copy_query("SELECT a\nFROM t;", ","), "SELECT a\nFROM t")
end

T["honours the configured delimiter"] = function()
	expect_match(export.copy_query("SELECT 1;", ";"), "DELIMITER ';'")
end

T["writes the psql output to the target file"] = function()
	stub_output("id,name\n1,alice\n")
	local path = vim.fs.joinpath(tmpdir, "out.csv")
	local got
	export.run("SELECT 1;", path, function(p) got = p end)
	vim.wait(500, function() return got ~= nil end)
	eq(got, path)
	eq(vim.fn.readfile(path), { "id,name", "1,alice" })
end

T["surfaces the error when psql fails"] = function()
	stub_output("", 2)
	local err
	export.run("SELECT 1;", vim.fs.joinpath(tmpdir, "out.csv"), function(_, e) err = e end)
	vim.wait(500, function() return err ~= nil end)
	expect_match(err, "boom")
end

return T
