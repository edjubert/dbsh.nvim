-- Asynchronous CLI runner.
-- Every invocation owns an immutable context snapshot, and process slots are
-- scoped by that snapshot's session ID.

local config = require("dbsh.config")
local context = require("dbsh.context")

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
	local tmpfile = M.write_script(backend, sql, mode)
	local slots = slots_for(snapshot, true)
	local operation = {}
	slots[slot] = operation
	local handle = M.runner(
		backend.argv(snapshot.connection, tmpfile, mode),
		{
			text = true,
			timeout = opts.timeout or config.options().query_timeout,
			env = backend.env(snapshot.connection, config.options()),
		},
		vim.schedule_wrap(function(obj)
			os.remove(tmpfile)
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
