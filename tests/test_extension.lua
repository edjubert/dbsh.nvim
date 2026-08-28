local helpers = dofile("tests/helpers.lua")
local eq, expect_match = helpers.eq, helpers.expect_match

local T = MiniTest.new_set()

T["loads without telescope installed and exports nothing"] = function()
	local extension = dofile("lua/telescope/_extensions/psql.lua")
	eq(type(extension), "table")
	eq(extension.exports, nil)
end

T["declares the four pickers in its exports table"] = function()
	local source = table.concat(vim.fn.readfile("lua/telescope/_extensions/psql.lua"), "\n")
	expect_match(source, "connections")
	expect_match(source, "databases")
	expect_match(source, "schemas")
	expect_match(source, "tables")
end

T["guards against a missing telescope"] = function()
	local source = table.concat(vim.fn.readfile("lua/telescope/_extensions/psql.lua"), "\n")
	expect_match(source, 'pcall%(require, "telescope"%)')
end

return T
