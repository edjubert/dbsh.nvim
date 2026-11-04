-- Generic catalog request construction and backend response validation.

local config = require("dbsh.config")
local context = require("dbsh.context")

local M = {}

local cache, revisions, epoch = {}, {}, 0

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
	cache, revisions, epoch = {}, {}, epoch + 1
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
