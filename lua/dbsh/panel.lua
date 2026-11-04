-- Tab-local sidebar. Rendering and tree navigation only read local state;
-- loading a catalog page is a separate, explicit action.

local config = require("dbsh.config")
local context = require("dbsh.context")
local catalog = require("dbsh.catalog")
local tree = require("dbsh.panel_tree")

local M = {}
local sessions = {}
local namespace = vim.api.nvim_create_namespace("dbsh.panel")
local queued = false

local function notify(err)
	vim.notify("dbsh.nvim: " .. tostring(err), vim.log.levels.WARN)
end

local function valid_win(win)
	return win ~= nil and vim.api.nvim_win_is_valid(win)
end

local function current_session()
	return sessions[vim.api.nvim_get_current_tabpage()]
end

function M.is_panel(bufnr)
	bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
	for _, session in pairs(sessions) do
		if session.bufnr == bufnr then return true end
	end
	return false
end

local function source(session)
	local bufnr = session.source_buf
	if bufnr == nil or not vim.api.nvim_buf_is_valid(bufnr) then
		for _, win in ipairs(vim.api.nvim_tabpage_list_wins(session.tab)) do
			local candidate = vim.api.nvim_win_get_buf(win)
			if vim.bo[candidate].buftype == "" then
				session.source_win, session.source_buf = win, candidate
				bufnr = candidate
				break
			end
		end
	end
	return context.snapshot(bufnr or session.bufnr)
end

function M.source_snapshot()
	local session = current_session()
	if session ~= nil and M.is_panel(0) then return source(session) end
end

local function selected(node, snapshot)
	local value = node.snapshot
	if value == nil or value.connection_name ~= snapshot.connection_name then return false end
	if node.kind == "connection" then return true end
	if value.levels.database ~= snapshot.levels.database then return false end
	if node.kind == "database" then return true end
	return node.kind == "schema" and value.levels.schema == snapshot.levels.schema
end

local function focus_entry(session, id)
	while id ~= nil do
		for row, node in pairs(session.entries) do
			if node.id == id then
				vim.api.nvim_win_set_cursor(session.win, { row, 0 })
				return
			end
		end
		id = session.nodes[id] and session.nodes[id].parent
	end
end

