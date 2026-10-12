-- MongoDB backend driving mongosh. The script is delivered on standard input
-- because mongosh has no environment variable for a password and -p would put it
-- in the argv, visible system-wide.

local credentials = require("dbsh.credentials")
local aws = require("dbsh.aws")

local M = {}

M.name = "mongo"
M.script_delivery = "stdin"
M.tabular = false
M.contexts = {}
M.catalogs = {}

local required_fields = { "host", "username", "database" }

local function valid_argv(argv)
	if type(argv) ~= "table" or #argv == 0 then return false end
	for _, value in ipairs(argv) do
		if type(value) ~= "string" or value == "" then return false end
	end
	return true
end

local function valid_port(value)
	return type(value) == "number" and value > 0 and value < 65536 and value == math.floor(value)
end

local function valid_proxy(proxy)
	return type(proxy) == "table" and type(proxy.host) == "string" and proxy.host ~= ""
		and valid_port(proxy.port)
end

local function valid_aws_profile(connection)
	return type(connection.aws_profile) == "string" and connection.aws_profile ~= ""
		and type(connection.aws_account_id) == "string" and connection.aws_account_id ~= ""
		and type(connection.aws_role_name) == "string" and connection.aws_role_name ~= ""
end

function M.validate(connection)
	if type(connection) ~= "table" then return nil, "Mongo profile must be a table" end
	if connection.password ~= nil then return nil, "Mongo profile must not provide a password" end
	for _, key in ipairs({ "uri", "connection_string", "url" }) do
		if connection[key] ~= nil then return nil, "Mongo profile must not provide a connection string" end
	end
	for _, key in ipairs(required_fields) do
		if type(connection[key]) ~= "string" or connection[key] == "" then
			return nil, "Mongo profile requires a non-empty " .. key
		end
	end
	if connection.srv ~= true and not valid_port(connection.port) then
		return nil, "Mongo profile requires a valid port unless srv is true"
	end
	if not valid_proxy(connection.proxy) then
		return nil, "Mongo profile requires proxy = { host, port }; start one with ssh -D <port> <bastion>"
	end
	if connection.auth == "aws" then
		if connection.password_command ~= nil then
			return nil, "Mongo profile with auth=aws must not provide password_command"
		end
		if not valid_aws_profile(connection) then
			return nil, "Mongo profile with auth=aws requires aws_profile, aws_account_id and aws_role_name"
		end
	elseif connection.auth ~= nil and connection.auth ~= "password" then
		return nil, "Mongo profile auth must be \"password\" or \"aws\""
	else
		if not valid_argv(connection.password_command) then
			return nil, "Mongo profile requires password_command as a non-empty argv list"
		end
	end
	return true
end

local function percent_encode(value)
	return (tostring(value):gsub("[^%w%-%.%_%~]", function(char)
		return string.format("%%%02X", string.byte(char))
	end))
end

function M.uri(connection, password)
	local scheme = connection.srv == true and "mongodb+srv" or "mongodb"
	local host = connection.host
	if connection.srv ~= true then host = host .. ":" .. tostring(connection.port) end
	local options = {
		"proxyHost=" .. percent_encode(connection.proxy.host),
		"proxyPort=" .. tostring(connection.proxy.port),
	}
	if connection.tls ~= false then table.insert(options, "tls=true") end
	if type(connection.replica_set) == "string" and connection.replica_set ~= "" then
		table.insert(options, "replicaSet=" .. percent_encode(connection.replica_set))
	end
	if connection.auth == "aws" then
		table.insert(options, "authMechanism=MONGODB-AWS")
		table.insert(options, "authSource=" .. percent_encode(connection.auth_source or "$external"))
		return string.format("%s://%s@%s/?%s", scheme, percent_encode(connection.username),
			host, table.concat(options, "&"))
	end
	table.insert(options, "authSource=" .. percent_encode(connection.auth_source or "admin"))
	return string.format("%s://%s:%s@%s/?%s", scheme, percent_encode(connection.username),
		percent_encode(password or ""), host, table.concat(options, "&"))
end

local function credential_key(snapshot)
	if type(snapshot.connection_name) == "string" and snapshot.connection_name ~= "" then
		return "mongo:" .. snapshot.connection_name
	end
	return table.concat({ "mongo", snapshot.connection.host, snapshot.connection.username }, ":")
end

local function aws_credential_key(snapshot)
	local base = credential_key(snapshot)
	return base .. ":aws:" .. snapshot.connection.aws_profile
		.. ":" .. snapshot.connection.aws_account_id
		.. ":" .. snapshot.connection.aws_role_name
end

