local helpers = dofile("tests/helpers.lua")
local eq, expect_match = helpers.eq, helpers.expect_match

local config = require("psql.config")
local exec = require("psql.exec")
local introspect = require("psql.introspect")

local original_runner

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
		end,
		post_case = function()
			exec.runner = original_runner
			exec.slots = { user = nil, introspect = nil }
		end,
	},
})

T["parses tab separated rows and skips blank lines"] = function()
	local rows = introspect.parse_rows("a\tb\tc\n\nd\te\tf\n")
	eq(rows, { { "a", "b", "c" }, { "d", "e", "f" } })
end

T["returns an empty list for empty output"] = function()
	eq(introspect.parse_rows(""), {})
end

T["quotes identifiers and doubles inner quotes"] = function()
	eq(introspect.quote_ident("users"), '"users"')
	eq(introspect.quote_ident('we"ird'), '"we""ird"')
end

T["builds a quoted preview query with the configured limit"] = function()
	eq(
		introspect.preview_query("analytics", "events"),
		'SELECT * FROM "analytics"."events" LIMIT 10;'
	)
end

T["honours an explicit preview limit"] = function()
	eq(
		introspect.preview_query("public", "users", 3),
		'SELECT * FROM "public"."users" LIMIT 3;'
	)
end

T["excludes system schemas from the queries"] = function()
	expect_match(introspect.queries.schemas, "information_schema")
	expect_match(introspect.queries.databases, "datistemplate")
	expect_match(introspect.queries.tables, "relkind")
end

T["lists database names"] = function()
	stub_output("postgres\nanalytics\n")
	local got
	introspect.databases(function(names) got = names end)
	vim.wait(500, function() return got ~= nil end)
	eq(got, { "postgres", "analytics" })
end

T["lists schema names"] = function()
	stub_output("public\nanalytics\n")
	local got
	introspect.schemas(function(names) got = names end)
	vim.wait(500, function() return got ~= nil end)
	eq(got, { "public", "analytics" })
end

T["lists tables as structured rows"] = function()
	stub_output("public\tusers\tr\nanalytics\tevents\tv\n")
	local got
	introspect.tables({}, function(rows) got = rows end)
	vim.wait(500, function() return got ~= nil end)
	eq(got, {
		{ schema = "public", name = "users", kind = "r" },
		{ schema = "analytics", name = "events", kind = "v" },
	})
end

T["filters tables by schema"] = function()
	stub_output("public\tusers\tr\nanalytics\tevents\tv\n")
	local got
	introspect.tables({ schema = "analytics" }, function(rows) got = rows end)
	vim.wait(500, function() return got ~= nil end)
	eq(#got, 1)
	eq(got[1].name, "events")
end

T["surfaces the error when psql fails"] = function()
	stub_output("", 2)
	local err
	introspect.databases(function(_, e) err = e end)
	vim.wait(500, function() return err ~= nil end)
	expect_match(err, "boom")
end

return T
