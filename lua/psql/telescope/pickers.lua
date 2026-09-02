-- Telescope pickers for connections, databases, schemas and tables.
-- Telescope is an optional dependency: every picker degrades to a clear
-- message when it is not installed.

local config = require("psql.config")
local introspect = require("psql.introspect")

local M = {}

local KINDS = {
	r = "table",
	v = "view",
	m = "matview",
	p = "partitioned",
}

function M.kind_label(relkind)
	return KINDS[relkind] or relkind
end

function M.format_table_entry(row)
	local label = string.format("%s.%s", row.schema, row.name)
	return {
		value = row,
		display = string.format("%s  [%s]", label, M.kind_label(row.kind)),
		ordinal = label,
	}
end

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
	vim.notify("psql.nvim: " .. err, vim.log.levels.ERROR)
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
		title = "PSQL connections",
		results = config.names(),
		entry_maker = plain_entry,
		attach_mappings = function(bufnr, map)
			bind_enter(t, bufnr, map, function(entry)
				local _, err = config.set_connection(entry.value)
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

function M.databases()
	local t = require_telescope()
	if t == nil then
		return
	end

	vim.notify("psql.nvim: fetching databases...")
	introspect.databases(function(names, err)
		if err ~= nil then
			return notify_error(err)
		end
		open(t, {
			title = "PSQL databases",
			results = names,
			entry_maker = plain_entry,
			attach_mappings = function(bufnr, map)
				bind_enter(t, bufnr, map, function(entry)
					local _, set_err = config.set_database(entry.value)
					if set_err ~= nil then
						notify_error(set_err)
					else
						vim.notify("psql.nvim: using database " .. entry.value)
					end
				end)
				return true
			end,
		})
	end)
end

function M.schemas()
	local t = require_telescope()
	if t == nil then
		return
	end

	vim.notify("psql.nvim: fetching schemas...")
	introspect.schemas(function(names, err)
		if err ~= nil then
			return notify_error(err)
		end
		open(t, {
			title = "PSQL schemas",
			results = names,
			entry_maker = plain_entry,
			attach_mappings = function(bufnr, map)
				bind_enter(t, bufnr, map, function(entry)
					M.tables({ schema = entry.value })
				end)
				return true
			end,
		})
	end)
end

-- opts: { schema = string? }. Without a schema this is the flat picker.
function M.tables(opts)
	opts = opts or {}
	local t = require_telescope()
	if t == nil then
		return
	end

	vim.notify("psql.nvim: fetching tables...")
	introspect.tables(opts, function(rows, err)
		if err ~= nil then
			return notify_error(err)
		end
		open(t, {
			title = opts.schema and ("PSQL tables - " .. opts.schema) or "PSQL tables",
			results = rows,
			entry_maker = M.format_table_entry,
			attach_mappings = function(bufnr, map)
				bind_enter(t, bufnr, map, function(entry)
					local sql = introspect.preview_query(entry.value.schema, entry.value.name)
					-- Deferred require: psql.init imports this module.
					require("psql").query(sql)
				end)

				-- Normal mode only: mapping <BS> in insert mode would break
				-- character deletion in the Telescope prompt.
				if opts.schema ~= nil then
					map("n", "<BS>", function()
						t.actions.close(bufnr)
						M.schemas()
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
			{ prompt = "psql variable " .. name .. " = ", default = choices[1] or "" },
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
		title = "PSQL variable " .. name,
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
