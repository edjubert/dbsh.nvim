-- Opt-in Snowflake CLI smoke test. It is not part of MiniTest because it
-- requires a private local connection supplied through environment variables.

local M = {}

local required_variables = {
	"DBSH_SNOWFLAKE_HOST",
	"DBSH_SNOWFLAKE_PORT",
	"DBSH_SNOWFLAKE_USERNAME",
	"DBSH_SNOWFLAKE_AUTHENTICATOR",
	"DBSH_SNOWFLAKE_ROLE",
	"DBSH_SNOWFLAKE_WAREHOUSE",
	"DBSH_SNOWFLAKE_DATABASE",
	"DBSH_SNOWFLAKE_PASSWORD_COMMAND_JSON",
}

local function trim_terminal_newline(value)
	if value:sub(-2) == "\r\n" then
		return value:sub(1, -3)
	end
	if value:sub(-1) == "\n" then
		return value:sub(1, -2)
	end
	return value
end

local function wait_for(process)
	local ok, wait = pcall(function()
		return process.wait
	end)
	if ok and type(wait) == "function" then
		return process:wait()
	end
	return process
end

local function is_non_empty_argv(argv)
	if type(argv) ~= "table" or #argv == 0 then
		return false
	end
	for _, value in ipairs(argv) do
		if type(value) ~= "string" or value == "" then
			return false
		end
	end
	return true
end

function M.decode_password_command(value)
	local ok, argv = pcall(vim.json.decode, value)
	if not ok or not is_non_empty_argv(argv) then
		return nil, "invalid DBSH_SNOWFLAKE_PASSWORD_COMMAND_JSON"
	end
	return argv
end

function M.account_from_host(host)
	return host:match("^([^.]+)%.")
end

function M.config_from_env(env)
	for _, name in ipairs(required_variables) do
		if type(env[name]) ~= "string" or env[name] == "" then
			return nil, "missing " .. name
		end
	end

	local port = tonumber(env.DBSH_SNOWFLAKE_PORT)
	if port == nil or port % 1 ~= 0 or port < 1 or port > 65535 then
		return nil, "invalid DBSH_SNOWFLAKE_PORT"
	end

	local account = M.account_from_host(env.DBSH_SNOWFLAKE_HOST)
	if account == nil then
		return nil, "invalid DBSH_SNOWFLAKE_HOST"
	end

	local password_command, err = M.decode_password_command(env.DBSH_SNOWFLAKE_PASSWORD_COMMAND_JSON)
	if password_command == nil then
		return nil, err
	end

	local schema = env.DBSH_SNOWFLAKE_SCHEMA
	if schema == "" then
		schema = nil
	end

	return {
		account = account,
		host = env.DBSH_SNOWFLAKE_HOST,
		port = port,
		username = env.DBSH_SNOWFLAKE_USERNAME,
		authenticator = env.DBSH_SNOWFLAKE_AUTHENTICATOR,
		role = env.DBSH_SNOWFLAKE_ROLE,
		warehouse = env.DBSH_SNOWFLAKE_WAREHOUSE,
		database = env.DBSH_SNOWFLAKE_DATABASE,
		schema = schema,
		password_command = password_command,
	}
end

function M.snow_argv(config)
	local argv = {
		"snow",
		"sql",
		"--temporary-connection",
		"--account",
		config.account,
		"--host",
		config.host,
		"--port",
		tostring(config.port),
		"--user",
		config.username,
		"--authenticator",
		config.authenticator,
		"--role",
		config.role,
		"--warehouse",
		config.warehouse,
		"--database",
		config.database,
	}

	if config.schema ~= nil then
		table.insert(argv, "--schema")
		table.insert(argv, config.schema)
	end

	table.insert(argv, "--format")
	table.insert(argv, "JSON_EXT")
	table.insert(argv, "--silent")
	table.insert(argv, "--query")
	table.insert(
		argv,
		"SELECT CURRENT_USER() AS current_user, CURRENT_ROLE() AS current_role, "
			.. "CURRENT_WAREHOUSE() AS current_warehouse, CURRENT_DATABASE() AS current_database, "
			.. "CURRENT_SCHEMA() AS current_schema"
	)
	return argv
end

