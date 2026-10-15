-- Persistent, context-owning scratchpads in the backend's query language.

local config = require("dbsh.config")
local context = require("dbsh.context")
local backends = require("dbsh.backends")

local M = {}

local LEVEL_KEYS = { "database", "schema", "role", "warehouse" }

function M._data_dir()
	return vim.fs.joinpath(vim.fn.stdpath("data"), "dbsh", "scratchpads")
end

function M._rename(from, to)
	local ok, err = os.rename(from, to)
	if ok then
		return true
	end
	return nil, err
end

function M._id()
	local entropy = string.format("%s:%s:%s", vim.uv.hrtime(), math.random(), vim.uv.os_getpid())
	return vim.fn.sha256(entropy):sub(1, 24)
end

function M.dir()
	return M._data_dir()
end

local function stem(id)
	return vim.fs.joinpath(M.dir(), id)
end

local function extensions()
	local known = { sql = true }
	for _, backend in ipairs(backends.all()) do
		known[backend.extension or "sql"] = true
	end
	local values = vim.tbl_keys(known)
	table.sort(values)
	return values
end

function M.paths(id, backend_name)
	if backend_name == nil then
		local item = M.read(id)
		backend_name = item and item.backend
	end
	local backend = backends.get(backend_name)
	local path = stem(id) .. "." .. (backend and backend.extension or "sql")
	-- Reuse existing files, including Mongo scratchpads previously stored as
	-- .sql and scratchpads whose connection/backend was changed later.
	if vim.fn.filereadable(path) ~= 1 then
		for _, extension in ipairs(extensions()) do
			local existing = stem(id) .. "." .. extension
			if vim.fn.filereadable(existing) == 1 then
				path = existing
				break
			end
		end
	end
	return path, stem(id) .. ".json"
end

function M.legacy_path(connection_name)
	return vim.fs.joinpath(vim.fs.dirname(M.dir()), connection_name .. ".sql")
end

local function metadata(value)
	return {
		version = 1,
		id = value.id,
		name = value.name or value.id,
		backend = value.backend,
		connection_name = value.connection_name,
		levels = vim.deepcopy(value.levels or {}),
		project_root = value.project_root,
	}
end

local function metadata_error(id, detail)
	return string.format("invalid metadata for scratchpad %s: %s", id, detail)
end

function M.write_metadata(value)
	local item = metadata(value)
	local path = stem(item.id) .. ".json"
	local ok, encoded = pcall(vim.json.encode, item)
	if not ok then
		return nil, tostring(encoded)
	end

	vim.fn.mkdir(M.dir(), "p")
	local tmp = path .. ".tmp-" .. M._id()
	if vim.fn.writefile({ encoded }, tmp) ~= 0 then
		return nil, "could not write temporary metadata"
	end

	local renamed, err = M._rename(tmp, path)
	if not renamed then
		vim.fn.delete(tmp)
		return nil, err or "could not replace metadata"
	end
	return item
end

function M.read(id)
	local path = stem(id) .. ".json"
	if vim.fn.filereadable(path) ~= 1 then
		return nil, metadata_error(id, "metadata file is missing")
	end

	local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
	if not ok or type(decoded) ~= "table" then
		return nil, metadata_error(id, "JSON cannot be decoded")
	end
	if decoded.version ~= 1
		or decoded.id ~= id
		or type(decoded.name) ~= "string"
		or type(decoded.backend) ~= "string"
		or (decoded.connection_name ~= nil and type(decoded.connection_name) ~= "string")
		or type(decoded.levels) ~= "table"
		or (decoded.project_root ~= nil and type(decoded.project_root) ~= "string") then
		return nil, metadata_error(id, "unsupported schema")
	end
	return metadata(decoded)
end

function M.create(value)
	local item = metadata(value)
	item.id = item.id or M._id()
	item.name = item.name or item.id
	local path, json = M.paths(item.id, item.backend)
	if vim.fn.filereadable(path) == 1 or vim.fn.filereadable(json) == 1 then
		return nil, "scratchpad already exists"
	end

	vim.fn.mkdir(M.dir(), "p")
	if vim.fn.writefile({}, path) ~= 0 then
		return nil, "could not create scratchpad query file"
	end
	local saved, err = M.write_metadata(item)
	if saved == nil then
		return nil, err
	end
	return saved
