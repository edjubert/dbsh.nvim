local helpers = dofile("tests/helpers.lua")
local eq, expect_match = helpers.eq, helpers.expect_match

local dbsh = require("dbsh")
local context = require("dbsh.context")
local exec = require("dbsh.exec")
local results = require("dbsh.results")
local csv = require("dbsh.csv")

local original_runner

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			dbsh.setup({
				connections = {
					local_db = { host = "localhost", port = 5432, database = "postgres", username = "dev" },
				},
				default = "local_db",
			})
			original_runner = exec.runner
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
		end,
	},
})

T["finds the paragraph around the cursor line"] = function()
	local lines = { "one", "", "SELECT 1", "FROM t;", "", "three" }
	local start, stop = dbsh.paragraph_range(lines, 3)
	eq(start, 3)
	eq(stop, 4)
end

T["treats a single line surrounded by blanks as its own paragraph"] = function()
	local lines = { "", "SELECT 1;", "" }
	local start, stop = dbsh.paragraph_range(lines, 2)
	eq(start, 2)
	eq(stop, 2)
end

T["handles a paragraph running to the end of the buffer"] = function()
	local lines = { "", "SELECT 1", "FROM t;" }
	local start, stop = dbsh.paragraph_range(lines, 2)
	eq(start, 2)
	eq(stop, 3)
end

T["declares every backend-agnostic command"] = function()
	for _, name in ipairs({
		"DbConnections", "DbTemp", "DbCancel", "DbToggleResults", "DbInfo",
		"DbObjects", "DbGlobalConnection", "DbForgetConnection",
		"DbDefinitions", "DbToggleDefinition", "DbRefreshDefinition", "DbCloseDefinitions",
	}) do
		eq(vim.fn.exists(":" .. name), 2)
	end
end

T["delegates definition commands to their picker and registry"] = function()
	local pickers = require("dbsh.telescope.pickers")
	local definitions = require("dbsh.definitions")
	local original_picker = pickers.definitions
	local original_toggle, original_refresh, original_close =
		definitions.toggle, definitions.refresh, definitions.close
	local calls = {}
	pickers.definitions = function() table.insert(calls, "picker") end
	definitions.toggle = function()
		table.insert(calls, "toggle")
		return true
	end
	definitions.refresh = function()
		table.insert(calls, "refresh")
		return true
	end
	definitions.close = function()
		table.insert(calls, "close")
	end

	vim.cmd("DbDefinitions")
	vim.cmd("DbToggleDefinition")
	vim.cmd("DbRefreshDefinition")
	vim.cmd("DbCloseDefinitions")

	definitions.close = original_close
	definitions.refresh = original_refresh
	definitions.toggle = original_toggle
	pickers.definitions = original_picker
	eq(calls, { "picker", "toggle", "refresh", "close" })
end

T["opens the scratchpad catalog from DbTemp"] = function()
	local pickers = require("dbsh.telescope.pickers")
	local original = pickers.scratchpads
	local calls = 0
	pickers.scratchpads = function() calls = calls + 1 end

	vim.cmd("DbTemp")

	pickers.scratchpads = original
	eq(calls, 1)
end

T["declares context and catalog commands from the backend union"] = function()
	for _, name in ipairs({ "DbDatabases", "DbSchemas", "DbRelations", "DbTables" }) do
		eq(vim.fn.exists(":" .. name), 2)
	end
end

