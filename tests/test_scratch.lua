local helpers = dofile("tests/helpers.lua")
local eq = helpers.eq

local config = require("psql.config")
local scratch = require("psql.scratch")

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			config.setup({
				connections = {
					local_db = { host = "localhost", port = 5432, database = "postgres", username = "dev" },
				},
				default = "local_db",
			})
		end,
	},
})

T["stores scratchpads under the data directory"] = function()
	eq(scratch.dir(), vim.fs.joinpath(vim.fn.stdpath("data"), "psql"))
end

T["names the file after the connection"] = function()
	eq(scratch.path("local_db"), vim.fs.joinpath(scratch.dir(), "local_db.sql"))
end

T["falls back to a default name"] = function()
	eq(scratch.path(nil), vim.fs.joinpath(scratch.dir(), "default.sql"))
end

T["opens the scratchpad of the current connection as a sql buffer"] = function()
	local path = scratch.open()
	eq(path, scratch.path("local_db"))
	eq(vim.bo.filetype, "sql")
	eq(vim.api.nvim_buf_get_name(0), path)
	eq(vim.fn.isdirectory(scratch.dir()), 1)
end

T["uses the default scratchpad when no connection is selected"] = function()
	config.setup({ connections = {} })
	local path = scratch.open()
	eq(path, scratch.path("default"))
end

return T
