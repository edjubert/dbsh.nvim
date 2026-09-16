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

-- Buffer names live in a namespace Neovim shares with everything else, so the
-- name has to be unique per session and not per connection: two sessions on
-- one connection would otherwise collide and nvim_buf_set_name would raise E95.
local function buf_name(snapshot)
	return string.format(
		"__DBSH__ %s #%s",
		label(snapshot),
		vim.fn.sha256(tostring(snapshot.id)):sub(1, 8)
	)
end

-- Reloading the plugin empties state.buffers while its buffers survive the
-- reload. The buffer-local id is the durable record of a session, so recover
-- the buffer from it rather than build a second one that could never be named.
local function adopt(id)
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(buf) then
			local ok, existing = pcall(vim.api.nvim_buf_get_var, buf, "dbsh_context_id")
			if ok and existing == id then
				return buf
			end
		end
	end
	return nil
end

function M.find_buf(snapshot_or_id)
	local id = session_id(snapshot_or_id)
	if id == nil then
		return nil
	end
	local buf = state.buffers[id]
	if buf ~= nil and not vim.api.nvim_buf_is_valid(buf) then
		state.snapshots[id] = nil
		buf = nil
	end
	if buf == nil then
		buf = adopt(id)
	end
	state.buffers[id] = buf
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
		-- Identity first, and all or nothing: a buffer left half built would
		-- never reach state.buffers, and every later query on this session
		-- would rebuild and fail on it the same way.
		local named, err = pcall(function()
			vim.api.nvim_buf_set_name(buf, buf_name(snapshot))
			vim.api.nvim_buf_set_var(buf, "dbsh_context_id", snapshot.id)
		end)
		if not named then
			pcall(vim.api.nvim_buf_delete, buf, { force = true })
			error(err, 0)
		end
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
