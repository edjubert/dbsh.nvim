-- Read-only DDL buffers keyed by catalog-object identity.

local context = require("dbsh.context")
local exec = require("dbsh.exec")

local M = {}

local state = {
	by_key = {},
	by_buf = {},
	last = {},
}

local function selected_object(object)
	if type(object) == "table" and type(object.value) == "table" then
		return object.value
	end
	return object
end

local function normalized_levels(snapshot)
	local levels = {}
	for key, value in pairs(snapshot.levels or {}) do
		table.insert(levels, { key = key, value = value })
	end
	table.sort(levels, function(a, b) return a.key < b.key end)
	return levels
end

local function public_connection(snapshot)
	local connection = snapshot.connection or {}
	return {
		name = snapshot.connection_name,
		host = connection.host,
		port = connection.port,
		username = connection.username,
		database = connection.database,
	}
end

local function object_identity(object)
	object = selected_object(object) or {}
	local identity = {
		kind = object.kind,
		oid = object.oid and tostring(object.oid) or nil,
	}
	if identity.oid == nil then
		identity.qualified_name = {
			schema = object.schema,
			relation = object.relation and object.relation.name or nil,
			name = object.name,
		}
	end
	return identity
end

function M.key(snapshot, object)
	local backend = snapshot.backend_name
		or (snapshot.connection and snapshot.connection.type)
		or "postgres"
	return vim.json.encode({
		backend = backend,
		connection = public_connection(snapshot),
		levels = normalized_levels(snapshot),
		object = object_identity(object),
	})
end

local function label(object)
	object = selected_object(object) or {}
	local qualified = {}
	if object.schema ~= nil then
		table.insert(qualified, object.schema)
	end
	if object.relation ~= nil and object.relation.name ~= nil then
		table.insert(qualified, object.relation.name)
	end
	if object.name ~= nil then
		table.insert(qualified, object.name)
	end
	local name = #qualified > 0 and table.concat(qualified, ".") or tostring(object.oid)
	return string.format("%s  [%s]", name, object.kind or "object")
end

function M.find_win(buf)
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_get_buf(win) == buf then
			return win
		end
	end
	return nil
end

local function forget(record)
	if record == nil then
		return
	end
	state.by_key[record.key] = nil
	state.by_buf[record.bufnr] = nil
	for session_id in pairs(record.session_ids or { [record.session_id] = true }) do
		if state.last[session_id] == record.key then
			state.last[session_id] = nil
		end
	end
	if record.bufnr ~= nil then
		context.detach(record.bufnr)
	end
end

local function valid(record)
	if record == nil then
		return false
	end
	if record.bufnr == nil or not vim.api.nvim_buf_is_valid(record.bufnr) then
		forget(record)
		return false
	end
	return true
end

local function set_lines(record, lines)
	if not valid(record) then
		return
	end
	vim.bo[record.bufnr].modifiable = true
	vim.api.nvim_buf_set_lines(record.bufnr, 0, -1, true, lines)
	vim.bo[record.bufnr].modifiable = false
end

local function render(record, output)
	set_lines(record, vim.split(output or "", "\n", { plain = true }))
end

local function render_error(record, err)
	render(record, "-- dbsh.nvim: " .. tostring(err))
end

local function focus(record)
	if not valid(record) then
		return nil
	end
	local win = M.find_win(record.bufnr)
	if win ~= nil then
		vim.api.nvim_set_current_win(win)
		return record
	end
	local current = state.by_buf[vim.api.nvim_get_current_buf()]
	if current ~= nil and current.key ~= record.key then
		vim.cmd("split")
	end
	win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(win, record.bufnr)
	return record
end

function M.focus(record)
	return focus(record)
end

