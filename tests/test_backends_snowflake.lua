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

return T
