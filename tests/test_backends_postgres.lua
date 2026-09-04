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

return T
