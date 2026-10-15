local helpers = dofile("tests/helpers.lua")
local eq, expect_match = helpers.eq, helpers.expect_match
local mongo = require("dbsh.backends.mongo")
local context = require("dbsh.context")
local catalog = require("dbsh.catalog")
local config = require("dbsh.config")
local exec = require("dbsh.exec")
local pickers = require("dbsh.telescope.pickers")

local originals
local connection = {
	type = "mongo", srv = true, host = "cluster.example.test", database = "analytics",
	username = "analyst", password_command = { "password-command" },
}
local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			config.setup({ connections = { atlas = connection }, default = "atlas", catalog_page_size = 2 })
			context.setup()
			originals = {
				run = exec.run, select = vim.ui.select, telescope = pickers._telescope,
				query = require("dbsh").query,
				render = require("dbsh.results").render, open = require("dbsh.results").open,
			}
			pickers._telescope = function() return nil end
		end,
		post_case = function()
			exec.run = originals.run
			vim.ui.select = originals.select
			pickers._telescope = originals.telescope
			require("dbsh").query = originals.query
			require("dbsh.results").render = originals.render
			require("dbsh.results").open = originals.open
		end,
	},
})

local function definition(key)
	if key == "databases" then return mongo.contexts[1] end
	for _, value in ipairs(mongo.catalogs) do
		if value.key == key then return value end
	end
end

local function inventory(key, rows, options)
	local received
	exec.run = function(query, opts, callback)
		received = { query = query, opts = opts }
		callback(0, vim.json.encode(rows), "")
	end
	local page, err
	catalog.request(context.snapshot(0), definition(key), options or {}, function(p, e)
		page, err = p, e
	end)
	return page, err, received
end

T["lists all authorized databases for local search regardless of page size"] = function()
	local rows = { ok = 1, databases = { { name = "z" }, { name = "analytics" }, { name = "admin" } } }
	local page, err, received = inventory("databases", rows)
	eq(err, nil)
	eq(page.items, {
		{ value = "admin", display = "admin" }, { value = "analytics", display = "analytics" },
		{ value = "z", display = "z" },
	})
	eq(page.next_cursor, nil)
	eq(received.opts.context.connection.database, "analytics")
	eq(received.opts.slot, "introspect")
	eq(received.opts.mode, "raw")
	local command = vim.json.decode(received.query:match("^db.adminCommand%((.*)%)$"))
	eq(command, { listDatabases = 1, nameOnly = true, authorizedDatabases = true })
end

T["keeps listDatabases first even when the JSON encoder puts filter first"] = function()
	local encode = vim.json.encode
	vim.json.encode = function(value)
		if type(value) == "table" and value.listDatabases ~= nil then
			return '{"filter":' .. encode(value.filter or {})
				.. ',"listDatabases":1,"nameOnly":true,"authorizedDatabases":true}'
		end
		return encode(value)
	end
	local ok, err = pcall(function()
		for _, filter in ipairs({ "", "pla", "a.b" }) do
			local query = mongo.catalog_query("databases", { query = filter })
			local command = query:match("^db.adminCommand%((.*)%)$")
			eq(command:match('^%{"([^"]+)":'), "listDatabases")
			local decoded = vim.json.decode(command)
			eq(decoded.listDatabases, 1)
			eq(decoded.nameOnly, true)
			eq(decoded.authorizedDatabases, true)
			if filter ~= "" then
				eq(decoded.filter.name["$options"], "i")
			end
		end
	end)
	vim.json.encode = encode
	assert(ok, err)
end

