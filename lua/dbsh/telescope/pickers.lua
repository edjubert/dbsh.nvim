-- Telescope pickers: the connection picker, the generic catalog picker, and
-- the variable prompt. The catalog levels themselves are declared by the
-- backend, so this file knows no database vocabulary at all.
-- Telescope is an optional dependency: every picker degrades to a clear
-- message when it is not installed.

local config = require("dbsh.config")
local catalog = require("dbsh.catalog")
local context = require("dbsh.context")
local scratch = require("dbsh.scratch")

local M = {}

-- Injection point: tests replace this to simulate a missing Telescope.
function M._telescope()
	local ok = pcall(require, "telescope")
	if not ok then
		return nil
	end
	return {
		pickers = require("telescope.pickers"),
		finders = require("telescope.finders"),
		conf = require("telescope.config").values,
		actions = require("telescope.actions"),
		state = require("telescope.actions.state"),
	}
end

local function require_telescope()
	local t = M._telescope()
	if t == nil then
		vim.notify(
			"psql.nvim: telescope.nvim is required for this picker",
			vim.log.levels.ERROR
		)
	end
	return t
end

local function notify_error(err)
	vim.notify("dbsh.nvim: " .. err, vim.log.levels.ERROR)
end

local function open(t, opts)
	t.pickers.new({}, {
		prompt_title = opts.title,
		finder = t.finders.new_table({
			results = opts.results,
			entry_maker = opts.entry_maker,
		}),
		sorter = t.conf.generic_sorter({}),
		attach_mappings = opts.attach_mappings,
		on_input_filter_cb = opts.on_input_filter_cb,
	}):find()
end

local function plain_entry(value)
	return { value = value, display = value, ordinal = value }
end

-- Binds <CR> explicitly in both modes instead of replacing select_default:
-- a user config that remaps <CR> to another action (e.g. select_tab_drop)
-- would otherwise silently bypass a select_default override.
local function bind_enter(t, bufnr, map, handler)
	local select = function()
		local entry = t.state.get_selected_entry()
		t.actions.close(bufnr)
		handler(entry)
	end
	map("i", "<CR>", select)
	map("n", "<CR>", select)
end

local function scratchpad_label(item)
	if item.kind == "new" then
		return "New scratchpad"
	end
	if item.kind == "legacy" then
		return "Migrate legacy scratchpad: " .. item.connection_name
	end
	if item.error ~= nil then
		return string.format("%s (metadata unavailable)", item.id)
	end
	local metadata = item.metadata
	local levels = {}
	for key, value in pairs(metadata.levels or {}) do
		table.insert(levels, key .. "=" .. tostring(value))
	end
	table.sort(levels)
	return table.concat({
		metadata.name,
		metadata.backend,
		metadata.connection_name or "no connection",
		table.concat(levels, ", "),
	}, " — ")
end

local function scratchpad_entry(item)
	local label = scratchpad_label(item)
	return { value = item, display = label, ordinal = label }
end

local function choose_project_root(callback)
	local choices = {
		{ kind = "current", label = "Current/project directory" },
		{ kind = "choose", label = "Choose directory" },
		{ kind = "standalone", label = "Standalone" },
	}
	vim.ui.select(choices, {
		prompt = "dbsh scratchpad project root: ",
		format_item = function(choice) return choice.label end,
	}, function(choice)
		if choice == nil then
			return
		end
		if choice.kind == "current" then
			callback(vim.fn.getcwd())
		elseif choice.kind == "choose" then
			vim.ui.input({
				prompt = "dbsh scratchpad directory: ",
				default = vim.fn.getcwd(),
				completion = "dir",
			}, function(directory)
				if directory ~= nil and vim.trim(directory) ~= "" then
					callback(vim.trim(directory))
				end
			end)
		else
			callback(nil)
		end
	end)
end

function M.new_scratchpad()
	vim.ui.select(config.names(), {
		prompt = "dbsh scratchpad connection: ",
	}, function(connection_name)
		if connection_name == nil then
			return
		end
		local connection, err = config.connection(connection_name)
		if connection == nil then
			return notify_error(err)
		end
		local levels = {}
		for _, key in ipairs({ "database", "schema", "role", "warehouse" }) do
			if connection[key] ~= nil then
				levels[key] = connection[key]
			end
		end

		choose_project_root(function(project_root)
			vim.ui.input({
				prompt = "dbsh scratchpad name: ",
				default = connection_name,
			}, function(name)
				if name == nil or vim.trim(name) == "" then
					return
				end
				local item, create_err = scratch.create({
					name = vim.trim(name),
					backend = connection.type or "postgres",
					connection_name = connection_name,
					levels = levels,
					project_root = project_root,
				})
				if item == nil then
					return notify_error(create_err)
				end
				scratch.open(item.id)
			end)
		end)
	end)
end

local function select_scratchpad(item)
	if item == nil then
		return
	end
	if item.kind == "new" then
		return M.new_scratchpad()
	end
	if item.kind == "legacy" then
		local migrated, err = scratch.migrate_legacy(item.connection_name)
		if migrated == nil then
			return notify_error(err)
		end
		return scratch.open(migrated.id)
	end
	if item.error ~= nil then
		return notify_error(item.error)
	end
	scratch.open(item.id)
