-- Telescope pickers: the connection picker, the generic catalog picker, and
-- the variable prompt. The catalog levels themselves are declared by the
-- backend, so this file knows no database vocabulary at all.
-- Telescope is an optional dependency: every picker degrades to a clear
-- message when it is not installed.

local config = require("dbsh.config")
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

function M.connections()
	local t = require_telescope()
	if t == nil then
		return
	end

	open(t, {
		title = "dbsh connections",
		results = config.names(),
		entry_maker = plain_entry,
		attach_mappings = function(bufnr, map)
			bind_enter(t, bufnr, map, function(entry)
				local _, err = context.bind(0, entry.value, "connections")
				if err ~= nil then
					notify_error(err)
				else
					vim.notify("psql.nvim: connected to " .. entry.value)
				end
			end)
			return true
		end,
	})
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

-- on_select is "set_level" (fix this level on the current connection),
-- "descend" (open the level below with an enriched context), or a function
-- taking the selected value and the context.
function M.select(backend, index, ctx, value)
	local level = backend.levels[index]
	if level.on_select == "set_level" then
		local _, err = context.set_level(0, level.key, value, "catalog")
		if err ~= nil then
			notify_error(err)
		else
			vim.notify(string.format("dbsh.nvim: using %s %s", level.key, tostring(value)))
		end
	elseif level.on_select == "descend" then
		local down = vim.deepcopy(ctx)
		down[level.key] = value
		M.level(index + 1, down)
	else
		level.on_select(value, ctx)
	end
end

-- index is a position in backend.levels; ctx holds the values already chosen
-- for the levels above it, e.g. { schema = "public" }.
function M.level(index, ctx)
	ctx = ctx or {}
	local t = require_telescope()
	if t == nil then
		return
	end

	local backend, err = context.backend(context.snapshot(0))
	if backend == nil then
		return notify_error(err)
	end

	local level = backend.levels[index]
	if level == nil then
		return notify_error(string.format("no level %s on a %s connection", tostring(index), backend.name))
	end

	vim.notify(string.format("dbsh.nvim: fetching %s...", level.command:lower()))
	level.list(ctx, function(items, list_err)
		if list_err ~= nil then
			return notify_error(list_err)
		end
		open(t, {
			title = "dbsh " .. level.command:lower(),
			results = items,
			-- The backend already shapes each item as a Telescope entry.
			entry_maker = function(item) return item end,
			attach_mappings = function(bufnr, map)
				bind_enter(t, bufnr, map, function(entry)
					M.select(backend, index, ctx, entry.value)
				end)

				-- Normal mode only: mapping <BS> in insert mode would break
				-- character deletion in the Telescope prompt. Offered only
				-- when we actually descended from the level above.
				local previous = backend.levels[index - 1]
				if previous ~= nil and ctx[previous.key] ~= nil then
					map("n", "<BS>", function()
						t.actions.close(bufnr)
						local up = vim.deepcopy(ctx)
						up[previous.key] = nil
						M.level(index - 1, up)
					end)
				end
				return true
			end,
		})
	end)
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
