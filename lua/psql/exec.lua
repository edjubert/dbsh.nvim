-- Asynchronous psql runner.
-- Never blocks the editor, never prompts for a password: authentication is
-- delegated to ~/.pgpass through psql's own resolution.

local config = require("psql.config")

local M = {}

-- Injection point: tests replace this with a fake runner.
M.runner = vim.system

-- One in-flight handle per slot, so opening a picker does not cancel a user query.
M.slots = { user = nil, introspect = nil }

local PRETTY_PREAMBLE = table.concat({
	"\\set QUIET 1",
	"\\timing on",
	"\\pset null (NULL)",
	"\\pset linestyle unicode",
	"\\pset border 2",
}, "\n")

local RAW_PREAMBLE = table.concat({
	"\\set QUIET 1",
	"\\set ON_ERROR_STOP 1",
}, "\n")

-- -X ignores ~/.psqlrc, -w never prompts for a password.
function M.build_argv(conn, tmpfile, raw)
	local argv = {
		"psql", "-X", "-w",
		"-h", conn.host,
		"-p", tostring(conn.port),
		"-U", conn.username,
		"-d", conn.database,
	}
	if raw then
		vim.list_extend(argv, { "-A", "-t", "-F", "\t" })
	end
	vim.list_extend(argv, { "-f", tmpfile })
	return argv
end

function M.write_script(sql, raw)
	local path = os.tmpname()
	local fd = assert(io.open(path, "w"))
	fd:write(raw and RAW_PREAMBLE or PRETTY_PREAMBLE)
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

-- opts: { raw = boolean?, slot = "user"|"introspect"?, timeout = number? }
-- callback(code, stdout, stderr)
function M.run(sql, opts, callback)
	opts = opts or {}
	local slot = opts.slot or "user"

	local conn = config.current()
	if conn == nil then
		callback(1, "", "psql.nvim: no current connection")
		return nil
	end

	M.cancel(slot)

	local generation = config.generation()
	local tmpfile = M.write_script(sql, opts.raw)

	local handle = M.runner(
		M.build_argv(conn, tmpfile, opts.raw),
		{
			text = true,
			timeout = opts.timeout or config.options().query_timeout,
			env = { PGCONNECT_TIMEOUT = tostring(config.options().connect_timeout) },
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
