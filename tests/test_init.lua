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

T["yanks to the unnamed register by default"] = function()
	eq(psql.yank_registers(""), { '"' })
end

T["also yanks to + when clipboard is unnamedplus"] = function()
	eq(psql.yank_registers("unnamedplus"), { '"', "+" })
end

T["also yanks to * when clipboard is unnamed"] = function()
	eq(psql.yank_registers("unnamed"), { '"', "*" })
end

T["honours both clipboard flags at once"] = function()
	eq(psql.yank_registers("unnamed,unnamedplus"), { '"', "*", "+" })
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

	export.run = function(sql, path, _, cb)
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

T["sends the preamble to psql but renders only the query"] = function()
	local resolve = require("psql.resolve")
	local original_preamble = resolve.preamble
	resolve.preamble = function(_, cb) cb("\\set raw_data 'public.events'\n") end

	local script
	exec.runner = function(argv, _, on_exit)
		-- exec.run writes the script to the file passed after -f.
		for index, argument in ipairs(argv) do
			if argument == "-f" then
				script = table.concat(vim.fn.readfile(argv[index + 1]), "\n")
			end
		end
		vim.schedule(function()
			on_exit({ code = 0, stdout = "one", stderr = "" })
		end)
		return { kill = function() end }
	end

	psql.query("SELECT * FROM :raw_data;")

	local buf
	vim.wait(1000, function()
		buf = results.find_buf()
		return buf ~= nil and vim.api.nvim_buf_get_lines(buf, 0, 1, true)[1] == "SELECT * FROM :raw_data;"
	end)
	resolve.preamble = original_preamble

	-- Lua patterns escape with %, not with a backslash, so this matches the
	-- single backslash the directive actually holds.
	expect_match(script, "\\set raw_data")
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, true)
	eq(lines, { "SELECT * FROM :raw_data;", "", "one" })
end

T["runs nothing when the variable prompt is cancelled"] = function()
	local resolve = require("psql.resolve")
	local original_preamble = resolve.preamble
	resolve.preamble = function(_, cb) cb(nil) end

	local ran = false
	exec.runner = function(_, _, _)
		ran = true
		return { kill = function() end }
	end

	psql.query("SELECT * FROM :raw_data;")
	vim.wait(200, function() return ran end)

	resolve.preamble = original_preamble
	eq(ran, false)
end

T["hands the preamble to the csv export"] = function()
	local resolve = require("psql.resolve")
	local export = require("psql.export")
	local original_preamble, original_run = resolve.preamble, export.run
	local original_input, original_notify = vim.ui.input, vim.notify

	resolve.preamble = function(_, cb) cb("\\set raw_data 'public.events'\n") end
	vim.ui.input = function(_, cb) cb("/tmp/psql-variables-test.csv") end
	vim.notify = function() end

	local seen
	export.run = function(_, path, preamble, cb)
		seen = preamble
		cb(path, nil)
	end

	-- A fresh buffer, so the export never mistakes a leftover __SQL__ for
	-- the current one and falls back to last_query.
	vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(true, true))
	vim.api.nvim_buf_set_lines(0, 0, -1, false, { "SELECT * FROM :raw_data;" })
	psql.export_csv({ range = 0 })

	vim.notify = original_notify
	vim.ui.input = original_input
	export.run = original_run
	resolve.preamble = original_preamble

	eq(seen, "\\set raw_data 'public.events'\n")
end

return T