T["lists collections and views with literal case-insensitive filtering"] = function()
	local page, err, received = inventory("collections", {
		{ name = "a.b", type = "view" }, { name = "axb", type = "collection" },
		{ name = "A.B_more", type = "collection" },
	}, { query = "a.b" })
	eq(err, nil)
	eq(#page.items, 2)
	eq(page.items[1].value, { kind = "collection", database = "analytics", name = "A.B_more" })
	eq(page.items[2].value.kind, "view")
	local filter = vim.json.decode(received.query:match("^db.getCollectionInfos%((.*), true, true%)$"))
	eq(filter, { name = { ["$regex"] = "a\\.b", ["$options"] = "i" } })
end

T["lists every collection and view for local search beyond page size"] = function()
	local rows = {
		{ name = "branches", type = "collection" }, { name = "alpha", type = "collection" },
		{ name = "beta", type = "view" },
	}
	for _, key in ipairs({ "collections", "preview" }) do
		local page, err = inventory(key, rows)
		eq(err, nil)
		eq(vim.tbl_map(function(item) return item.value.name end, page.items), { "alpha", "beta", "branches" })
		eq(page.items[2].value.kind, "view")
		eq(page.next_cursor, nil)
	end
end

T["handles empty inventories without load more"] = function()
	local page, err = inventory("collections", {})
	eq(err, nil)
	eq(page.items, {})
	eq(page.next_cursor, nil)
	page, err = inventory("databases", { ok = 1, databases = {} })
	eq(err, nil)
	eq(page.items, {})
end

T["rejects invalid metadata and cursors"] = function()
	local _, err = inventory("collections", { { type = "collection" } })
	expect_match(err, "invalid Mongo catalog entry")
	_, err = inventory("databases", { ok = 1 })
	expect_match(err, "invalid Mongo database inventory")
	local ran = false
	exec.run = function() ran = true end
	catalog.request(context.snapshot(0), definition("collections"), {
		cursor = '["bad"]',
	}, function(_, e) err = e end)
	expect_match(err, "invalid Mongo catalog cursor")
	eq(ran, false)
end

T["lists full index specifications with literal-name quoting"] = function()
	local name = 'events."quoted"'
	local spec = { name = "created_1", key = { created = 1 }, unique = true, partialFilterExpression = { active = true } }
	local page, err, received = inventory("indexes", { spec, { name = "_id_", key = { _id = 1 } } }, {
		relation = { name = name, database = "analytics" }, query = "created",
	})
	eq(err, nil)
	eq(received.query, "db.getCollection(" .. vim.json.encode(name) .. ").getIndexes()")
	eq(#page.items, 1)
	eq(page.items[1].value.spec, spec)
	eq(page.items[1].value.collection, name)
end

T["requires a collection from the active database for indexes"] = function()
	local query, err = mongo.catalog_query("indexes", { context = { database = "analytics" } })
	eq(query, nil)
	expect_match(err, "require a collection")
	query, err = mongo.catalog_query("indexes", {
		context = { database = "analytics" }, relation = { database = "other", name = "events" },
	})
	eq(query, nil)
	expect_match(err, "another database")
end

T["sanitizes Mongo errors before returning them to the picker"] = function()
	local err
	exec.run = function(_, _, callback)
		callback(1, "", "MongoServerError: not authorized mongodb://user:private@host")
	end
	catalog.request(context.snapshot(0), definition("collections"), {}, function(_, e) err = e end)
	expect_match(err, "access denied")
	eq(err:find("private", 1, true), nil)
end

T["reports the error category without exposing raw CLI output"] = function()
	exec.run = function(_, _, callback)
		callback(1, "", "MongoServerError: no such command: 'filter'; mongodb://user:private@host")
	end
	local err
	catalog.request(context.snapshot(0), definition("databases"), {}, function(_, e) err = e end)
	eq(err, "Mongo catalog request failed (MongoServerError, exit 1)")
	eq(err:find("private", 1, true), nil)
end

T["changes only the selected buffer database and preserves the profile"] = function()
	local source = vim.api.nvim_get_current_buf()
	local other = vim.api.nvim_create_buf(false, true)
	local snapshot = context.snapshot(source)
	assert(mongo.contexts[1].apply(snapshot, "plato"))
	eq(context.snapshot(source).connection.database, "plato")
	eq(context.snapshot(other).connection.database, "analytics")
	eq(config.connection("atlas").database, "analytics")
	vim.api.nvim_buf_delete(other, { force = true })
end

T["selects a database beyond page size without requesting another page"] = function()
	local queries = {}
	exec.run = function(query, _, callback)
		table.insert(queries, query)
		callback(0, vim.json.encode({ databases = { { name = "a" }, { name = "b" }, { name = "c" } } }), "")
	end
	vim.ui.select = function(items, _, callback)
		eq(#items, 3)
		callback(items[3])
	end
	pickers.context("database")
	eq(#queries, 1)
	eq(context.snapshot(0).connection.database, "c")
end

T["lets Telescope search the complete database inventory without a request callback"] = function()
	local calls, received, items = 0
	exec.run = function(_, _, callback)
		calls = calls + 1
		callback(0, '{"databases":[{"name":"admin"},{"name":"analytics"},{"name":"plato"}]}', "")
	end
	pickers._telescope = function()
		return {
			pickers = { new = function(_, options)
				received = options
				return { find = function() assert(options.attach_mappings(1, function() end)) end }
			end },
			finders = { new_table = function(options) items = options.results; return {} end },
			conf = { generic_sorter = function() return {} end },
			actions = { close = function() end },
			state = { get_selected_entry = function() return nil end },
		}
	end
	pickers.context("database")
	eq(received.on_input_filter_cb, nil)
	eq(vim.tbl_map(function(item) return item.value end, items), { "admin", "analytics", "plato" })
	eq(calls, 1)
end

T["searches collections locally and previews a selection beyond page size"] = function()
	for _, key in ipairs({ "collections", "preview" }) do
		local calls, received, items, maps, queries = 0, nil, nil, {}, {}
		exec.run = function(_, _, callback)
			calls = calls + 1
			callback(0, '[{"name":"alpha"},{"name":"beta","type":"view"},{"name":"branches"}]', "")
		end
		require("dbsh").query = function(query, snapshot)
			table.insert(queries, { query = query, snapshot = snapshot })
		end
		pickers._telescope = function()
			return {
				pickers = { new = function(_, options)
					received = options
					return { find = function()
						assert(options.attach_mappings(1, function(mode, mapping, action)
							maps[mode .. mapping] = action
						end))
					end }
				end },
				finders = { new_table = function(options) items = options.results; return {} end },
				conf = { generic_sorter = function() return {} end },
				actions = { close = function() end },
				state = { get_selected_entry = function() return { value = items[3] } end },
			}
		end
		pickers.catalog(key)
		eq(received.on_input_filter_cb, nil)
		eq(vim.tbl_map(function(item) return item.value.name end, items), { "alpha", "beta", "branches" })
		eq(calls, 1)
		eq(#queries, 0)
		maps["i<CR>"]()
		eq(calls, 1)
		eq(#queries, 1)
		eq(queries[1].query, 'db.getCollection("branches").find({}, null, { limit: 10 })')
		eq(queries[1].snapshot.connection.database, "analytics")
	end
end

T["asks for a collection before indexes without running a preview"] = function()
	local queries, count = {}, 0
	local previewed = false
	require("dbsh").query = function() previewed = true end
	exec.run = function(query, _, callback)
		table.insert(queries, query)
		callback(0, vim.json.encode(#queries == 1 and { { name = "events", type = "collection" } }
			or { { name = "_id_", key = { _id = 1 } } }), "")
	end
	vim.ui.select = function(items, _, callback)
		count = count + 1
		callback(count == 1 and items[1] or nil)
	end
	pickers.catalog("indexes")
	eq(queries, { "db.getCollectionInfos({}, true, true)", 'db.getCollection("events").getIndexes()' })
	eq(previewed, false)
end

T["previews safely quoted names with the configured limit and source context"] = function()
	local source = context.snapshot(0)
	local got
	require("dbsh").query = function(query, snapshot) got = { query = query, snapshot = snapshot } end
	local name = 'events.\\");db.dropDatabase();//'
	local item = { value = { name = name, database = "analytics", kind = "collection" } }
	definition("collections").on_select(item, source, { preview_limit = 7 })
	eq(got.query, "db.getCollection(" .. vim.json.encode(name) .. ").find({}, null, { limit: 7 })")
	eq(got.snapshot, source)
	eq(mongo.classify(got.query).action, "run")
	eq(mongo.preview_query(item, 0), "db.getCollection(" .. vim.json.encode(name) .. ").find({}, null, { limit: 10 })")
end

T["ignores a selection after the source context has changed"] = function()
	exec.run = function(_, _, callback)
		callback(0, '[{"name":"events","type":"collection"}]', "")
	end
	local previewed = false
	require("dbsh").query = function() previewed = true end
	vim.ui.select = function(items, _, callback)
		assert(context.set_level(0, "database", "other"))
		callback(items[1])
	end
	pickers.catalog("collections")
	eq(previewed, false)
end

T["renders the selected full index specification without another request"] = function()
	local spec = { name = "expires_1", key = { expires = 1 }, expireAfterSeconds = 3600 }
	local snapshot = context.snapshot(0)
	local rendered
	require("dbsh.results").open = function() end
	require("dbsh.results").render = function(source, query, output)
		rendered = { source = source, query = query, spec = vim.json.decode(output) }
	end
	exec.run = function() error("index selection must use fetched metadata") end
	definition("indexes").on_select({
		value = { name = spec.name, collection = "events", spec = spec },
	}, snapshot, { results_split = "float" })
	eq(rendered.source, snapshot)
	eq(rendered.query, 'db.getCollection("events").getIndexes()')
	eq(rendered.spec, spec)
end

T["keeps the source database when the user changes buffers before choosing a collection"] = function()
	local source_buf = vim.api.nvim_get_current_buf()
	local other = vim.api.nvim_create_buf(false, true)
	assert(context.bind(other, "atlas"))
	assert(context.set_level(other, "database", "other"))
	local databases, count = {}, 0
	exec.run = function(_, options, callback)
		table.insert(databases, options.context.connection.database)
		callback(0, count == 0 and '[{"name":"events","type":"collection"}]' or "[]", "")
	end
	vim.ui.select = function(items, _, callback)
		count = count + 1
		if count == 1 then
			vim.api.nvim_set_current_buf(other)
			callback(items[1])
		else
			callback(nil)
		end
	end
	pickers.catalog("indexes")
	eq(databases, { "analytics", "analytics" })
	vim.api.nvim_set_current_buf(source_buf)
	vim.api.nvim_buf_delete(other, { force = true })
end

T["executes document previews against the captured context"] = function()
	local snapshot = context.snapshot(0)
	local other = vim.api.nvim_create_buf(false, true)
	assert(context.bind(other, "atlas"))
	assert(context.set_level(other, "database", "other"))
	local executed
	require("dbsh.results").open = function() end
	local results = require("dbsh.results")
	local running = results.running
	results.running = function() end
	exec.run = function(query, options)
		executed = { query = query, database = options.context.connection.database }
	end
	vim.api.nvim_set_current_buf(other)
	local ok, err = pcall(function()
		definition("collections").on_select({ value = { name = "events" } }, snapshot, { preview_limit = 3 })
	end)
	results.running = running
	vim.api.nvim_set_current_buf(snapshot.bufnr)
	vim.api.nvim_buf_delete(other, { force = true })
	assert(ok, err)
	eq(executed, { query = 'db.getCollection("events").find({}, null, { limit: 3 })', database = "analytics" })
end

return T