local function contains_result_set(value)
	if type(value) ~= "table" then
		return false
	end
	if #value > 0 then
		return true
	end
	if value.data ~= nil or value.rows ~= nil or value.rowset ~= nil then
		return true
	end
	if type(value.results) == "table" then
		for _, result in ipairs(value.results) do
			if contains_result_set(result) then
				return true
			end
		end
	end
	for _, entry in ipairs(value) do
		if contains_result_set(entry) then
			return true
		end
	end
	return false
end

function M.run(config, runner)
	runner = runner or vim.system

	local password_result = wait_for(runner(config.password_command, { text = true }))
	if password_result == nil or password_result.code ~= 0 then
		return nil, "password command failed"
	end

	local password = trim_terminal_newline(password_result.stdout or "")
	if password == "" then
		return nil, "password command returned an empty value"
	end

	local result = wait_for(runner(M.snow_argv(config), {
		text = true,
		env = { SNOWFLAKE_PASSWORD = password },
	}))
	password = nil

	if result == nil or result.code ~= 0 then
		return nil, "snow sql failed"
	end

	local ok, payload = pcall(vim.json.decode, result.stdout or "")
	if not ok or not contains_result_set(payload) then
		return nil, "snow sql did not return a JSON result set"
	end

	return true
end

local function self_test()
	local config, err = M.config_from_env({})
	assert(config == nil)
	assert(err == "missing DBSH_SNOWFLAKE_HOST")

	local password_command, decode_err = M.decode_password_command('["password-command", "--value"]')
	assert(decode_err == nil)
	assert(password_command[1] == "password-command")

	local invalid_command, invalid_err = M.decode_password_command('{"command":"password-command"}')
	assert(invalid_command == nil)
	assert(invalid_err == "invalid DBSH_SNOWFLAKE_PASSWORD_COMMAND_JSON")

	config = assert(M.config_from_env({
		DBSH_SNOWFLAKE_HOST = "account.example.test",
		DBSH_SNOWFLAKE_PORT = "443",
		DBSH_SNOWFLAKE_USERNAME = "user",
		DBSH_SNOWFLAKE_AUTHENTICATOR = "https://sso.example.test",
		DBSH_SNOWFLAKE_ROLE = "ANALYST",
		DBSH_SNOWFLAKE_WAREHOUSE = "COMPUTE",
		DBSH_SNOWFLAKE_DATABASE = "ANALYTICS",
		DBSH_SNOWFLAKE_SCHEMA = "PUBLIC",
		DBSH_SNOWFLAKE_PASSWORD_COMMAND_JSON = '["password-command", "--value"]',
	}))
	assert(config.account == "account")

	local invocations = 0
	local passed_password = "fake-password"
	local ok, run_err = M.run(config, function(argv, opts)
		invocations = invocations + 1
		if invocations == 1 then
			assert(argv[1] == "password-command")
			assert(opts.text == true)
			assert(opts.env == nil)
			return { code = 0, stdout = passed_password .. "\n", stderr = "" }
		end

		assert(argv[1] == "snow")
		assert(argv[2] == "sql")
		assert(vim.tbl_contains(argv, "--temporary-connection"))
		assert(vim.tbl_contains(argv, "--account"))
		assert(vim.tbl_contains(argv, "account"))
		assert(vim.tbl_contains(argv, "JSON_EXT"))
		for _, value in ipairs(argv) do
			assert(value ~= passed_password)
		end
		assert(opts.text == true)
		assert(opts.env.SNOWFLAKE_PASSWORD == passed_password)
		return { code = 0, stdout = '[{"CURRENT_USER":"USER"}]', stderr = "" }
	end)

	assert(ok == true)
	assert(run_err == nil)
	assert(invocations == 2)
end

function M.main()
	local config, err = M.config_from_env(vim.env)
	if config == nil then
		vim.api.nvim_err_writeln("dbsh snowflake smoke: " .. err)
		vim.cmd("cquit 1")
		return
	end

	local ok, run_err = M.run(config)
	if not ok then
		vim.api.nvim_err_writeln("dbsh snowflake smoke: " .. run_err)
		vim.cmd("cquit 1")
		return
	end

	print("dbsh snowflake smoke: authenticated JSON_EXT result received")
end

if vim.tbl_contains(vim.v.argv, "--self-test") then
	self_test()
	print("dbsh snowflake smoke: local checks passed")
	return
end

M.main()
