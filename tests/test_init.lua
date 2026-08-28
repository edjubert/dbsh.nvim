local helpers = dofile("tests/helpers.lua")
local eq, expect_match = helpers.eq, helpers.expect_match

local psql = require("psql")
local exec = require("psql.exec")
local results = require("psql.results")

local original_runner

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			psql.setup({
				connections = {
					local_db = { host = "localhost", port = 5432, database = "postgres", username = "dev" },
				},
				default = "local_db",
			})
			original_runner = exec.runner
		end,
		post_case = function()
			exec.runner = original_runner
			exec.slots = { user = nil, introspect = nil }
			local buf = results.find_buf()
			if buf ~= nil then
				vim.api.nvim_buf_delete(buf, { force = true })
			end
		end,
	},
})

T["finds the paragraph around the cursor line"] = function()
	local lines = { "one", "", "SELECT 1", "FROM t;", "", "three" }
	local start, stop = psql.paragraph_range(lines, 3)
	eq(start, 3)
	eq(stop, 4)
end

T["treats a single line surrounded by blanks as its own paragraph"] = function()
	local lines = { "", "SELECT 1;", "" }
	local start, stop = psql.paragraph_range(lines, 2)
	eq(start, 2)
	eq(stop, 2)
end

T["handles a paragraph running to the end of the buffer"] = function()
	local lines = { "", "SELECT 1", "FROM t;" }
	local start, stop = psql.paragraph_range(lines, 2)
	eq(start, 2)
	eq(stop, 3)
end

T["declares every user command"] = function()
	for _, name in ipairs({
		"PSQLConnections", "PSQLDatabases", "PSQLSchemas",
		"PSQLTables", "PSQLTemp", "PSQLCancel", "PSQLInfo",
	}) do
		eq(vim.fn.exists(":" .. name), 2)
	end
end

T["refuses an empty query"] = function()
	local notified
	local original_notify = vim.notify
	vim.notify = function(msg) notified = msg end
	psql.query("   ")
	vim.notify = original_notify
	expect_match(notified, "empty")
end

T["renders successful output in the result buffer"] = function()
	exec.runner = function(_, _, on_exit)
		vim.schedule(function()
			on_exit({ code = 0, stdout = "one\ntwo", stderr = "" })
		end)
		return { kill = function() end }
	end

	psql.query("SELECT 1;")

	local buf
	vim.wait(1000, function()
		buf = results.find_buf()
		if buf == nil then
			return false
		end
		return vim.api.nvim_buf_get_lines(buf, 0, 1, true)[1] == "SELECT 1;"
	end)

	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, true)
	eq(lines, { "SELECT 1;", "", "one", "two" })
end

T["renders stderr when psql fails"] = function()
	exec.runner = function(_, _, on_exit)
		vim.schedule(function()
			on_exit({ code = 2, stdout = "", stderr = "connection refused" })
		end)
		return { kill = function() end }
	end

	psql.query("SELECT 1;")

	local buf
	vim.wait(1000, function()
		buf = results.find_buf()
		if buf == nil then
			return false
		end
		local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, true)
		return vim.tbl_contains(lines, "connection refused")
	end)

	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, true)
	eq(vim.tbl_contains(lines, "connection refused"), true)
end

return T
