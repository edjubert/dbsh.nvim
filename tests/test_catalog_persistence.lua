local helpers = dofile("tests/helpers.lua")
local eq = helpers.eq
local catalog = require("dbsh.catalog")
local config = require("dbsh.config")
local context = require("dbsh.context")

local root, original_dir, original_rename, original_notify
local options = {
	connections = {
		local_db = { host = "localhost", port = 5432, database = "app", schema = "public", username = "dev" },
	},
	default = "local_db",
	progress = { enabled = false },
}

local function definition(pages)
	return {
		key = "relations",
		list = function(request, callback) callback(pages[request.cursor or "first"], nil) end,
	}
end

local function read_store(key)
	return vim.json.decode(table.concat(vim.fn.readfile(catalog.path(key)), "\n"))
end

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			root = vim.fn.tempname()
			original_dir, original_rename, original_notify = catalog.dir, catalog._rename, vim.notify
			catalog.dir = function() return vim.fs.joinpath(root, "catalog") end
			catalog.clear()
			config.setup(options)
			context.setup()
		end,
		post_case = function()
			catalog.clear()
			catalog.dir, catalog._rename, vim.notify = original_dir, original_rename, original_notify
			vim.fn.delete(root, "rf")
		end,
	},
})

T["restores pages and pagination after resetting the runtime"] = function()
	local snapshot = context.snapshot(0)
	local request = definition({
		first = { items = { { name = "a" } }, next_cursor = "next" },
		next = { items = { { name = "b" } } },
	})
	catalog.request(snapshot, request, {}, function() end)
	context.setup()
	catalog.setup()
	snapshot = context.snapshot(0)
	eq(catalog.cached(snapshot, request).items, { { name = "a" } })
	eq(catalog.cached(snapshot, request).next_cursor, "next")
	catalog.request(snapshot, request, { cursor = "next" }, function() end)
	catalog.setup()
	eq(catalog.cached(snapshot, request).items, { { name = "a" }, { name = "b" } })
	eq(catalog.cached(snapshot, request).partial, false)
	eq(catalog.cached(snapshot, request).next_cursor, nil)
	catalog.request(snapshot, request, {}, function() end)
	catalog.setup()
	eq(catalog.cached(snapshot, request).items, { { name = "a" } })
end

T["persists only public catalog data without credentials or runtime identities"] = function()
	local snapshot = context.snapshot(0)
	snapshot.connection.password = "never-persist-password"
	snapshot.connection.password_command = { "never-persist-command" }
	local request = definition({ first = { items = { { name = "users" } } } })
	catalog.request(snapshot, request, {}, function() end)
	local store = read_store(catalog.cache_key(snapshot, request))
	eq(store.version, 1)
	eq(store.entry.context, {
		connection_name = "local_db", backend = "postgres",
		levels = { database = "app", schema = "public" },
	})
	local text = vim.inspect(store)
	eq(text:find("never-persist", 1, true), nil)
	eq(store.entry.context.id, nil)
	eq(store.entry.context.bufnr, nil)
	eq(store.entry.context.generation, nil)
end

T["restores filtered and partial entries without mixing scopes"] = function()
	local snapshot = context.snapshot(0)
	local request = definition({ first = { items = { { name = "filtered" } } }, next = { items = {} } })
	local scope = { schema = "public", all_schemas = false }
	catalog.request(snapshot, request, { scope = scope, query = "filter" }, function() end)
	catalog.request(snapshot, request, { scope = { all_schemas = true }, cursor = "next" }, function() end)
	catalog.setup()
	eq(catalog.cached(snapshot, request, { scope = scope, query = "filter" }).items, { { name = "filtered" } })
	eq(catalog.cached(snapshot, request, { scope = scope }), nil)
	eq(catalog.cached(snapshot, request, { scope = { all_schemas = true } }).partial, true)
end

T["ignores caches belonging to a changed connection profile"] = function()
	local request = definition({ first = { items = { { name = "old_host" } } } })
	catalog.request(context.snapshot(0), request, {}, function() end)
	local changed = vim.deepcopy(options)
	changed.connections.local_db.host = "other"
	config.setup(changed)
	context.setup()
	catalog.setup()
	eq(catalog.entries(), {})
	config.setup(options)
	context.setup()
	catalog.setup()
	eq(catalog.cached(context.snapshot(0), request).items, { { name = "old_host" } })
end