function M.prepare(snapshot, options, callback)
	local connection = snapshot.connection
	local valid, err = M.validate(connection)
	if valid == nil then callback(nil, err); return end
	if connection.auth == "aws" then
		local key = aws_credential_key(snapshot)
		aws.resolve(key, connection.aws_profile, connection.aws_account_id, connection.aws_role_name, {
			cache_ttl_ms = ((options or {}).credentials or {}).cache_ttl_ms,
		}, function(creds, resolve_err)
			if resolve_err ~= nil then callback(nil, resolve_err); return end
			callback({ aws = creds, credential_backed = true, credential_key = key }, nil)
		end)
		return
	end
	local key = credential_key(snapshot)
	credentials.resolve(key, connection.password_command, {
		cache_ttl_ms = ((options or {}).credentials or {}).cache_ttl_ms,
	}, function(password, resolve_err)
		if resolve_err ~= nil then callback(nil, resolve_err); return end
		callback({ password = password, credential_backed = true, credential_key = key }, nil)
	end)
end

function M.preamble() return "" end

local function js_literal(value)
	return vim.json.encode(value)
end

function M.compose(text, mode, connection, runtime)
	local password = nil
	if connection.auth ~= "aws" then
		password = (type(runtime) == "table" and runtime.password) or ""
	end
	local printer = "printjson(__dbsh_result);"
	if mode == "raw" then
		printer = "print(EJSON.stringify(__dbsh_result, null, 0, { relaxed: true }));"
	end
	return table.concat({
		"const __dbsh_conn = Mongo(" .. js_literal(M.uri(connection, password)) .. ");",
		"db = __dbsh_conn.getDB(" .. js_literal(connection.database) .. ");",
		"const __dbsh_src = " .. js_literal(text) .. ";",
		"let __dbsh_result = eval(__dbsh_src);",
		'if (__dbsh_result && typeof __dbsh_result.toArray === "function") {',
		"\t__dbsh_result = __dbsh_result.toArray();",
		"}",
		printer,
		"",
	}, "\n")
end

function M.argv(_, script_path)
	return { "mongosh", "--nodb", "--quiet", "--norc", "--file", script_path }
end

function M.env(connection, _, runtime)
	if connection.auth ~= "aws" then return {} end
	if type(runtime) ~= "table" or type(runtime.aws) ~= "table" then return {} end
	local creds = runtime.aws
	return {
		AWS_ACCESS_KEY_ID = creds.access_key_id,
		AWS_SECRET_ACCESS_KEY = creds.secret_access_key,
		AWS_SESSION_TOKEN = creds.session_token,
	}
end

function M.parse_raw(stdout)
	local text = vim.trim(stdout or "")
	if text == "" then return {} end
	local ok, decoded = pcall(vim.json.decode, text)
	if not ok or type(decoded) ~= "table" then
		return nil, "mongosh output could not be parsed as EJSON"
	end
	if decoded[1] == nil and next(decoded) ~= nil then return { decoded } end
	return decoded
end

local READ_METHODS = {
	find = true, findOne = true, countDocuments = true, estimatedDocumentCount = true,
	aggregate = true, distinct = true, getIndexes = true, explain = true, stats = true,
	listCollections = true,
}

local CHAIN_METHODS = {
	limit = true, skip = true, sort = true, project = true, toArray = true, pretty = true,
	hint = true, explain = true, count = true, itcount = true, batchSize = true,
	collation = true, allowDiskUse = true, maxTimeMS = true, readPref = true,
}

local function strip_literals(text)
	local out, index = {}, 1
	while index <= #text do
		local char = text:sub(index, index)
		if char == '"' or char == "'" or char == string.char(96) then
			index = index + 1
			while index <= #text do
				local inner = text:sub(index, index)
				if inner == "\\" then index = index + 2
				elseif inner == char then index = index + 1; break
				else index = index + 1 end
			end
			table.insert(out, '""')
		else
			table.insert(out, char)
			index = index + 1
		end
	end
	return table.concat(out)
end

local function called_methods(text)
	local names = {}
	for name in text:gmatch("[%.%s]([%a_][%w_]*)%s*%(") do table.insert(names, name) end
	return names
end

function M.classify(text)
	local stripped = strip_literals(vim.trim(text or ""))
	if stripped == "" then return { action = "confirm", reason = "javascript" } end
	stripped = stripped:gsub(";%s*$", "")
	if stripped:find(";", 1, true) then return { action = "confirm", reason = "multiple_statements" } end
	if stripped:find("=>", 1, true) or stripped:find("function", 1, true)
		or stripped:find("[^=!<>]=[^=]") then
		return { action = "confirm", reason = "javascript" }
	end
	local names = called_methods(stripped)
	if #names == 0 or not READ_METHODS[names[1]] then
		return { action = "confirm", reason = "javascript" }
	end
	for index = 2, #names do
		if not CHAIN_METHODS[names[index]] then return { action = "confirm", reason = "javascript" } end
	end
	return { action = "run", reason = "read" }
end

function M.is_authentication_error(stderr, stdout)
	local haystack = ((stderr or "") .. "\n" .. (stdout or "")):lower()
	return haystack:find("authentication failed", 1, true) ~= nil
		or haystack:find("bad auth", 1, true) ~= nil
		or haystack:find("aws credentials", 1, true) ~= nil
		or haystack:find("mongomissingcredentialserror", 1, true) ~= nil
end

return M
