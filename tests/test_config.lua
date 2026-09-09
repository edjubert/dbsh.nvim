local helpers = dofile("tests/helpers.lua")
local eq, expect_match = helpers.eq, helpers.expect_match

local config = require("dbsh.config")

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

T["applies csv export defaults"] = function()
	eq(config.options().csv_delimiter, ",")
	eq(
		config.options().export_dir,
		vim.fs.joinpath(vim.fn.stdpath("data"), "dbsh", "exports")
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

T["resolves postgres for a connection with no declared type"] = function()
	eq(config.backend(), require("dbsh.backends.postgres"))
end

T["resolves the backend a connection declares"] = function()
	config.setup({
		connections = {
			pg = { type = "postgres", host = "localhost", port = 5432, database = "postgres", username = "dev" },
		},
		default = "pg",
	})
	eq(config.backend(), require("dbsh.backends.postgres"))
end

T["rejects a connection whose type has no backend"] = function()
	config.setup({
		connections = { weird = { type = "oracle", host = "h", port = 1, database = "d", username = "u" } },
		default = "weird",
	})
	local backend, err = config.backend()
	eq(backend, nil)
	expect_match(err, "unknown connection type")
end

T["reports no current connection when resolving a backend"] = function()
	config.setup({ connections = {} })
	local backend, err = config.backend()
	eq(backend, nil)
	expect_match(err, "no current connection")
end

T["sets an arbitrary navigation level on the current connection"] = function()
	config.set_level("schema", "analytics")
	eq(config.current().schema, "analytics")
end

T["bumps the generation when setting a level"] = function()
	local before = config.generation()
	config.set_level("schema", "analytics")
	eq(config.generation() > before, true)
end

T["setting a level does not mutate the declared connection"] = function()
	config.set_level("database", "analytics")
	eq(config.options().connections.local_db.database, "postgres")
end

T["reports an error when setting a level with no connection"] = function()
	config.setup({ connections = {} })
	local conn, err = config.set_level("database", "analytics")
	eq(conn, nil)
	expect_match(err, "no current connection")
end

T["announces a connection change"] = function()
	local fired = 0
	local group = vim.api.nvim_create_augroup("dbsh_test_config", { clear = true })
	vim.api.nvim_create_autocmd("User", {
		pattern = "DbshConnectionChanged",
		group = group,
		callback = function() fired = fired + 1 end,
	})

	config.set_connection("staging")
	config.set_level("database", "analytics")

	vim.api.nvim_del_augroup_by_id(group)
	eq(fired, 2)
end

T["defaults the language server integration to off"] = function()
	eq(config.options().lsp.enabled, false)
end

T["announces the change when fixing a navigation level"] = function()
	local fired = 0
	local group = vim.api.nvim_create_augroup("dbsh_test_level_event", { clear = true })
	vim.api.nvim_create_autocmd("User", {
		pattern = "DbshConnectionChanged",
		group = group,
		callback = function()
			fired = fired + 1
		end,
	})

	config.set_level("database", "other")

	vim.api.nvim_del_augroup_by_id(group)
	eq(fired, 1)
end

return T
