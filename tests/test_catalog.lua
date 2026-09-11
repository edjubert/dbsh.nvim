local helpers = dofile("tests/helpers.lua")
local eq, expect_match = helpers.eq, helpers.expect_match

local catalog = require("dbsh.catalog")
local config = require("dbsh.config")
local context = require("dbsh.context")

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
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

T["forwards scope, query, cursor, and an explicit page size"] = function()
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
	}, function() end)

	eq(received.limit, 25)
	eq(received.scope, { schema = "analytics", all_schemas = false })
	eq(received.query, "events")
	eq(received.cursor, "cursor-1")
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

return T
