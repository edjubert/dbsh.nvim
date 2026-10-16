-- MongoDB backend driving mongosh. The script is delivered on standard input
-- because mongosh has no environment variable for a password and -p would put it
-- in the argv, visible system-wide.

local credentials = require("dbsh.credentials")
local aws = require("dbsh.aws")

local M = {}

M.name = "mongo"
M.filetype = "javascript"
M.extension = "js"
M.script_delivery = "stdin"
M.tabular = false

local required_fields = { "host", "database" }

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
	if connection.proxy ~= nil and not valid_proxy(connection.proxy) then
		return nil, "Mongo profile proxy must be { host, port }; start one with ssh -D <port> <bastion>"
	end
	if connection.auth == "aws" then
		if connection.password_command ~= nil then
			return nil, "Mongo profile with auth=aws must not provide password_command"
		end
		if type(connection.aws_profile) ~= "string" or connection.aws_profile == "" then
			return nil, "Mongo profile with auth=aws requires aws_profile"
		end
		if connection.auth_source ~= nil and connection.auth_source ~= "$external" then
			return nil, "Mongo profile with auth=aws requires auth_source=$external"
		end
	elseif connection.auth ~= nil and connection.auth ~= "password" then
		return nil, "Mongo profile auth must be \"password\" or \"aws\""
	else
		if type(connection.username) ~= "string" or connection.username == "" then
			return nil, "Mongo profile requires a non-empty username"
		end
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
	local options = {}
	if connection.proxy ~= nil then
		table.insert(options, "proxyHost=" .. percent_encode(connection.proxy.host))
		table.insert(options, "proxyPort=" .. tostring(connection.proxy.port))
	end
	if connection.tls ~= false then table.insert(options, "tls=true") end
	if type(connection.replica_set) == "string" and connection.replica_set ~= "" then
		table.insert(options, "replicaSet=" .. percent_encode(connection.replica_set))
	end
	if connection.auth == "aws" then
		table.insert(options, "authMechanism=MONGODB-AWS")
		table.insert(options, "authSource=" .. percent_encode("$external"))
		if type(connection.read_preference) == "string" and connection.read_preference ~= "" then
			table.insert(options, "readPreference=" .. percent_encode(connection.read_preference))
		end
		-- AWS URI userinfo means access key and secret key, not an IAM role ARN.
		-- Omitting it makes mongosh resolve the credentials from its environment.
		return string.format("%s://%s/?%s", scheme, host, table.concat(options, "&"))
	end
	table.insert(options, "authSource=" .. percent_encode(connection.auth_source or "admin"))
	return string.format("%s://%s:%s@%s/?%s", scheme, percent_encode(connection.username),
		percent_encode(password or ""), host, table.concat(options, "&"))
end

local function credential_key(snapshot)
	if type(snapshot.connection_name) == "string" and snapshot.connection_name ~= "" then
		return "mongo:" .. snapshot.connection_name
	end
	return table.concat({ "mongo", snapshot.connection.host, snapshot.connection.username or "" }, ":")
end

local function aws_credential_key(snapshot)
	local base = credential_key(snapshot)
	return base .. ":aws:" .. snapshot.connection.aws_profile
end

function M.prepare(snapshot, options, callback)
	local connection = snapshot.connection
	local valid, err = M.validate(connection)
	if valid == nil then callback(nil, err); return end
	if connection.auth == "aws" then
		local key = aws_credential_key(snapshot)
		return aws.resolve(key, connection.aws_profile, {
			cache_ttl_ms = ((options or {}).credentials or {}).cache_ttl_ms,
		}, function(creds, resolve_err)
			if resolve_err ~= nil then callback(nil, resolve_err); return end
			callback({ aws = creds, credential_backed = true, credential_key = key }, nil)
		end)
	end
	local key = credential_key(snapshot)
	credentials.resolve(key, connection.password_command, {
		cache_ttl_ms = ((options or {}).credentials or {}).cache_ttl_ms,
	}, function(password, resolve_err)
		if resolve_err ~= nil then callback(nil, resolve_err); return end
		callback({ password = password, credential_backed = true, credential_key = key }, nil)
	end)
end

