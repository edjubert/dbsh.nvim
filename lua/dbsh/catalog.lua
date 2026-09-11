-- Generic catalog request construction and backend response validation.

local config = require("dbsh.config")
local context = require("dbsh.context")

local M = {}

local function malformed(detail)
	return "malformed catalog response: " .. detail
end

function M.page_size()
	return config.options().catalog_page_size
end

function M.request(snapshot, definition, options, callback)
	options = options or {}
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
		callback({
			items = response.items,
			next_cursor = response.next_cursor,
			total = response.total,
		}, nil)
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
