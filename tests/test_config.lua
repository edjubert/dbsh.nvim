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

T["keeps the configured default profile as static configuration"] = function()
	eq(config.default_name(), "local_db")
end

T["applies default options"] = function()
	eq(config.options().connect_timeout, 5)
	eq(config.options().query_timeout, 30000)
	eq(config.options().preview_limit, 10)
	eq(config.options().catalog_page_size, 200)
end

T["accepts a positive catalog page size"] = function()
	config.setup({ connections = {}, catalog_page_size = 25 })
	eq(config.options().catalog_page_size, 25)
end

T["falls back from a non-positive catalog page size with a clear warning"] = function()
	local original_notify = vim.notify
	local notified
	vim.notify = function(message) notified = message end

	config.setup({ connections = {}, catalog_page_size = 0 })

	vim.notify = original_notify
	eq(config.options().catalog_page_size, 200)
	expect_match(notified, "catalog_page_size")
end

T["falls back from a fractional catalog page size"] = function()
	config.setup({ connections = {}, catalog_page_size = 2.5 })
	eq(config.options().catalog_page_size, 200)
end

T["lists connection names sorted"] = function()
	eq(config.names(), { "local_db", "staging" })
end

T["returns a deep copy of a declared connection"] = function()
	local connection = assert(config.connection("local_db"))
	connection.database = "analytics"

	eq(config.options().connections.local_db.database, "postgres")
	eq(assert(config.connection("local_db")).database, "postgres")
end

T["rejects an unknown declared connection"] = function()
	local connection, err = config.connection("missing")
	eq(connection, nil)
	expect_match(err, "unknown connection")
end

T["resolves postgres for a connection with no declared type"] = function()
	local backend = assert(config.backend_for(assert(config.connection("local_db"))))
	eq(backend, require("dbsh.backends.postgres"))
end

T["resolves the backend a connection declares"] = function()
	config.setup({
		connections = {
			pg = { type = "postgres", host = "localhost", port = 5432, database = "postgres", username = "dev" },
		},
		default = "pg",
	})

	local backend = assert(config.backend_for(assert(config.connection("pg"))))
	eq(backend, require("dbsh.backends.postgres"))
end

T["rejects a connection whose type has no backend"] = function()
	config.setup({
		connections = { weird = { type = "oracle", host = "h", port = 1, database = "d", username = "u" } },
		default = "weird",
	})

	local backend, err = config.backend_for(assert(config.connection("weird")))
	eq(backend, nil)
	expect_match(err, "unknown connection type")
end

T["reports no connection when resolving a backend"] = function()
	local backend, err = config.backend_for(nil)
	eq(backend, nil)
	expect_match(err, "no connection")
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

T["defaults the language server integration to off"] = function()
	eq(config.options().lsp.enabled, false)
end

return T
