-- Turns the variables found in a query into the preamble its backend uses to
-- declare them, asking the user for each value it does not have yet.

local config = require("dbsh.config")
local context = require("dbsh.context")
local history = require("dbsh.history")
local variables = require("dbsh.variables")

local M = {}

-- Deferred require, and an injection point for tests: importing the pickers
-- here would drag telescope in at plugin load time.
function M.picker()
	return require("dbsh.telescope.pickers")
end

-- callback(preamble) gets nil when the user gives up on any prompt: a
-- half-parameterised query must never run.
function M.preamble(sql, snapshot, callback)
	if callback == nil then
		callback = snapshot
		snapshot = context.snapshot(0)
	end

	local names = variables.detect(sql, config.options().variable_patterns)
	if #names == 0 then
		-- Synchronous on purpose: without variables the query path has to
		-- behave exactly as it did before.
		callback("")
		return
	end

	local connection = snapshot.connection_name
	local values = {}

	local function ask(index)
		if index > #names then
			local backend, err = context.backend(snapshot)
			if backend == nil then
				vim.notify("dbsh.nvim: " .. err, vim.log.levels.ERROR)
				callback(nil)
				return
			end
			callback(backend.variable_preamble(names, values))
			return
		end

		local name = names[index]
		M.picker().variable(name, history.values(connection, name), function(value)
			if value == nil or value == "" then
				callback(nil)
				return
			end
			values[name] = value
			history.record(connection, name, value)
			ask(index + 1)
		end)
	end

	ask(1)
end

return M