function M.invalidate_credentials(connection, key)
	if connection.auth == "aws" then
		aws.invalidate(key)
	else
		credentials.invalidate(key)
	end
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
		"(async () => {",
		"const __dbsh_conn = await Mongo(" .. js_literal(M.uri(connection, password)) .. ");",
		"db = __dbsh_conn.getDB(" .. js_literal(connection.database) .. ");",
		"const __dbsh_src = " .. js_literal(text) .. ";",
		"let __dbsh_result = await eval(__dbsh_src);",
		'if (__dbsh_result && typeof __dbsh_result.toArray === "function") {',
		"\t__dbsh_result = await __dbsh_result.toArray();",
		"}",
		printer,
		"})();",
		"",
	}, "\n")
end

function M.argv(connection, script_path)
	local argv = { "mongosh", "--nodb", "--quiet", "--norc", "--file", script_path }
	if connection.auth == "aws" then
		-- The SDK prioritizes AWS_PROFILE over exported credentials. Remove it
		-- in the child without changing Neovim's environment or exposing keys.
		argv = vim.list_extend({ "env", "-u", "AWS_PROFILE", "-u", "AWS_DEFAULT_PROFILE" }, argv)
	end
	return argv
end

function M.env(connection, _, runtime)
	if connection.auth ~= "aws" then return {} end
	if type(runtime) ~= "table" or type(runtime.aws) ~= "table" then return {} end
	local creds = runtime.aws
	return {
		AWS_ACCESS_KEY_ID = creds.access_key_id,
		AWS_SECRET_ACCESS_KEY = creds.secret_access_key,
		AWS_SESSION_TOKEN = creds.session_token or "",
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

M.csv_mode = "raw"
function M.csv_output(stdout, delimiter)
	local documents, err = M.parse_raw(stdout)
	if documents == nil then return nil, err end
	return require("dbsh.csv").documents_to_csv(documents, delimiter)
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
	-- getCollection is an accessor, not a read itself. Only accept its
	-- literal-name form followed by the same read/chain rules as db.users.
	if stripped:match('^db%s*%.%s*getCollection%s*%(%s*""%s*%)%s*%.') then
		table.remove(names, 1)
	end
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

local function name_filter(query)
	if query == nil or query == "" then return {} end
	local escaped = query:gsub(".", function(char)
		if ("\\^$.*+?()[]{}|"):find(char, 1, true) then return "\\" .. char end
		return char
	end)
	return { name = { ["$regex"] = escaped, ["$options"] = "i" } }
end

function M.catalog_query(key, request)
	if key == "databases" then
		-- Mongo selects the command from the first BSON key. A Lua table's
		-- JSON key order is unspecified, so encode optional values separately.
		local command = '{"listDatabases":1,"nameOnly":true,"authorizedDatabases":true'
		local filter = name_filter(request.query)
		if next(filter) ~= nil then
			command = command .. ',"filter":' .. js_literal(filter)
		end
		return "db.adminCommand(" .. command .. "})"
	elseif key == "collections" then
		local filter = name_filter(request.query)
		return "db.getCollectionInfos(" .. (next(filter) and js_literal(filter) or "{}") .. ", true, true)"
	elseif key == "indexes" then
		local relation = request.relation
		if type(relation) ~= "table" or type(relation.name) ~= "string" or relation.name == "" then
			return nil, "Mongo indexes require a collection"
		end
		if relation.database ~= request.context.database then
			return nil, "Mongo collection belongs to another database"
		end
		return "db.getCollection(" .. js_literal(relation.name) .. ").getIndexes()"
	end
	return nil, "unknown Mongo catalog"
end

-- Mongo's inventory APIs have no sorted LIMIT/keyset operation. Only metadata
-- is fetched; filtering and deterministic name pagination belong to this
-- backend. Database/collection filters also run on the server.
local function list_catalog(key, paginated)
	return function(request, callback)
		local after
		if request.cursor ~= nil then
			local ok, cursor = pcall(vim.json.decode, request.cursor)
			if not ok or type(cursor) ~= "table" or type(cursor.name) ~= "string" then
				callback(nil, "invalid Mongo catalog cursor")
				return
			end
			after = cursor.name
		end
		local query, query_err = M.catalog_query(key, request)
		if query == nil then callback(nil, query_err); return end
		local context = require("dbsh.context")
		local snapshot = context.snapshot(request.context.bufnr)
		if snapshot.id ~= request.context.id or snapshot.generation ~= request.context.generation then
			callback(nil, "Mongo catalog context changed")
			return
		end
		require("dbsh.exec").run(query, {
			context = snapshot, mode = "raw", slot = "introspect",
		}, function(code, stdout, stderr)
			if code ~= 0 then
				-- Never surface a CLI error that might contain a credential URI.
				local output = (stderr or "") .. (stdout or "")
				local message = "Mongo catalog request failed"
				if output:find("not authorized", 1, true) or output:find("Unauthorized", 1, true) then
					message = "Mongo catalog access denied for the current database"
				elseif M.is_authentication_error(stderr, stdout) then
					message = "Mongo catalog authentication failed; refresh your credentials"
				else
					local category = output:match("(Mongo[%w]+Error)")
						or output:match("(TypeError)") or output:match("(SyntaxError)")
					message = message .. " (" .. (category or "process error")
						.. ", exit " .. tostring(code) .. ")"
				end
				callback(nil, message)
				return
			end
			local rows, parse_err = M.parse_raw(stdout)
			if rows == nil then callback(nil, parse_err); return end
			if key == "databases" then
				rows = rows[1] and rows[1].databases
				if type(rows) ~= "table" then
					callback(nil, "invalid Mongo database inventory")
					return
				end
			end
			local matching = {}
			local filter = (request.query or ""):lower()
			for _, row in ipairs(rows) do
				if type(row) ~= "table" or type(row.name) ~= "string" then
					callback(nil, "invalid Mongo catalog entry")
					return
				end
				if (after == nil or row.name > after) and row.name:lower():find(filter, 1, true) then
					table.insert(matching, row)
				end
			end
			table.sort(matching, function(a, b) return a.name < b.name end)
			local items = {}
			local limit = paginated == false and #matching or request.limit
			for index = 1, math.min(#matching, limit) do
				local row = matching[index]
				if key == "databases" then
					table.insert(items, { value = row.name, display = row.name })
				else
					local object = {
						kind = key == "collections" and (row.type or "collection") or "index",
						database = request.context.database,
						name = row.name,
						collection = request.relation and request.relation.name,
						spec = key == "indexes" and row or nil,
					}
					local detail = key == "indexes" and js_literal(row.key or {}) or object.kind
					table.insert(items, {
						value = object, display = row.name .. "  [" .. detail .. "]",
					})
				end
			end
			local next_cursor
			if #matching > limit then
				next_cursor = js_literal({ name = matching[limit].name })
			end
			callback({ items = items, next_cursor = next_cursor }, nil)
		end)
	end
end

function M.preview_query(item, limit)
	local object = type(item.value) == "table" and item.value or item
	if type(limit) ~= "number" or limit < 1 or limit == math.huge or limit ~= math.floor(limit) then
		limit = 10
	end
	-- eval does not receive mongosh's async rewriting: find() returns a
	-- Promise there, so chaining .limit() would access it before the cursor.
	-- Supplying the limit in find options bounds the query on the server.
	return "db.getCollection(" .. js_literal(object.name) .. ").find({}, null, { limit: " .. tostring(limit) .. " })"
end

local function preview(item, snapshot, options)
	require("dbsh").query(M.preview_query(item, options.preview_limit), snapshot)
end

local function show_index(item, snapshot, options)
	local object = item.value
	local results = require("dbsh.results")
	local opts = { split = options.results_split }
	results.open(snapshot, { split = opts.split, focus = opts.split == "float" })
	results.render(snapshot, "db.getCollection(" .. js_literal(object.collection) .. ").getIndexes()",
		js_literal(object.spec), opts)
end

M.contexts = {
	{
		key = "database", command = "MongoDatabases", title = "Mongo databases",
		-- listDatabases already returns all names. Search the complete
		-- inventory in Telescope instead of spawning mongosh while typing.
		list = list_catalog("databases", false),
		apply = function(snapshot, value)
			return require("dbsh.context").apply(snapshot, "database", value, "mongo-catalog")
		end,
	},
}

M.catalogs = {
	{
		key = "collections", command = "MongoCollections", title = "Mongo collections",
		list = list_catalog("collections", false), scope = false, on_select = preview,
		inspect = function(item)
			return {
				{ display = "Preview", action = preview },
				{ display = "Indexes", catalog = "indexes", relation = item.value },
			}
		end,
	},
	{
		key = "indexes", command = "MongoIndexes", title = "Mongo indexes",
		list = list_catalog("indexes"), scope = false, parent = "collections", on_select = show_index,
	},
	{
		key = "preview", command = "MongoPreview", title = "Mongo preview",
		list = list_catalog("collections", false), scope = false, on_select = preview,
	},
}

return M
