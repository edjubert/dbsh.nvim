local helpers = dofile("tests/helpers.lua")
local eq, expect_match = helpers.eq, helpers.expect_match

local config = require("psql.config")

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			config.setup({
				connections = {
					local_db = { host = "localhost", port = 5432, database = "postgres", username = "dev" },
					staging = { host = "db.example.com", port = 5432, database = "app", username = "readonly" },
				},
				default = "local_db",
			})
		end,
	},
})

T["selects the default connection on setup"] = function()
	eq(config.current_name(), "local_db")
	eq(config.current().database, "postgres")
end

T["applies default options"] = function()
	eq(config.options().connect_timeout, 5)
	eq(config.options().query_timeout, 30000)
	eq(config.options().preview_limit, 10)
end

T["lists connection names sorted"] = function()
	eq(config.names(), { "local_db", "staging" })
end

T["bumps the generation when switching connection"] = function()
	local before = config.generation()
	config.set_connection("staging")
	eq(config.current().host, "db.example.com")
	eq(config.generation() > before, true)
end

T["rejects an unknown connection"] = function()
	local conn, err = config.set_connection("missing")
	eq(conn, nil)
	expect_match(err, "unknown connection")
end

T["switching database does not mutate the declared connection"] = function()
	config.set_database("analytics")
	eq(config.current().database, "analytics")
	eq(config.options().connections.local_db.database, "postgres")
end

T["bumps the generation when switching database"] = function()
	local before = config.generation()
	config.set_database("analytics")
	eq(config.generation() > before, true)
end

T["reports an error when switching database with no connection"] = function()
	config.setup({ connections = {} })
	local conn, err = config.set_database("analytics")
	eq(conn, nil)
	expect_match(err, "no current connection")
end

T["applies csv export defaults"] = function()
	eq(config.options().csv_delimiter, ",")
	eq(
		config.options().export_dir,
		vim.fs.joinpath(vim.fn.stdpath("data"), "psql", "exports")
	)
end

T["lets the user override the csv delimiter"] = function()
	config.setup({ connections = {}, csv_delimiter = ";" })
	eq(config.options().csv_delimiter, ";")
end

T["defaults the result split to horizontal"] = function()
	eq(config.options().results_split, "horizontal")
end

T["lets the user request a vertical result split"] = function()
	config.setup({ connections = {}, results_split = "vertical" })
	eq(config.options().results_split, "vertical")
end

T["defaults to no variable pattern"] = function()
	eq(config.options().variable_patterns, {})
end

T["lets the user declare variable patterns"] = function()
	config.setup({ connections = {}, variable_patterns = { ":(raw_data)" } })
	eq(config.options().variable_patterns, { ":(raw_data)" })
end

return T
