-- Public API and user commands for psql.nvim.

local config = require("psql.config")
local exec = require("psql.exec")
local results = require("psql.results")
local scratch = require("psql.scratch")
local csv = require("psql.csv")
local export = require("psql.export")
local resolve = require("psql.resolve")

local M = {}

-- Last query handed to M.query(), reused by the CSV export when the result
-- buffer is the active one.
local last_query = nil

function M.last_query()
	return last_query
end

function M.query(sql)
	sql = vim.trim(sql or "")
	if sql == "" then
		vim.notify("psql.nvim: query is empty", vim.log.levels.WARN)
		return
	end

	last_query = sql
	resolve.preamble(sql, function(preamble)
		-- nil means the user dismissed a prompt: run nothing, say nothing.
		if preamble == nil then
			return
		end

		-- The result buffer shows the query as written; only psql sees the
		-- \set directives.
		local split_opts = { split = config.options().results_split }
		results.running(sql, split_opts)
		exec.run(preamble .. sql, {}, function(code, stdout, stderr)
			local output = stdout
			if code ~= 0 then
				output = stderr ~= "" and stderr or stdout
			end
			results.render(sql, output, split_opts)
		end)
	end)
end

function M.query_current_line()
	local lnum = vim.api.nvim_win_get_cursor(0)[1]
	local line = vim.api.nvim_buf_get_lines(0, lnum - 1, lnum, false)[1]
	M.query(line)
end

-- Pure helper: expands from lnum to the surrounding blank lines.
-- Returns 1-based inclusive bounds.
function M.paragraph_range(lines, lnum)
	local start = lnum
	while start > 1 and vim.trim(lines[start - 1] or "") ~= "" do
		start = start - 1
	end

	local stop = lnum
	while stop < #lines and vim.trim(lines[stop + 1] or "") ~= "" do
		stop = stop + 1
	end

	return start, stop
end

function M.query_paragraph()
	local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
	local lnum = vim.api.nvim_win_get_cursor(0)[1]
	local start, stop = M.paragraph_range(lines, lnum)
	M.query(table.concat(vim.list_slice(lines, start, stop), "\n"))
end

function M.query_selection()
	-- getregion replaces the ~50 line helper the upstream kept in lua/util.
	local mode = vim.fn.mode()
	local region = vim.fn.getregion(vim.fn.getpos("v"), vim.fn.getpos("."), { type = mode })
	M.query(table.concat(region, "\n"))
end

function M.yank_cell()
	vim.api.nvim_feedkeys(
		vim.api.nvim_replace_termcodes("/<C-v>u2502<Esc>gemz", true, true, true), "n", false)
	vim.api.nvim_feedkeys(
		vim.api.nvim_replace_termcodes("?<C-v>u2502<CR>", true, true, true), "n", false)
	vim.api.nvim_feedkeys("llv`zy", "n", false)
end

-- Registers a yank has to land in for 'clipboard' to be honoured. Writing
-- to the unnamed register alone is not enough: under unnamedplus every put
-- reads from +, which setreg('"') leaves untouched.
function M.yank_registers(clipboard)
	local names = { '"' }
	for _, item in ipairs(vim.split(clipboard or "", ",", { plain = true })) do
		if item == "unnamedplus" then
			table.insert(names, "+")
		elseif item == "unnamed" then
			table.insert(names, "*")
		end
	end
	return names
end

