local helpers = dofile("tests/helpers.lua")
local eq, expect_match = helpers.eq, helpers.expect_match

local catalog = require("dbsh.catalog")
local config = require("dbsh.config")
local context = require("dbsh.context")

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			catalog.clear()
			config.setup({
				connections = {
					local_db = { host = "localhost", port = 5432, database = "postgres", username = "dev" },
				},
				default = "local_db",
			})
			context.setup()
		end,
	},
})

T["uses the configured default page size and public context"] = function()
	local received
	local definition = {
		list = function(request, callback)
			received = request
			callback({ items = { { name = "users" } }, next_cursor = nil }, nil)
		end,
	}
	local page
	catalog.request(context.snapshot(0), definition, {}, function(value) page = value end)

	eq(received.limit, 200)
	eq(received.context.connection, nil)
	eq(received.context.connection_name, "local_db")
	eq(page.items, { { name = "users" } })
end

T["forwards scope, query, cursor, relation, and an explicit page size"] = function()
	config.setup({
		connections = {
			local_db = { host = "localhost", port = 5432, database = "postgres", username = "dev" },
		},
		default = "local_db",
		catalog_page_size = 25,
	})
	context.setup()
	local received
	local definition = {
		list = function(request, callback)
			received = request
			callback({ items = {}, next_cursor = "next" }, nil)
		end,
	}

	catalog.request(context.snapshot(0), definition, {
		scope = { schema = "analytics", all_schemas = false },
		query = "events",
		cursor = "cursor-1",
		relation = { oid = "42", schema = "analytics", name = "events" },
	}, function() end)

	eq(received.limit, 25)
	eq(received.scope, { schema = "analytics", all_schemas = false })
	eq(received.query, "events")
	eq(received.cursor, "cursor-1")
	eq(received.relation, { oid = "42", schema = "analytics", name = "events" })
end

T["turns malformed backend responses into a clear error"] = function()
	local cases = {
		{ items = "no", next_cursor = nil },
		{ items = {}, next_cursor = 1 },
		{ items = { "no-record" }, next_cursor = nil },
	}
	for _, response in ipairs(cases) do
		local got
		catalog.request(context.snapshot(0), {
			list = function(_, callback) callback(response, nil) end,
		}, {}, function(_, err) got = err end)
		expect_match(got, "malformed catalog response")
	end
end

T["reports load-more eligibility only when a cursor exists"] = function()
	eq(catalog.load_more_entry({ items = {}, next_cursor = nil }), nil)
	eq(catalog.load_more_entry({ items = {}, next_cursor = "next" }), {
		kind = "more",
		cursor = "next",
		display = "Load 200 more…",
	})
end

T["keeps a temporary all-schema scope public and non-mutating"] = function()
	local received
	catalog.request(context.snapshot(0), {
		list = function(request, callback)
			received = request
			callback({ items = {}, next_cursor = nil }, nil)
		end,
	}, {
		scope = { schema = nil, all_schemas = true },
	}, function() end)

	eq(received.scope, { schema = nil, all_schemas = true })
	eq(context.current(0).levels.schema, nil)
end

local function inventory(pages)
	return {
		key = "relations",
		list = function(request, callback)
			callback(pages[request.cursor or "first"], nil)
		end,
	}
end

T["caches loaded pages without fetching the remaining inventory"] = function()
	local snapshot = context.snapshot(0)
	local definition = inventory({
		first = { items = { { name = "a" } }, next_cursor = "next" },
		next = { items = { { name = "b" } } },
	})
	catalog.request(snapshot, definition, {}, function() end)
	eq(catalog.cached(snapshot, definition).items, { { name = "a" } })
	eq(catalog.cached(snapshot, definition).next_cursor, "next")
	local returned
	catalog.request(snapshot, definition, { cursor = "next" }, function(page) returned = page end)
	eq(returned.items, { { name = "b" } })
	eq(catalog.cached(snapshot, definition).items, { { name = "a" }, { name = "b" } })
	eq(catalog.cached(snapshot, definition).next_cursor, nil)
	catalog.request(snapshot, definition, {}, function() end)
	eq(catalog.cached(snapshot, definition).items, { { name = "a" } })
end

T["isolates filters, schema scopes, and effective databases without caching secrets"] = function()
	local snapshot = context.snapshot(0)
	snapshot.connection.password = "never-cache"
	snapshot.connection.password_command = { "secret-command" }
	local definition = inventory({ first = { items = { { name = "a" } } } })
	local options = { scope = { schema = "public", all_schemas = false }, query = "a" }
	catalog.request(snapshot, definition, options, function() end)
	eq(catalog.cached(snapshot, definition, { scope = options.scope }), nil)
	eq(catalog.cached(snapshot, definition, { scope = { schema = "other" }, query = "a" }), nil)
	local other = vim.deepcopy(snapshot)
	other.levels.database = "other"
	eq(catalog.cached(other, definition, options), nil)
	local text = vim.inspect(catalog.entries())
	eq(text:find("never-cache", 1, true), nil)
	eq(text:find("secret-command", 1, true), nil)
	eq(catalog.entries()[1].context.connection, nil)
end

T["does not cache malformed responses or overwrite a good page on errors"] = function()
	local snapshot = context.snapshot(0)
	local definition = inventory({ first = { items = { { name = "a" } } } })
	catalog.request(snapshot, definition, {}, function() end)
	definition.list = function(_, callback) callback(nil, "offline") end
	catalog.request(snapshot, definition, {}, function() end)
	eq(catalog.cached(snapshot, definition).items, { { name = "a" } })
	definition.list = function(_, callback) callback({ items = { "invalid" } }, nil) end
	catalog.request(snapshot, definition, {}, function() end)
	eq(catalog.cached(snapshot, definition).items, { { name = "a" } })
end

T["rejects stale callbacks after a source change, cache reset, or newer request"] = function()
	local callbacks = {}
	local definition = {
		key = "relations",
		list = function(_, callback) table.insert(callbacks, callback) end,
	}
	local snapshot = context.snapshot(0)
	catalog.request(snapshot, definition, {}, function() end)
	catalog.request(snapshot, definition, {}, function() end)
	callbacks[2]({ items = { { name = "new" } } })
	callbacks[1]({ items = { { name = "old" } } })
	eq(catalog.cached(snapshot, definition).items, { { name = "new" } })
	catalog.clear()
	catalog.request(snapshot, definition, {}, function() end)
	catalog.clear()
	callbacks[3]({ items = { { name = "reset" } } })
	eq(catalog.entries(), {})
	catalog.request(snapshot, definition, {}, function() end)
	context.set_level(0, "schema", "changed")
	callbacks[4]({ items = { { name = "stale" } } })
	eq(catalog.entries(), {})
end

T["does not mark an isolated later page as a complete inventory"] = function()
	local snapshot = context.snapshot(0)
	local definition = inventory({ next = { items = { { name = "b" } } } })
	catalog.request(snapshot, definition, { cursor = "next" }, function() end)
	eq(catalog.cached(snapshot, definition).partial, true)
end

return T