T["keeps catalog commands declared and dispatches by active backend"] = function()
	local backends = require("dbsh.backends")
	local previous = backends.registry.fake
	backends.registry.fake = {
		name = "fake",
		contexts = {},
		catalogs = {},
	}
	dbsh.setup({
		connections = {
			local_db = { host = "localhost", port = 5432, database = "postgres", username = "dev" },
			weird = { type = "fake", host = "h", port = 1, database = "d", username = "u" },
		},
		default = "local_db",
	})
	local a = vim.api.nvim_create_buf(false, true)
	local b = vim.api.nvim_create_buf(false, true)
	assert(context.bind(a, "local_db", "test"))
	assert(context.bind(b, "weird", "test"))
	local pickers = require("dbsh.telescope.pickers")
	local original_catalog, original_notify = pickers.catalog, vim.notify
	local called, notified
	pickers.catalog = function(key) called = key end
	vim.notify = function(message) notified = message end

	vim.api.nvim_set_current_buf(a)
	vim.cmd("DbRelations")
	vim.api.nvim_set_current_buf(b)
	vim.cmd("DbRelations")

	vim.notify = original_notify
	pickers.catalog = original_catalog
	backends.registry.fake = previous
	eq(vim.fn.exists(":DbTables"), 2)
	eq(called, "relations")
	expect_match(notified, "not available")

	vim.api.nvim_buf_delete(a, { force = true })
	vim.api.nvim_buf_delete(b, { force = true })
end

T["refuses an empty query"] = function()
	local notified
	local original_notify = vim.notify
	vim.notify = function(msg) notified = msg end
	dbsh.query("   ")
	vim.notify = original_notify
	expect_match(notified, "empty")
end

T["confirms a mutating query before it resolves and runs"] = function()
	local original_select = vim.ui.select
	local captured
	local ran = false
	vim.ui.select = function(items, opts, callback)
		captured = { items = items, opts = opts }
		callback("Run")
	end
	exec.runner = function(_, _, callback)
		ran = true
		vim.schedule(function()
			callback({ code = 0, stdout = "DELETE 1", stderr = "" })
		end)
		return { kill = function() end }
	end

	dbsh.query("DELETE FROM users;")
	vim.wait(500, function() return ran end)

	vim.ui.select = original_select
	eq(captured.items, { "Run", "Cancel" })
	expect_match(captured.opts.prompt, "mutation")
	eq(ran, true)
end

T["does not resolve variables or run after confirmation is cancelled"] = function()
	local resolve = require("dbsh.resolve")
	local original_preamble, original_select = resolve.preamble, vim.ui.select
	local preambles, ran = 0, false
	resolve.preamble = function()
		preambles = preambles + 1
	end
	vim.ui.select = function(_, _, callback) callback("Cancel") end
	exec.runner = function()
		ran = true
		return { kill = function() end }
	end

	dbsh.query("DELETE FROM :raw_data;")
	vim.wait(100, function() return ran end)

	vim.ui.select = original_select
	resolve.preamble = original_preamble
	eq(preambles, 0)
	eq(ran, false)
end

T["runs directly when safety is off"] = function()
	dbsh.setup({
		connections = {
			local_db = { host = "localhost", port = 5432, database = "postgres", username = "dev" },
		},
		default = "local_db",
		safety = { mode = "off" },
	})
	local original_select = vim.ui.select
	local ran = false
	vim.ui.select = function()
		error("safety off must not prompt")
	end
	exec.runner = function(_, _, callback)
		ran = true
		vim.schedule(function()
			callback({ code = 0, stdout = "DELETE 1", stderr = "" })
		end)
		return { kill = function() end }
	end

	dbsh.query("DELETE FROM users;")
	vim.wait(500, function() return ran end)

	vim.ui.select = original_select
	eq(ran, true)
end

T["renders successful output in the result buffer"] = function()
	local snapshot = context.snapshot(0)
	exec.runner = function(_, _, on_exit)
		vim.schedule(function()
			on_exit({ code = 0, stdout = "one\ntwo", stderr = "" })
		end)
		return { kill = function() end }
	end

	dbsh.query("SELECT 1;")

	local buf
	vim.wait(1000, function()
		buf = results.find_buf(snapshot)
		if buf == nil then
			return false
		end
		return vim.api.nvim_buf_get_lines(buf, 0, 1, true)[1] == "SELECT 1;"
	end)

	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, true)
	eq(lines, { "SELECT 1;", "", "one", "two" })
