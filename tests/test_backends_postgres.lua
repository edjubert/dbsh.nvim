local helpers = dofile("tests/helpers.lua")
local eq, expect_match = helpers.eq, helpers.expect_match

local backends = require("dbsh.backends")
local postgres = require("dbsh.backends.postgres")

local T = MiniTest.new_set()

local conn = { host = "localhost", port = 5432, database = "postgres", username = "dev" }

T["declares its identity, its shape and its rendering"] = function()
	eq(postgres.name, "postgres")
	eq(postgres.shape, "tabular")
	eq(postgres.filetype, "sql")
	eq(postgres.extension, "sql")
	eq(postgres.table_border, "│")
end

T["builds a pretty argv without password flags"] = function()
	eq(postgres.argv(conn, "/tmp/script.sql", "pretty"), {
		"psql", "-X", "-w",
		"-h", "localhost",
		"-p", "5432",
		"-U", "dev",
		"-d", "postgres",
		"-f", "/tmp/script.sql",
	})
end

T["adds unaligned tuple flags in raw mode"] = function()
	eq(postgres.argv(conn, "/tmp/script.sql", "raw"), {
		"psql", "-X", "-w",
		"-h", "localhost",
		"-p", "5432",
		"-U", "dev",
		"-d", "postgres",
		"-A", "-t", "-F", "\t",
		"-f", "/tmp/script.sql",
	})
end

T["decorates the output in pretty mode"] = function()
	expect_match(postgres.preamble("pretty"), "\\pset border 2")
	expect_match(postgres.preamble("pretty"), "\\timing on")
end

T["asks for no decoration in raw mode"] = function()
	local preamble = postgres.preamble("raw")
	eq(preamble:find("pset border", 1, true), nil)
	expect_match(preamble, "ON_ERROR_STOP")
end

T["passes PGCONNECT_TIMEOUT and never PGPASSWORD"] = function()
	local env = postgres.env(conn, { connect_timeout = 7 })
	eq(env.PGCONNECT_TIMEOUT, "7")
	eq(env.PGPASSWORD, nil)
end

T["names the language server it drives"] = function()
	eq(postgres.lsp.client_name, "postgres_lsp")
	eq(postgres.lsp.invalidate_command, "pgls.invalidateSchemaCache")
end

T["builds language server settings from the connection"] = function()
	eq(postgres.lsp.settings(conn, { connect_timeout = 9 }), {
		db = {
			host = "localhost",
			port = 5432,
			username = "dev",
			database = "postgres",
			connTimeoutSecs = 9,
		},
	})
end

T["never puts a password in the language server settings"] = function()
	local with_password = vim.tbl_extend("force", conn, { password = "hunter2" })
	local settings = postgres.lsp.settings(with_password, {})
	eq(settings.db.password, nil)
	eq(settings.db.connTimeoutSecs, 5)
end

T["parses tab separated rows and skips blank lines"] = function()
	eq(postgres.parse_raw("a\tb\tc\n\nd\te\tf\n"), { { "a", "b", "c" }, { "d", "e", "f" } })
end

T["returns an empty list for empty output"] = function()
	eq(postgres.parse_raw(""), {})
end

T["builds one set directive per variable, in order"] = function()
	eq(
		postgres.variable_preamble({ "a", "b" }, { a = "1", b = "2" }),
		"\\set a '1'\n\\set b '2'\n"
	)
end

T["builds an empty preamble when there is no variable"] = function()
	eq(postgres.variable_preamble({}, {}), "")
end

T["escapes a single quote in a variable value"] = function()
	eq(postgres.variable_preamble({ "a" }, { a = "it's" }), "\\set a 'it\\'s'\n")
end

T["escapes a backslash before the quotes"] = function()
	eq(postgres.variable_preamble({ "a" }, { a = "a\\b" }), "\\set a 'a\\\\b'\n")
end

T["wraps the query in a COPY TO STDOUT statement"] = function()
	local query = postgres.export_query("SELECT 1;", ",")
	expect_match(query, "COPY %(SELECT 1%) TO STDOUT")
	expect_match(query, "FORMAT CSV, HEADER, DELIMITER ','")
end

T["keeps a multi line query intact in the export"] = function()
	expect_match(postgres.export_query("SELECT a\nFROM t;", ","), "SELECT a\nFROM t")
end

T["honours the given delimiter in the export"] = function()
	expect_match(postgres.export_query("SELECT 1;", ";"), "DELIMITER ';'")
end

T["builds a quoted preview query with the given limit"] = function()
	eq(
		postgres.preview_query({ schema = "analytics", name = "events" }, 10),
		'SELECT * FROM "analytics"."events" LIMIT 10;'
	)
end

