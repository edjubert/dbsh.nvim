local helpers = dofile("tests/helpers.lua")
local eq = helpers.eq

local T = MiniTest.new_set()

T["runs on neovim 0.10 or later"] = function()
	eq(vim.fn.has("nvim-0.10"), 1)
end

T["exposes vim.system"] = function()
	eq(type(vim.system), "function")
end

T["exposes vim.fn.getregion"] = function()
	eq(vim.fn.exists("*getregion"), 1)
end

return T
