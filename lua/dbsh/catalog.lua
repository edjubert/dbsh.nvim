-- Generic catalog requests, response validation, and persistent public pages.

local config = require("dbsh.config")
local context = require("dbsh.context")

local M = {}

local cache, revisions, epoch = {}, {}, 0
local STORE_VERSION = 1
local LEVEL_KEYS = { "database", "schema", "role", "warehouse" }

function M.dir()
	return vim.fs.joinpath(vim.fn.stdpath("data"), "dbsh", "catalog")
end

function M.path(key)
	return vim.fs.joinpath(M.dir(), vim.fn.sha256(key) .. ".json")
end

function M._rename(from, to)
	return os.rename(from, to)
end

local function reset()
	cache, revisions, epoch = {}, {}, epoch + 1
end

local function public_entry(entry)
	local copy = {
		context = {
			connection_name = entry.context.connection_name,
			backend = entry.context.backend,
			levels = {},
		},
	}
	for _, key in ipairs(LEVEL_KEYS) do
		copy.context.levels[key] = entry.context.levels[key]
	end
	for _, key in ipairs({
		"key", "profile", "catalog", "selector", "scope", "query",
		"relation", "limit", "items", "next_cursor", "partial",
	}) do
		copy[key] = vim.deepcopy(entry[key])
	end
	return copy
end

local function persist(entry)
	local path = M.path(entry.key)
	local temporary = path .. ".tmp-" .. vim.uv.os_getpid() .. "-" .. vim.uv.hrtime()
	local ok, saved = pcall(function()
		local encoded = vim.json.encode({ version = STORE_VERSION, entry = public_entry(entry) })
		vim.fn.mkdir(M.dir(), "p")
		if vim.fn.writefile({ encoded }, temporary) ~= 0 then return false end
		return M._rename(temporary, path)
	end)
	if not ok or not saved then
		pcall(vim.fn.delete, temporary)
		vim.notify("dbsh.nvim: could not persist catalog cache", vim.log.levels.WARN)
	end
end

local function stable(value)
	if type(value) ~= "table" then
		return value
	end
	local keys, result = vim.tbl_keys(value), {}
	table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
	for _, key in ipairs(keys) do
		table.insert(result, { key, stable(value[key]) })
	end
	return result
end

local function fingerprint(snapshot)
	local connection = snapshot.connection or {}
	return vim.json.encode({
		snapshot.connection_name or "",
		snapshot.backend_name or connection.type or "postgres",
		connection.host or "",
		connection.port or "",
		connection.username or "",
	})
end

function M.cache_key(snapshot, definition, options)
	options = options or {}
	local levels = vim.deepcopy(snapshot.levels or {})
	if definition.apply ~= nil and definition.key == "database" then
		levels.database, levels.schema = nil, nil
	elseif definition.apply ~= nil and definition.key == "schema" then
		levels.schema = nil
	elseif options.scope and options.scope.schema then
		levels.schema = options.scope.schema
	elseif options.scope and options.scope.all_schemas then
		levels.schema = nil
	end
	return vim.json.encode(stable({
		profile = fingerprint(snapshot),
		catalog = definition.key,
		selector = definition.apply ~= nil,
		levels = levels,
		scope = options.scope or { all_schemas = false },
		query = options.query or "",
		relation = options.relation,
		limit = options.limit or M.page_size(),
	}))
end

local function restore(store)
	local entry = type(store) == "table" and store.version == STORE_VERSION and store.entry
	if type(entry) ~= "table" or type(entry.key) ~= "string" or type(entry.profile) ~= "string"
		or type(entry.catalog) ~= "string" or type(entry.selector) ~= "boolean"
		or type(entry.context) ~= "table" or type(entry.context.connection_name) ~= "string"
		or type(entry.context.levels) ~= "table" or type(entry.scope) ~= "table"
		or type(entry.query) ~= "string" or type(entry.partial) ~= "boolean"
		or type(entry.limit) ~= "number" or entry.limit <= 0 or entry.limit == math.huge
		or entry.limit ~= math.floor(entry.limit) or type(entry.items) ~= "table"
		or not vim.islist(entry.items) or (entry.next_cursor ~= nil and type(entry.next_cursor) ~= "string")
		or (entry.relation ~= nil and type(entry.relation) ~= "table") then return end
	for _, key in ipairs(LEVEL_KEYS) do
		if entry.context.levels[key] ~= nil and type(entry.context.levels[key]) ~= "string" then return end
	end
	if (entry.scope.schema ~= nil and type(entry.scope.schema) ~= "string")
		or (entry.scope.all_schemas ~= nil and type(entry.scope.all_schemas) ~= "boolean") then return end
	for _, item in ipairs(entry.items) do
		if type(item) ~= "table" then return end
	end
	local connection = config.connection(entry.context.connection_name)
	if connection == nil then return end
	local snapshot = {
		connection_name = entry.context.connection_name, connection = connection,
		backend_name = connection.type or "postgres", levels = entry.context.levels,
	}
	if entry.context.backend ~= snapshot.backend_name or entry.profile ~= fingerprint(snapshot)
		or entry.key ~= M.cache_key(snapshot, { key = entry.catalog, apply = entry.selector and true or nil }, {
			scope = entry.scope, query = entry.query, relation = entry.relation, limit = entry.limit,
		}) then return end
	return public_entry(entry)
