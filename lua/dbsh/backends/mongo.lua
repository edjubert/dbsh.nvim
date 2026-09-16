-- MongoDB backend driving mongosh. The script is delivered on standard input
-- because mongosh has no environment variable for a password and -p would put it
-- in the argv, visible system-wide.

local credentials = require("dbsh.credentials")

local M = {}

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
	if not valid_argv(connection.password_command) then
		return nil, "Mongo profile requires password_command as a non-empty argv list"
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
		"authSource=" .. percent_encode(connection.auth_source or "admin"),
		"proxyHost=" .. percent_encode(connection.proxy.host),
		"proxyPort=" .. tostring(connection.proxy.port),
	}
	if connection.tls ~= false then table.insert(options, "tls=true") end
	if type(connection.replica_set) == "string" and connection.replica_set ~= "" then
		table.insert(options, "replicaSet=" .. percent_encode(connection.replica_set))
	end
	return string.format("%s://%s:%s@%s/?%s", scheme, percent_encode(connection.username),
		percent_encode(password), host, table.concat(options, "&"))
end

local function credential_key(snapshot)
	if type(snapshot.connection_name) == "string" and snapshot.connection_name ~= "" then
		return "mongo:" .. snapshot.connection_name
	end
	return table.concat({ "mongo", snapshot.connection.host, snapshot.connection.username }, ":")
end

function M.prepare(snapshot, options, callback)
	local connection = snapshot.connection
	local valid, err = M.validate(connection)
	if valid == nil then callback(nil, err); return end
	local key = credential_key(snapshot)
	credentials.resolve(key, connection.password_command, {
		cache_ttl_ms = ((options or {}).credentials or {}).cache_ttl_ms,
	}, function(password, resolve_err)
		if resolve_err ~= nil then callback(nil, resolve_err); return end
		callback({ password = password, credential_backed = true, credential_key = key }, nil)
	end)
end

function M.argv(_, script_path)
	return { "mongosh", "--nodb", "--quiet", "--norc", "--file", script_path }
end

function M.env() return {} end

function M.is_authentication_error(stderr, stdout)
	local haystack = ((stderr or "") .. "\n" .. (stdout or "")):lower()
	return haystack:find("authentication failed", 1, true) ~= nil
		or haystack:find("bad auth", 1, true) ~= nil
end

return M
