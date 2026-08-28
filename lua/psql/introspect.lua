-- Catalog introspection.
-- Runs in raw mode (-A -t -F '\t') so the output can be parsed reliably,
-- unlike the decorated output used for user queries.

local config = require("psql.config")
local exec = require("psql.exec")

local M = {}

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

function M.parse_rows(stdout)
	local rows = {}
	for _, line in ipairs(vim.split(stdout or "", "\n", { plain = true })) do
		if line ~= "" then
			table.insert(rows, vim.split(line, "\t", { plain = true }))
		end
	end
	return rows
end

-- Double inner quotes so mixed-case names and reserved words survive.
function M.quote_ident(name)
	local escaped = (tostring(name):gsub('"', '""'))
	return '"' .. escaped .. '"'
end

function M.preview_query(schema, relname, limit)
	return string.format(
		"SELECT * FROM %s.%s LIMIT %d;",
		M.quote_ident(schema),
		M.quote_ident(relname),
		limit or config.options().preview_limit
	)
end

-- Introspection uses its own slot so it never cancels a running user query.
local function fetch(sql, callback)
	exec.run(sql, { raw = true, slot = "introspect" }, function(code, stdout, stderr)
		if code ~= 0 then
			callback(nil, stderr ~= "" and stderr or "psql exited with code " .. tostring(code))
			return
		end
		callback(M.parse_rows(stdout), nil)
	end)
end

local function first_column(sql, callback)
	fetch(sql, function(rows, err)
		if err ~= nil then
			callback(nil, err)
			return
		end
		local names = {}
		for _, row in ipairs(rows) do
			table.insert(names, row[1])
		end
		callback(names, nil)
	end)
end

function M.databases(callback)
	first_column(M.queries.databases, callback)
end

function M.schemas(callback)
	first_column(M.queries.schemas, callback)
end

-- opts: { schema = string? }
function M.tables(opts, callback)
	opts = opts or {}
	fetch(M.queries.tables, function(rows, err)
		if err ~= nil then
			callback(nil, err)
			return
		end
		local out = {}
		for _, row in ipairs(rows) do
			local schema, relname, relkind = row[1], row[2], row[3]
			if opts.schema == nil or opts.schema == schema then
				table.insert(out, { schema = schema, name = relname, kind = relkind })
			end
		end
		callback(out, nil)
	end)
end

return M
