-- Public API and user commands for psql.nvim.

local config = require("psql.config")
local exec = require("psql.exec")
local results = require("psql.results")
local scratch = require("psql.scratch")

local M = {}

function M.query(sql)
	sql = vim.trim(sql or "")
	if sql == "" then
		vim.notify("psql.nvim: query is empty", vim.log.levels.WARN)
		return
	end

	results.running(sql)
	exec.run(sql, {}, function(code, stdout, stderr)
		local output = stdout
		if code ~= 0 then
			output = stderr ~= "" and stderr or stdout
		end
		results.render(sql, output)
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