end

function M.scratchpads()
	local items = { { kind = "new" } }
	for _, item in ipairs(scratch.list()) do
		table.insert(items, item)
	end
	for _, item in ipairs(scratch.legacy()) do
		item.kind = "legacy"
		table.insert(items, item)
	end

	local t = M._telescope()
	if t == nil then
		vim.ui.select(items, {
			prompt = "dbsh scratchpads: ",
			format_item = scratchpad_label,
		}, select_scratchpad)
		return
	end

	open(t, {
		title = "dbsh scratchpads",
		results = items,
		entry_maker = scratchpad_entry,
		attach_mappings = function(bufnr, map)
			bind_enter(t, bufnr, map, function(entry)
				select_scratchpad(entry and entry.value)
			end)
			return true
		end,
	})
end

local function contract_for(backend, kind, key)
	for _, definition in ipairs(backend[kind] or {}) do
		if definition.key == key then
			return definition
		end
	end
	return nil
end

local function current_backend()
	local snapshot = context.snapshot(0)
	local backend, err = context.backend(snapshot)
	if backend == nil then
		return nil, nil, err
	end
	return snapshot, backend, nil
end

local function item_label(item)
	if type(item) ~= "table" then
		return tostring(item)
	end
	if item.display ~= nil then
		return item.display
	end
	if item.title ~= nil then
		return item.title
	end
	if item.schema ~= nil and item.name ~= nil then
		return string.format("%s.%s", item.schema, item.name)
	end
	if item.value ~= nil then
		return tostring(item.value)
	end
	return item.name or item.key or item.kind or vim.inspect(item)
end

local function choose(title, items, callback, options)
	options = options or {}
	local t = M._telescope()
	if t == nil then
		vim.ui.select(items, {
			prompt = title .. ": ",
			format_item = item_label,
		}, callback)
		return
	end
	local close_picker
	open(t, {
		title = title,
		results = items,
		entry_maker = function(item)
			local label = item_label(item)
			return { value = item, display = label, ordinal = label }
		end,
		on_input_filter_cb = options.on_input_filter_cb and function(prompt)
			options.on_input_filter_cb(prompt, function()
				if close_picker ~= nil then
					close_picker()
				end
			end)
		end or nil,
		attach_mappings = function(bufnr, map)
			close_picker = function() t.actions.close(bufnr) end
			bind_enter(t, bufnr, map, function(entry)
				callback(entry and entry.value)
			end)
			if options.on_inspect ~= nil then
				local inspect = function()
					local entry = t.state.get_selected_entry()
					if entry == nil or entry.value == nil then
						return
					end
					t.actions.close(bufnr)
					options.on_inspect(entry.value)
				end
				map("i", "<C-i>", inspect)
				map("n", "<C-i>", inspect)
			end
			return true
		end,
	})
end

local function choose_profile(callback)
	choose("dbsh connections", config.names(), callback)
end

function M.connections()
	choose_profile(function(connection_name)
		if connection_name == nil then
			return
		end
		local current, err = context.bind(0, connection_name, "connections")
		if current == nil then
			return notify_error(err)
		end
		local backend, backend_err = context.backend(context.snapshot(0))
		if backend == nil then
			return notify_error(backend_err)
		end
		if contract_for(backend, "contexts", "database") ~= nil then
			M.context("database", { preferred = context.snapshot(0).levels.database })
		end
	end)
end

function M.global_connection()
	choose_profile(function(connection_name)
		if connection_name == nil then
			return
		end
		local _, err = context.set_global(connection_name, "global")
		if err ~= nil then
			notify_error(err)
		end
	end)
end

function M.context(key, options)
	options = options or {}
	local snapshot, backend, err = current_backend()
	if backend == nil then
		return notify_error(err)
	end
	local definition = contract_for(backend, "contexts", key)
	if definition == nil then
		return notify_error(string.format("%s is not available for %s", key, backend.name))
	end

	catalog.request(snapshot, definition, {
		query = options.query,
		cursor = options.cursor,
	}, function(page, request_err)
		if request_err ~= nil then
			return notify_error(request_err)
		end
		local items = vim.deepcopy(page.items)
		if options.preferred ~= nil then
			table.sort(items, function(a, b)
				return a.value == options.preferred and b.value ~= options.preferred
			end)
		end
		choose("dbsh " .. definition.title:lower(), items, function(item)
			if item == nil then
				return
			end
			local value = item.value ~= nil and item.value or item
			local applied, apply_err = definition.apply(snapshot, value)
			if applied == nil then
				return notify_error(apply_err)
			end
			if options.on_selected ~= nil then
				options.on_selected(value, context.snapshot(snapshot.bufnr))
			end
		end)
	end)
end

function M.objects()
	local _, backend, err = current_backend()
	if backend == nil then
		return notify_error(err)
	end
	choose("dbsh objects", backend.catalogs or {}, function(definition)
		if definition ~= nil then
			M.catalog(definition.key)
		end
	end)
