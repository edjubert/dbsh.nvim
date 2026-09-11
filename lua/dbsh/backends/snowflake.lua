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

local function top_level_array_values(input)
	local index = skip_whitespace(input, 1)
	if input:sub(index, index) ~= "[" then
		return nil
	end
	index = skip_whitespace(input, index + 1)
	local values = {}
	while index <= #input do
		if input:sub(index, index) == "]" then
			return values
		end
		local start = index
		index = skip_json_value(input, index)
		if index == nil then
			return nil
		end
		table.insert(values, input:sub(start, index - 1))
		index = skip_whitespace(input, index)
		if input:sub(index, index) == "]" then
			return values
		end
		if input:sub(index, index) ~= "," then
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
	local source = stdout or ""
	local result_sources = top_level_array_values(source)
	if result_sources ~= nil
		and #result_sources == #payload
		and result_sources[1] ~= nil
		and result_sources[1]:match("^%s*%[") ~= nil then
		payload = payload[#payload]
		source = result_sources[#result_sources]
	end
	local keys = ordered_object_keys(source)
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

local function quote_ident(value)
	return '"' .. tostring(value):gsub('"', '""') .. '"'
end

local function quote_literal(value)
	return "'" .. tostring(value):gsub("'", "''") .. "'"
end

local function filtered_literal(value)
	local escaped = tostring(value or "")
	escaped = escaped:gsub("!", "!!")
	escaped = escaped:gsub("%%", "!%%")
	escaped = escaped:gsub("_", "!_")
	return quote_literal(escaped)
end

local function context_level(request, key)
	local context = request.context or {}
	return (context.levels or {})[key] or context[key]
end

local function valid_limit(value)
	return type(value) == "number" and value > 0 and value == math.floor(value)
end

local function decode_cursor(cursor, length)
	if cursor == nil then
		return nil
	end
	local ok, values = pcall(vim.json.decode, cursor)
	if not ok or type(values) ~= "table" or #values ~= length then
		return nil, "malformed Snowflake catalog cursor"
	end
	for _, value in ipairs(values) do
		if type(value) ~= "string" then
			return nil, "malformed Snowflake catalog cursor"
		end
	end
	return values
end

local function keyset_predicate(fields, values)
	if values == nil then
		return nil
	end
	local alternatives = {}
	for index, field in ipairs(fields) do
		local terms = {}
		for previous = 1, index - 1 do
			table.insert(terms, fields[previous] .. " = " .. quote_literal(values[previous]))
		end
		table.insert(terms, field .. " > " .. quote_literal(values[index]))
		table.insert(alternatives, "(" .. table.concat(terms, " AND ") .. ")")
	end
	return "(" .. table.concat(alternatives, " OR ") .. ")"
end

local function info_schema_query(spec, request)
	local database = context_level(request, "database")
	if type(database) ~= "string" or database == "" then
		return nil, "Snowflake catalog requires a database context"
	end
	if not valid_limit(request.limit) then
		return nil, "Snowflake catalog requires a positive page size"
	end

	local where = {}
	for _, predicate in ipairs(spec.where or {}) do
		table.insert(where, predicate)
	end
	local scope = request.scope or {}
	if spec.scoped and not scope.all_schemas and type(scope.schema) == "string" and scope.schema ~= "" then
		table.insert(where, spec.schema_column .. " = " .. quote_literal(scope.schema))
	end
	if request.query ~= nil and request.query ~= "" then
		table.insert(
			where,
			spec.name_column .. " ILIKE '%' || " .. filtered_literal(request.query) .. " || '%' ESCAPE '!'"
		)
	end

	local cursor_fields = spec.scoped and { spec.schema_column, spec.name_column } or { spec.name_column }
	local cursor, cursor_err = decode_cursor(request.cursor, #cursor_fields)
	if cursor_err ~= nil then
		return nil, cursor_err
	end
	local predicate = keyset_predicate(cursor_fields, cursor)
	if predicate ~= nil then
		table.insert(where, predicate)
	end
	if #where == 0 then
		table.insert(where, "TRUE")
	end

	local select = {}
	if spec.scoped then
		table.insert(select, spec.schema_column .. " AS schema_name")
	end
	table.insert(select, spec.name_column .. " AS name")
	table.insert(select, (spec.kind_column or quote_literal(spec.kind)) .. " AS object_type")
	return table.concat({
		"SELECT " .. table.concat(select, ", "),
		"FROM " .. quote_ident(database) .. ".INFORMATION_SCHEMA." .. spec.source,
		"WHERE " .. table.concat(where, "\n  AND "),
		"ORDER BY " .. table.concat(cursor_fields, ", "),
		"LIMIT " .. tostring(request.limit + 1) .. ";",
	}, "\n")
end

local function show_query(spec, request)
	if not valid_limit(request.limit) then
		return nil, "Snowflake catalog requires a positive page size"
	end
	local show = spec.show
	if spec.show_scoped then
		local database = context_level(request, "database")
		if type(database) ~= "string" or database == "" then
			return nil, "Snowflake catalog requires a database context"
		end
		local scope = request.scope or {}
		if not scope.all_schemas and type(scope.schema) == "string" and scope.schema ~= "" then
			show = show .. " IN SCHEMA " .. quote_ident(database) .. "." .. quote_ident(scope.schema)
		else
			show = show .. " IN DATABASE " .. quote_ident(database)
		end
	end
	local where = {}
	if request.query ~= nil and request.query ~= "" then
		table.insert(where, '"name" ILIKE \'%\' || ' .. filtered_literal(request.query) .. " || '%' ESCAPE '!'")
	end
	local cursor, cursor_err = decode_cursor(request.cursor, 1)
	if cursor_err ~= nil then
		return nil, cursor_err
	end
	local predicate = keyset_predicate({ '"name"' }, cursor)
	if predicate ~= nil then
		table.insert(where, predicate)
	end
	if #where == 0 then
		table.insert(where, "TRUE")
	end
	return table.concat({
		show .. ";",
		"SELECT \"name\" AS name, " .. quote_literal(spec.kind) .. " AS object_type",
		"FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))",
		"WHERE " .. table.concat(where, "\n  AND "),
		"ORDER BY \"name\"",
		"LIMIT " .. tostring(request.limit + 1) .. ";",
	}, "\n")
end

local catalog_specs = {
	roles = { kind = "role", show = "SHOW ROLES", scope = false, query = show_query },
	warehouses = { kind = "warehouse", show = "SHOW WAREHOUSES", scope = false, query = show_query },
	databases = { kind = "database", show = "SHOW DATABASES", scope = false, query = show_query },
	schemas = {
		kind = "schema",
		source = "SCHEMATA",
		name_column = "SCHEMA_NAME",
		scope = false,
		query = info_schema_query,
	},
	relations = {
		kind = "relation",
		source = "TABLES",
		schema_column = "TABLE_SCHEMA",
		name_column = "TABLE_NAME",
		kind_column = "TABLE_TYPE",
		where = { "TABLE_TYPE IN ('BASE TABLE', 'VIEW', 'MATERIALIZED VIEW', 'DYNAMIC TABLE')" },
		scoped = true,
		row_has_schema = true,
		query = info_schema_query,
	},
	routines = {
		kind = "routine",
		show = "SHOW USER FUNCTIONS",
		scoped = true,
		show_scoped = true,
		query = show_query,
	},
	sequences = {
		kind = "sequence",
		source = "SEQUENCES",
		schema_column = "SEQUENCE_SCHEMA",
		name_column = "SEQUENCE_NAME",
		scoped = true,
		row_has_schema = true,
		query = info_schema_query,
	},
	stages = {
		kind = "stage",
		source = "STAGES",
		schema_column = "STAGE_SCHEMA",
		name_column = "STAGE_NAME",
		scoped = true,
		row_has_schema = true,
		query = info_schema_query,
	},
	file_formats = {
		kind = "file format",
		source = "FILE_FORMATS",
		schema_column = "FILE_FORMAT_SCHEMA",
		name_column = "FILE_FORMAT_NAME",
		scoped = true,
		row_has_schema = true,
		query = info_schema_query,
	},
	streams = {
		kind = "stream",
		show = "SHOW STREAMS",
		scoped = true,
		show_scoped = true,
		query = show_query,
	},
	tasks = {
		kind = "task",
		show = "SHOW TASKS",
		scoped = true,
		show_scoped = true,
		query = show_query,
	},
	pipes = {
		kind = "pipe",
		source = "PIPES",
		schema_column = "PIPE_SCHEMA",
		name_column = "PIPE_NAME",
		scoped = true,
		row_has_schema = true,
		query = info_schema_query,
	},
}

function M.catalog_query(key, request)
	local spec = catalog_specs[key]
	if spec == nil then
		return nil, "unknown Snowflake catalog"
	end
	return spec.query(spec, request)
end

local function fetch(sql, callback)
	local exec = require("dbsh.exec")
	exec.run(sql, { mode = "raw", slot = "introspect" }, function(code, stdout, stderr)
		if code ~= 0 then
			callback(nil, stderr ~= "" and stderr or "snow sql failed")
			return
		end
		local rows, err = M.parse_raw(stdout)
		if rows == nil then
			callback(nil, err)
			return
		end
		callback(rows, nil)
	end)
end

local function object_item(spec, request, row)
	local database = context_level(request, "database")
	local schema, name, object_type
	if spec.row_has_schema then
		schema, name, object_type = row[1], row[2], row[3]
	else
		name, object_type = row[1], row[2]
	end
	local identity = { database = database, schema = schema, name = name }
	local value = {
		kind = spec.kind,
		database = database,
		schema = schema,
		name = name,
		relation_type = object_type,
		identity = identity,
	}
	local qualified = schema ~= nil and schema .. "." .. name or name
	return {
		value = value,
		display = string.format("%s  [%s]", qualified, object_type ~= "" and object_type or spec.kind),
		ordinal = string.format("%s %s", qualified:gsub("%.", " "), spec.kind),
	}
end

local function list_catalog(key)
	return function(request, callback)
		local spec = catalog_specs[key]
		local sql, err = M.catalog_query(key, request)
		if sql == nil then
			callback(nil, err)
			return
		end
		fetch(sql, function(rows, fetch_err)
			if rows == nil then
				callback(nil, fetch_err)
				return
			end
			local items = {}
			for index = 1, math.min(#rows, request.limit) do
				table.insert(items, object_item(spec, request, rows[index]))
			end
			local next_cursor
			if #rows > request.limit then
				local row = rows[request.limit]
				next_cursor = vim.json.encode(spec.row_has_schema and { row[1], row[2] } or { row[1] })
			end
			callback({ items = items, next_cursor = next_cursor }, nil)
		end)
	end
end

local function context_list(key)
	local list = list_catalog(key)
	return function(request, callback)
		list(request, function(page, err)
			if page == nil then
				callback(nil, err)
				return
			end
			local items = {}
			for _, item in ipairs(page.items) do
				table.insert(items, {
					value = item.value.name,
					display = item.value.name,
					ordinal = item.value.name,
				})
			end
			callback({ items = items, next_cursor = page.next_cursor }, nil)
		end)
	end
end

local function apply_context(key)
	return function(snapshot, value)
		return require("dbsh.context").apply(snapshot, key, value, "catalog")
	end
end

local function select_relation(item)
	local object = type(item.value) == "table" and item.value or item
	if object.database == nil or object.schema == nil or object.name == nil then
		return
	end
	local config = require("dbsh.config")
	require("dbsh").query(string.format(
		"SELECT * FROM %s.%s.%s LIMIT %d;",
		quote_ident(object.database),
		quote_ident(object.schema),
		quote_ident(object.name),
		config.options().preview_limit
	))
end

M.catalogs = {
	{ key = "roles", command = "Roles", title = "Roles", list = list_catalog("roles"), scope = false },
	{
		key = "warehouses",
		command = "Warehouses",
		title = "Warehouses",
		list = list_catalog("warehouses"),
		scope = false,
	},
	{
		key = "databases",
		command = "Databases",
		title = "Databases",
		list = list_catalog("databases"),
		scope = false,
	},
	{ key = "schemas", command = "Schemas", title = "Schemas", list = list_catalog("schemas"), scope = false },
	{
		key = "relations",
		command = "Relations",
		title = "Relations",
		list = list_catalog("relations"),
		on_select = select_relation,
		scope = true,
	},
	{
		key = "routines",
		command = "Functions",
		title = "Functions",
		list = list_catalog("routines"),
		scope = true,
		definition = true,
	},
	{
		key = "sequences",
		command = "Sequences",
		title = "Sequences",
		list = list_catalog("sequences"),
		scope = true,
		definition = true,
	},
	{
		key = "stages",
		command = "Stages",
		title = "Stages",
		list = list_catalog("stages"),
		scope = true,
		definition = true,
	},
	{
		key = "file_formats",
		command = "FileFormats",
		title = "File formats",
		list = list_catalog("file_formats"),
		scope = true,
		definition = true,
	},
	{
		key = "streams",
		command = "Streams",
		title = "Streams",
		list = list_catalog("streams"),
		scope = true,
		definition = true,
	},
	{
		key = "tasks",
		command = "Tasks",
		title = "Tasks",
		list = list_catalog("tasks"),
		scope = true,
		definition = true,
	},
	{
		key = "pipes",
		command = "Pipes",
		title = "Pipes",
		list = list_catalog("pipes"),
		scope = true,
		definition = true,
	},
}

M.contexts = {
	{ key = "role", command = "Roles", title = "Roles", list = context_list("roles"), apply = apply_context("role") },
	{
		key = "warehouse",
		command = "Warehouses",
		title = "Warehouses",
		list = context_list("warehouses"),
		apply = apply_context("warehouse"),
	},
	{
		key = "database",
		command = "Databases",
		title = "Databases",
		list = context_list("databases"),
		apply = apply_context("database"),
	},
	{ key = "schema", command = "Schemas", title = "Schemas", list = context_list("schemas"), apply = apply_context("schema") },
}

function M.definition_request(snapshot, object)
	if type(object) ~= "table" or object.kind ~= "relation" then
		return nil, "definition is not available for this object kind"
	end
	local database = object.database or (snapshot.levels or {}).database
	if type(database) ~= "string"
		or type(object.schema) ~= "string"
		or type(object.name) ~= "string" then
		return nil, "definition requires a qualified Snowflake relation"
	end
	local relation_type = {
		["BASE TABLE"] = "TABLE",
		["VIEW"] = "VIEW",
		["MATERIALIZED VIEW"] = "MATERIALIZED VIEW",
		["DYNAMIC TABLE"] = "DYNAMIC TABLE",
	}
	local object_type = relation_type[object.relation_type] or "TABLE"
	local qualified = table.concat({ database, object.schema, object.name }, ".")
	return {
		kind = "sql",
		sql = "SELECT GET_DDL(" .. quote_literal(object_type) .. ", " .. quote_literal(qualified) .. ");",
		parse = function(stdout)
			local rows = M.parse_raw(stdout)
			if rows == nil or rows[1] == nil or rows[1][1] == nil then
				return nil, "definition output could not be parsed"
			end
			return rows[1][1], nil
		end,
	}
end

return M
