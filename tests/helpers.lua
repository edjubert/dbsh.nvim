-- Shared test helpers.
-- Loaded with dofile("tests/helpers.lua"): require() only searches lua/.

local M = {}

M.eq = MiniTest.expect.equality
M.neq = MiniTest.expect.no_equality

-- mini.test has no built-in pattern expectation. This is the documented
-- way to add one.
M.expect_match = MiniTest.new_expectation("string matching", function(str, pattern)
	return type(str) == "string" and str:find(pattern) ~= nil
end, function(str, pattern)
	return string.format(
		"Pattern: %s\nObserved: %s",
		vim.inspect(pattern),
		vim.inspect(str)
	)
end)

return M