end

function M.list()
	local ids = {}
	local patterns = { "*.json" }
	for _, extension in ipairs(extensions()) do
		table.insert(patterns, "*." .. extension)
	end
	for _, pattern in ipairs(patterns) do
		for _, path in ipairs(vim.fn.globpath(M.dir(), pattern, false, true)) do
			local id = vim.fs.basename(path):gsub("%.[^.]+$", "")
			ids[id] = true
		end
	end

	local items = {}
	for id in pairs(ids) do
		local item, err = M.read(id)
		table.insert(items, {
			id = id,
			metadata = item,
			error = err,
		})
	end
	table.sort(items, function(a, b)
		local left = (a.metadata and a.metadata.name or a.id):lower()
		local right = (b.metadata and b.metadata.name or b.id):lower()
		return left == right and a.id < b.id or left < right
	end)
	return items
end

function M.legacy()
	local items = {}
	for _, path in ipairs(vim.fn.globpath(vim.fs.dirname(M.dir()), "*.sql", false, true)) do
		local connection_name = vim.fs.basename(path):gsub("%.sql$", "")
		table.insert(items, { connection_name = connection_name, path = path })
	end
	table.sort(items, function(a, b) return a.connection_name < b.connection_name end)
	return items
end

local function profile_levels(connection)
	local levels = {}
	for _, key in ipairs(LEVEL_KEYS) do
		if connection[key] ~= nil then
			levels[key] = connection[key]
		end
	end
	return levels
end

function M.migrate_legacy(connection_name)
	local legacy = M.legacy_path(connection_name)
	if vim.fn.filereadable(legacy) ~= 1 then
		return nil, "legacy scratchpad does not exist"
	end
	local connection = config.connection(connection_name)

	local item, create_err = M.create({
		id = M._id(),
		name = "Migrated " .. connection_name,
		backend = connection and (connection.type or "postgres") or "postgres",
		connection_name = connection and connection_name or nil,
		levels = connection and profile_levels(connection) or {},
		project_root = nil,
	})
	if item == nil then
		return nil, create_err
	end

	local sql = M.paths(item.id)
	if vim.fn.writefile(vim.fn.readfile(legacy), sql) ~= 0 then
		return nil, "could not copy legacy scratchpad"
	end
	return item
end

local function set_filetype(bufnr, backend_name)
	local backend = backends.get(backend_name)
	local filetype = backend and backend.filetype or "sql"
	if vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].filetype ~= filetype then
		vim.bo[bufnr].filetype = filetype
	end
end

local function persist_from_context(item, public)
	local saved, err = M.write_metadata({
		id = item.id,
		name = item.name,
		backend = public.backend,
		connection_name = public.connection_name,
		levels = public.levels,
		project_root = public.project_root,
	})
	if saved == nil then
		vim.notify(
			"dbsh.nvim: could not save scratchpad metadata: " .. tostring(err),
			vim.log.levels.ERROR
		)
	end
	set_filetype(public.bufnr, public.backend)
end

function M.open(id)
	local item, err = M.read(id)
	if item == nil then
		vim.notify("dbsh.nvim: " .. err, vim.log.levels.WARN)
		return nil, err
	end

	local path = M.paths(id, item.backend)
	vim.fn.mkdir(M.dir(), "p")
	vim.cmd("edit " .. vim.fn.fnameescape(path))

	local connection, connection_err = config.connection(item.connection_name)
	if connection == nil and item.connection_name ~= nil then
		vim.notify("dbsh.nvim: " .. connection_err, vim.log.levels.WARN)
	end
	context.attach(0, {
		id = "scratchpad:" .. item.id,
		scratchpad_id = item.id,
		kind = "scratchpad",
		connection_name = item.connection_name,
		connection = connection,
		backend_name = item.backend,
		levels = item.levels,
		project_root = item.project_root,
		on_change = function(public) persist_from_context(item, public) end,
	})
	set_filetype(vim.api.nvim_get_current_buf(), connection and (connection.type or "postgres") or item.backend)
	return path
end

return M
