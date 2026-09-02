-- Turns the variables found in a query into a psql \set preamble, asking
-- the user for each value it does not have yet.

local config = require("psql.config")
local history = require("psql.history")
local variables = require("psql.variables")

local M = {}

-- Deferred require, and an injection point for tests: importing the pickers
-- here would drag telescope in at plugin load time.
function M.picker()
	return require("psql.telescope.pickers")
end

-- callback(preamble) gets nil when the user gives up on any prompt: a
-- half-parameterised query must never run.
function M.preamble(sql, callback)
	local names = variables.detect(sql, config.options().variable_patterns)
	if #names == 0 then
		-- Synchronous on purpose: without variables the query path has to
		-- behave exactly as it did before.
		callback("")
		return
	end

	local connection = config.current_name()
	local values = {}

	local function ask(index)
		if index > #names then
			callback(variables.preamble(names, values))
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
