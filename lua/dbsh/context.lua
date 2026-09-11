-- Runtime database contexts for dbsh.nvim.
-- Declared profiles remain immutable configuration in dbsh.config; this module
-- owns every mutable connection selection, including the fallback used by
-- ordinary buffers that have not been explicitly bound.

local config = require("dbsh.config")

local M = {}

local state = {
	fallback = nil,
	buffers = {},
	next_id = 0,
}

local LEVEL_KEYS = { "database", "schema", "role", "warehouse" }

local function concrete_bufnr(bufnr)
	if bufnr == nil or bufnr == 0 then
		return vim.api.nvim_get_current_buf()
	end
	return bufnr
end

local function next_id(kind, bufnr)
	state.next_id = state.next_id + 1
	return string.format("%s:%s:%d", kind, tostring(bufnr or "global"), state.next_id)
end

local function levels_from(connection)
	local levels = {}
	for _, key in ipairs(LEVEL_KEYS) do
		if connection ~= nil and connection[key] ~= nil then
			levels[key] = connection[key]
		end
	end
	return levels
end

local function context_for_profile(name, kind, bufnr, previous)
	if name == nil then
		return {
			id = previous and previous.id or next_id(kind, bufnr),
			kind = kind,
			bufnr = bufnr,
			scratchpad_id = previous and previous.scratchpad_id or nil,
			connection_name = nil,
			connection = nil,
			backend_name = nil,
			levels = {},
			project_root = nil,
			on_change = previous and previous.on_change or nil,
			generation = previous and previous.generation or 0,
		}
	end

	local connection, err = config.connection(name)
	if connection == nil then
		return nil, err
	end

	return {
		id = previous and previous.id or next_id(kind, bufnr),
		kind = kind,
		bufnr = bufnr,
		scratchpad_id = previous and previous.scratchpad_id or nil,
		connection_name = name,
		connection = connection,
		backend_name = connection.type or "postgres",
		levels = levels_from(connection),
		project_root = previous and previous.project_root or nil,
		on_change = previous and previous.on_change or nil,
		generation = previous and previous.generation or 0,
	}
end

local function effective(bufnr)
	return state.buffers[concrete_bufnr(bufnr)] or state.fallback
end

local function public(value)
	if value == nil then
		return nil
	end

	local result = {
		id = value.id,
		kind = value.kind,
		bufnr = value.bufnr,
		scratchpad_id = value.scratchpad_id,
		connection_name = value.connection_name,
		backend = value.backend_name,
		levels = vim.deepcopy(value.levels),
		project_root = value.project_root,
		generation = value.generation,
	}
	for key, level in pairs(value.levels) do
		result[key] = level
	end
	return result
end

local function persist(current)
	if type(current.on_change) ~= "function" then
		return
	end
	local ok, err = pcall(current.on_change, public(current))
	if not ok then
		vim.notify("dbsh.nvim: could not persist context: " .. tostring(err), vim.log.levels.ERROR)
	end
end

local function announce(bufnr, origin, previous, current)
	vim.api.nvim_exec_autocmds("User", {
		pattern = "DbshContextChanged",
		modeline = false,
		data = {
			bufnr = concrete_bufnr(bufnr),
			origin = origin,
			previous = public(previous),
			current = public(current),
		},
	})
	vim.api.nvim_exec_autocmds("User", {
		pattern = "DbshConnectionChanged",
		modeline = false,
	})
end

local function materialize_buffer(bufnr)
	bufnr = concrete_bufnr(bufnr)
	local existing = state.buffers[bufnr]
	if existing ~= nil then
		return existing
	end

	local fallback = state.fallback
	local value = vim.deepcopy(fallback)
	value.id = next_id("buffer", bufnr)
	value.kind = "buffer"
	value.bufnr = bufnr
	value.generation = 0
	state.buffers[bufnr] = value
	return value
end

function M.setup()
	state.buffers = {}
	state.next_id = 0
	local fallback, err = context_for_profile(config.default_name(), "fallback", nil, nil)
	if fallback == nil then
		error("dbsh.nvim: " .. err)
	end
	state.fallback = fallback
end

function M.current(bufnr)
	return effective(bufnr)
end

function M.snapshot(bufnr)
	local snapshot = vim.deepcopy(effective(bufnr))
	snapshot.bufnr = concrete_bufnr(bufnr)
	return snapshot
end

function M.public(value)
	return public(value)
