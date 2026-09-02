-- Values already entered for SQL variables, one store per connection.
-- Table and schema names only make sense on the database they came from,
-- which is the same reasoning the scratchpad follows.

local M = {}

local LIMIT = 50

function M.dir()
	return vim.fs.joinpath(vim.fn.stdpath("data"), "psql", "vars")
end

function M.path(connection)
	return vim.fs.joinpath(M.dir(), (connection or "default") .. ".json")
end

-- Never raises: a missing, empty or hand-corrupted store is just an empty
-- history. This is a cache, and losing it must never break a query.
function M.load(connection)
	local path = M.path(connection)
	if vim.fn.filereadable(path) == 0 then
		return {}
	end

	local ok, decoded = pcall(function()
		return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
	end)
	if not ok or type(decoded) ~= "table" then
		return {}
	end
	return decoded
end

function M.values(connection, name)
	return M.load(connection)[name] or {}
end

-- Most recent first, without duplicates.
function M.record(connection, name, value)
	local store = M.load(connection)

	local kept = { value }
	for _, previous in ipairs(store[name] or {}) do
		if previous ~= value and #kept < LIMIT then
			table.insert(kept, previous)
		end
	end
	store[name] = kept

	-- "p" makes mkdir idempotent: no error when the directory exists.
	vim.fn.mkdir(M.dir(), "p")
	vim.fn.writefile({ vim.json.encode(store) }, M.path(connection))
	return kept
end

return M
