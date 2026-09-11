-- Asynchronous CLI runner.
-- Every invocation owns an immutable context snapshot, and process slots are
-- scoped by that snapshot's session ID.

local config = require("dbsh.config")
local context = require("dbsh.context")
local credentials = require("dbsh.credentials")

local M = {}

M.runner = vim.system
M.slots = {}

local function snapshot_for(value)
	if type(value) == "table" then
		return value
	end
	return context.snapshot(value or 0)
end

local function slots_for(snapshot, create)
	local slots = M.slots[snapshot.id]
	if slots == nil and create then
		slots = {}
		M.slots[snapshot.id] = slots
	end
	return slots
end

local function prune_slots(snapshot, slots)
	if slots.user == nil and slots.introspect == nil and slots.definition == nil then
		M.slots[snapshot.id] = nil
	end
end

function M.write_script(backend, sql, mode)
	local path = os.tmpname()
	local fd = assert(io.open(path, "w"))
	fd:write(backend.preamble(mode))
	fd:write("\n")
	fd:write(sql)
	fd:write("\n")
	fd:close()
	return path
end

function M.cancel(slot, snapshot_or_bufnr)
	slot = slot or "user"
	local snapshot = snapshot_for(snapshot_or_bufnr)
	local slots = slots_for(snapshot, false)
	if slots == nil then
		return
	end

	local entry = slots[slot]
	if entry == nil then
		return
	end
	local handle = entry.handle or entry
	if handle ~= nil then
		pcall(function()
			handle:kill(15)
		end)
	end
	slots[slot] = nil
	prune_slots(snapshot, slots)
end

-- opts: {
--   context = dbsh.context.snapshot()?,
--   mode = "pretty"|"raw"?,
--   slot = "user"|"introspect"?,
--   timeout = number?,
-- }
-- callback(code, stdout, stderr)
function M.run(sql, opts, callback)
	opts = opts or {}
	local slot = opts.slot or "user"
	local snapshot = opts.context or context.snapshot(0)

	if snapshot.connection == nil then
		callback(1, "", "dbsh.nvim: no current connection")
		return nil
	end

	local backend, err = context.backend(snapshot)
	if backend == nil then
		callback(1, "", "dbsh.nvim: " .. err)
		return nil
	end

	M.cancel(slot, snapshot)

	local mode = opts.mode or "pretty"
	local slots = slots_for(snapshot, true)
	local operation = {}
	local retry_count = 0
	slots[slot] = operation

	local function is_active()
		local current_slots = slots_for(snapshot, false)
		if current_slots == nil then
			return false
		end
		local active = current_slots[slot]
		return active == operation or active == operation.handle
	end

	local function discard_operation()
		local current_slots = slots_for(snapshot, false)
		if current_slots == nil then
			return false
		end
		local active = current_slots[slot]
		if active ~= operation and active ~= operation.handle then
			return false
		end
		current_slots[slot] = nil
		prune_slots(snapshot, current_slots)
		return true
	end

	local prepare_then_execute

	local function should_retry(obj, runtime)
		if retry_count ~= 0
			or type(backend.is_authentication_error) ~= "function"
			or type(runtime) ~= "table"
			or runtime.credential_backed ~= true
			or type(runtime.credential_key) ~= "string"
			or runtime.credential_key == ""
			or obj.code == 0 then
			return false
		end
		local ok, is_authentication_error = pcall(
			backend.is_authentication_error,
			obj.stderr or "",
			obj.stdout or ""
		)
		return ok and is_authentication_error == true
	end

	local function execute(runtime)
		if not context.is_current(snapshot) then
			discard_operation()
			return nil
		end
		if not is_active() then
			return nil
		end

		local tmpfile = M.write_script(backend, sql, mode)
		local handle = M.runner(
			backend.argv(snapshot.connection, tmpfile, mode, runtime),
			{
				text = true,
				timeout = opts.timeout or config.options().query_timeout,
				env = backend.env(snapshot.connection, config.options(), runtime),
			},
			vim.schedule_wrap(function(obj)
				os.remove(tmpfile)
				if not is_active() then
					return
				end
				if not context.is_current(snapshot) then
					discard_operation()
					return
				end
				if should_retry(obj, runtime) then
					retry_count = retry_count + 1
					credentials.invalidate(runtime.credential_key)
					slots = slots_for(snapshot, true)
					slots[slot] = operation
					operation.handle = nil
					prepare_then_execute()
					return
				end
				if not discard_operation() then
					return
				end
				callback(obj.code, obj.stdout or "", obj.stderr or "")
			end)
		)

		operation.handle = handle
		if slots[slot] == operation then
			slots[slot] = handle
		end
		return handle
	end

	prepare_then_execute = function()
		local prepared_once = false
		local function prepared(runtime, prepare_err)
			if prepared_once then
				return nil
			end
			prepared_once = true
			if prepare_err ~= nil or type(runtime) ~= "table" then
				if discard_operation() then
					callback(1, "", "dbsh.nvim: backend preparation failed")
				end
				return nil
			end
			return execute(runtime)
		end
		if type(backend.prepare) == "function" then
			return backend.prepare(snapshot, config.options(), prepared)
		end
		return prepared({})
	end

	return prepare_then_execute()
end

-- Runs a backend-provided command (for example pg_dump) without materialising
-- a temporary SQL script. Definition requests get their own session-local
-- slot, so refreshing DDL never cancels a user query or catalog request.
function M.run_argv(snapshot_or_bufnr, request, callback)
	local snapshot = snapshot_for(snapshot_or_bufnr)
	request = request or {}
	if snapshot.connection == nil then
		callback(1, "", "dbsh.nvim: no current connection")
		return nil
	end
	if type(request.argv) ~= "table" or #request.argv == 0 then
		callback(1, "", "dbsh.nvim: definition request has no argv")
		return nil
	end

	local slot = "definition"
	M.cancel(slot, snapshot)

	local slots = slots_for(snapshot, true)
	local operation = {}
	slots[slot] = operation
	local handle = M.runner(
		request.argv,
		{
			text = true,
			timeout = request.timeout or config.options().query_timeout,
			env = request.env or {},
		},
		vim.schedule_wrap(function(obj)
			local current_slots = slots_for(snapshot, false)
			if current_slots == nil then
				return
			end
			local active = current_slots[slot]
			if active ~= operation and active ~= operation.handle then
				return
			end
			current_slots[slot] = nil
			prune_slots(snapshot, current_slots)
			if not context.is_current(snapshot) then
				return
			end
			callback(obj.code, obj.stdout or "", obj.stderr or "")
		end)
	)

	operation.handle = handle
	if slots[slot] == operation then
		slots[slot] = handle
	end
	return handle
end

return M