T["doubles inner quotes in identifiers"] = function()
	eq(
		postgres.preview_query({ schema = "public", name = 'we"ird' }, 3),
		'SELECT * FROM "public"."we""ird" LIMIT 3;'
	)
end

T["excludes system objects from the catalog queries"] = function()
	expect_match(postgres.queries.databases, "datistemplate")
	expect_match(postgres.queries.schemas, "information_schema")
	expect_match(postgres.queries.tables, "relkind")
end

T["resolves the postgres backend by name"] = function()
	eq(backends.get("postgres"), postgres)
end

T["defaults to postgres when no type is given"] = function()
	eq(backends.get(nil), postgres)
end

T["rejects an unknown backend"] = function()
	local backend, err = backends.get("oracle")
	eq(backend, nil)
	expect_match(err, "unknown connection type")
end

local original_runner

T["levels"] = MiniTest.new_set({
	hooks = {
		pre_case = function()
			require("dbsh.config").setup({
				connections = {
					local_db = { host = "localhost", port = 5432, database = "postgres", username = "dev" },
				},
				default = "local_db",
			})
			require("dbsh.context").setup()
			original_runner = require("dbsh.exec").runner
		end,
		post_case = function()
			local exec = require("dbsh.exec")
			exec.runner = original_runner
			exec.slots = { user = nil, introspect = nil }
		end,
	},
})

-- Replaces the runner with one that immediately returns the given output.
local function stub_output(stdout, code)
	require("dbsh.exec").runner = function(_, _, on_exit)
		vim.schedule(function()
			on_exit({ code = code or 0, stdout = stdout, stderr = code == 0 and "" or "boom" })
		end)
		return { kill = function() end }
	end
end

T["levels"]["declares database, schema and relation"] = function()
	eq(#postgres.levels, 3)
	eq(postgres.levels[1].key, "database")
	eq(postgres.levels[1].command, "Databases")
	eq(postgres.levels[1].on_select, "set_level")
	eq(postgres.levels[2].key, "schema")
	eq(postgres.levels[2].command, "Schemas")
	eq(postgres.levels[2].on_select, "descend")
	eq(postgres.levels[3].key, "relation")
	eq(postgres.levels[3].command, "Tables")
	eq(type(postgres.levels[3].on_select), "function")
end

T["levels"]["lists databases as plain entries"] = function()
	stub_output("postgres\nanalytics\n")
	local got
	postgres.levels[1].list({}, function(items) got = items end)
	vim.wait(500, function() return got ~= nil end)
	eq(got, {
		{ value = "postgres", display = "postgres", ordinal = "postgres" },
		{ value = "analytics", display = "analytics", ordinal = "analytics" },
	})
end

T["levels"]["lists schemas as plain entries"] = function()
	stub_output("public\nanalytics\n")
	local got
	postgres.levels[2].list({}, function(items) got = items end)
	vim.wait(500, function() return got ~= nil end)
	eq(#got, 2)
	eq(got[1].value, "public")
end

T["levels"]["lists relations with their schema, name and kind"] = function()
	stub_output("public\tusers\tr\nanalytics\tevents\tv\n")
	local got
	postgres.levels[3].list({}, function(items) got = items end)
	vim.wait(500, function() return got ~= nil end)
	eq(#got, 2)
	eq(got[1].value, { schema = "public", name = "users", kind = "r" })
	eq(got[1].ordinal, "public.users")
	expect_match(got[1].display, "table")
	expect_match(got[2].display, "view")
end

T["levels"]["filters relations by the schema in the context"] = function()
	stub_output("public\tusers\tr\nanalytics\tevents\tv\n")
	local got
	postgres.levels[3].list({ schema = "analytics" }, function(items) got = items end)
	vim.wait(500, function() return got ~= nil end)
	eq(#got, 1)
	eq(got[1].value.name, "events")
end

T["levels"]["surfaces the error when the CLI fails"] = function()
	stub_output("", 2)
	local err
	postgres.levels[1].list({}, function(_, e) err = e end)
	vim.wait(500, function() return err ~= nil end)
	expect_match(err, "boom")
end

T["levels"]["labels every supported relkind"] = function()
	eq(postgres.kind_label("r"), "table")
	eq(postgres.kind_label("v"), "view")
	eq(postgres.kind_label("m"), "matview")
	eq(postgres.kind_label("p"), "partitioned")
	eq(postgres.kind_label("x"), "x")
end

T["levels"]["previews the selected relation"] = function()
	local dbsh = require("dbsh")
	local original = dbsh.query
	local asked
	dbsh.query = function(sql) asked = sql end

	postgres.levels[3].on_select({ schema = "public", name = "users" }, {})

	dbsh.query = original
	eq(asked, 'SELECT * FROM "public"."users" LIMIT 10;')
end

return T
