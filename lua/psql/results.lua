-- Result buffer management.
-- The buffer is reused across queries, which keeps a history of previous
-- results, and never soft-wraps: wide tables scroll horizontally instead.

local float = require("psql.float")

local M = {}

local BUFNAME = "__SQL__"

function M.find_buf()
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(buf) then
			-- nvim_buf_set_name stores an absolute path, so compare basenames.
			local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t")
			if name == BUFNAME then
				return buf
			end
		end
	end
	return nil
end

function M.find_win(buf)
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_get_buf(win) == buf then
			return win
		end
	end
	return nil
end

-- opts: { split = "horizontal"|"vertical"|"float"?, focus = boolean? }.
-- `split` is only read the first time a window is created for this buffer:
-- once open, the existing window is reused regardless of what a later call
-- asks for. `focus` only applies to a float, and defaults to true.
function M.open(opts)
	opts = opts or {}
	local buf = M.find_buf()
	if buf == nil then
		buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_name(buf, BUFNAME)
		vim.bo[buf].buftype = "nofile"
		vim.bo[buf].bufhidden = "hide"
		vim.bo[buf].swapfile = false
		vim.bo[buf].filetype = "sql"
	end

	local win = M.find_win(buf)
	if win == nil then
		if opts.split == "float" then
			win = float.open(buf, { focus = opts.focus })
		else
			vim.cmd(opts.split == "vertical" and "vsplit" or "split")
			win = vim.api.nvim_get_current_win()
			vim.api.nvim_win_set_buf(win, buf)
		end
	end

	-- Rendered by the plugin only: hand editing would desync it from psql.
	vim.bo[buf].modifiable = false

	-- Wide result tables must scroll horizontally instead of soft-wrapping.
	vim.wo[win].wrap = false
	vim.wo[win].sidescrolloff = 0

	return buf, win
end

-- Closes the result window, if one is open. The buffer and its content
-- survive: a later render() or toggle() brings it back as-is.
function M.close()
	local buf = M.find_buf()
	if buf == nil then
		return
	end
	local win = M.find_win(buf)
	if win ~= nil then
		vim.api.nvim_win_close(win, false)
	end
end

-- Toggles the result window: closes it if open, otherwise reopens it with
-- focus. Returns false when there is no result yet to show.
function M.toggle(opts)
	local buf = M.find_buf()
	if buf == nil then
		return false
	end
	if M.find_win(buf) ~= nil then
		M.close()
	else
		M.open(vim.tbl_extend("force", opts or {}, { focus = true }))
	end
	return true
end

local function set_lines(buf, lines)
	-- nvim_buf_set_lines refuses a non-modifiable buffer, so lift the
	-- protection for the write and put it straight back.
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, true, lines)
	vim.bo[buf].modifiable = false
end

-- nvim_buf_set_lines rejects an item holding a newline, so a multi-line
-- query has to be spread over as many entries as it has lines.
local function split_lines(text)
	return vim.split(text or "", "\n", { plain = true })
end

-- A query result never steals focus on its own: only :PSQLToggleResults
-- (via M.toggle) does, so typing in a .sql file is never interrupted.
local function without_focus(opts)
	return vim.tbl_extend("force", opts or {}, { focus = false })
end

function M.running(query, opts)
	local buf = M.open(without_focus(opts))
	local lines = { "# Running..." }
	vim.list_extend(lines, split_lines(query))
	table.insert(lines, "")
	set_lines(buf, lines)
	vim.cmd("redraw")
	return buf
end

function M.render(query, output, opts)
	local buf = M.open(without_focus(opts))
	local lines = split_lines(query)
	table.insert(lines, "")
	vim.list_extend(lines, split_lines(output))
	set_lines(buf, lines)
	return buf
end

return M