end

function M.setup()
	reset()
	-- Each key has its own file, so separate Neovim sessions do not overwrite
	-- unrelated pages. Restored entries have no previous buffer/session identity.
	local ok, paths = pcall(vim.fn.globpath, M.dir(), "*.json", false, true)
	if not ok then return end
	for _, path in ipairs(paths) do
		local read_ok, entry = pcall(function()
			return restore(vim.json.decode(table.concat(vim.fn.readfile(path), "\n")))
		end)
		if read_ok and entry ~= nil and path == M.path(entry.key) then cache[entry.key] = entry end
	end
end

function M.cached(snapshot, definition, options)
	return vim.deepcopy(cache[M.cache_key(snapshot, definition, options)])
end

function M.entries(snapshot)
	local entries = {}
	for _, entry in pairs(cache) do
		if snapshot == nil or entry.profile == fingerprint(snapshot) then
			table.insert(entries, vim.deepcopy(entry))
		end
	end
	table.sort(entries, function(a, b) return a.key < b.key end)
	return entries
end

function M.clear()
	reset()
	if vim.fn.isdirectory(M.dir()) == 1 then
		local ok, status = pcall(vim.fn.delete, M.dir(), "rf")
		if not ok or status ~= 0 then
			vim.notify("dbsh.nvim: could not clear catalog cache", vim.log.levels.WARN)
		end
	end
end

local function malformed(detail)
	return "malformed catalog response: " .. detail
end

function M.page_size()
	return config.options().catalog_page_size
end

function M.request(snapshot, definition, options, callback)
	options = options or {}
	local key = definition.key and M.cache_key(snapshot, definition, options)
	local request_epoch = epoch
	local revision
	if key ~= nil then
		revisions[key] = (revisions[key] or 0) + 1
		revision = revisions[key]
	end
	local request = {
		context = context.public(snapshot),
		scope = vim.deepcopy(options.scope or { schema = nil, all_schemas = false }),
		query = options.query or "",
		cursor = options.cursor,
		limit = options.limit or M.page_size(),
		relation = vim.deepcopy(options.relation),
	}

	local function respond(response, err)
		if err ~= nil then
			callback(nil, err)
			return
		end
		if type(response) ~= "table" or type(response.items) ~= "table" then
			callback(nil, malformed("items must be a table"))
			return
		end
		if response.next_cursor ~= nil and type(response.next_cursor) ~= "string" then
			callback(nil, malformed("next_cursor must be a string or nil"))
			return
		end
		for _, item in ipairs(response.items) do
			if type(item) ~= "table" then
				callback(nil, malformed("items must be backend-shaped records"))
				return
			end
		end
		local page = {
			items = response.items,
			next_cursor = response.next_cursor,
			total = response.total,
		}
		if key ~= nil and request_epoch == epoch and revisions[key] == revision
			and context.is_current(snapshot) then
			local previous = cache[key]
			local items = {}
			local partial = options.cursor ~= nil
			if previous ~= nil and options.cursor ~= nil and previous.next_cursor == options.cursor then
				items = vim.deepcopy(previous.items)
				partial = previous.partial
			end
			vim.list_extend(items, vim.deepcopy(page.items))
			cache[key] = {
				key = key,
				profile = fingerprint(snapshot),
				context = context.public(snapshot),
				catalog = definition.key,
				selector = definition.apply ~= nil,
				scope = request.scope,
				query = request.query,
				relation = request.relation,
				limit = request.limit,
				items = items,
				next_cursor = page.next_cursor,
				partial = partial,
			}
			persist(cache[key])
			vim.api.nvim_exec_autocmds("User", {
				pattern = "DbshCatalogChanged",
				modeline = false,
				data = { key = key },
			})
		end
		callback(page, nil)
	end

	local ok, err = pcall(definition.list, request, respond)
	if not ok then
		callback(nil, "catalog request failed: " .. tostring(err))
	end
end

function M.load_more_entry(page)
	if page.next_cursor == nil then
		return nil
	end
	return {
		kind = "more",
		cursor = page.next_cursor,
		display = string.format("Load %d more…", M.page_size()),
	}
end

return M