end

local function choose_scope(snapshot, callback)
	if snapshot.levels.schema ~= nil then
		callback({ schema = snapshot.levels.schema, all_schemas = false })
		return
	end
	choose("dbsh schema scope", {
		{ kind = "schema", display = "Select schema…" },
		{ kind = "all", display = "All schemas" },
	}, function(choice)
		if choice == nil then
			return
		end
		if choice.kind == "all" then
			callback({ schema = nil, all_schemas = true })
			return
		end
		M.context("schema", {
			on_selected = function(value)
				callback({ schema = value, all_schemas = false })
			end,
		})
	end)
end

function M._debounce(callback)
	if M._debounce_timer ~= nil then
		M._debounce_timer:stop()
		M._debounce_timer:close()
	end
	local timer = (vim.uv or vim.loop).new_timer()
	M._debounce_timer = timer
	timer:start(100, 0, vim.schedule_wrap(function()
		if M._debounce_timer ~= timer then
			return
		end
		M._debounce_timer = nil
		timer:stop()
		timer:close()
		callback()
	end))
end

function M.catalog(key, options)
	options = options or {}
	local snapshot, backend, err = current_backend()
	if backend == nil then
		return notify_error(err)
	end
	local definition = contract_for(backend, "catalogs", key)
		or contract_for(backend, "inspectors", key)
	if definition == nil then
		return notify_error(string.format("%s is not available for %s", key, backend.name))
	end

	local function open_scope(scope)
		local active_query = options.query or ""
		local function load(cursor, query)
			catalog.request(snapshot, definition, {
				scope = scope,
				query = query,
				cursor = cursor,
				relation = options.relation,
			}, function(page, request_err)
				if request_err ~= nil then
					return notify_error(request_err)
				end
				local items = vim.deepcopy(page.items)
				local more = catalog.load_more_entry(page)
				if more ~= nil then
					table.insert(items, more)
				end
				choose("dbsh " .. definition.title:lower(), items, function(item)
					if item == nil then
						return
					end
					if item.kind == "more" then
						return load(item.cursor, active_query)
					end
					if definition.on_select ~= nil then
						definition.on_select(item, snapshot)
					end
				end, {
					on_inspect = definition.inspect and function(item)
						if item.kind == "more" then
							return
						end
						local actions = definition.inspect(item, snapshot) or {}
						choose("dbsh relation inspector", actions, function(action)
							if action == nil then
								return
							end
							if action.action ~= nil then
								action.action(item, snapshot)
								return
							end
							local child = action.catalog or action.inspector
							if child ~= nil then
								M.catalog(child, {
									scope = scope,
									relation = action.relation,
								})
							end
						end)
					end or nil,
					on_input_filter_cb = function(query_value, close)
						if query_value == active_query then
							return
						end
						active_query = query_value
						local requested_query = query_value
						M._debounce(function()
							if requested_query ~= active_query then
								return
							end
							close()
							load(nil, requested_query)
						end)
					end,
				})
			end)
		end
		load(options.cursor, active_query)
	end

	if options.scope ~= nil then
		open_scope(options.scope)
	else
		choose_scope(snapshot, open_scope)
	end
end

-- Asks for the value of a SQL variable. The prompt doubles as the input
-- field: <CR> takes the highlighted entry when there is one, the typed text
-- otherwise, and <C-e> always takes the typed text -- without it a value
-- that is a substring of an existing one could never be entered.
-- callback(value) receives nil when the user gives up.
function M.variable(name, choices, callback)
	choices = choices or {}

	local t = M._telescope()
	if t == nil then
		vim.ui.input(
			{ prompt = "dbsh variable " .. name .. " = ", default = choices[1] or "" },
			callback
		)
		return
	end

	-- Guards against answering twice: the close autocommand fires after a
	-- selection too.
	local answered = false
	local function answer(value)
		if answered then
			return
		end
		answered = true
		callback(value)
	end

	open(t, {
		title = "dbsh variable " .. name,
		results = choices,
		entry_maker = plain_entry,
		attach_mappings = function(bufnr, map)
			local function take(typed_only)
				local entry = t.state.get_selected_entry()
				local typed = t.state.get_current_line()
				local value
				if typed_only or entry == nil then
					value = typed ~= "" and typed or nil
				else
					value = entry.value
				end
				-- Claim the answer before close(): closing the window fires the
				-- BufWinLeave autocommand synchronously, and without the guard
				-- set first it would read the selection as a cancellation.
				answered = true
				t.actions.close(bufnr)
				callback(value)
			end

			map("i", "<CR>", function() take(false) end)
			map("n", "<CR>", function() take(false) end)
			map("i", "<C-e>", function() take(true) end)
			map("n", "<C-e>", function() take(true) end)

			-- Closing the picker any other way is a cancellation, and the
			-- caller has to hear about it or its chain stalls forever.
			vim.api.nvim_create_autocmd("BufWinLeave", {
				buffer = bufnr,
				once = true,
				callback = function() answer(nil) end,
			})
			return true
		end,
	})
end

return M
