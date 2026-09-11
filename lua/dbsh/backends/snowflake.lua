-- The Snowflake backend: stateless Snow CLI invocation and JSON_EXT parsing.

local credentials = require("dbsh.credentials")

local M = {}

M.name = "snowflake"
M.shape = "tabular"
M.filetype = "sql"
M.extension = "sql"

local required_fields = {
	"host",
	"username",
	"authenticator",
	"role",
	"warehouse",
	"database",
}

local function valid_argv(argv)
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

local function valid_port(port)
	return type(port) == "number"
		and port == math.floor(port)
		and port >= 1
		and port <= 65535
end

function M.validate(connection)
	if type(connection) ~= "table" then
		return nil, "Snowflake profile must be a table"
	end
	if connection.password ~= nil then
		return nil, "Snowflake profile must not provide a password"
	end
	for _, key in ipairs({ "connection_string", "url", "jdbc_url" }) do
		if connection[key] ~= nil then
			return nil, "Snowflake profile must not provide a connection string"
		end
	end
	for _, key in ipairs(required_fields) do
		if type(connection[key]) ~= "string" or connection[key] == "" then
			return nil, "Snowflake profile requires a non-empty " .. key
		end
	end
	if not valid_port(connection.port) then
		return nil, "Snowflake profile requires a valid port"
	end
	if connection.schema ~= nil and type(connection.schema) ~= "string" then
		return nil, "Snowflake profile schema must be a string"
	end
	if not valid_argv(connection.password_command) then
		return nil, "Snowflake profile requires password_command as a non-empty argv list"
	end
	return true
end

function M.account_from_host(host)
	return host:match("^([^.]+)%.") or host
end

local function credential_key(snapshot)
	if type(snapshot.connection_name) == "string" and snapshot.connection_name ~= "" then
		return "snowflake:" .. snapshot.connection_name
	end
	local connection = snapshot.connection
	return table.concat({
		"snowflake",
		connection.host,
		tostring(connection.port),
		connection.username,
	}, ":")
end

function M.prepare(snapshot, options, callback)
	local connection = snapshot.connection
	local valid, err = M.validate(connection)
	if valid == nil then
		callback(nil, err)
		return
	end

	local key = credential_key(snapshot)
	credentials.resolve(key, connection.password_command, {
		cache_ttl_ms = ((options or {}).credentials or {}).cache_ttl_ms,
	}, function(password, resolve_err)
		if resolve_err ~= nil then
			callback(nil, resolve_err)
			return
		end
		callback({
			password = password,
			credential_backed = true,
			credential_key = key,
		}, nil)
	end)
end

function M.preamble()
	return ""
end

function M.argv(connection, script_path, mode)
	local argv = {
		"snow",
		"sql",
		"--temporary-connection",
		"--account",
		M.account_from_host(connection.host),
		"--host",
		connection.host,
		"--port",
		tostring(connection.port),
		"--user",
		connection.username,
		"--authenticator",
		connection.authenticator,
		"--role",
		connection.role,
		"--warehouse",
		connection.warehouse,
		"--database",
		connection.database,
	}
	if type(connection.schema) == "string" and connection.schema ~= "" then
		vim.list_extend(argv, { "--schema", connection.schema })
	end
	if mode == "raw" then
		vim.list_extend(argv, { "--format", "JSON_EXT" })
	end
	vim.list_extend(argv, { "--silent", "--filename", script_path })
	return argv
end

function M.env(_, _, runtime)
	if type(runtime) ~= "table" or type(runtime.password) ~= "string" then
		return {}
	end
	return { SNOWFLAKE_PASSWORD = runtime.password }
end

local function skip_whitespace(input, index)
	while input:sub(index, index):match("%s") do
		index = index + 1
	end
	return index
end

local function parse_json_string(input, index)
	if input:sub(index, index) ~= '"' then
		return nil, nil
	end
	local start = index
	index = index + 1
	while index <= #input do
		local character = input:sub(index, index)
		if character == "\\" then
			index = index + 2
		elseif character == '"' then
			local ok, value = pcall(vim.json.decode, input:sub(start, index))
			if not ok or type(value) ~= "string" then
				return nil, nil
			end
			return value, index + 1
		else
			index = index + 1
		end
	end
	return nil, nil
end

