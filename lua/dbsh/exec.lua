-- Asynchronous CLI runner.
-- Every invocation owns an immutable context snapshot, so callbacks cannot
-- render into a buffer whose connection changed while the process was running.

local config = require("dbsh.config")
local context = require("dbsh.context")

local M = {}

M.runner = vim.system
M.slots = { user = nil, introspect = nil }

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

function M.cancel(slot)
	slot = slot or "user"
	local handle = M.slots[slot]
	if handle ~= nil then
		pcall(function()
			handle:kill(15)
		end)
		M.slots[slot] = nil
	end
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

	M.cancel(slot)

	local mode = opts.mode or "pretty"
	local tmpfile = M.write_script(backend, sql, mode)
	local handle = M.runner(
		backend.argv(snapshot.connection, tmpfile, mode),
		{
			text = true,
			timeout = opts.timeout or config.options().query_timeout,
			env = backend.env(snapshot.connection, config.options()),
		},
		vim.schedule_wrap(function(obj)
			os.remove(tmpfile)
			M.slots[slot] = nil
			if not context.is_current(snapshot) then
				return
			end
			callback(obj.code, obj.stdout or "", obj.stderr or "")
		end)
	)

	M.slots[slot] = handle
	return handle
end

return M
