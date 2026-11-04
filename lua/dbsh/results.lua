-- Result buffer management scoped by dbsh context session.

local float = require("dbsh.float")
local context = require("dbsh.context")
local backends = require("dbsh.backends")
local config = require("dbsh.config")

local M = {}

-- "replace" renders every query over the previous one; "tabs" appends one
-- folded section per query so the buffer keeps a working history.
local function tabs_mode()
	return config.options().results_mode == "tabs"
end

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
		state.buffers[snapshot.id] = buf
	end
	local backend = context.backend(snapshot) or backends.get(snapshot.backend_name)
	local filetype = backend and backend.filetype or "sql"
	if vim.bo[buf].filetype ~= filetype then
		vim.bo[buf].filetype = filetype
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
	if tabs_mode() then
		-- Each "-- query #N" header opens a level-1 fold: one section per query.
		vim.wo[win].foldmethod = "expr"
		vim.wo[win].foldexpr = "v:lua.require('dbsh.results').foldexpr(v:lnum)"
		vim.wo[win].foldlevel = 0
	end

	-- An already-open window is never entered by the branches above, so an
	-- explicit focus has to be honoured here or only the first query of a
	-- session would land in the float.
	if opts.focus == false and vim.api.nvim_win_is_valid(previous_win) then
		vim.api.nvim_set_current_win(previous_win)
	elseif opts.focus == true and vim.api.nvim_win_is_valid(win) then
		vim.api.nvim_set_current_win(win)
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

local function set_lines_range(buf, start0, end0, lines)
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, start0, end0, true, lines)
	vim.bo[buf].modifiable = false
end

local function split_lines(text)
	return vim.split(text or "", "\n", { plain = true })
end

-- Fold expression for results_mode = "tabs": every section header opens a
-- level-1 fold covering its query and output, down to the next header.
function M.foldexpr(lnum)
	if vim.fn.getline(lnum):match("^%-%- query #") then
		return ">1"
	end
	return "="
end

local function tab_header(snapshot, n)
	return string.format("-- query #%d · %s · %s", n, label(snapshot), os.date("%H:%M:%S"))
end

-- Appends lines at the end of the buffer and returns the 1-based line where
-- they start. A fresh buffer holds a single empty line: replace it rather
-- than leave a blank first line.
local function append_lines(buf, lines)
	local count = vim.api.nvim_buf_line_count(buf)
	if count == 1 and vim.api.nvim_buf_get_lines(buf, 0, 1, true)[1] == "" then
		set_lines(buf, lines)
		return 1
	end
	set_lines_range(buf, count, -1, lines)
	return count + 1
end

-- Opens the section's fold and scrolls it into view. zM first: only the
-- newest tab stays expanded, the older ones collapse to their header line.
local function reveal(buf, start)
	local win = M.find_win(buf)
	if win == nil then
		return
	end
	vim.api.nvim_win_call(win, function()
		vim.cmd("normal! zM")
		vim.api.nvim_win_set_cursor(0, { start, 0 })
		vim.cmd("normal! zv")
	end)
end

local function without_focus(opts)
	return vim.tbl_extend("force", opts or {}, { focus = false })
end

-- A split sits beside the SQL buffer and must not take the cursor: the point
-- of it is to keep typing. A float covers that buffer instead, and unfocused
-- it can neither be scrolled nor closed -- its q and <Esc> mappings never
-- fire. Only this door focuses: M.render runs from the CLI callback, long
-- after the user moved on, and an async focus steal is worse than none.
local function initial_focus(opts)
	opts = opts or {}
	return vim.tbl_extend("force", opts, { focus = opts.split == "float" })
end

-- In "tabs" mode each query appends a new section instead of overwriting the
-- buffer. The exec slot cancels a superseded query without firing its
-- callback, so its placeholder is rewritten here, when the next one starts.
local function running_tab(snapshot, query, opts)
	local buf = M.open(snapshot, initial_focus(opts))
	vim.b[buf].dbsh_result_query = query
	local pending = vim.b[buf].dbsh_tab_running
	if pending ~= nil then
		local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, true)
		if lines[#lines] == "# Running..." then
			set_lines_range(buf, #lines - 1, #lines, { "# Cancelled" })
		end
		vim.b[buf].dbsh_tab_running = nil
	end
	local n = (vim.b[buf].dbsh_tab_count or 0) + 1
	vim.b[buf].dbsh_tab_count = n
	local lines = { tab_header(snapshot, n) }
	vim.list_extend(lines, split_lines(query))
	table.insert(lines, "")
	table.insert(lines, "# Running...")
	local start = append_lines(buf, lines)
	vim.b[buf].dbsh_tab_running = start
	reveal(buf, start)
	vim.cmd("redraw")
	return buf
end

local function render_tab(snapshot, query, output, opts)
	local buf = M.open(snapshot, without_focus(opts))
	vim.b[buf].dbsh_result_query = query
	local start = vim.b[buf].dbsh_tab_running
	if start == nil then
		-- A render without a preceding running (direct call): append a whole
		-- section straight away.
		local n = (vim.b[buf].dbsh_tab_count or 0) + 1
		vim.b[buf].dbsh_tab_count = n
		local lines = { tab_header(snapshot, n) }
		vim.list_extend(lines, split_lines(query))
		table.insert(lines, "")
		vim.list_extend(lines, split_lines(output))
		reveal(buf, append_lines(buf, lines))
		return buf
	end
	-- The pending section is always the last one: a newer query would have
	-- cancelled this one's exec slot, and a cancelled callback never fires.
	-- Replace only its placeholder line so later sections are never touched.
	local section = vim.api.nvim_buf_get_lines(buf, start - 1, -1, true)
	local idx = #section
	while idx >= 1 and section[idx] ~= "# Running..." do
		idx = idx - 1
	end
	if idx >= 1 then
		set_lines_range(buf, start - 1 + idx - 1, start - 1 + idx, split_lines(output))
	end
	vim.b[buf].dbsh_tab_running = nil
	reveal(buf, start)
	return buf
end

function M.running(snapshot, query, opts)
	if tabs_mode() then
		return running_tab(snapshot, query, opts)
	end
	local buf = M.open(snapshot, initial_focus(opts))
	vim.b[buf].dbsh_result_query = query
	local lines = { "# Running..." }
	vim.list_extend(lines, split_lines(query))
	table.insert(lines, "")
	set_lines(buf, lines)
	vim.cmd("redraw")
	return buf
end

function M.render(snapshot, query, output, opts)
	if tabs_mode() then
		return render_tab(snapshot, query, output, opts)
	end
	local buf = M.open(snapshot, without_focus(opts))
	vim.b[buf].dbsh_result_query = query
	local lines = split_lines(query)
	table.insert(lines, "")
	vim.list_extend(lines, split_lines(output))
	set_lines(buf, lines)
	return buf
end

return M
