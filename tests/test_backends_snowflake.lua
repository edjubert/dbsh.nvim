local helpers = dofile("tests/helpers.lua")
local eq, expect_match = helpers.eq, helpers.expect_match

local snowflake = require("dbsh.backends.snowflake")

local connection = {
	type = "snowflake",
	host = "account.example.test",
	port = 443,
	username = "analyst",
	authenticator = "https://sso.example.test",
	role = "ANALYST",
	warehouse = "COMPUTE",
	database = "ANALYTICS",
	schema = "PUBLIC",
	password_command = { "password-command", "--profile", "analytics" },
}

local T = MiniTest.new_set()

T["declares the Snowflake backend shape"] = function()
	eq(snowflake.name, "snowflake")
	eq(snowflake.shape, "tabular")
	eq(snowflake.filetype, "sql")
	eq(snowflake.extension, "sql")
end

T["builds a temporary structured Snow CLI invocation"] = function()
	local password = "fake-password"
	local argv = snowflake.argv(connection, "/tmp/query.sql", "pretty", { password = password })

	eq(argv[1], "snow")
	eq(argv[2], "sql")
	eq(vim.tbl_contains(argv, "--temporary-connection"), true)
	eq(vim.tbl_contains(argv, "--account"), true)
	eq(vim.tbl_contains(argv, "account"), true)
	eq(vim.tbl_contains(argv, "--filename"), true)
	eq(vim.tbl_contains(argv, "/tmp/query.sql"), true)
	eq(vim.tbl_contains(argv, "--role"), true)
	eq(vim.tbl_contains(argv, "ANALYST"), true)
	eq(vim.tbl_contains(argv, "--warehouse"), true)
	eq(vim.tbl_contains(argv, "COMPUTE"), true)
	eq(vim.tbl_contains(argv, "--database"), true)
	eq(vim.tbl_contains(argv, "ANALYTICS"), true)
	eq(vim.tbl_contains(argv, "--schema"), true)
	eq(vim.tbl_contains(argv, "PUBLIC"), true)
	for _, value in ipairs(argv) do
		eq(value == password, false)
	end
end

T["uses JSON_EXT only for raw output and password only in the environment"] = function()
	local raw = snowflake.argv(connection, "/tmp/query.sql", "raw", { password = "fake-password" })
	local pretty = snowflake.argv(connection, "/tmp/query.sql", "pretty", { password = "fake-password" })

	eq(vim.tbl_contains(raw, "JSON_EXT"), true)
	eq(vim.tbl_contains(pretty, "JSON_EXT"), false)
	eq(snowflake.env(connection, {}, { password = "fake-password" }), {
		SNOWFLAKE_PASSWORD = "fake-password",
	})
end

T["parses JSON_EXT while preserving result column order"] = function()
	local fixture = table.concat(vim.fn.readfile("tests/fixtures/snowflake_json_ext.json"), "\n")
	local rows, err = snowflake.parse_raw(fixture)

	eq(err, nil)
	eq(rows[1][1], "2")
	eq(rows[1][2], "alpha")
	eq(rows[1][3], "(NULL)")
	eq(vim.json.decode(rows[1][4]), { enabled = true, tags = { "one", "two" } })
	eq(rows[2][1], "3")
	eq(rows[2][2], "beta")
	eq(rows[2][3], "false")
	eq(vim.json.decode(rows[2][4]), { "next", 7 })
end

T["returns sanitized errors for malformed JSON_EXT output"] = function()
	local payload = "{\"secret\":\"fake-password\""
	local rows, err = snowflake.parse_raw(payload)

	eq(rows, nil)
	expect_match(err, "invalid Snowflake JSON_EXT")
	eq(err:find("fake-password", 1, true), nil)
end

T["uses the final result set from a multi-statement JSON_EXT response"] = function()
	local rows, err = snowflake.parse_raw(
		'[[{"IGNORED":"show result"}],[{"NAME":"ANALYST","OBJECT_TYPE":"role"}]]'
	)

	eq(err, nil)
	eq(rows, { { "ANALYST", "role" } })
end

