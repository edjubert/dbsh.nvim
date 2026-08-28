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

function M.connections()
	local t = require_telescope()
	if t == nil then
		return
	end

	open(t, {
		title = "PSQL connections",
		results = config.names(),
		entry_maker = plain_entry,
		attach_mappings = function(bufnr)
			t.actions.select_default:replace(function()
				local entry = t.state.get_selected_entry()
				t.actions.close(bufnr)
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
			attach_mappings = function(bufnr)
				t.actions.select_default:replace(function()
					local entry = t.state.get_selected_entry()
					t.actions.close(bufnr)
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
			attach_mappings = function(bufnr)
				t.actions.select_default:replace(function()
					local entry = t.state.get_selected_entry()
					t.actions.close(bufnr)
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
				t.actions.select_default:replace(function()
					local entry = t.state.get_selected_entry()
					t.actions.close(bufnr)
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

return M
