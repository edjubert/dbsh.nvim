local helpers = dofile("tests/helpers.lua")
local eq, expect_match = helpers.eq, helpers.expect_match

local T = MiniTest.new_set()

T["loads without telescope installed and exports nothing"] = function()
	local extension = dofile("lua/telescope/_extensions/dbsh.lua")
	eq(type(extension), "table")
	eq(extension.exports, nil)
end

T["declares the connection and level pickers in its exports table"] = function()
	local source = table.concat(vim.fn.readfile("lua/telescope/_extensions/dbsh.lua"), "\n")
	expect_match(source, "connections")
	expect_match(source, "level")
end

T["guards against a missing telescope"] = function()
	local source = table.concat(vim.fn.readfile("lua/telescope/_extensions/dbsh.lua"), "\n")
	expect_match(source, 'pcall%(require, "telescope"%)')
end

return T
