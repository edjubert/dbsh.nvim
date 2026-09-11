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
local function quote_ident(name)
	local escaped = (tostring(name):gsub('"', '""'))
	return '"' .. escaped .. '"'
end

-- item is a row of the relation level: { schema = ..., name = ..., kind = ... }.
function M.preview_query(item, limit)
	return string.format(
		"SELECT * FROM %s.%s LIMIT %d;",
		quote_ident(item.schema),
		quote_ident(item.name),
		limit or 10
	)
end

M.queries = {
	databases = "SELECT datname FROM pg_database "
		.. "WHERE datallowconn AND NOT datistemplate ORDER BY 1;",

	schemas = "SELECT nspname FROM pg_namespace "
		.. "WHERE nspname !~ '^pg_' AND nspname <> 'information_schema' ORDER BY 1;",

	tables = table.concat({
		"SELECT n.nspname, c.relname, c.relkind",
		"FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace",
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

local function list_relations(request, callback)
	fetch(M.queries.tables, request, function(rows, err)
		if err ~= nil then
			callback(nil, err)
			return
		end
		local items = {}
		for _, row in ipairs(rows) do
			local schema, name, kind = row[1], row[2], row[3]
			local scope = request.scope or {}
			if scope.all_schemas or scope.schema == nil or scope.schema == schema then
				table.insert(items, {
					schema = schema,
					name = name,
					kind = kind,
				})
			end
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

local function select_relation(item)
	local config = require("dbsh.config")
	require("dbsh").query(M.preview_query(item, config.options().preview_limit))
end

M.catalogs = {
	{
		key = "relations",
		command = "Relations",
		title = "Relations",
		list = list_relations,
		on_select = select_relation,
	},
	{
		key = "tables",
		command = "Tables",
		title = "Tables",
		list = list_relations,
		on_select = select_relation,
	},
}

return M
