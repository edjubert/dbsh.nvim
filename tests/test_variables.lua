local helpers = dofile("tests/helpers.lua")
local eq = helpers.eq

local variables = require("dbsh.variables")

local T = MiniTest.new_set()

T["finds a declared variable"] = function()
	eq(variables.detect("SELECT * FROM :raw_data;", { ":(raw_data)" }), { "raw_data" })
end

T["reports a variable only once"] = function()
	local sql = "SELECT * FROM :raw_data JOIN :raw_data USING (id);"
	eq(variables.detect(sql, { ":(raw_data)" }), { "raw_data" })
end

T["keeps the order the variables appear in"] = function()
	local sql = "SELECT * FROM :second JOIN :first USING (id);"
	eq(variables.detect(sql, { ":(second)", ":(first)" }), { "second", "first" })
end

T["finds nothing without a pattern"] = function()
	eq(variables.detect("SELECT * FROM :raw_data;", {}), {})
	eq(variables.detect("SELECT * FROM :raw_data;", nil), {})
end

T["finds every name matched by a wide pattern"] = function()
	eq(
		variables.detect("SELECT :a FROM :b;", { ":([%w_]+)" }),
		{ "a", "b" }
	)
end

return T
