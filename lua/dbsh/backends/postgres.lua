-- The postgres backend: everything psql-specific, as data and pure functions.
-- No state lives here. The current connection and the generation counter stay
-- in dbsh.config, which this module must never require: config requires the
-- backend registry, and the cycle would close at load time.

local M = {}

M.name = "postgres"
-- "tabular": psql draws the table itself, and dbsh.csv parses the frame it draws.
M.shape = "tabular"
M.filetype = "sql"
M.extension = "sql"
M.table_border = "│"

local PRETTY_PREAMBLE = table.concat({
	"\\set QUIET 1",
	"\\timing on",
	"\\pset null (NULL)",
	"\\pset linestyle unicode",
	"\\pset border 2",
}, "\n")

local RAW_PREAMBLE = table.concat({
	"\\set QUIET 1",
	"\\set ON_ERROR_STOP 1",
}, "\n")

-- mode is "pretty" (decorated, meant for the user) or "raw" (parsable).
function M.preamble(mode)
	if mode == "raw" then
		return RAW_PREAMBLE
	end
	return PRETTY_PREAMBLE
end

-- -X ignores ~/.psqlrc, -w never prompts for a password: authentication is
-- delegated to ~/.pgpass through psql's own resolution.
function M.argv(conn, script_path, mode)
	local argv = {
		"psql", "-X", "-w",
		"-h", conn.host,
		"-p", tostring(conn.port),
		"-U", conn.username,
		"-d", conn.database,
	}
	if mode == "raw" then
		vim.list_extend(argv, { "-A", "-t", "-F", "\t" })
	end
	vim.list_extend(argv, { "-f", script_path })
	return argv
end

-- options is the table dbsh.config.options() returns, handed over by the
-- caller rather than required here.
function M.env(conn, options)
	return { PGCONNECT_TIMEOUT = tostring((options or {}).connect_timeout or 5) }
end

-- The language server dbsh steers for this backend, and how to talk to it.
-- Absent on a backend with no server: the caller then does nothing at all.
M.lsp = {
	client_name = "postgres_lsp",
	invalidate_command = "pgls.invalidateSchemaCache",
	-- Free-form: each server names its own settings. No password here -- the
	-- server merges only the fields it receives, so the one declared in the
	-- project file or in PGPASSWORD survives, and no secret ever reaches the
	-- Neovim LSP log.
	settings = function(conn, options)
		return {
			db = {
				host = conn.host,
				port = conn.port,
				username = conn.username,
				database = conn.database,
				connTimeoutSecs = (options or {}).connect_timeout or 5,
			},
		}
	end,
}

-- Raw mode output: one row per line, cells separated by a tab.
function M.parse_raw(stdout)
	local rows = {}
	for _, line in ipairs(vim.split(stdout or "", "\n", { plain = true })) do
		if line ~= "" then
			table.insert(rows, vim.split(line, "\t", { plain = true }))
		end
	end
	return rows
end

-- psql processes escape sequences inside a single-quoted \set argument.
-- Backslashes have to go first: doing the quotes first would then double
-- the backslashes this very step introduces.
local function escape_value(value)
	local escaped = tostring(value or "")
	escaped = (escaped:gsub("\\", "\\\\"))
	escaped = (escaped:gsub("'", "\\'"))
	return escaped
end

-- Substitution itself is left to psql, which interpolates :name from a \set
-- directive and, unlike a textual replacement, never touches the inside of a
-- quoted literal. Directives are line-oriented, hence the trailing newline on
-- each. An empty list gives an empty string, so concatenating this in front of
-- a query never shifts the line numbers psql reports on error.
function M.variable_preamble(names, values)
	values = values or {}
	local lines = {}
	for _, name in ipairs(names or {}) do
		table.insert(lines, string.format("\\set %s '%s'", name, escape_value(values[name] or "")))
	end
	if #lines == 0 then
		return ""
	end
	return table.concat(lines, "\n") .. "\n"
end