function M.render(session)
	session = session or current_session()
	if session == nil or not valid_win(session.win) or not vim.api.nvim_buf_is_valid(session.bufnr) then return end
	local anchor = (session.entries or {})[vim.api.nvim_win_get_cursor(session.win)[1]]
	local snapshot = source(session)
	session.roots, session.nodes = tree.build(snapshot)
	local lines = { "dbsh", "Enter open · h/l fold · s select", "r fetch · g refresh · q close", "" }
	local highlights = { { 1, "Title" }, { 2, "Comment" }, { 3, "Comment" } }
	session.entries = {}
	local function visit(node, depth)
		if node.branch and session.closed[node.id] == nil then
			session.closed[node.id] = node.kind ~= "section" and node.kind ~= "group" and not selected(node, snapshot)
		end
		local marker = node.branch and (session.closed[node.id] and "▸ " or "▾ ") or "  "
		local active = selected(node, snapshot)
		local label = node.label:gsub("%c", " ")
		table.insert(lines, string.rep("  ", depth) .. marker .. label .. (active and " ◀" or ""))
		session.entries[#lines] = node
		local group = node.error and "DiagnosticWarn" or active and "Special"
			or node.branch and "Directory" or (node.kind == "load" or node.kind == "more" or node.kind == "new") and "MoreMsg"
			or node.kind == "empty" and "Comment" or "Normal"
		table.insert(highlights, { #lines, group })
		if node.branch and not session.closed[node.id] then
			for _, child in ipairs(node.children) do visit(child, depth + 1) end
		end
	end
	for _, root in ipairs(session.roots) do visit(root, 0) end
	if session.loading ~= nil then
		table.insert(lines, "")
		table.insert(lines, "Loading " .. session.loading.title .. "…")
		table.insert(highlights, { #lines, "Comment" })
	end
	vim.bo[session.bufnr].modifiable = true
	vim.api.nvim_buf_set_lines(session.bufnr, 0, -1, false, lines)
	vim.bo[session.bufnr].modifiable = false
	vim.api.nvim_buf_clear_namespace(session.bufnr, namespace, 0, -1)
	for _, decoration in ipairs(highlights) do
		vim.api.nvim_buf_set_extmark(session.bufnr, namespace, decoration[1] - 1, 0, {
			end_col = #lines[decoration[1]], hl_group = decoration[2],
		})
	end
	if anchor ~= nil then focus_entry(session, anchor.id) end
end

local function refresh()
	if queued then return end
	queued = true
	vim.schedule(function()
		queued = false
		for _, session in pairs(sessions) do M.render(session) end
	end)
end

local function working_window(session)
	local win = session.source_win
	if not valid_win(win) or vim.api.nvim_win_get_tabpage(win) ~= session.tab
		or vim.bo[vim.api.nvim_win_get_buf(win)].buftype ~= "" then
		win = nil
		for _, candidate in ipairs(vim.api.nvim_tabpage_list_wins(session.tab)) do
			if candidate ~= session.win and vim.api.nvim_win_get_config(candidate).relative == ""
				and vim.bo[vim.api.nvim_win_get_buf(candidate)].buftype == "" then
				win = candidate
				break
			end
		end
	end
	if win == nil then
		vim.api.nvim_set_current_win(session.win)
		vim.cmd("botright vnew")
		win = vim.api.nvim_get_current_win()
	end
	session.source_win = win
	vim.api.nvim_set_current_win(win)
	return win
end

function M.focus_source()
	local session = current_session()
	if session ~= nil and M.is_panel(0) then return working_window(session) end
end

local function apply(session, node)
	if node.snapshot == nil or node.snapshot.connection == nil then return nil, "no connection selected" end
	if not context.is_current(node.snapshot) then return nil, "source context changed; refresh the panel" end
	local bufnr = source(session).bufnr
	if not vim.api.nvim_buf_is_valid(bufnr) or M.is_panel(bufnr) then return nil, "no query buffer available" end
	local current = context.snapshot(bufnr)
	local target = node.snapshot
	local applied, err
	if current.connection_name ~= target.connection_name then
		applied, err = context.bind(bufnr, target.connection_name, "panel")
		if applied == nil then return nil, err end
	end
	if node.kind ~= "connection" then
		for _, key in ipairs({ "database", "schema" }) do
			if context.current(bufnr).levels[key] ~= target.levels[key] then
				applied, err = context.set_level(bufnr, key, target.levels[key], "panel")
				if applied == nil then return nil, err end
			end
		end
	end
	return context.snapshot(bufnr)
end

local function load(session, node)
	if node.request == nil or node.snapshot == nil then return end
	if session.loading ~= nil then return notify("a catalog page is already loading") end
	if not context.is_current(node.snapshot) then
		M.render(session)
		return notify("source context changed; select the branch again")
	end
	local token = { title = node.request.title, snapshot = node.snapshot }
	session.loading = token
	M.render(session)
	catalog.request(node.snapshot, node.request, node.options or { scope = node.scope }, function(_, err)
		if session.loading ~= token then return end
		session.loading = nil
		if err ~= nil then notify(err) end
		M.render(session)
	end)
end

local function activate(session, node)
	if node.kind == "load" or node.kind == "more" then return load(session, node) end
	if node.error ~= nil then return notify(node.error) end
	if node.kind == "empty" then return end
	local ok, err = pcall(function()
		if node.kind == "table" then
			local snapshot, apply_err = apply(session, node)
			if snapshot == nil then return notify(apply_err) end
			local win = working_window(session)
			vim.api.nvim_win_set_buf(win, snapshot.bufnr)
			node.definition.on_select(node.item, snapshot, config.options())
		elseif node.kind == "file" then
			if not vim.api.nvim_buf_is_valid(node.bufnr) then return notify("file buffer no longer exists") end
			vim.api.nvim_win_set_buf(working_window(session), node.bufnr)
		elseif node.kind == "scratchpad" then
			working_window(session)
			require("dbsh.scratch").open(node.scratchpad_id)
		elseif node.kind == "legacy" then
			local scratch = require("dbsh.scratch")
			local item, migration_err = scratch.migrate_legacy(node.connection_name)
			if item == nil then return notify(migration_err) end
			working_window(session)
			scratch.open(item.id)
		elseif node.kind == "new" then
			working_window(session)
			require("dbsh.telescope.pickers").new_scratchpad()
		end
	end)
	if not ok then notify(err) end
end

function M.action(action)
	local session = current_session()
	if session == nil or not valid_win(session.win) then return end
	local row = vim.api.nvim_win_get_cursor(session.win)[1]
	local node = session.entries[row]
	if action == "refresh" then return M.render(session) end
	if action == "expand_all" or action == "collapse_all" then
		for id, value in pairs(session.nodes) do
			if value.branch then session.closed[id] = action == "collapse_all" end
		end
		return M.render(session)
	end
	if node == nil then return end
	if action == "fetch" then
		if node.branch then session.closed[node.id] = false end
		return load(session, node)
	end
	if action == "select" then
		if node.kind ~= "connection" and node.kind ~= "database" and node.kind ~= "schema" then return end
		local _, err = apply(session, node)
		if err ~= nil then notify(err) end
		return M.render(session)
	end
	if action == "left" and (not node.branch or session.closed[node.id]) then
		return focus_entry(session, node.parent)
	elseif action == "right" and node.branch and not session.closed[node.id] then
		local child = session.entries[row + 1]
		if child ~= nil and child.parent == node.id then focus_entry(session, child.id) end
		return
	elseif node.branch then
		if action == "left" then session.closed[node.id] = true
		elseif action == "right" then session.closed[node.id] = false
		else session.closed[node.id] = not session.closed[node.id] end
		M.render(session)
	elseif action == "open" or action == "right" then
		activate(session, node)
	end
end

function M.open()
	local tab = vim.api.nvim_get_current_tabpage()
	local session = sessions[tab]
	if session ~= nil and valid_win(session.win) then
		M.render(session)
		vim.api.nvim_set_current_win(session.win)
		return session
	end
	if session == nil then
		session = { tab = tab, closed = {}, entries = {}, nodes = {} }
		sessions[tab] = session
	end
	local current_buf = vim.api.nvim_get_current_buf()
	if vim.bo[current_buf].buftype == "" then
		session.source_buf, session.source_win = current_buf, vim.api.nvim_get_current_win()
	else
		local captured = require("dbsh.results").context_snapshot(current_buf)
			or require("dbsh.csvview").context_snapshot(current_buf)
		if captured ~= nil and vim.api.nvim_buf_is_valid(captured.bufnr)
			and vim.bo[captured.bufnr].buftype == "" then
			session.source_buf = captured.bufnr
		end
	end
	if vim.api.nvim_win_get_config(0).relative ~= "" then
		for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
			if vim.api.nvim_win_get_config(win).relative == "" then
				vim.api.nvim_set_current_win(win)
				break
			end
		end
	end
	if session.bufnr == nil or not vim.api.nvim_buf_is_valid(session.bufnr) then
		session.bufnr = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_name(session.bufnr, "dbsh://panel/" .. tab)
		vim.bo[session.bufnr].buftype = "nofile"
		vim.bo[session.bufnr].bufhidden = "hide"
		vim.bo[session.bufnr].swapfile = false
		vim.bo[session.bufnr].filetype = "dbsh-panel"
		local mappings = {
			["<CR>"] = "open", ["o"] = "open", ["h"] = "left", ["<Left>"] = "left",
			["l"] = "right", ["<Right>"] = "right", ["s"] = "select",
			["r"] = "fetch", ["g"] = "refresh", ["zR"] = "expand_all", ["zM"] = "collapse_all",
		}
		for key, action in pairs(mappings) do
			vim.keymap.set("n", key, function() M.action(action) end, {
				buffer = session.bufnr, silent = true, nowait = true, desc = "dbsh panel: " .. action,
			})
		end
		vim.keymap.set("n", "q", M.close, { buffer = session.bufnr, silent = true, nowait = true })
	end
	local options = config.options().panel
	vim.cmd((options.position == "right" and "botright" or "topleft") .. " vsplit")
	session.win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(session.win, session.bufnr)
	vim.api.nvim_win_set_width(session.win, math.min(options.width, math.max(1, vim.o.columns - 20)))
	for key, value in pairs({
		number = false, relativenumber = false, wrap = false, signcolumn = "no",
		foldenable = false, winfixwidth = true, cursorline = true, spell = false,
	}) do
		vim.wo[session.win][key] = value
	end
	M.render(session)
	if session.anchor ~= nil then focus_entry(session, session.anchor)
	else vim.api.nvim_win_set_cursor(session.win, { 5, 0 }) end
	return session
end

function M.close()
	local session = current_session()
	if session == nil or not valid_win(session.win) then return end
	local node = session.entries[vim.api.nvim_win_get_cursor(session.win)[1]]
	session.anchor = node and node.id
	if #vim.api.nvim_tabpage_list_wins(session.tab) == 1 then working_window(session) end
	vim.api.nvim_win_close(session.win, false)
	session.win = nil
	if valid_win(session.source_win) then vim.api.nvim_set_current_win(session.source_win) end
end

function M.toggle()
	local session = current_session()
	if session ~= nil and valid_win(session.win) then M.close() else M.open() end
end

function M.setup()
	for _, session in pairs(sessions) do
		if session.loading ~= nil then require("dbsh.exec").cancel("introspect", session.loading.snapshot) end
		if valid_win(session.win) then
			if #vim.api.nvim_tabpage_list_wins(session.tab) == 1 then
				vim.api.nvim_win_call(session.win, function() vim.cmd("botright vnew") end)
			end
			vim.api.nvim_win_close(session.win, true)
		end
		if session.bufnr and vim.api.nvim_buf_is_valid(session.bufnr) then
			vim.api.nvim_buf_delete(session.bufnr, { force = true })
		end
	end
	sessions = {}
	local group = vim.api.nvim_create_augroup("dbsh_panel", { clear = true })
	vim.api.nvim_create_autocmd("User", {
		group = group, pattern = { "DbshCatalogChanged", "DbshContextChanged", "DbshScratchChanged" },
		callback = function()
			for _, session in pairs(sessions) do
				if session.loading ~= nil and not context.is_current(session.loading.snapshot) then
					require("dbsh.exec").cancel("introspect", session.loading.snapshot)
					session.loading = nil
				end
			end
			refresh()
		end,
	})
	vim.api.nvim_create_autocmd("BufEnter", {
		group = group,
		callback = function(args)
			local session = current_session()
			if session ~= nil and vim.bo[args.buf].buftype == "" then
				session.source_buf, session.source_win = args.buf, vim.api.nvim_get_current_win()
			end
			refresh()
		end,
	})
	vim.api.nvim_create_autocmd({ "BufAdd", "BufDelete", "BufWipeout", "BufFilePost", "BufModifiedSet", "FileType" }, {
		group = group,
		callback = function(args)
			if args.event == "BufDelete" or args.event == "BufWipeout" then
				for _, session in pairs(sessions) do
					if session.source_buf == args.buf then
						session.source_buf = nil
						if session.loading ~= nil then
							require("dbsh.exec").cancel("introspect", session.loading.snapshot)
							session.loading = nil
						end
					end
				end
			end
			if not M.is_panel(args.buf) then refresh() end
		end,
	})
	vim.api.nvim_create_autocmd("TabClosed", {
		group = group,
		callback = function()
			for tab, session in pairs(sessions) do
				if not vim.api.nvim_tabpage_is_valid(tab) then
					if session.loading ~= nil then require("dbsh.exec").cancel("introspect", session.loading.snapshot) end
					if session.bufnr and vim.api.nvim_buf_is_valid(session.bufnr) then
						vim.api.nvim_buf_delete(session.bufnr, { force = true })
					end
					sessions[tab] = nil
				end
			end
		end,
	})
end

return M
