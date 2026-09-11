-- Result buffer management scoped by dbsh context session.

local float = require("dbsh.float")

local M = {}

local state = {
	buffers = {},
	snapshots = {},
}

local function session_id(snapshot_or_id)
	if type(snapshot_or_id) == "table" then
		return snapshot_or_id.id
	end
	return snapshot_or_id
end

local function remember(snapshot)
	state.snapshots[snapshot.id] = vim.deepcopy(snapshot)
end

local function label(snapshot)
	return snapshot.connection_name or snapshot.id
end

function M.find_buf(snapshot_or_id)
	local id = session_id(snapshot_or_id)
	if id == nil then
		return nil
	end
	local buf = state.buffers[id]
	if buf ~= nil and not vim.api.nvim_buf_is_valid(buf) then
		state.buffers[id] = nil
		state.snapshots[id] = nil
		return nil
	end
	return buf
end

function M.find_win(buf)
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_get_buf(win) == buf then
			return win
		end
	end
	return nil
end

function M.context_snapshot(bufnr)
	if bufnr == nil or bufnr == 0 then
		bufnr = vim.api.nvim_get_current_buf()
	end
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return nil
	end
	local ok, id = pcall(vim.api.nvim_buf_get_var, bufnr, "dbsh_context_id")
	if not ok then
		return nil
	end
	local snapshot = state.snapshots[id]
	return snapshot and vim.deepcopy(snapshot) or nil
end

-- opts: { split = "horizontal"|"vertical"|"float"?, focus = boolean? }.
function M.open(snapshot, opts)
	opts = opts or {}
	local buf = M.find_buf(snapshot)
	remember(snapshot)
	if buf == nil then
		buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_name(buf, "__DBSH__ " .. label(snapshot))
		vim.api.nvim_buf_set_var(buf, "dbsh_context_id", snapshot.id)
		vim.bo[buf].buftype = "nofile"
		vim.bo[buf].bufhidden = "hide"
		vim.bo[buf].swapfile = false
		vim.bo[buf].filetype = "sql"
		state.buffers[snapshot.id] = buf
	end

	local previous_win = vim.api.nvim_get_current_win()
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

	vim.bo[buf].modifiable = false
	vim.wo[win].wrap = false
	vim.wo[win].sidescrolloff = 0

	if opts.focus == false and vim.api.nvim_win_is_valid(previous_win) then
		vim.api.nvim_set_current_win(previous_win)
	end
	return buf, win
end

function M.close(snapshot)
	local buf = M.find_buf(snapshot)
	if buf == nil then
		return
	end
	local win = M.find_win(buf)
	if win ~= nil then
		vim.api.nvim_win_close(win, false)
	end
end

function M.toggle(snapshot, opts)
	local buf = M.find_buf(snapshot)
	if buf == nil then
		return false
	end
	if M.find_win(buf) ~= nil then
		M.close(snapshot)
	else
		M.open(snapshot, vim.tbl_extend("force", opts or {}, { focus = true }))
	end
	return true
end

local function set_lines(buf, lines)
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, true, lines)
	vim.bo[buf].modifiable = false
end

local function split_lines(text)
	return vim.split(text or "", "\n", { plain = true })
end

local function without_focus(opts)
	return vim.tbl_extend("force", opts or {}, { focus = false })
end

function M.running(snapshot, query, opts)
	local buf = M.open(snapshot, without_focus(opts))
	local lines = { "# Running..." }
	vim.list_extend(lines, split_lines(query))
	table.insert(lines, "")
	set_lines(buf, lines)
	vim.cmd("redraw")
	return buf
end

function M.render(snapshot, query, output, opts)
	local buf = M.open(snapshot, without_focus(opts))
	local lines = split_lines(query)
	table.insert(lines, "")
	vim.list_extend(lines, split_lines(output))
	set_lines(buf, lines)
	return buf
end

return M