-- COPY ... TO STDOUT is used instead of the COPY meta-command: psql
-- meta-commands are line-oriented, which breaks on multi-line queries, and
-- COPY ... TO '<file>' would need a superuser right and write server side.
-- The inner query must not carry its trailing semicolon: COPY (SELECT 1;) is
-- a syntax error.
function M.export_query(query, delimiter)
	local inner = (vim.trim(query):gsub(";%s*$", ""))
	return string.format(
		"COPY (%s) TO STDOUT WITH (FORMAT CSV, HEADER, DELIMITER '%s');",
		inner,
		delimiter
	)
end

-- Double inner quotes so mixed-case names and reserved words survive.
function M.quote_ident(name)
	local escaped = (tostring(name):gsub('"', '""'))
	return '"' .. escaped .. '"'
end

local function quoted_value(value, escape_pattern)
	local escaped = tostring(value or "")
	escaped = (escaped:gsub("\\", "\\\\"))
	escaped = (escaped:gsub("'", "''"))
	if escape_pattern then
		escaped = (escaped:gsub("%%", "\\\\%%"))
		escaped = (escaped:gsub("_", "\\\\_"))
	end
	return "E'" .. escaped .. "'"
end

-- Catalog filters are values, never pieces of executable SQL. The E literal
-- makes the pattern escape explicit; %, _, and \ are escaped because the
-- generated query uses ILIKE ... ESCAPE E'\\'.
function M.quote_literal(value)
	return quoted_value(value, true)
end

local function quote_value(value)
	return quoted_value(value, false)
end

function M.encode_cursor(sort_values)
	return vim.json.encode(sort_values)
end

function M.decode_cursor(cursor, expected_length)
	if cursor == nil then
		return nil, nil
	end
	if type(cursor) ~= "string" then
		return nil, "malformed catalog cursor: expected an opaque JSON string"
	end
	local ok, values = pcall(vim.json.decode, cursor)
	if not ok or type(values) ~= "table" or #values ~= expected_length then
		return nil, "malformed catalog cursor"
	end
	for index = 1, expected_length do
		local value_type = type(values[index])
		if value_type ~= "string" and value_type ~= "number" then
			return nil, "malformed catalog cursor"
		end
	end
	return values, nil
end

-- item is a row of the relation level: { schema = ..., name = ..., kind = ... }.
function M.preview_query(item, limit)
	return string.format(
		"SELECT * FROM %s.%s LIMIT %d;",
		M.quote_ident(item.schema),
		M.quote_ident(item.name),
		limit or 10
	)
end

M.queries = {
	databases = "SELECT datname FROM pg_catalog.pg_database "
		.. "WHERE datallowconn AND NOT datistemplate ORDER BY 1;",

	schemas = "SELECT nspname FROM pg_catalog.pg_namespace "
		.. "WHERE nspname !~ '^pg_' AND nspname <> 'information_schema' ORDER BY 1;",

	tables = table.concat({
		"SELECT n.nspname, c.relname, c.relkind",
		"FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace",
		"WHERE c.relkind IN ('r','v','m','p')",
		"  AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'",
		"ORDER BY 1, 2;",
	}, "\n"),
}

-- Deferred require: dbsh.exec requires dbsh.config, which requires the backend
-- registry, which requires this module. Requiring it at load time would close
-- that cycle.
local function fetch(sql, request, callback)
	local exec = require("dbsh.exec")
	-- Its own slot, so opening a picker never cancels a running user query.
	exec.run(sql, {
		mode = "raw",
		slot = "introspect",
	}, function(code, stdout, stderr)
		if code ~= 0 then
			callback(nil, stderr ~= "" and stderr or "psql exited with code " .. tostring(code))
			return
		end
		callback(M.parse_raw(stdout), nil)
	end)
end

local KINDS = {
	r = "table",
	v = "view",
	m = "matview",
	p = "partitioned",
	f = "foreign table",
}

function M.kind_label(relkind)
	return KINDS[relkind] or relkind
end

