local helpers = dofile("tests/helpers.lua")
local eq, expect_match = helpers.eq, helpers.expect_match
local dbsh = require("dbsh")
local context = require("dbsh.context")
local results = require("dbsh.results")
local exec = require("dbsh.exec")
local csvview = require("dbsh.csvview")

local original_exec, original_viewer, original_notify, original_select
local requests, enabled, messages
local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			dbsh.setup({
				connections = {
					pg = { host = "localhost", port = 5432, database = "postgres", username = "dev" },
					snow = {
						type = "snowflake", host = "account.example.test", port = 443, username = "analyst",
						authenticator = "https://sso.example.test", role = "ANALYST", warehouse = "COMPUTE",
						database = "ANALYTICS", password_command = { "password-command" },
					},
					mongo = {
						type = "mongo", srv = true, host = "cluster.example.test", database = "analytics",
						username = "analyst", password_command = { "password-command" },
					},
				},
				default = "pg",
			})
			original_exec, original_viewer = exec.run, package.loaded.csvview
			original_notify, original_select = vim.notify, vim.ui.select
			requests, enabled, messages = {}, {}, {}
			package.loaded.csvview = {
				enable = function(buf, opts) table.insert(enabled, { buf = buf, opts = opts }) end,
			}
			exec.run = function(query, opts, callback)
				table.insert(requests, { query = query, opts = opts, callback = callback })
			end
			vim.notify = function(message) table.insert(messages, message) end
		end,
		post_case = function()
			exec.run, package.loaded.csvview = original_exec, original_viewer
			vim.notify, vim.ui.select = original_notify, original_select
			for _, buf in ipairs(vim.api.nvim_list_bufs()) do
				if vim.api.nvim_buf_is_valid(buf) then
					local name = vim.fs.basename(vim.api.nvim_buf_get_name(buf))
					if vim.startswith(name, "__DBSH") then vim.api.nvim_buf_delete(buf, { force = true }) end
				end
			end
		end,
	},
})

local function query_buffer(lines, connection)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_current_buf(buf)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	assert(context.bind(buf, connection or "pg"))
	return buf, context.snapshot(buf)
end

T["runs the current PostgreSQL paragraph as native CSV without copying the query"] = function()
	local source, snapshot = query_buffer({ "", "SELECT 1 AS id,", "'a,b' AS name;", "", "SELECT 2;" })
	vim.api.nvim_win_set_cursor(0, { 2, 0 })
	vim.cmd("DbCSVView")
	local csv_buf = vim.api.nvim_get_current_buf()
	eq(#requests, 1)
	eq(requests[1].query, "\\pset csv_fieldsep ','\nSELECT 1 AS id,\n'a,b' AS name;")
	eq(requests[1].opts.mode, "csv")
	eq(requests[1].opts.context.id, snapshot.id)
	eq(csvview.source(csv_buf).query, "SELECT 1 AS id,\n'a,b' AS name;")
	-- A delayed response must not take focus from a window entered meanwhile.
	vim.cmd("wincmd p")
	local before = vim.api.nvim_get_current_win()
	requests[1].callback(0, 'id,name\n1,"a,b"\n', "")
	eq(vim.api.nvim_get_current_win(), before)
	eq(vim.api.nvim_buf_get_lines(csv_buf, 0, -1, false), { "id,name", '1,"a,b"' })
	eq(vim.api.nvim_buf_get_lines(source, 0, -1, false)[2], "SELECT 1 AS id,")
	eq(vim.bo[csv_buf].filetype, "csv")
	eq(vim.bo[csv_buf].modifiable, false)
	eq(enabled[1].buf, csv_buf)
	eq(enabled[1].opts.parser, { delimiter = ",", quote_char = '"', comments = {}, comment_lines = 0 })
	eq(enabled[1].opts.view.header_lnum, 1)
	eq(results.find_buf(snapshot), nil)
end

T["uses the query displayed in a Snowflake result and its captured connection"] = function()
	local source, snapshot = query_buffer({ "SELECT id, name FROM users;" }, "snow")
	local result = results.render(snapshot, "SELECT id, name FROM users;", "old output", { split = "vertical" })
	vim.api.nvim_set_current_buf(result)
	vim.cmd("DbCSVView")
	eq(requests[1].query, "SELECT id, name FROM users;")
	eq(requests[1].opts.mode, "csv")
	eq(requests[1].opts.context.backend_name, "snowflake")
	requests[1].callback(0, 'ID,NAME\n1,"#hello"\n', "")
	eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "ID,NAME", '1,"#hello"' })
	eq(vim.api.nvim_buf_get_lines(result, 0, -1, false), { "SELECT id, name FROM users;", "", "old output" })
	eq(csvview.context_snapshot(0).bufnr, source)
end