-- Copies the selected cells of the result table as CSV into the default
-- register, and into the clipboard registers 'clipboard' asks for.
-- V takes whole rows, <C-v> takes only the columns of the block.
function M.yank_csv()
	local mode = vim.fn.mode()
	if mode ~= csv.LINEWISE and mode ~= csv.BLOCKWISE then
		vim.notify(
			"psql.nvim: select lines with V or a block with <C-v> first",
			vim.log.levels.WARN
		)
		return
	end

	-- getpos("v") and getpos(".") work during visual mode, unlike the '< '>
	-- marks, which only get set once visual mode is left.
	local from = vim.fn.getpos("v")
	local to = vim.fn.getpos(".")
	local lines = vim.api.nvim_buf_get_lines(
		0,
		math.min(from[2], to[2]) - 1,
		math.max(from[2], to[2]),
		false
	)

	local rows = csv.rows_from_lines(
		lines,
		mode,
		math.min(from[3], to[3]),
		math.max(from[3], to[3])
	)
	if #rows == 0 then
		vim.notify("psql.nvim: no table cell in the selection", vim.log.levels.WARN)
		return
	end

	local text = csv.to_csv(rows, config.options().csv_delimiter)
	for _, name in ipairs(M.yank_registers(vim.o.clipboard)) do
		vim.fn.setreg(name, text)
	end
	vim.notify(string.format("psql.nvim: yanked %d row(s) as CSV", #rows))
end

-- The result buffer exports the query it is showing. Any other buffer
-- exports the given range -- which is how a visual selection reaches a user
-- command -- or the SQL paragraph under the cursor when no range is given.
local function query_to_export(opts)
	local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t")
	if name == "__SQL__" then
		return M.last_query()
	end

	local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
	local start, stop
	if opts ~= nil and (opts.range or 0) > 0 then
		start, stop = opts.line1, opts.line2
	else
		start, stop = M.paragraph_range(lines, vim.api.nvim_win_get_cursor(0)[1])
	end
	return table.concat(vim.list_slice(lines, start, stop), "\n")
end

-- opts is the user command table, or nil when called straight from Lua.
function M.export_csv(opts)
	local sql = vim.trim(query_to_export(opts) or "")
	if sql == "" then
		vim.notify("psql.nvim: nothing to export", vim.log.levels.WARN)
		return
	end

	-- Variables first, destination second: dismissing a prompt must not
	-- ask for a path that will never be used.
	resolve.preamble(sql, function(preamble)
		if preamble == nil then
			return
		end

		local dir = config.options().export_dir
		vim.fn.mkdir(dir, "p")
		local suggestion = export.default_path(
			dir,
			config.current_name() or "scratchpad",
			os.date("%Y%m%d")
		)

		vim.ui.input(
			{ prompt = "Export to: ", default = suggestion, completion = "file" },
			function(choice)
				if choice == nil or vim.trim(choice) == "" then
					return
				end
				-- The suggestion may have been edited onto an existing file.
				local path = export.free_path(vim.trim(choice))
				export.run(sql, path, preamble, function(written, err)
					if err ~= nil then
						vim.notify("psql.nvim: " .. err, vim.log.levels.ERROR)
						return
					end
					vim.notify("psql.nvim: exported to " .. written)
				end)
			end
		)
	end)
end

local function pickers()
	-- Deferred require: psql.telescope.pickers requires this module back.
	return require("psql.telescope.pickers")
end

local function declare_commands()
	local command = vim.api.nvim_create_user_command

	command("PSQLConnections", function() pickers().connections() end, {})
	command("PSQLDatabases", function() pickers().databases() end, {})
	command("PSQLSchemas", function() pickers().schemas() end, {})
	command("PSQLTables", function() pickers().tables({}) end, {})

	command("PSQLTemp", function() scratch.open() end, {})
	command("PSQLCancel", function() exec.cancel("user") end, {})
	-- range = true: typing : in visual mode prefills '<,'>, which would
	-- otherwise fail with E481 before the command even runs.
	command("PSQLExportCSV", function(opts) M.export_csv(opts) end, { range = true })

	command("PSQLInfo", function()
		local name = config.current_name()
		if name == nil then
			vim.notify("psql.nvim: no current connection", vim.log.levels.WARN)
			return
		end
		local conn = config.current()
		vim.notify(string.format(
			"psql.nvim: %s -> %s@%s:%s/%s",
			name, conn.username, conn.host, tostring(conn.port), conn.database))
	end, {})
end

function M.setup(opts)
	config.setup(opts)
	declare_commands()
end

return M