local function list_names(sql, request, callback)
	fetch(sql, request, function(rows, err)
		if err ~= nil then
			callback(nil, err)
			return
		end
		local items = {}
		for _, row in ipairs(rows) do
			table.insert(items, { value = row[1], display = row[1], ordinal = row[1] })
		end
		callback({ items = items, next_cursor = nil }, nil)
	end)
end

local function apply_context(key)
	return function(snapshot, value)
		return require("dbsh.context").apply(snapshot, key, value, "catalog")
	end
end

M.contexts = {
	{
		key = "database",
		command = "Databases",
		title = "Databases",
		list = function(request, callback)
			list_names(M.queries.databases, request, callback)
		end,
		apply = apply_context("database"),
	},
	{
		key = "schema",
		command = "Schemas",
		title = "Schemas",
		list = function(request, callback)
			list_names(M.queries.schemas, request, callback)
		end,
		apply = apply_context("schema"),
	},
}

local function selected_value(item)
	if type(item) == "table" and type(item.value) == "table" then
		return item.value
	end
	return item
end

local function select_relation(item)
	item = selected_value(item)
	local config = require("dbsh.config")
	require("dbsh").query(M.preview_query(item, config.options().preview_limit))
end

function M.definition_unavailable()
	vim.notify(
		"dbsh.nvim: definition unavailable until DbDefinitions is implemented",
		vim.log.levels.INFO
	)
end

local function object_item(value, display_name, label)
	return {
		value = value,
		display = string.format("%s  [%s]", display_name, label),
		ordinal = string.format("%s %s", display_name:gsub("%.", " "), label),
	}
end

local function relation_value(item)
	local value = selected_value(item)
	if type(value) ~= "table" or value.oid == nil then
		return nil
	end
	return {
		oid = tostring(value.oid),
		schema = value.schema,
		name = value.name,
	}
end

local function relation_item(row)
	local value = {
		kind = "relation",
		oid = row[4],
		schema = row[1],
		name = row[2],
		relkind = row[3],
	}
	return object_item(value, row[1] .. "." .. row[2], M.kind_label(row[3]))
end

local function column_item(row)
	local relation = { oid = row[3], schema = row[1], name = row[2] }
	local value = {
		kind = "column",
		relation = relation,
		attnum = row[5],
		schema = row[1],
		name = row[4],
		type = row[6],
		not_null = row[7] == "t",
		default = row[8] ~= "" and row[8] or nil,
	}
	return object_item(value, row[1] .. "." .. row[2] .. "." .. row[4], "column")
end

local function index_item(row)
	local value = {
		kind = "index",
		oid = row[3],
		schema = row[1],
		name = row[2],
		relation = { oid = row[4], schema = row[1], name = row[5] },
		unique = row[6] == "t",
		method = row[7],
	}
	return object_item(value, row[1] .. "." .. row[2], "index")
end

local function constraint_item(row)
	local value = {
		kind = "constraint",
		oid = row[3],
		schema = row[1],
		name = row[2],
		relation = { oid = row[4], schema = row[1], name = row[5] },
		constraint_type = row[6],
		definition = row[7],
	}
	return object_item(value, row[1] .. "." .. row[2], "constraint")
end

local function sequence_item(row)
	local value = {
		kind = "sequence",
		oid = row[3],
		schema = row[1],
		name = row[2],
	}
	return object_item(value, row[1] .. "." .. row[2], "sequence")
end

local function routine_item(row)
	local value = {
		kind = "routine",
		oid = row[3],
		schema = row[1],
		name = row[2],
		identity_arguments = row[4],
		routine_kind = row[5],
	}
	local signature = row[1] .. "." .. row[2] .. "(" .. row[4] .. ")"
	return object_item(value, signature, "routine")
end

local function type_item(row)
	local value = {
		kind = "type",
		oid = row[3],
		schema = row[1],
		name = row[2],
		type_kind = row[4],
		category = row[5],
	}
	return object_item(value, row[1] .. "." .. row[2], "type")
end

local function policy_item(row)
	local value = {
		kind = "policy",
		schema = row[1],
		name = row[2],
		relation = { oid = row[3], schema = row[1], name = row[4] },
		command = row[5],
		permissive = row[6] == "t",
	}
	return object_item(value, row[1] .. "." .. row[4] .. "." .. row[2], "policy")
