local helpers = dofile("tests/helpers.lua")
local eq, expect_match = helpers.eq, helpers.expect_match

local psql = require("psql")
local exec = require("psql.exec")
local results = require("psql.results")
local csv = require("psql.csv")

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

T["remembers the last executed query"] = function()
	exec.runner = function(_, _, on_exit)
		vim.schedule(function()
			on_exit({ code = 0, stdout = "one", stderr = "" })
		end)
		return { kill = function() end }
	end

	psql.query("SELECT 42;")
	vim.wait(1000, function() return psql.last_query() ~= nil end)
	eq(psql.last_query(), "SELECT 42;")
end

T["does not remember an empty query"] = function()
	local before = psql.last_query()
	local original_notify = vim.notify
	vim.notify = function() end
	psql.query("   ")
	vim.notify = original_notify
	eq(psql.last_query(), before)
end

T["refuses to yank csv outside a supported visual mode"] = function()
	local notified
	local original_notify = vim.notify
	vim.notify = function(msg) notified = msg end
	psql.yank_csv()
	vim.notify = original_notify
	expect_match(notified, "V")
end

T["serializes a rendered table into the default register"] = function()
	-- The rendering psql produces with linestyle unicode and border 2.
	local lines = {
		"┌────┬───────┐",
		"│ id │ name  │",
		"├────┼───────┤",
		"│  1 │ alice │",
		"└────┴───────┘",
	}
	local rows = csv.rows_from_lines(lines, csv.LINEWISE)
	eq(csv.to_csv(rows, ","), "id,name\n1,alice")
end

T["declares the export command"] = function()
	eq(vim.fn.exists(":PSQLExportCSV"), 2)
end

T["accepts a range on the export command"] = function()
	-- Typing : in visual mode prefills '<,'>, which raises E481 on a
	-- command declared without a range.
	eq(vim.api.nvim_get_commands({})["PSQLExportCSV"].range, ".")
end

T["exports the given range rather than the paragraph"] = function()
	local export = require("psql.export")
	local original_run, original_input = export.run, vim.ui.input
	local captured

	export.run = function(sql, path, cb)
		captured = sql
		cb(path, nil)
	end
	vim.ui.input = function(_, cb) cb("/tmp/psql-range-test.csv") end
	local original_notify = vim.notify
	vim.notify = function() end

	-- One paragraph, no blank line: without a range the whole block is taken.
	vim.api.nvim_buf_set_lines(0, 0, -1, false, {
		"TRUNCATE t;",
		"SELECT a",
		"FROM t;",
	})
	psql.export_csv({ range = 2, line1 = 2, line2 = 3 })

	vim.notify = original_notify
	vim.ui.input = original_input
	export.run = original_run

	eq(captured, "SELECT a\nFROM t;")
end

return T