end

T["renders stderr when psql fails"] = function()
	local snapshot = context.snapshot(0)
	exec.runner = function(_, _, on_exit)
		vim.schedule(function()
			on_exit({ code = 2, stdout = "", stderr = "connection refused" })
		end)
		return { kill = function() end }
	end

	dbsh.query("SELECT 1;")

	local buf
	vim.wait(1000, function()
		buf = results.find_buf(snapshot)
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

	dbsh.query("SELECT 42;")
	vim.wait(1000, function() return dbsh.last_query() ~= nil end)
	eq(dbsh.last_query(), "SELECT 42;")
end

T["does not remember an empty query"] = function()
	local before = dbsh.last_query()
	local original_notify = vim.notify
	vim.notify = function() end
	dbsh.query("   ")
	vim.notify = original_notify
	eq(dbsh.last_query(), before)
end

T["refuses to yank csv outside a supported visual mode"] = function()
	local notified
	local original_notify = vim.notify
	vim.notify = function(msg) notified = msg end
	dbsh.yank_csv()
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
	eq(vim.fn.exists(":DbExportCSV"), 2)
end

T["yanks to the unnamed register by default"] = function()
	eq(dbsh.yank_registers(""), { '"' })
end

T["also yanks to + when clipboard is unnamedplus"] = function()
	eq(dbsh.yank_registers("unnamedplus"), { '"', "+" })
end

T["also yanks to * when clipboard is unnamed"] = function()
	eq(dbsh.yank_registers("unnamed"), { '"', "*" })
end

T["honours both clipboard flags at once"] = function()
	eq(dbsh.yank_registers("unnamed,unnamedplus"), { '"', "*", "+" })
end

T["accepts a range on the export command"] = function()
	-- Typing : in visual mode prefills '<,'>, which raises E481 on a
	-- command declared without a range.
	eq(vim.api.nvim_get_commands({})["DbExportCSV"].range, ".")
end

T["exports the given range rather than the paragraph"] = function()
	local export = require("dbsh.export")
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
	dbsh.export_csv({ range = 2, line1 = 2, line2 = 3 })

	vim.notify = original_notify
	vim.ui.input = original_input
	export.run = original_run

	eq(captured, "SELECT a\nFROM t;")
end

T["sends the preamble to psql but renders only the query"] = function()
	local snapshot = context.snapshot(0)
	local resolve = require("dbsh.resolve")
	local original_preamble = resolve.preamble
	resolve.preamble = function(_, _, cb) cb("\\set raw_data 'public.events'\n") end

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

	dbsh.query("SELECT * FROM :raw_data;")

	local buf
	vim.wait(1000, function()
		buf = results.find_buf(snapshot)
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
	local resolve = require("dbsh.resolve")
	local original_preamble = resolve.preamble
	resolve.preamble = function(_, _, cb) cb(nil) end

	local ran = false
	exec.runner = function(_, _, _)
		ran = true
		return { kill = function() end }
	end

	dbsh.query("SELECT * FROM :raw_data;")
	vim.wait(200, function() return ran end)

	resolve.preamble = original_preamble
	eq(ran, false)
end

T["hands the preamble to the csv export"] = function()
	local resolve = require("dbsh.resolve")
	local export = require("dbsh.export")
	local original_preamble, original_run = resolve.preamble, export.run
	local original_input, original_notify = vim.ui.input, vim.notify

	resolve.preamble = function(_, _, cb) cb("\\set raw_data 'public.events'\n") end
	vim.ui.input = function(_, cb) cb("/tmp/psql-variables-test.csv") end
	vim.notify = function() end

	local seen
	export.run = function(_, path, preamble, cb)
		seen = preamble
		cb(path, nil)
	end

	-- A fresh buffer, so the export never mistakes a leftover __DBSH__ for
	-- the current one and falls back to last_query.
	vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(true, true))
	vim.api.nvim_buf_set_lines(0, 0, -1, false, { "SELECT * FROM :raw_data;" })
	dbsh.export_csv({ range = 0 })

	vim.notify = original_notify
	vim.ui.input = original_input
	export.run = original_run
	resolve.preamble = original_preamble

	eq(seen, "\\set raw_data 'public.events'\n")
end

T["refreshes the schema cache after a successful query"] = function()
	local lsp = require("dbsh.lsp")
	local original = lsp.invalidate_external
	local snapshot
	lsp.invalidate_external = function(value)
		snapshot = value
	end

	exec.runner = function(_, _, on_exit)
		vim.schedule(function()
			on_exit({ code = 0, stdout = "one", stderr = "" })
		end)
		return { kill = function() end }
	end

	dbsh.query("SELECT 1;")
	vim.wait(1000, function()
		return snapshot ~= nil
	end)

	lsp.invalidate_external = original
	eq(snapshot.id, context.snapshot(0).id)
end

T["does not refresh the schema cache when the query fails"] = function()
	dbsh.setup({
		connections = {
			local_db = { host = "localhost", port = 5432, database = "postgres", username = "dev" },
		},
		default = "local_db",
		safety = { mode = "off" },
	})
	local lsp = require("dbsh.lsp")
	local original = lsp.invalidate_external
	local calls = 0
	lsp.invalidate_external = function()
		calls = calls + 1
	end

	exec.runner = function(_, _, on_exit)
		vim.schedule(function()
			on_exit({ code = 2, stdout = "", stderr = "syntax error" })
		end)
		return { kill = function() end }
	end

	dbsh.query("SELEC 1;")
	vim.wait(200, function()
		return calls > 0
	end)

	lsp.invalidate_external = original
	eq(calls, 0)
end

T["keeps queries, results, and last-query state independent by context"] = function()
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
	local snapshot_a, snapshot_b = context.snapshot(a), context.snapshot(b)

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

	vim.wait(500, function()
		local a_buf = results.find_buf(snapshot_a)
		local b_buf = results.find_buf(snapshot_b)
		return a_buf ~= nil
			and b_buf ~= nil
			and vim.api.nvim_buf_get_lines(a_buf, 0, 1, true)[1] == "SELECT 'a';"
			and vim.api.nvim_buf_get_lines(b_buf, 0, 1, true)[1] == "SELECT 'b';"
	end)
	eq(vim.api.nvim_buf_get_lines(results.find_buf(snapshot_a), 0, -1, true), {
		"SELECT 'a';", "", "a",
	})
	eq(vim.api.nvim_buf_get_lines(results.find_buf(snapshot_b), 0, -1, true), {
		"SELECT 'b';", "", "b",
	})
	eq(dbsh.last_query(a), "SELECT 'a';")
	eq(dbsh.last_query(b), "SELECT 'b';")
end

T["DbToggleResults and DbCancel affect only the active context"] = function()
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
	local snapshot_a, snapshot_b = context.snapshot(a), context.snapshot(b)

	local handles = {}
	exec.runner = function(_, _, _)
		local handle = {
			killed = false,
			kill = function(self) self.killed = true end,
		}
		table.insert(handles, handle)
		return handle
	end
	exec.run("SELECT 1;", { context = snapshot_a }, function() end)
	exec.run("SELECT 2;", { context = snapshot_b }, function() end)

	results.render(snapshot_a, "SELECT 1;", "a")
	results.render(snapshot_b, "SELECT 2;", "b")
	results.close(snapshot_a)
	vim.api.nvim_set_current_buf(a)
	vim.cmd("DbToggleResults")
	vim.cmd("DbCancel")

	eq(results.find_win(results.find_buf(snapshot_a)) ~= nil, true)
	eq(results.find_win(results.find_buf(snapshot_b)) ~= nil, true)
	eq(handles[1].killed, true)
	eq(handles[2].killed, false)
end

return T