end

local function trigger_item(row)
	local value = {
		kind = "trigger",
		oid = row[3],
		schema = row[1],
		name = row[2],
		relation = { oid = row[4], schema = row[1], name = row[5] },
		enabled = row[6],
	}
	return object_item(value, row[1] .. "." .. row[2], "trigger")
end

local function extension_item(row)
	local value = {
		kind = "extension",
		oid = row[3],
		schema = row[1],
		name = row[2],
		version = row[4],
	}
	return object_item(value, row[1] .. "." .. row[2], "extension")
end

local function dependency_item(row)
	local value = {
		kind = "dependency",
		oid = row[3],
		schema = row[1],
		name = row[2],
		dependency_type = row[4],
		relation = { oid = row[5] },
	}
	return object_item(value, row[1] .. "." .. row[2], "dependency")
end

local function cursor_sql_value(field, value)
	local text = tostring(value)
	if field.type == "oid" then
		if text:match("^%d+$") == nil then
			return nil
		end
		return quote_value(text) .. "::oid"
	end
	if field.type == "integer" then
		if text:match("^%d+$") == nil then
			return nil
		end
		return quote_value(text) .. "::integer"
	end
	return quote_value(text)
end

local function keyset_predicate(sort, values)
	local alternatives = {}
	for index, field in ipairs(sort) do
		local parts = {}
		for previous = 1, index - 1 do
			local literal = cursor_sql_value(sort[previous], values[previous])
			if literal == nil then
				return nil, "malformed catalog cursor"
			end
			table.insert(parts, sort[previous].sql .. " = " .. literal)
		end
		local literal = cursor_sql_value(field, values[index])
		if literal == nil then
			return nil, "malformed catalog cursor"
		end
		table.insert(parts, field.sql .. " > " .. literal)
		table.insert(alternatives, "(" .. table.concat(parts, " AND ") .. ")")
	end
	return "(" .. table.concat(alternatives, " OR ") .. ")", nil
end