local function create(snapshot, object, request, key)
	local record = {
		key = key,
		session_id = snapshot.id,
		session_ids = { [snapshot.id] = true },
		snapshot = vim.deepcopy(snapshot),
		object = vim.deepcopy(selected_object(object)),
		request = vim.deepcopy(request),
		label = label(object),
	}
	local buf = vim.api.nvim_create_buf(false, true)
	record.bufnr = buf
	vim.api.nvim_buf_set_name(buf, "__DBSH_DDL__ " .. record.label .. " #" .. vim.fn.sha256(key):sub(1, 8))
	vim.api.nvim_buf_set_var(buf, "dbsh_definition_key", key)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].swapfile = false
	vim.bo[buf].filetype = "sql"
	vim.bo[buf].modifiable = false

	local execution_snapshot = vim.deepcopy(snapshot)
	execution_snapshot.bufnr = buf
	context.attach(buf, execution_snapshot)
	record.execution_snapshot = context.snapshot(buf)

	state.by_key[key] = record
	state.by_buf[buf] = record
	state.last[record.session_id] = key
	vim.api.nvim_create_autocmd("BufWipeout", {
		buffer = buf,
		once = true,
		callback = function() forget(record) end,
	})
	return record
end

local function execute(record, request, callback)
	if request.kind == "sql" then
		exec.run(request.sql, {
			context = record.execution_snapshot,
			mode = "raw",
			slot = "definition",
		}, callback)
		return
	end
	if request.kind == "argv" then
		exec.run_argv(record.execution_snapshot, request, callback)
		return
	end
	callback(1, "", "definition request is malformed")
end

local function refresh(record)
	if not valid(record) then
		return false, "definition buffer no longer exists"
	end
	set_lines(record, { "-- Loading definition…" })
	execute(record, record.request, function(code, stdout, stderr)
		if not valid(record) then
			return
		end
		if code == 0 then
			render(record, stdout)
			return
		end
		local fallback = record.request.fallback
		if fallback ~= nil then
			execute(record, fallback, function(fallback_code, fallback_stdout, fallback_stderr)
				if fallback_code == 0 then
					render(record, fallback_stdout)
				else
					render_error(record, fallback_stderr ~= "" and fallback_stderr or fallback_stdout)
				end
			end)
			return
		end
		render_error(record, stderr ~= "" and stderr or stdout)
	end)
	return true
end

function M.open(snapshot, object)
	if snapshot == nil or snapshot.connection == nil then
		return nil, "no current connection"
	end
	local key = M.key(snapshot, object)
	local existing = state.by_key[key]
	if valid(existing) then
		state.last[snapshot.id] = existing.key
		existing.session_ids[snapshot.id] = true
		focus(existing)
		return existing
	end

	local backend, backend_err = context.backend(snapshot)
	if backend == nil then
		return nil, backend_err
	end
	if type(backend.definition_request) ~= "function" then
		return nil, "definition is not available for this backend"
	end
	local request, request_err = backend.definition_request(snapshot, selected_object(object))
	if request == nil then
		return nil, request_err
	end
	local record = create(snapshot, object, request, key)
	focus(record)
	refresh(record)
	return record
end

function M.list(snapshot)
	local records = {}
	for _, record in pairs(state.by_key) do
		if valid(record) and record.session_ids[snapshot.id] then
			table.insert(records, record)
		end
	end
	table.sort(records, function(a, b) return a.label < b.label end)
	return records
end

local function record_for(snapshot, bufnr)
	local current = state.by_buf[bufnr or vim.api.nvim_get_current_buf()]
	if valid(current) and (snapshot == nil or current.session_ids[snapshot.id]) then
		return current
	end
	if snapshot == nil then
		return nil
	end
	return state.by_key[state.last[snapshot.id]]
end

function M.refresh(bufnr)
	local record = record_for(nil, bufnr)
	if record == nil then
		return false, "no definition buffer selected"
	end
	return refresh(record)
end

function M.toggle(snapshot)
	local record = record_for(snapshot)
	if not valid(record) then
		return false
	end
	local win = M.find_win(record.bufnr)
	if win ~= nil then
		vim.api.nvim_win_close(win, false)
	else
		focus(record)
	end
	return true
end

function M.close(snapshot)
	for _, record in ipairs(M.list(snapshot)) do
		local win = M.find_win(record.bufnr)
		if win ~= nil then
			vim.api.nvim_win_close(win, false)
		end
	end
end

function M._reset()
	for _, record in pairs(vim.deepcopy(state.by_key)) do
		if record.bufnr ~= nil and vim.api.nvim_buf_is_valid(record.bufnr) then
			context.detach(record.bufnr)
			vim.api.nvim_buf_delete(record.bufnr, { force = true })
		end
	end
	state.by_key = {}
	state.by_buf = {}
	state.last = {}
end

return M