local function skip_json_value(input, index)
	index = skip_whitespace(input, index)
	local character = input:sub(index, index)
	if character == '"' then
		local _, next_index = parse_json_string(input, index)
		return next_index
	end
	if character ~= "{" and character ~= "[" then
		while index <= #input do
			character = input:sub(index, index)
			if character == "," or character == "}" or character == "]" or character:match("%s") then
				return index
			end
			index = index + 1
		end
		return nil
	end

	local opening = character
	local closing = opening == "{" and "}" or "]"
	local depth = 0
	while index <= #input do
		character = input:sub(index, index)
		if character == '"' then
			local _, next_index = parse_json_string(input, index)
			if next_index == nil then
				return nil
			end
			index = next_index
		else
			if character == opening then
				depth = depth + 1
			elseif character == closing then
				depth = depth - 1
				if depth == 0 then
					return index + 1
				end
			end
			index = index + 1
		end
	end
	return nil
end

local function ordered_object_keys(input)
	local index = skip_whitespace(input, 1)
	if input:sub(index, index) ~= "[" then
		return nil
	end
	index = skip_whitespace(input, index + 1)
	if input:sub(index, index) == "]" then
		return {}
	end
	if input:sub(index, index) ~= "{" then
		return nil
	end

	local keys = {}
	index = skip_whitespace(input, index + 1)
	while index <= #input do
		if input:sub(index, index) == "}" then
			return keys
		end
		local key
		key, index = parse_json_string(input, index)
		if key == nil then
			return nil
		end
		index = skip_whitespace(input, index)
		if input:sub(index, index) ~= ":" then
			return nil
		end
		index = skip_json_value(input, index + 1)
		if index == nil then
			return nil
		end
		table.insert(keys, key)
		index = skip_whitespace(input, index)
		local separator = input:sub(index, index)
		if separator == "}" then
			return keys
		end
		if separator ~= "," then
			return nil
		end
		index = skip_whitespace(input, index + 1)
	end
	return nil
end

local function stringify(value)
	if value == vim.NIL then
		return "(NULL)"
	end
	if type(value) == "string" or type(value) == "number" then
		return tostring(value)
	end
	if type(value) == "boolean" then
		return value and "true" or "false"
	end
	if type(value) == "table" then
		return vim.json.encode(value)
	end
	return nil
end

function M.parse_raw(stdout)
	local ok, payload = pcall(vim.json.decode, stdout or "")
	if not ok or type(payload) ~= "table" then
		return nil, "invalid Snowflake JSON_EXT output"
	end
	local keys = ordered_object_keys(stdout or "")
	if keys == nil then
		return nil, "invalid Snowflake JSON_EXT output"
	end
	if #payload == 0 then
		return {}
	end

	local expected = {}
	for _, key in ipairs(keys) do
		expected[key] = true
	end
	local rows = {}
	for _, source_row in ipairs(payload) do
		if type(source_row) ~= "table" or #source_row ~= 0 then
			return nil, "invalid Snowflake JSON_EXT output"
		end
		for key in pairs(source_row) do
			if not expected[key] then
				return nil, "invalid Snowflake JSON_EXT output"
			end
		end
		local row = {}
		for _, key in ipairs(keys) do
			local value = rawget(source_row, key)
			local cell = stringify(value)
			if cell == nil then
				return nil, "invalid Snowflake JSON_EXT output"
			end
			table.insert(row, cell)
		end
		table.insert(rows, row)
	end
	return rows, nil
end

function M.is_authentication_error(stderr, stdout)
	local output = string.lower((stderr or "") .. "\n" .. (stdout or ""))
	return output:find("250001", 1, true) ~= nil
		and output:find("incorrect username or password", 1, true) ~= nil
end

local function apply_context(key)
	return function(snapshot, value)
		return require("dbsh.context").apply(snapshot, key, value, "catalog")
	end
end

local function unavailable_context(_, callback)
	callback(nil, "Snowflake context catalog is not available yet")
end

M.contexts = {
	{ key = "role", command = "Roles", title = "Roles", list = unavailable_context, apply = apply_context("role") },
	{
		key = "warehouse",
		command = "Warehouses",
		title = "Warehouses",
		list = unavailable_context,
		apply = apply_context("warehouse"),
	},
	{
		key = "database",
		command = "Databases",
		title = "Databases",
		list = unavailable_context,
		apply = apply_context("database"),
	},
	{ key = "schema", command = "Schemas", title = "Schemas", list = unavailable_context, apply = apply_context("schema") },
}

return M