end

function M.backend(value)
	value = value or M.current(0)
	if value == nil or value.connection == nil then
		return nil, "no current connection"
	end
	return config.backend_for(value.connection)
end

function M.bind(bufnr, connection_name, origin)
	bufnr = concrete_bufnr(bufnr)
	local previous = vim.deepcopy(effective(bufnr))
	local existing = state.buffers[bufnr]
	local current, err = context_for_profile(
		connection_name,
		existing and existing.kind or "buffer",
		bufnr,
		existing
	)
	if current == nil then
		return nil, err
	end
	current.generation = (existing and existing.generation or 0) + 1
	state.buffers[bufnr] = current
	persist(current)
	announce(bufnr, origin, previous, current)
	return current
end

function M.set_level(bufnr, key, value, origin)
	bufnr = concrete_bufnr(bufnr)
	local previous = vim.deepcopy(effective(bufnr))
	local current = materialize_buffer(bufnr)
	if current.connection == nil then
		return nil, "no current connection"
	end
	current.connection[key] = value
	current.levels[key] = value
	current.generation = current.generation + 1
	persist(current)
	announce(bufnr, origin, previous, current)
	return current
end

function M.apply(snapshot, key, value, origin)
	if snapshot == nil then
		return nil, "no current context"
	end
	return M.set_level(snapshot.bufnr, key, value, origin)
end

function M.set_global(connection_name, origin)
	local previous = vim.deepcopy(state.fallback)
	local current, err = context_for_profile(connection_name, "fallback", nil, state.fallback)
	if current == nil then
		return nil, err
	end
	current.generation = state.fallback.generation + 1
	state.fallback = current
	announce(0, origin, previous, current)
	return current
end

function M.forget(bufnr, origin)
	bufnr = concrete_bufnr(bufnr)
	local previous = state.buffers[bufnr]
	if previous == nil then
		return state.fallback
	end
	if previous.kind == "scratchpad" then
		return nil, "cannot forget a persistent context"
	end
	state.buffers[bufnr] = nil
	announce(bufnr, origin, previous, state.fallback)
	return state.fallback
end

function M.generation(value_or_bufnr)
	if type(value_or_bufnr) == "table" then
		return value_or_bufnr.generation
	end
	return effective(value_or_bufnr).generation
end

function M.is_current(snapshot)
	if snapshot == nil then
		return false
	end
	local current = effective(snapshot.bufnr)
	return current ~= nil and current.id == snapshot.id and current.generation == snapshot.generation
end

function M.attach(bufnr, value)
	bufnr = concrete_bufnr(bufnr)
	local current = vim.deepcopy(value)
	current.id = current.id or next_id("scratchpad", bufnr)
	current.kind = current.kind or "scratchpad"
	current.scratchpad_id = current.scratchpad_id or current.id
	current.bufnr = bufnr
	current.connection = current.connection and vim.deepcopy(current.connection) or nil
	current.levels = vim.deepcopy(current.levels or levels_from(current.connection))
	if current.connection ~= nil then
		for key, level in pairs(current.levels) do
			current.connection[key] = level
		end
	end
	current.backend_name = current.backend_name
		or (current.connection and (current.connection.type or "postgres"))
	current.generation = current.generation or 0
	state.buffers[bufnr] = current
	return current
end

function M.detach(bufnr)
	bufnr = concrete_bufnr(bufnr)
	local previous = state.buffers[bufnr]
	state.buffers[bufnr] = nil
	return previous
end

function M.resolved_project_root(snapshot)
	snapshot = snapshot or M.snapshot(0)
	if type(snapshot.project_root) == "string" and snapshot.project_root ~= "" then
		return snapshot.project_root
	end
	return vim.fs.joinpath(vim.fn.stdpath("data"), "dbsh", "lsp")
end

function M.resolved_search_path(snapshot)
	snapshot = snapshot or M.snapshot(0)
	local search_path, seen = {}, {}
	local function append(schema)
		if type(schema) == "string" and schema ~= "" and not seen[schema] then
			seen[schema] = true
			table.insert(search_path, schema)
		end
	end

	local connection = snapshot.connection or {}
	append((snapshot.levels or {}).schema or connection.schema)
	local configured = connection.search_path
	if type(configured) == "string" then
		append(configured)
	elseif type(configured) == "table" then
		for _, schema in ipairs(configured) do
			append(schema)
		end
	end
	return search_path
end

return M
