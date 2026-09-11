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

T["enumerates registered backends in deterministic name order"] = function()
	local original = backends.registry.test_catalog
	backends.registry.test_catalog = { name = "test_catalog", contexts = {}, catalogs = {} }

	local names = vim.tbl_map(function(backend) return backend.name end, backends.all())

	backends.registry.test_catalog = original
	eq(names, { "postgres", "test_catalog" })
end

local original_runner

T["contracts"] = MiniTest.new_set({
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
			exec.slots = {}
		end,
	},
})

-- Replaces the runner with one that immediately returns the given output.
local function stub_output(stdout, code, on_run)
	require("dbsh.exec").runner = function(argv, _, on_exit)
		if on_run ~= nil then
			local script = assert(io.open(argv[#argv], "r"))
			on_run(script:read("*a"))
			script:close()
		end
		vim.schedule(function()
			on_exit({ code = code or 0, stdout = stdout, stderr = code == 0 and "" or "boom" })
		end)
		return { kill = function() end }
	end
end

T["contracts"]["declares explicit context selectors and object catalogs"] = function()
	eq(#postgres.contexts, 2)
	eq(postgres.contexts[1].key, "database")
	eq(postgres.contexts[1].command, "Databases")
	eq(type(postgres.contexts[1].apply), "function")
	eq(postgres.contexts[2].key, "schema")
	eq(postgres.contexts[2].command, "Schemas")
	eq(vim.tbl_map(function(definition) return definition.key end, postgres.catalogs), {
		"relations",
		"tables",
		"columns",
		"indexes",
		"constraints",
		"sequences",
		"routines",
		"types",
		"policies",
		"triggers",
		"extensions",
	})
	eq(vim.tbl_map(function(definition) return definition.command end, postgres.catalogs), {
		"Relations",
		"Tables",
		"Columns",
		"Indexes",
		"Constraints",
		"Sequences",
		"Functions",
		"Types",
		"Policies",
		"Triggers",
		"Extensions",
	})
end

T["contracts"]["lists databases as paged context choices"] = function()
	stub_output("postgres\nanalytics\n")
	local got
	postgres.contexts[1].list({}, function(page) got = page end)
	vim.wait(500, function() return got ~= nil end)
	eq(got, {
		items = {
			{ value = "postgres", display = "postgres", ordinal = "postgres" },
			{ value = "analytics", display = "analytics", ordinal = "analytics" },
		},
		next_cursor = nil,
	})
end

T["contracts"]["lists schemas as paged context choices"] = function()
	stub_output("public\nanalytics\n")
	local got
	postgres.contexts[2].list({}, function(page) got = page end)
	vim.wait(500, function() return got ~= nil end)
	eq(#got.items, 2)
	eq(got.items[1].value, "public")
end

T["contracts"]["lists relations with their schema, name and kind"] = function()
	stub_output("public\tusers\tr\t100\nanalytics\tevents\tv\t101\n")
	local got
	postgres.catalogs[1].list({ scope = {}, limit = 2 }, function(page) got = page end)
	vim.wait(500, function() return got ~= nil end)
	eq(#got.items, 2)
	eq(got.items[1].value, {
		kind = "relation",
		oid = "100",
		schema = "public",
		name = "users",
		relkind = "r",
	})
	eq(got.items[1].display, "public.users  [table]")
	eq(got.items[2].value.relkind, "v")
end

T["contracts"]["filters relations by the requested scope on the server"] = function()
	local sql
	stub_output("analytics\tevents\tv\t101\n", nil, function(value) sql = value end)
	local got
	postgres.catalogs[1].list({ scope = { schema = "analytics", all_schemas = false }, limit = 2 }, function(page) got = page end)
	vim.wait(500, function() return got ~= nil end)
	eq(#got.items, 1)
	eq(got.items[1].value.name, "events")
	assert(sql:find("n.nspname = E'analytics'", 1, true) ~= nil)
end

T["contracts"]["does not add a schema predicate for an all-schema relation listing"] = function()
	local sql
	stub_output("", nil, function(value) sql = value end)
	local done = false
	postgres.catalogs[1].list({ scope = { schema = "analytics", all_schemas = true }, limit = 2 }, function() done = true end)
	vim.wait(500, function() return done end)
	assert(sql:find("n.nspname = E'analytics'", 1, true) == nil)
end

T["contracts"]["keeps foreign tables in relations but not in compatibility tables"] = function()
	local relations_sql, tables_sql
	stub_output("", nil, function(value) relations_sql = value end)
	local relations_done = false
	postgres.catalogs[1].list({ scope = {}, limit = 2 }, function() relations_done = true end)
	vim.wait(500, function() return relations_done end)

	stub_output("", nil, function(value) tables_sql = value end)
	local tables_done = false
	postgres.catalogs[2].list({ scope = {}, limit = 2 }, function() tables_done = true end)
	vim.wait(500, function() return tables_done end)

	assert(relations_sql:find("c.relkind IN ('r', 'v', 'm', 'p', 'f')", 1, true) ~= nil)
	assert(tables_sql:find("c.relkind IN ('r', 'v', 'm', 'p')", 1, true) ~= nil)
	assert(tables_sql:find("'f'", 1, true) == nil)
end

T["contracts"]["builds each catalog query with server filtering, keyset ordering, and limit plus one"] = function()
	for _, definition in ipairs(postgres.catalogs) do
		local sql
		stub_output("", nil, function(value) sql = value end)
		local done = false
		definition.list({
			scope = { schema = "analytics", all_schemas = false },
			query = "a_b%'\\",
			limit = 2,
		}, function() done = true end)
		vim.wait(500, function() return done end)
		expect_match(sql, "ORDER BY")
		expect_match(sql, "LIMIT 3")
		expect_match(sql, "ILIKE")
		assert(sql:find("n.nspname = E'analytics'", 1, true) ~= nil)
	end
end

T["contracts"]["escapes literal catalog filters without creating SQL fragments"] = function()
	eq(postgres.quote_literal("a_b%'\\"), "E'a\\\\_b\\\\%''\\\\'")
	local sql
	stub_output("", nil, function(value) sql = value end)
	local done = false
	postgres.catalogs[1].list({
		scope = {},
		query = "a_b%'\\",
		limit = 2,
	}, function() done = true end)
	vim.wait(500, function() return done end)
	assert(sql:find("ILIKE '%' || E'a\\\\_b\\\\%''\\\\' || '%' ESCAPE E'\\\\'", 1, true) ~= nil)
end

T["contracts"]["rejects malformed cursors before starting psql"] = function()
	local started = false
	stub_output("", nil, function() started = true end)
	local err
	postgres.catalogs[1].list({
		scope = {},
		limit = 2,
		cursor = "not json",
	}, function(_, value) err = value end)
	expect_match(err, "malformed catalog cursor")
	eq(started, false)
end

T["contracts"]["uses the sentinel row only to emit a next cursor"] = function()
	stub_output("public\taccounts\tr\t100\npublic\torders\tr\t101\npublic\tusers\tr\t102\n")
	local got
	postgres.catalogs[1].list({ scope = {}, limit = 2 }, function(page) got = page end)
	vim.wait(500, function() return got ~= nil end)
	eq(vim.tbl_map(function(item) return item.value.name end, got.items), { "accounts", "orders" })
	eq(vim.json.decode(got.next_cursor), { "public", "orders", "101" })
end

T["contracts"]["adds a keyset predicate from an opaque cursor"] = function()
	local sql
	stub_output("", nil, function(value) sql = value end)
	local done = false
	postgres.catalogs[1].list({
		scope = {},
		limit = 2,
		cursor = postgres.encode_cursor({ "public", "orders", "101" }),
	}, function() done = true end)
	vim.wait(500, function() return done end)
	assert(sql:find("c.oid > E'101'::oid", 1, true) ~= nil)
end

T["contracts"]["surfaces the error when the CLI fails"] = function()
	stub_output("", 2)
	local err
	postgres.contexts[1].list({}, function(_, e) err = e end)
	vim.wait(500, function() return err ~= nil end)
	expect_match(err, "boom")
end

T["contracts"]["labels every supported relkind"] = function()
	eq(postgres.kind_label("r"), "table")
	eq(postgres.kind_label("v"), "view")
	eq(postgres.kind_label("m"), "matview")
	eq(postgres.kind_label("p"), "partitioned")
	eq(postgres.kind_label("x"), "x")
end

T["contracts"]["previews the selected relation"] = function()
	local dbsh = require("dbsh")
	local original = dbsh.query
	local asked
	dbsh.query = function(sql) asked = sql end

	postgres.catalogs[1].on_select({
		value = { schema = "public", name = "users", kind = "relation", oid = "100", relkind = "r" },
	}, {})

	dbsh.query = original
	eq(asked, 'SELECT * FROM "public"."users" LIMIT 10;')
end

return T