T["uses the final result set when an earlier SHOW result is empty"] = function()
	local rows, err = snowflake.parse_raw('[[],[{"NAME":"TASK","OBJECT_TYPE":"task"}]]')

	eq(err, nil)
	eq(rows, { { "TASK", "task" } })
end

T["recognizes only documented authentication failures"] = function()
	eq(
		snowflake.is_authentication_error(
			"250001: Failed to connect: Incorrect username or password was specified",
			""
		),
		true
	)
	eq(snowflake.is_authentication_error("SQL compilation error", ""), false)
end

T["declares every first-version Snowflake catalog"] = function()
	local keys = vim.tbl_map(function(definition) return definition.key end, snowflake.catalogs)

	eq(keys, {
		"roles",
		"warehouses",
		"databases",
		"schemas",
		"relations",
		"routines",
		"sequences",
		"stages",
		"file_formats",
		"streams",
		"tasks",
		"pipes",
	})
end

T["builds paged, literal-safe catalog queries with active or all-schema scope"] = function()
	local request = {
		context = { levels = { database = "ANALYTICS", schema = "PUBLIC" } },
		scope = { schema = "PUBLIC", all_schemas = false },
		query = "order%_!",
		limit = 10,
	}
	local scoped = assert(snowflake.catalog_query("relations", request))
	expect_match(scoped, "INFORMATION_SCHEMA%.TABLES")
	expect_match(scoped, "TABLE_SCHEMA = 'PUBLIC'")
	expect_match(scoped, "order!%%!_!!")
	expect_match(scoped, "ORDER BY")
	expect_match(scoped, "LIMIT 11")

	request.scope = { schema = nil, all_schemas = true }
	local all_schemas = assert(snowflake.catalog_query("relations", request))
	eq(all_schemas:find("TABLE_SCHEMA = 'PUBLIC'", 1, true), nil)
end

T["forwards an opaque catalog cursor through a stable keyset predicate"] = function()
	local sql = assert(snowflake.catalog_query("relations", {
		context = { levels = { database = "ANALYTICS" } },
		scope = { schema = nil, all_schemas = true },
		query = "",
		cursor = vim.json.encode({ "PUBLIC", "ORDERS" }),
		limit = 25,
	}))

	expect_match(sql, "TABLE_SCHEMA > 'PUBLIC'")
	expect_match(sql, "TABLE_NAME > 'ORDERS'")
	expect_match(sql, "LIMIT 26")
end

T["uses SHOW plus RESULT_SCAN for account-level catalogs"] = function()
	local request = { context = { levels = {} }, scope = {}, query = "", limit = 5 }

	expect_match(assert(snowflake.catalog_query("roles", request)), "SHOW ROLES")
	expect_match(assert(snowflake.catalog_query("warehouses", request)), "SHOW WAREHOUSES")
	expect_match(assert(snowflake.catalog_query("databases", request)), "SHOW DATABASES")
	expect_match(assert(snowflake.catalog_query("roles", request)), "RESULT_SCAN")
end

T["keeps INFORMATION_SCHEMA queries valid when no optional predicate is selected"] = function()
	local sql = assert(snowflake.catalog_query("schemas", {
		context = { levels = { database = "ANALYTICS" } },
		scope = { schema = nil, all_schemas = false },
		query = "",
		limit = 1,
	}))

	expect_match(sql, "WHERE TRUE")
end

T["builds a supported normalized Snowflake definition request"] = function()
	local request = assert(snowflake.definition_request({
		connection = connection,
		levels = { database = "ANALYTICS" },
	}, {
		kind = "relation",
		database = "ANALYTICS",
		schema = "PUBLIC",
		name = "ORDERS",
		relation_type = "BASE TABLE",
		identity = { database = "ANALYTICS", schema = "PUBLIC", name = "ORDERS" },
	}))
	expect_match(request.sql, "GET_DDL")
	expect_match(request.sql, "ANALYTICS%.PUBLIC%.ORDERS")

	local unsupported, err = snowflake.definition_request({ connection = connection }, { kind = "task" })
	eq(unsupported, nil)
	expect_match(err, "not available")
end

return T