T["converts Mongo EJSON documents into columns and keeps arrays in one cell"] = function()
	local _, snapshot = query_buffer({ 'db.getCollection("users").find({})' }, "mongo")
	local result = results.render(snapshot, 'db.getCollection("users").find({})', "pretty ObjectId output")
	vim.api.nvim_set_current_buf(result)
	vim.cmd("DbCSVView")
	eq(requests[1].opts.mode, "raw")
	eq(requests[1].query, 'db.getCollection("users").find({})')
	requests[1].callback(0, vim.json.encode({
		{ _id = { ["$oid"] = "abc" }, address = { city = "Paris" }, active = false, tags = { "one", "two" } },
		{ _id = { ["$oid"] = "def" }, address = { zip = "75001" }, active = vim.NIL },
	}), "")
	eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), {
		"_id,active,address.city,address.zip,tags",
		'abc,false,Paris,,"[""one"",""two""]"',
		"def,,,75001,",
	})
	eq(vim.api.nvim_buf_get_lines(result, 0, -1, false)[3], "pretty ObjectId output")
	eq(#enabled, 1)
end

T["supports a selected range without executing adjacent queries"] = function()
	query_buffer({ "SELECT 1;", "SELECT", "  2;", "SELECT 3;" })
	vim.cmd("2,3DbCSVView")
	eq(requests[1].query, "\\pset csv_fieldsep ','\nSELECT\n  2;")
end

T["opens a PostgreSQL result with a semicolon followed by comments without COPY syntax errors"] = function()
	local query = 'SELECT email, profile_id FROM "authentication"."app_users"; -- selected query\n/* notes */'
	local _, snapshot = query_buffer(vim.split(query, "\n", { plain = true }))
	local result = results.render(snapshot, query, "old result")
	vim.api.nvim_set_current_buf(result)
	vim.cmd("DbCSVView")
	eq(requests[1].query, "\\pset csv_fieldsep ','\n" .. query)
	eq(requests[1].opts.mode, "csv")
	requests[1].callback(0, "email,profile_id\nfixture@example.test,42\n", "")
	eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), {
		"email,profile_id", "fixture@example.test,42",
	})
	eq(#enabled, 1)
end

T["keeps safety confirmation when rerunning a query from the results"] = function()
	local _, snapshot = query_buffer({ "DELETE FROM users RETURNING id;" })
	local buf = results.render(snapshot, "DELETE FROM users RETURNING id;", "DELETE 1")
	vim.api.nvim_set_current_buf(buf)
	local prompt
	vim.ui.select = function(_, opts, callback)
		prompt = opts.prompt
		callback("Cancel")
	end
	vim.cmd("DbCSVView")
	expect_match(prompt, "mutation")
	eq(#requests, 0)
	eq(vim.api.nvim_get_current_buf(), buf)
end

T["refuses stale source contexts instead of leaving a view loading forever"] = function()
	local source, snapshot = query_buffer({ "SELECT 1;" })
	local buf = results.render(snapshot, "SELECT 1;", "one")
	assert(context.bind(source, "mongo"))
	vim.api.nvim_set_current_buf(buf)
	vim.cmd("DbCSVView")
	eq(#requests, 0)
	expect_match(messages[1], "source context changed")
end

T["reports failures without enabling CSVView on error text"] = function()
	query_buffer({ "SELECT 1;" })
	vim.cmd("DbCSVView")
	requests[1].callback(1, "", "query failed")
	eq(#enabled, 0)
	eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "query failed" })
	expect_match(messages[1], "query failed")
end

T["reports invalid or empty Mongo results rather than producing a misleading table"] = function()
	for _, output in ipairs({ "invalid EJSON", "[]" }) do
		query_buffer({ "db.users.find({})" }, "mongo")
		vim.cmd("DbCSVView")
		requests[#requests].callback(0, output, "")
	end
	eq(#enabled, 0)
	expect_match(messages[1], "could not be parsed")
	expect_match(messages[2], "no documents")
end

T["ignores output when the CSV window was closed before the query completed"] = function()
	query_buffer({ "SELECT 1;" })
	vim.cmd("DbCSVView")
	local buf = vim.api.nvim_get_current_buf()
	vim.cmd("close")
	eq(vim.api.nvim_buf_is_valid(buf), false)
	requests[1].callback(0, "id\n1\n", "")
	eq(#enabled, 0)
end

T["keeps the source context when reopening from CSV and blocks query-reading mappings"] = function()
	local _, snapshot = query_buffer({ "SELECT 42;" }, "snow")
	vim.cmd("DbCSVView")
	requests[1].callback(0, "VALUE\n42\n", "")
	dbsh.query_current_line()
	dbsh.query_paragraph()
	eq(#requests, 1)
	vim.cmd("DbCSVView")
	eq(#requests, 2)
	eq(requests[2].query, "SELECT 42;")
	eq(requests[2].opts.context.id, snapshot.id)
end

T["requires CSVView before executing or opening a buffer"] = function()
	query_buffer({ "SELECT 1;" })
	local source = vim.api.nvim_get_current_buf()
	local preload = package.preload.csvview
	package.loaded.csvview = nil
	package.preload.csvview = function() error("not installed") end
	local ok, err = pcall(vim.cmd, "DbCSVView")
	package.preload.csvview = preload
	assert(ok, err)
	eq(#requests, 0)
	eq(vim.api.nvim_get_current_buf(), source)
	expect_match(messages[1], "requires hat0uma/csvview")
end

return T