T["ignores corrupted files and unsupported versions while keeping good entries"] = function()
	local snapshot = context.snapshot(0)
	local request = definition({ first = { items = { { name = "good" } } } })
	catalog.request(snapshot, request, {}, function() end)
	vim.fn.writefile({ "{not json" }, vim.fs.joinpath(catalog.dir(), "broken.json"))
	vim.fn.writefile({ '{"version":2,"entry":{}}' }, vim.fs.joinpath(catalog.dir(), "future.json"))
	vim.fn.writefile({ '{"version":1,"entry":{"items":[]}}' }, vim.fs.joinpath(catalog.dir(), "invalid.json"))
	catalog.setup()
	eq(#catalog.entries(), 1)
	eq(catalog.cached(snapshot, request).items, { { name = "good" } })
end

T["rejects invalid persisted items and cache identities"] = function()
	local snapshot = context.snapshot(0)
	local request = definition({ first = { items = { { name = "good" } } } })
	catalog.request(snapshot, request, {}, function() end)
	local key = catalog.cache_key(snapshot, request)
	local store = read_store(key)
	store.entry.items = { "bad item" }
	vim.fn.writefile({ vim.json.encode(store) }, catalog.path(key))
	catalog.setup()
	eq(catalog.entries(), {})
	store.entry.items = { { name = "good" } }
	store.entry.scope = { schema = "other" }
	vim.fn.writefile({ vim.json.encode(store) }, catalog.path(key))
	catalog.setup()
	eq(catalog.entries(), {})
end

T["explicit clearing removes persistent pages and rejects pending callbacks"] = function()
	local request = definition({ first = { items = { { name = "old" } } } })
	catalog.request(context.snapshot(0), request, {}, function() end)
	local respond
	request.list = function(_, callback) respond = callback end
	catalog.request(context.snapshot(0), request, {}, function() end)
	catalog.clear()
	respond({ items = { { name = "late" } } }, nil)
	catalog.setup()
	eq(catalog.entries(), {})
	eq(vim.fn.isdirectory(catalog.dir()), 0)
end

T["failed replacement preserves the previous file and still returns the new page"] = function()
	local snapshot = context.snapshot(0)
	local request = definition({ first = { items = { { name = "old" } } } })
	catalog.request(snapshot, request, {}, function() end)
	catalog._rename = function() return nil, "rename failed" end
	local notices = {}
	vim.notify = function(message) table.insert(notices, message) end
	request.list = function(_, callback) callback({ items = { { name = "new" } } }, nil) end
	local page, err
	catalog.request(snapshot, request, {}, function(value, failure) page, err = value, failure end)
	eq(page.items, { { name = "new" } })
	eq(err, nil)
	eq(#notices, 1)
	eq(read_store(catalog.cache_key(snapshot, request)).entry.items, { { name = "old" } })
	eq(#vim.fn.globpath(catalog.dir(), "*", false, true), 1)
end

T["storage errors do not fail successful catalog requests"] = function()
	vim.fn.mkdir(root, "p")
	vim.fn.writefile({ "not a directory" }, catalog.dir())
	local notices = {}
	vim.notify = function(message) table.insert(notices, message) end
	local request = definition({ first = { items = { { name = "users" } } } })
	local page, err
	catalog.request(context.snapshot(0), request, {}, function(value, failure) page, err = value, failure end)
	eq(page.items, { { name = "users" } })
	eq(err, nil)
	eq(#notices, 1)
	eq(catalog.cached(context.snapshot(0), request).items, page.items)
end

T["independent writers preserve unrelated catalog pages"] = function()
	local other = dofile("lua/dbsh/catalog.lua")
	other.dir = catalog.dir
	other.setup()
	local request = definition({ first = { items = { { name = "users" } } } })
	catalog.request(context.snapshot(0), request, { query = "first" }, function() end)
	other.request(context.snapshot(0), request, { query = "second" }, function() end)
	catalog.setup()
	eq(#catalog.entries(), 2)
	eq(catalog.cached(context.snapshot(0), request, { query = "first" }).items, { { name = "users" } })
	eq(catalog.cached(context.snapshot(0), request, { query = "second" }).items, { { name = "users" } })
end

T["restores the sidebar in a second Neovim process without fetching cached branches"] = function()
	local script = vim.fs.joinpath(root, "session.lua")
	vim.fn.mkdir(root, "p")
	local common = {
		"vim.opt.runtimepath:append(" .. string.format("%q", vim.fn.getcwd()) .. ")",
		"local catalog = require('dbsh.catalog')",
		"catalog.dir = function() return " .. string.format("%q", catalog.dir()) .. " end",
		"require('dbsh').setup(vim.json.decode(" .. string.format("%q", vim.json.encode(options)) .. "))",
	}
	local first = vim.list_extend(vim.deepcopy(common), {
		"local request = vim.tbl_extend('force', require('dbsh.backends.postgres').catalogs[1], {",
		"  list = function(_, callback) callback({",
		"    items = { { value = { name = 'users', schema = 'public', oid = '1', relkind = 'r' } } },",
		"    next_cursor = vim.json.encode({ 'public', 'users', '1' }),",
		"  }, nil) end,",
		"})",
		"catalog.request(require('dbsh.context').snapshot(0), request,",
		"  { scope = { schema = 'public', all_schemas = false } }, function() end)",
	})
	vim.fn.writefile(first, script)
	local result = vim.system({ vim.v.progpath, "--headless", "--noplugin", "-u", "NONE", "-l", script },
		{ text = true }):wait(5000)
	eq({ result.code, result.stderr }, { 0, "" })
	local second = vim.list_extend(vim.deepcopy(common), {
		"local calls = 0",
		"require('dbsh.exec').runner = function() calls = calls + 1 end",
		"local panel = require('dbsh.panel')",
		"local session = panel.open()",
		"local schema",
		"for row, node in pairs(session.entries) do",
		"  if node.kind == 'schema' and node.label == 'public' then",
		"    schema = node",
		"    vim.api.nvim_win_set_cursor(session.win, { row, 0 })",
		"  end",
		"end",
		"assert(schema and schema.loaded)",
		"panel.action('left')",
		"panel.action('open')",
		"local found, more = false, false",
		"for _, node in pairs(session.nodes) do",
		"  if node.kind == 'table' and node.label == 'users [table]' then found = true end",
		"  if node.kind == 'more' then more = true end",
		"end",
		"assert(found and more and calls == 0)",
	})
	vim.fn.writefile(second, script)
	result = vim.system({ vim.v.progpath, "--headless", "--noplugin", "-u", "NONE", "-l", script },
		{ text = true }):wait(5000)
	eq({ result.code, result.stderr }, { 0, "" })
end

return T
