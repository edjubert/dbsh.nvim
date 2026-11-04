local helpers = dofile("tests/helpers.lua")
local eq = helpers.eq
local dbsh = require("dbsh")
local context = require("dbsh.context")
local catalog = require("dbsh.catalog")
local panel = require("dbsh.panel")
local tree = require("dbsh.panel_tree")
local scratch = require("dbsh.scratch")
local postgres = require("dbsh.backends.postgres")
local exec = require("dbsh.exec")

local root, source_buf, original_dir, original_runner, before_bufs
local calls

local function cached(definition, items, options, snapshot, cursor)
	local copy = vim.tbl_extend("force", definition, {
		list = function(_, callback) callback({ items = items, next_cursor = cursor }, nil) end,
	})
	catalog.request(snapshot or context.snapshot(source_buf), copy, options or {}, function() end)
end

local function find_node(nodes, kind, label)
	for _, node in pairs(nodes) do
		if node.kind == kind and (label == nil or node.label == label) then return node end
	end
	error("missing " .. kind .. " " .. tostring(label))
end

local function choose(session, kind, label)
	panel.action("expand_all")
	for row, node in pairs(session.entries) do
		if node.kind == kind and (label == nil or node.label == label) then
			vim.api.nvim_win_set_cursor(session.win, { row, 0 })
			return node
		end
	end
	error("missing panel entry " .. kind .. " " .. tostring(label))
end

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			vim.cmd("silent! tabonly")
			vim.cmd("silent! only")
			before_bufs = {}
			for _, buf in ipairs(vim.api.nvim_list_bufs()) do before_bufs[buf] = true end
			source_buf = vim.api.nvim_create_buf(true, false)
			vim.api.nvim_set_current_buf(source_buf)
			vim.bo[source_buf].filetype = "sql"
			vim.o.columns = 120
			dbsh.setup({
				connections = {
					local_db = {
						host = "localhost", port = 5432, database = "app", schema = "public", username = "dev",
					},
					staging = { host = "other", port = 5432, database = "stage", username = "dev" },
					atlas = {
						type = "mongo", srv = true, host = "cluster.test", database = "docs",
						username = "dev", password_command = { "secret-command" },
					},
					snow = {
						type = "snowflake", host = "account.test", port = 443, username = "dev",
						role = "ANALYST", warehouse = "COMPUTE", database = "WAREHOUSE", schema = "PUBLIC",
						authenticator = "https://sso.test", password_command = { "secret-command" },
					},
				},
				default = "local_db",
				catalog_page_size = 2,
				progress = { enabled = false },
			})
			root = vim.fn.tempname()
			original_dir = scratch._data_dir
			scratch._data_dir = function() return vim.fs.joinpath(root, "scratchpads") end
			original_runner = exec.runner
			calls = {}
			exec.runner = function(argv, opts, callback)
				table.insert(calls, { argv = argv, opts = opts, callback = callback })
				return { kill = function() end }
			end
		end,
		post_case = function()
			panel.setup()
			exec.runner, exec.slots = original_runner, {}
			scratch._data_dir = original_dir
			vim.cmd("silent! tabonly")
			vim.cmd("silent! only")
			for _, buf in ipairs(vim.api.nvim_list_bufs()) do
				if not before_bufs[buf] and vim.api.nvim_buf_is_valid(buf) then
					context.detach(buf)
					vim.api.nvim_buf_delete(buf, { force = true })
				end
			end
			vim.fn.delete(root, "rf")
		end,
	},
})

