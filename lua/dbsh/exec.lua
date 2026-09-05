-- Asynchronous CLI runner.
-- Never blocks the editor and never prompts for a password: everything the
-- invocation needs -- argv, environment, script preamble -- comes from the
-- backend of the current connection, so this module knows no CLI at all.

local config = require("dbsh.config")

local M = {}

-- Injection point: tests replace this with a fake runner.
M.runner = vim.system

-- One in-flight handle per slot, so opening a picker does not cancel a user query.
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

-- opts: { mode = "pretty"|"raw"?, slot = "user"|"introspect"?, timeout = number? }
-- callback(code, stdout, stderr)
function M.run(sql, opts, callback)
	opts = opts or {}
	local slot = opts.slot or "user"

	local conn = config.current()
	if conn == nil then
		callback(1, "", "dbsh.nvim: no current connection")
		return nil
	end

	-- Resolved before cancelling anything: killing the running query only to
	-- fail on a misconfigured connection would help nobody.
	local backend, err = config.backend()
	if backend == nil then
		callback(1, "", "dbsh.nvim: " .. err)
		return nil
	end

	M.cancel(slot)

	local mode = opts.mode or "pretty"
	local generation = config.generation()
	local tmpfile = M.write_script(backend, sql, mode)

	local handle = M.runner(
		backend.argv(conn, tmpfile, mode),
		{
			text = true,
			timeout = opts.timeout or config.options().query_timeout,
			env = backend.env(conn, config.options()),
		},
		vim.schedule_wrap(function(obj)
			os.remove(tmpfile)
			M.slots[slot] = nil
			-- Drop results that belong to a connection we already left.
			if generation ~= config.generation() then
				return
			end
			callback(obj.code, obj.stdout or "", obj.stderr or "")
		end)
	)

	M.slots[slot] = handle
	return handle
end

return M
