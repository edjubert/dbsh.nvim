-- Result buffer management.
-- The buffer is reused across queries, which keeps a history of previous
-- results, and never soft-wraps: wide tables scroll horizontally instead.

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

function M.open()
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
		vim.cmd("split")
		win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(win, buf)
	end

	-- Rendered by the plugin only: hand editing would desync it from psql.
	vim.bo[buf].modifiable = false

	-- Wide result tables must scroll horizontally instead of soft-wrapping.
	vim.wo[win].wrap = false
	vim.wo[win].sidescrolloff = 0

	return buf, win
end

local function set_lines(buf, lines)
	-- nvim_buf_set_lines refuses a non-modifiable buffer, so lift the
	-- protection for the write and put it straight back.
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, true, lines)
	vim.bo[buf].modifiable = false
end

function M.running(query)
	local buf = M.open()
	set_lines(buf, { "# Running...", query, "" })
	vim.cmd("redraw")
	return buf
end

function M.render(query, output)
	local buf = M.open()
	local lines = { query, "" }
	vim.list_extend(lines, vim.split(output or "", "\n", { plain = true }))
	set_lines(buf, lines)
	return buf
end

return M