T["opens a read-only tree and expands only cached state without running a CLI"] = function()
	local before = context.snapshot(source_buf)
	local session = panel.open()
	panel.action("expand_all")
	panel.action("collapse_all")
	panel.action("expand_all")
	panel.action("refresh")
	eq(#calls, 0)
	eq(context.snapshot(source_buf), before)
	eq(vim.bo[session.bufnr].modifiable, false)
	eq(vim.wo[session.win].winfixwidth, true)
	eq(vim.api.nvim_win_get_width(session.win), 40)
	eq(panel.source_snapshot().bufnr, source_buf)
	eq(find_node(session.nodes, "schema", "public").snapshot.levels.database, "app")
	eq(find_node(session.nodes, "database", "docs").request.key, "collections")
	eq(find_node(session.nodes, "schema", "PUBLIC").snapshot.levels.role, "ANALYST")
end

T["merges cached tables and relations across schemas without duplication"] = function()
	local items = {
		{ value = { name = "users", schema = "public", oid = "1", relkind = "r" } },
		{ value = { name = "reports", schema = "analytics", oid = "2", relkind = "v" } },
	}
	cached(postgres.catalogs[1], items, { scope = { all_schemas = true } })
	cached(postgres.catalogs[2], { items[1] }, { scope = { schema = "public", all_schemas = false } })
	local _, nodes = tree.build(context.snapshot(source_buf))
	local count = 0
	for _, node in pairs(nodes) do if node.kind == "table" then count = count + 1 end end
	eq(count, 2)
	eq(find_node(nodes, "table", "reports [view]").snapshot.levels.schema, "analytics")
	eq(#calls, 0)
end

T["keeps filtered and incomplete inventories visibly loadable"] = function()
	cached(postgres.contexts[2], { { value = "filtered" } }, { query = "filter" })
	local _, nodes = tree.build(context.snapshot(source_buf))
	local db = find_node(nodes, "database", "app")
	eq(db.loaded, nil)
	eq(find_node(nodes, "load", "Load schemas…").parent ~= nil, true)
	eq(find_node(nodes, "schema", "filtered").parent, db.id)
end

T["groups persisted scratchpads and associated files without duplicate pads or result buffers"] = function()
	assert(scratch.create({
		id = "monthly", name = "Monthly", backend = "postgres", connection_name = "staging",
		levels = { database = "finance", schema = "reporting" },
	}))
	scratch.open("monthly")
	local pad_buf = vim.api.nvim_get_current_buf()
	vim.api.nvim_buf_set_lines(pad_buf, 0, -1, false, { "SELECT 'unsaved';" })
	local file = vim.api.nvim_create_buf(true, false)
	vim.api.nvim_buf_set_name(file, vim.fs.joinpath(root, "query.sql"))
	vim.bo[file].filetype = "sql"
	context.bind(file, "staging")
	local _, nodes = tree.build(context.snapshot(source_buf))
	local pad = find_node(nodes, "scratchpad", "Monthly [scratchpad] finance.reporting")
	eq(nodes[pad.parent].label, "staging")
	local found_file, count = false, 0
	for _, node in pairs(nodes) do
		if node.kind == "scratchpad" then count = count + 1 end
		if node.kind == "file" and node.bufnr == file then found_file = true end
		if node.kind == "file" then eq(node.bufnr == pad_buf, false) end
	end
	eq(count, 1)
	eq(found_file, true)
	eq(find_node(nodes, "schema", "reporting").snapshot.levels.database, "finance")
end

T["selects a database for the source buffer only and clears its old schema"] = function()
	local other = vim.api.nvim_create_buf(true, false)
	context.bind(other, "local_db")
	cached(postgres.contexts[1], { { value = "analytics" } })
	local session = panel.open()
	choose(session, "database", "analytics")
	panel.action("select")
	eq(context.current(source_buf).levels.database, "analytics")
	eq(context.current(source_buf).levels.schema, nil)
	eq(context.current(other).levels.database, "app")
	eq(context.current(session.bufnr).kind, "fallback")
	eq(#calls, 0)
end

T["fetches just the selected branch using its captured profile without changing the source"] = function()
	local before = context.snapshot(source_buf)
	local session = panel.open()
	choose(session, "database", "stage")
	panel.action("fetch")
	eq(#calls, 1)
	local argv = calls[1].argv
	eq(argv[vim.fn.index(argv, "-d") + 2], "stage")
	eq(argv[vim.fn.index(argv, "-h") + 2], "other")
	calls[1].callback({ code = 0, stdout = "tenant\n", stderr = "" })
	eq(vim.wait(1000, function() return session.loading == nil end, 10), true)
	eq(context.snapshot(source_buf), before)
	eq(find_node(session.nodes, "schema", "tenant").snapshot.connection_name, "staging")
	eq(#calls, 1)
end

T["loads the next page only when its load-more row is activated"] = function()
	local options = { scope = { schema = "public", all_schemas = false } }
	cached(postgres.catalogs[1], {
		{ value = { name = "a", schema = "public", oid = "1", relkind = "r" } },
	}, options, nil, postgres.encode_cursor({ "public", "a", "1" }))
	local session = panel.open()
	choose(session, "more", "Load more…")
	eq(#calls, 0)
	panel.action("open")
	eq(#calls, 1)
	calls[1].callback({ code = 0, stdout = "public\tb\tr\t2\n", stderr = "" })
	eq(vim.wait(1000, function() return session.loading == nil end, 10), true)
	find_node(session.nodes, "table", "a [table]")
	find_node(session.nodes, "table", "b [table]")
	local count = 0
	for _, node in pairs(session.nodes) do if node.kind == "more" then count = count + 1 end end
	eq(count, 0)
	eq(#calls, 1)
end

T["previews a cached table in the source context instead of the panel"] = function()
	local snapshot = context.snapshot(source_buf)
	snapshot.levels.database, snapshot.connection.database = "analytics", "analytics"
	cached(postgres.catalogs[1], {
		{ value = { name = "reports", schema = "tenant", oid = "3", relkind = "r" } },
	}, { scope = { all_schemas = true } }, snapshot)
	local session = panel.open()
	choose(session, "table", "reports [table]")
	local original_query, captured = dbsh.query
	dbsh.query = function(sql, value) captured = { sql = sql, snapshot = value } end
	panel.action("open")
	dbsh.query = original_query
	eq(captured.sql, 'SELECT * FROM "tenant"."reports" LIMIT 10;')
	eq(captured.snapshot.bufnr, source_buf)
	eq(captured.snapshot.connection.database, "analytics")
	eq(captured.snapshot.levels.schema, "tenant")
	eq(vim.api.nvim_get_current_buf(), source_buf)
	eq(#calls, 0)
end

T["reopens scratchpads beside the panel and keeps unsaved contents"] = function()
	assert(scratch.create({
		id = "debug", name = "Debug", backend = "postgres", connection_name = "local_db",
		levels = { database = "app" },
	}))
	scratch.open("debug")
	local pad_buf = vim.api.nvim_get_current_buf()
	vim.api.nvim_buf_set_lines(pad_buf, 0, -1, false, { "SELECT 'unsaved';" })
	local session = panel.open()
	choose(session, "scratchpad", "Debug [scratchpad] app")
	panel.action("open")
	eq(vim.api.nvim_get_current_buf(), pad_buf)
	eq(vim.api.nvim_win_get_buf(session.win), session.bufnr)
	eq(vim.api.nvim_buf_get_lines(pad_buf, 0, -1, false), { "SELECT 'unsaved';" })
	eq(vim.bo[pad_buf].modified, true)
end

T["preserves folds and cached data across close and reopen"] = function()
	local session = panel.open()
	local node = choose(session, "database", "app")
	panel.action("left")
	eq(session.closed[node.id], true)
	panel.close()
	eq(vim.api.nvim_get_current_buf(), source_buf)
	eq(panel.open(), session)
	eq(session.closed[node.id], true)
	eq(session.entries[vim.api.nvim_win_get_cursor(session.win)[1]].id, node.id)
	eq(#calls, 0)
end

T["opens from a result float using its original query buffer"] = function()
	local results = require("dbsh.results")
	results.running(context.snapshot(source_buf), "SELECT 1;", { split = "float" })
	eq(vim.api.nvim_win_get_config(0).relative, "editor")
	local session = panel.open()
	eq(panel.source_snapshot().bufnr, source_buf)
	eq(vim.api.nvim_win_get_config(session.win).relative, "")
	eq(#calls, 0)
end

T["reinitializes safely when the panel is the tab's last window"] = function()
	local session = panel.open()
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(session.tab)) do
		if win ~= session.win then vim.api.nvim_win_close(win, true) end
	end
	panel.setup()
	eq(vim.bo.buftype, "")
	eq(#vim.api.nvim_tabpage_list_wins(0), 1)
end

T["redraws new picker cache entries without moving the editor focus"] = function()
	local session = panel.open()
	local win = session.source_win
	vim.api.nvim_set_current_win(win)
	cached(postgres.catalogs[1], {
		{ value = { name = "arrived", schema = "public", oid = "4", relkind = "r" } },
	}, { scope = { schema = "public", all_schemas = false } })
	eq(vim.wait(1000, function()
		for _, node in pairs(session.nodes) do if node.kind == "table" then return true end end
		return false
	end, 10), true)
	eq(vim.api.nvim_get_current_win(), win)
	eq(#calls, 0)
end

T["keeps Snowflake and Mongo previews on their captured branch contexts"] = function()
	for _, name in ipairs({ "snow", "atlas" }) do
		local snapshot = vim.deepcopy(context.snapshot(source_buf))
		snapshot.connection = assert(require("dbsh.config").connection(name))
		snapshot.connection_name, snapshot.backend_name = name, snapshot.connection.type
		snapshot.levels = {}
		for _, key in ipairs({ "database", "schema", "role", "warehouse" }) do
			snapshot.levels[key] = snapshot.connection[key]
		end
		local backend = context.backend(snapshot)
		local definition
		for _, value in ipairs(backend.catalogs) do
			if value.key == "relations" or value.key == "collections" then definition = value end
		end
		cached(definition, {
			{ value = {
				name = "items", database = snapshot.levels.database, schema = snapshot.levels.schema,
				kind = name == "atlas" and "collection" or "relation",
			} },
		}, { scope = snapshot.levels.schema and { schema = snapshot.levels.schema, all_schemas = false } or {} }, snapshot)
		local session = panel.open()
		local wanted = name == "atlas" and "items [collection]" or "items [relation]"
		choose(session, "table", wanted)
		local original_query, captured = dbsh.query
		dbsh.query = function(sql, value) captured = { sql = sql, snapshot = value } end
		panel.action("open")
		dbsh.query = original_query
		eq(captured.snapshot.bufnr, source_buf)
		eq(captured.snapshot.connection_name, name)
		eq(captured.snapshot.connection.database, snapshot.levels.database)
		eq(captured.snapshot.levels.schema, snapshot.levels.schema)
	end
	eq(#calls, 0)
end

T["keeps panels independent between tabs"] = function()
	local first = panel.open()
	local first_tab = vim.api.nvim_get_current_tabpage()
	vim.cmd("tabnew")
	local second = panel.open()
	eq(first.bufnr == second.bufnr, false)
	panel.close()
	eq(vim.api.nvim_win_is_valid(first.win), true)
	vim.api.nvim_set_current_tabpage(first_tab)
	eq(panel.open(), first)
end

T["refuses global query-reading mappings in the panel"] = function()
	panel.open()
	dbsh.query_current_line()
	dbsh.query_paragraph()
	dbsh.export_csv()
	eq(#calls, 0)
end

T["cancels a pending catalog when its owning source context changes"] = function()
	local session = panel.open()
	choose(session, "database", "app")
	panel.action("fetch")
	eq(session.loading ~= nil, true)
	context.set_level(source_buf, "database", "changed")
	eq(session.loading, nil)
	calls[1].callback({ code = 0, stdout = "stale\n", stderr = "" })
	vim.wait(50)
	eq(catalog.entries(), {})
end

return T