local function query_for(spec, request)
	request = request or {}
	local where = vim.deepcopy(spec.where)
	local scope = request.scope or {}
	if spec.schema_column ~= nil and not scope.all_schemas and scope.schema ~= nil then
		table.insert(where, spec.schema_column .. " = " .. quote_value(scope.schema))
	end
	if request.query ~= nil and request.query ~= "" then
		table.insert(where, string.format(
			"%s ILIKE '%%' || %s || '%%' ESCAPE E'\\\\'",
			spec.filter_column,
			M.quote_literal(request.query)
		))
	end
	if request.relation ~= nil then
		local relation = relation_value(request.relation)
		if relation == nil or spec.relation_column == nil then
			return nil, "relation-scoped catalog requires a relation OID"
		end
		local oid = cursor_sql_value({ type = "oid" }, relation.oid)
		if oid == nil then
			return nil, "relation-scoped catalog requires a relation OID"
		end
		table.insert(where, spec.relation_column .. " = " .. oid)
	end

	local values, cursor_err = M.decode_cursor(request.cursor, #spec.sort)
	if cursor_err ~= nil then
		return nil, cursor_err
	end
	if values ~= nil then
		local predicate, predicate_err = keyset_predicate(spec.sort, values)
		if predicate_err ~= nil then
			return nil, predicate_err
		end
		table.insert(where, predicate)
	end

	local order = {}
	for _, field in ipairs(spec.sort) do
		table.insert(order, field.sql)
	end
	local limit = tonumber(request.limit) or 200
	if limit <= 0 or limit ~= math.floor(limit) then
		return nil, "catalog request requires a positive page size"
	end
	return table.concat({
		"SELECT " .. spec.select,
		"FROM " .. spec.from,
		"WHERE " .. table.concat(where, "\n  AND "),
		"ORDER BY " .. table.concat(order, ", "),
		"LIMIT " .. tostring(limit + 1) .. ";",
	}, "\n"), nil
end

local function paged_list(spec)
	return function(request, callback)
		local sql, query_err = query_for(spec, request)
		if query_err ~= nil then
			callback(nil, query_err)
			return
		end
		fetch(sql, request, function(rows, fetch_err)
			if fetch_err ~= nil then
				callback(nil, fetch_err)
				return
			end
			local limit = tonumber(request.limit) or 200
			local items = {}
			for index = 1, math.min(#rows, limit) do
				table.insert(items, spec.item(rows[index]))
			end
			local next_cursor
			if #rows > limit then
				local sentinel = rows[limit]
				local values = {}
				for index, row_index in ipairs(spec.cursor_rows) do
					values[index] = sentinel[row_index]
				end
				next_cursor = M.encode_cursor(values)
			end
			callback({ items = items, next_cursor = next_cursor }, nil)
		end)
	end
end

local function relation_actions(item)
	local relation = relation_value(item)
	if relation == nil then
		return {}
	end
	return {
		{ title = "Columns", catalog = "columns", relation = relation },
		{ title = "Indexes", catalog = "indexes", relation = relation },
		{ title = "Constraints", catalog = "constraints", relation = relation },
		{ title = "Triggers", catalog = "triggers", relation = relation },
		{ title = "Policies", catalog = "policies", relation = relation },
		{ title = "Dependencies", inspector = "dependencies", relation = relation },
		{ title = "Definition", action = M.definition_unavailable, relation = relation },
	}
end

local relation_sort = {
	{ sql = "n.nspname", type = "text" },
	{ sql = "c.relname", type = "text" },
	{ sql = "c.oid", type = "oid" },
}

local relation_base = {
	select = "n.nspname, c.relname, c.relkind, c.oid::text",
	from = "pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace",
	where = {
		"n.nspname !~ '^pg_'",
		"n.nspname <> 'information_schema'",
	},
	schema_column = "n.nspname",
	filter_column = "c.relname",
	sort = relation_sort,
	cursor_rows = { 1, 2, 4 },
	item = relation_item,
}

local function relation_spec(kinds)
	local spec = vim.deepcopy(relation_base)
	table.insert(spec.where, "c.relkind IN (" .. kinds .. ")")
	return spec
end

local column_spec = {
	select = table.concat({
		"n.nspname, c.relname, c.oid::text, a.attname, a.attnum::text,",
		"pg_catalog.format_type(a.atttypid, a.atttypmod), a.attnotnull::text,",
		"COALESCE(pg_catalog.pg_get_expr(ad.adbin, ad.adrelid), '')",
	}, " "),
	from = table.concat({
		"pg_catalog.pg_attribute a",
		"JOIN pg_catalog.pg_class c ON c.oid = a.attrelid",
		"JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace",
		"LEFT JOIN pg_catalog.pg_attrdef ad ON ad.adrelid = a.attrelid AND ad.adnum = a.attnum",
	}, "\n"),
	where = {
		"a.attnum > 0",
		"NOT a.attisdropped",
		"n.nspname !~ '^pg_'",
		"n.nspname <> 'information_schema'",
	},
	schema_column = "n.nspname",
	relation_column = "c.oid",
	filter_column = "a.attname",
	sort = {
		{ sql = "n.nspname", type = "text" },
		{ sql = "c.relname", type = "text" },
		{ sql = "a.attnum", type = "integer" },
		{ sql = "c.oid", type = "oid" },
	},
	cursor_rows = { 1, 2, 5, 3 },
	item = column_item,
}

local index_spec = {
	select = table.concat({
		"n.nspname, idx.relname, idx.oid::text, tbl.oid::text, tbl.relname,",
		"ix.indisunique::text, am.amname",
	}, " "),
	from = table.concat({
		"pg_catalog.pg_index ix",
		"JOIN pg_catalog.pg_class idx ON idx.oid = ix.indexrelid",
		"JOIN pg_catalog.pg_class tbl ON tbl.oid = ix.indrelid",
		"JOIN pg_catalog.pg_namespace n ON n.oid = tbl.relnamespace",
		"JOIN pg_catalog.pg_am am ON am.oid = idx.relam",
	}, "\n"),
	where = { "n.nspname !~ '^pg_'", "n.nspname <> 'information_schema'" },
	schema_column = "n.nspname",
	relation_column = "tbl.oid",
	filter_column = "idx.relname",
	sort = {
		{ sql = "n.nspname", type = "text" },
		{ sql = "idx.relname", type = "text" },
		{ sql = "idx.oid", type = "oid" },
	},
	cursor_rows = { 1, 2, 3 },
	item = index_item,
}

local constraint_spec = {
	select = table.concat({
		"n.nspname, con.conname, con.oid::text, c.oid::text, c.relname, con.contype,",
		"pg_catalog.pg_get_constraintdef(con.oid)",
	}, " "),
	from = table.concat({
		"pg_catalog.pg_constraint con",
		"JOIN pg_catalog.pg_class c ON c.oid = con.conrelid",
		"JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace",
	}, "\n"),
	where = { "n.nspname !~ '^pg_'", "n.nspname <> 'information_schema'" },
	schema_column = "n.nspname",
	relation_column = "c.oid",
	filter_column = "con.conname",
	sort = {
		{ sql = "n.nspname", type = "text" },
		{ sql = "con.conname", type = "text" },
		{ sql = "con.oid", type = "oid" },
	},
	cursor_rows = { 1, 2, 3 },
	item = constraint_item,
}

local sequence_spec = {
	select = "n.nspname, c.relname, c.oid::text",
	from = "pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace",
	where = {
		"c.relkind = 'S'",
		"n.nspname !~ '^pg_'",
		"n.nspname <> 'information_schema'",
	},
	schema_column = "n.nspname",
	filter_column = "c.relname",
	sort = relation_sort,
	cursor_rows = { 1, 2, 3 },
	item = sequence_item,
}

local routine_spec = {
	select = table.concat({
		"n.nspname, p.proname, p.oid::text,",
		"pg_catalog.pg_get_function_identity_arguments(p.oid), p.prokind",
	}, " "),
	from = "pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace",
	where = { "n.nspname !~ '^pg_'", "n.nspname <> 'information_schema'" },
	schema_column = "n.nspname",
	filter_column = "p.proname",
	sort = {
		{ sql = "n.nspname", type = "text" },
		{ sql = "p.proname", type = "text" },
		{ sql = "p.oid", type = "oid" },
	},
	cursor_rows = { 1, 2, 3 },
	item = routine_item,
}

local type_spec = {
	select = "n.nspname, t.typname, t.oid::text, t.typtype, t.typcategory",
	from = "pg_catalog.pg_type t JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace",
	where = {
		"t.typisdefined",
		"n.nspname !~ '^pg_'",
		"n.nspname <> 'information_schema'",
	},
	schema_column = "n.nspname",
	filter_column = "t.typname",
	sort = {
		{ sql = "n.nspname", type = "text" },
		{ sql = "t.typname", type = "text" },
		{ sql = "t.oid", type = "oid" },
	},
	cursor_rows = { 1, 2, 3 },
	item = type_item,
}

local policy_spec = {
	select = "n.nspname, p.polname, c.oid::text, c.relname, p.polcmd, p.polpermissive::text",
	from = table.concat({
		"pg_catalog.pg_policy p",
		"JOIN pg_catalog.pg_class c ON c.oid = p.polrelid",
		"JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace",
	}, "\n"),
	where = { "n.nspname !~ '^pg_'", "n.nspname <> 'information_schema'" },
	schema_column = "n.nspname",
	relation_column = "c.oid",
	filter_column = "p.polname",
	sort = {
		{ sql = "n.nspname", type = "text" },
		{ sql = "c.relname", type = "text" },
		{ sql = "p.polname", type = "text" },
		{ sql = "c.oid", type = "oid" },
	},
	cursor_rows = { 1, 4, 2, 3 },
	item = policy_item,
}

local trigger_spec = {
	select = "n.nspname, t.tgname, t.oid::text, c.oid::text, c.relname, t.tgenabled",
	from = table.concat({
		"pg_catalog.pg_trigger t",
		"JOIN pg_catalog.pg_class c ON c.oid = t.tgrelid",
		"JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace",
	}, "\n"),
	where = {
		"NOT t.tgisinternal",
		"n.nspname !~ '^pg_'",
		"n.nspname <> 'information_schema'",
	},
	schema_column = "n.nspname",
	relation_column = "c.oid",
	filter_column = "t.tgname",
	sort = {
		{ sql = "n.nspname", type = "text" },
		{ sql = "t.tgname", type = "text" },
		{ sql = "t.oid", type = "oid" },
	},
	cursor_rows = { 1, 2, 3 },
	item = trigger_item,
}

local extension_spec = {
	select = "n.nspname, e.extname, e.oid::text, e.extversion",
	from = "pg_catalog.pg_extension e JOIN pg_catalog.pg_namespace n ON n.oid = e.extnamespace",
	where = { "TRUE" },
	schema_column = "n.nspname",
	filter_column = "e.extname",
	sort = {
		{ sql = "n.nspname", type = "text" },
		{ sql = "e.extname", type = "text" },
		{ sql = "e.oid", type = "oid" },
	},
	cursor_rows = { 1, 2, 3 },
	item = extension_item,
}

local dependency_spec = {
	select = "target_ns.nspname, target.relname, target.oid::text, dep.deptype, source.oid::text",
	from = table.concat({
		"pg_catalog.pg_depend dep",
		"JOIN pg_catalog.pg_class source ON source.oid = dep.refobjid",
		"JOIN pg_catalog.pg_class target ON target.oid = dep.objid",
		"JOIN pg_catalog.pg_namespace target_ns ON target_ns.oid = target.relnamespace",
	}, "\n"),
	where = {
		"dep.refclassid = 'pg_catalog.pg_class'::pg_catalog.regclass",
		"dep.classid = 'pg_catalog.pg_class'::pg_catalog.regclass",
	},
	schema_column = "target_ns.nspname",
	relation_column = "source.oid",
	filter_column = "target.relname",
	sort = {
		{ sql = "target_ns.nspname", type = "text" },
		{ sql = "target.relname", type = "text" },
		{ sql = "dep.deptype", type = "text" },
		{ sql = "target.oid", type = "oid" },
	},
	cursor_rows = { 1, 2, 4, 3 },
	item = dependency_item,
}

local function catalog_definition(key, command, title, spec, on_select)
	return {
		key = key,
		command = command,
		title = title,
		list = paged_list(spec),
		on_select = on_select or M.definition_unavailable,
	}
end

local relations = catalog_definition(
	"relations",
	"Relations",
	"Relations",
	relation_spec("'r', 'v', 'm', 'p', 'f'"),
	select_relation
)
relations.inspect = relation_actions

local tables = catalog_definition(
	"tables",
	"Tables",
	"Tables",
	relation_spec("'r', 'v', 'm', 'p'"),
	select_relation
)
tables.inspect = relation_actions

M.catalogs = {
	relations,
	tables,
	catalog_definition("columns", "Columns", "Columns", column_spec),
	catalog_definition("indexes", "Indexes", "Indexes", index_spec),
	catalog_definition("constraints", "Constraints", "Constraints", constraint_spec),
	catalog_definition("sequences", "Sequences", "Sequences", sequence_spec),
	catalog_definition("routines", "Functions", "Functions", routine_spec),
	catalog_definition("types", "Types", "Types", type_spec),
	catalog_definition("policies", "Policies", "Policies", policy_spec),
	catalog_definition("triggers", "Triggers", "Triggers", trigger_spec),
	catalog_definition("extensions", "Extensions", "Extensions", extension_spec),
}

M.inspectors = {
	{
		key = "dependencies",
		title = "Dependencies",
		list = paged_list(dependency_spec),
		on_select = M.definition_unavailable,
	},
}

return M
